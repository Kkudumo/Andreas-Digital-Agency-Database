-- PERMANENT: the private file store of the Documents module - who may put a file where, who may read it, that files are write-once, that paths cannot be
-- forged, that anonymous callers get nothing, and that a hidden document answers exactly as a missing one. The module's own rules (document_can) are the authority.
begin;
select tests.setup();
select tests.setup_hr();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.put(p_user text, p_doc uuid, p_ext text default 'docx') returns text language plpgsql as $$
declare v_name text := p_doc || '/' || gen_random_uuid() || '.' || p_ext;
begin
  return tests.try(p_user, format($q$ insert into storage.objects (bucket_id, name) values ('documents', %L) $q$, v_name));
end $$;

-- The bucket ------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('the bucket is private, limited to 50 MB and to Word / Excel / PDF', (select concat_ws('|', public::text, file_size_limit::text, cardinality(allowed_mime_types)::text) from storage.buckets where id = 'documents'), 'false|52428800|3');
select tests.check('only the two policies exist (read, add): no update, no delete', (select string_agg(cmd, ',' order by cmd) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'documents\_%'), 'INSERT,SELECT');
select tests.check('no storage bucket has an update or delete policy for anyone', (select count(*)::text from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE', 'DELETE', 'ALL')), '0');
select tests.check('anonymous callers cannot run the policy helper', has_function_privilege('anon', 'document_storage_can(text, text)', 'execute')::text || '|' || has_function_privilege('authenticated', 'document_storage_can(text, text)', 'execute')::text, 'false|true');

-- A Web document, a Tech document, a restricted one --------------------------------------------------------------------------------------------------------
select tests.mk_doc('web_lead', 'web', 'Web proposal', 'proposal', 'web');
select tests.mk_doc('tech_staff', 'tech', 'Tech note', 'report', 'tech');
select tests.mk_doc('ceo', 'secret', 'Board paper', 'legal', 'web', null, 'restricted');

select tests.check('the owner may put a Word file, an Excel file and a PDF on their document', concat_ws(',', tests.put('web_lead', tests.id('doc:web'), 'docx'), tests.put('web_lead', tests.id('doc:web'), 'xlsx'), tests.put('web_lead', tests.id('doc:web'), 'pdf')), 'ok,ok,ok');
select tests.check('another division may not put a file on it', concat_ws(',', tests.put('tech_staff', tests.id('doc:web')), tests.put('tech_staff', tests.id('doc:secret'))), 'ERR:42501,ERR:42501');
select tests.check('the CEO may put a file on any document', tests.put('ceo', tests.id('doc:web')) || ',' || tests.put('ceo', tests.id('doc:tech')) || ',' || tests.put('ceo', tests.id('doc:secret')), 'ok,ok,ok');
select tests.check('a division lead may not put a file on a restricted document they cannot see', tests.put('web_lead', tests.id('doc:secret')), 'ERR:42501');
select tests.check('a hidden document and a made-up id are refused identically (no existence leak)', tests.same_for('web_lead', $q$ insert into storage.objects (bucket_id, name) values ('documents', %L || '/' || gen_random_uuid() || '.docx') $q$, tests.id('doc:secret'), tests.id('x:random')), 'same');
select tests.check('anonymous and non-staff callers cannot add or read anything', concat_ws(',',
  tests.scalar_anon(format($q$ insert into storage.objects (bucket_id, name) values ('documents', %L) returning 'ok' $q$, tests.id('doc:web') || '/' || gen_random_uuid() || '.docx')), tests.scalar_anon($q$ select count(*)::text from storage.objects $q$),
  tests.put('outsider', tests.id('doc:web')), tests.put('suspended', tests.id('doc:web'))), 'ERR:42501,ERR:42501,ERR:42501,ERR:42501');

-- Paths cannot be forged ---------------------------------------------------------------------------------------------------------------------------------------
select tests.check('names that are not <document>/<version>.<docx|xlsx|pdf> are refused: no document part, a plain name, a wrong type, upper case, a traversal, another bucket (refused before it is even looked up)',
  concat_ws(',', tests.try('ceo', $q$ insert into storage.objects (bucket_id, name) values ('documents', 'loose.docx') $q$),
    tests.try('ceo', format($q$ insert into storage.objects (bucket_id, name) values ('documents', %L) $q$, tests.id('doc:web') || '/x.docx')),
    tests.try('ceo', format($q$ insert into storage.objects (bucket_id, name) values ('documents', %L) $q$, tests.id('doc:web') || '/' || gen_random_uuid() || '.exe')),
    tests.try('ceo', format($q$ insert into storage.objects (bucket_id, name) values ('documents', upper(%L)) $q$, tests.id('doc:web') || '/' || gen_random_uuid() || '.docx')),
    tests.try('ceo', format($q$ insert into storage.objects (bucket_id, name) values ('documents', %L) $q$, tests.id('doc:web') || '/../' || gen_random_uuid() || '.docx')),
    tests.try('ceo', format($q$ insert into storage.objects (bucket_id, name) values ('avatars', %L) $q$, tests.id('doc:web') || '/' || gen_random_uuid() || '.docx'))),
  'ERR:42501,ERR:42501,ERR:42501,ERR:42501,ERR:42501,ERR:42501');

-- Reading ---------------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('the Web owner and the CEO see the Web document''s files; the Tech user and the outsider see none of them',
  concat_ws(',', tests.scalar('web_lead', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:web') || '/%')), tests.scalar('ceo', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:web') || '/%')),
    tests.scalar('tech_staff', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:web') || '/%')), tests.scalar('outsider', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:web') || '/%'))),
  '4,4,0,0');
select tests.check('the restricted document''s file is invisible to the division lead and visible to the CEO', concat_ws(',', tests.scalar('web_lead', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:secret') || '/%')), tests.scalar('ceo', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:secret') || '/%'))), '0,1');

-- Write-once ---------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('nobody can rename, overwrite or delete a stored file, not the owner and not the CEO',
  concat_ws(',', tests.scalar('web_lead', format($q$ with u as (update storage.objects set name = name || 'x' where name like %L returning 1) select count(*)::text from u $q$, tests.id('doc:web') || '/%')),
    tests.scalar('ceo', format($q$ with d as (delete from storage.objects where name like %L returning 1) select count(*)::text from d $q$, tests.id('doc:web') || '/%')),
    tests.scalar('ceo', format($q$ select count(*)::text from storage.objects where name like %L $q$, tests.id('doc:web') || '/%'))), '0,0,4');

-- The module's own flow: a version is recorded by reference, opened (logged) and the key points at the stored file --------------------------------------------
select tests.check('the version is recorded by reference, opened through document_open (which logs it), and the returned key is the stored path',
  tests.scalar('web_lead', format($q$ select (document_add_version(%L, 'supabase', %L, repeat('a', 64), 1234, 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'proposal.docx', 'v1')) ->> 'version_no' $q$, tests.id('doc:web'), tests.id('doc:web') || '/00000000-0000-4000-8000-0000000000aa.docx'))
  || '|' || tests.scalar('web_lead', format($q$ select (document_open(%L, 'read') ->> 'storage_key') = %L || '/00000000-0000-4000-8000-0000000000aa.docx' $q$, tests.id('doc:web'), tests.id('doc:web'))), '1|true');
select tests.check('that open was logged against the acting staff member (visible to the CEO)', tests.scalar('ceo', format($q$ select count(*)::text from document_events where document_id = %L and kind = 'opened' and actor_staff_id = %L $q$, tests.id('doc:web'), tests.id('staff:web_lead'))), '1');
select tests.check('another division gets NULL from document_open, exactly as for a made-up document', tests.same_for('tech_staff', $q$ select coalesce(document_open(%L, 'read')::text, 'null') $q$, tests.id('doc:web'), tests.id('x:random')), 'same');
select tests.finish();
rollback;
