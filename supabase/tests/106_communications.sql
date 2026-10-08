-- PERMANENT: Communications - identity, threads and messages (order, immutability, hash), participants by reference, links, attachments as Documents,
-- lifecycle, retention / legal holds / two-person disposal, historical retrieval, events and audit.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.thr_status(p_key text) returns text language sql as $$ select status::text from communication_threads where id = tests.id('thr:' || p_key) $$;
create function tests.msg_count(p_key text) returns text language sql as $$ select count(*)::text from communication_messages where thread_id = tests.id('thr:' || p_key) $$;
create function tests.seqs(p_key text) returns text language sql as $$ select string_agg(seq::text, ',' order by seq) from communication_messages where thread_id = tests.id('thr:' || p_key) $$;

-- Identity ------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('the web lead starts a thread: it comes back with an institutional ID, status open, origin division web', (tests.mk_thread('web_lead', 'a', 'Website quote follow-up') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the thread is a registered entity (type communication) with a well-formed opaque ID, no legacy alias, NO label (a subject is content)',
  (select concat_ws('|', (r.institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, (r.ada_id is null)::text, r.entity_family, r.entity_type, r.table_name, (r.origin_division_id = tests.id('div:web'))::text, r.origin_kind, r.status)
     from entity_registry r where r.entity_id = tests.id('thr:a') and r.table_name = 'communication_threads'), 'true|true|operations|communication|communication_threads|true|created|open');
select tests.check('the web lead records the first message', (tests.say('web_lead', 'a', 'a1', 'email', 'inbound', 'Hi, can you quote a website?') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('a message is its own registered entity (type communication_message), distinct from its thread',
  (select concat_ws('|', (r.institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, r.entity_type, r.table_name, (r.institutional_id <> tests.inst('communication_threads', 'thr:a'))::text, r.status)
     from entity_registry r where r.entity_id = tests.id('msg:a1')), 'true|communication_message|communication_messages|true|recorded');
select tests.check('neither type is public; both are built; the codebook knows both codes', (select string_agg((not publishable and is_built)::text || (c.code = t.id_code)::text, ',' order by t.key)
                      from entity_types t join id_codebook c on c.kind = 'type' and c.meaning = t.key where t.key in ('communication', 'communication_message')), 'truetrue,truetrue');
select tests.check('communications have no ID input and no generator of their own', (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns
                      where table_name in ('communication_threads', 'communication_messages') and column_name ~ 'institutional|ada_id|number|code|public'), 'none');
select tests.check('every registered table is mapped and every thread and message has a registry row', tests.unregistered_tables() || (select count(*)::text from communication_threads t where not exists (select 1 from entity_registry r where r.table_name = 'communication_threads' and r.entity_id = t.id))
                      || (select count(*)::text from communication_messages t where not exists (select 1 from entity_registry r where r.table_name = 'communication_messages' and r.entity_id = t.id)), 'none00');
select tests.check('starting a communication needs communications.create in THAT division and a real division',
  tests.mk_thread('tech_staff', 'b1', 'x', 'web') || tests.mk_thread('recruiter', 'b2', 'x') || tests.mk_thread('fin', 'b3', 'x') || tests.mk_thread('outsider', 'b4', 'x'), repeat('ERR:42501', 4));

-- Direct writes are refused for every caller; the commands are the only way in ---------------------------------------------------------------------------
select tests.check('API users cannot insert, update or delete threads, messages or participants directly',
  tests.try('web_lead', format($q$ insert into communication_threads (division_id, retention_class_id) values (%L, (select id from retention_classes limit 1)) $q$, tests.id('div:web'))) ||
  tests.try('web_lead', format($q$ insert into communication_messages (thread_id, seq, type_key, direction, occurred_at, body_hash, division_id) values (%L, 9, 'email', 'inbound', now(), repeat('a', 64), %L) $q$, tests.id('thr:a'), tests.id('div:web'))) ||
  tests.try('web_lead', format($q$ update communication_threads set status = 'closed' where id = %L $q$, tests.id('thr:a'))) ||
  tests.try('web_lead', format($q$ delete from communication_messages where id = %L $q$, tests.id('msg:a1'))) ||
  tests.try('web_lead', format($q$ delete from communication_participants where message_id = %L $q$, tests.id('msg:a1'))), repeat('ERR:42501', 5));
select tests.age_message('msg:a1');
select tests.check('participants are added only inside the transaction that recorded the message: later, nobody - not the lead, not the owner - can add one, and the refusal is the same for a missing message',
  tests.try('web_lead', format($q$ insert into communication_participants (message_id, role, address_snapshot) values (%L, 'from', 'x@y.z') $q$, tests.id('msg:a1'))) ||
  tests.try_owner(format($q$ insert into communication_participants (message_id, role, address_snapshot) values (%L, 'from', 'x@y.z') $q$, tests.id('msg:a1'))) ||
  tests.try('web_lead', format($q$ insert into communication_participants (message_id, role, address_snapshot) values (%L, 'from', 'x@y.z') $q$, tests.id('x:random'))), repeat('ERR:42501', 3));
select tests.check('...and neither can the database owner: a thread is started and a message recorded only through the commands',
  tests.try_owner(format($q$ insert into communication_threads (division_id, retention_class_id) values (%L, (select id from retention_classes limit 1)) $q$, tests.id('div:web'))) ||
  tests.try_owner(format($q$ insert into communication_messages (thread_id, seq, type_key, direction, occurred_at, body_hash, division_id) values (%L, 9, 'email', 'inbound', now(), repeat('a', 64), %L) $q$, tests.id('thr:a'), tests.id('div:web'))), 'ERR:42501ERR:42501');
select tests.check('a recorded message is permanent for every caller: its body, time, type, direction, hash and number cannot change, and it cannot be deleted',
  tests.try_owner(format($q$ update communication_messages set body = 'edited' where id = %L $q$, tests.id('msg:a1'))) || tests.try_owner(format($q$ update communication_messages set occurred_at = now() - interval '9 days' where id = %L $q$, tests.id('msg:a1'))) ||
  tests.try_owner(format($q$ update communication_messages set type_key = 'sms' where id = %L $q$, tests.id('msg:a1'))) || tests.try_owner(format($q$ update communication_messages set direction = 'outbound' where id = %L $q$, tests.id('msg:a1'))) ||
  tests.try_owner(format($q$ update communication_messages set body_hash = repeat('b', 64) where id = %L $q$, tests.id('msg:a1'))) || tests.try_owner(format($q$ update communication_messages set seq = 7 where id = %L $q$, tests.id('msg:a1'))) ||
  tests.try_owner(format($q$ update communication_messages set body = null, body_purged_at = now(), status = 'purged' where id = %L $q$, tests.id('msg:a1'))) ||
  tests.try_owner(format($q$ delete from communication_messages where id = %L $q$, tests.id('msg:a1'))), repeat('ERR:42501', 8));
select tests.check('a thread''s creator and creation time are permanent, it is never deleted, and its division changes only through communication_transfer',
  tests.try_owner(format($q$ update communication_threads set created_by = null where id = %L $q$, tests.id('thr:a'))) || tests.try_owner(format($q$ delete from communication_threads where id = %L $q$, tests.id('thr:a'))) ||
  tests.try_owner(format($q$ update communication_threads set division_id = %L where id = %L $q$, tests.id('div:tech'), tests.id('thr:a'))) ||
  tests.try_owner(format($q$ update communication_threads set retention_months = 1 where id = %L $q$, tests.id('thr:a'))) ||
  tests.try_owner(format($q$ update communication_threads set subject = null where id = %L $q$, tests.id('thr:a'))), repeat('ERR:42501', 5));

-- Messages: order, numbering, hash, idempotence ----------------------------------------------------------------------------------------------------------
select tests.check('messages are numbered 1, 2, 3 ... in the order recorded, whatever the time they say they happened', (tests.say('web_lead', 'a', 'a2', 'phone_call', 'outbound', null, '[]', now() - interval '3 days') ~ '^[0-9a-f-]{36}$')::text ||
  (tests.say('web_lead', 'a', 'a3', 'email', 'outbound', 'Quote attached', '[]', now() - interval '30 seconds') ~ '^[0-9a-f-]{36}$')::text, 'truetrue');
select tests.check('...gap-free', tests.seqs('a'), '1,2,3');
select tests.check('when it happened (occurred_at) and when it was recorded (recorded_at) are kept apart', (select (m.occurred_at < m.recorded_at - interval '2 days')::text from communication_messages m where m.id = tests.id('msg:a2')), 'true');
select tests.check('the database computes the SHA-256 of the body; nobody supplies it, and the drift check finds nothing', (select (body_hash = encode(extensions.digest(convert_to(id::text || '|' || body, 'UTF8'), 'sha256'), 'hex'))::text from communication_messages where id = tests.id('msg:a1'))
  || (select count(*)::text from communication_integrity_drift()), 'true0');
select tests.check('the thread''s last activity follows the recording', (select (last_activity_at >= created_at)::text from communication_threads where id = tests.id('thr:a')), 'true');
select tests.check('a message that needs content (an email) is refused without it; a call needs none; blank is not content',
  tests.say('web_lead', 'a', 'x1', 'email', 'inbound', null) || tests.say('web_lead', 'a', 'x2', 'email', 'inbound', '   ') || (tests.say('web_lead', 'a', 'x3', 'meeting', 'mutual', null) ~ '^[0-9a-f-]{36}$')::text, 'ERR:23514ERR:23514true');
select tests.check('unknown type, bad direction, a time in the future, an end before the start are refused',
  tests.say('web_lead', 'a', 'x4', 'telepathy', 'inbound', 'x') || tests.say('web_lead', 'a', 'x5', 'email', 'sideways', 'x') || tests.say('web_lead', 'a', 'x6', 'email', 'inbound', 'x', '[]', now() + interval '2 days') ||
  tests.scalar('web_lead', format($q$ select communication_message_add(%L, 'meeting', 'mutual', now() - interval '1 hour', null, '[]', now() - interval '2 hours')::text $q$, tests.id('thr:a'))), 'ERR:23514ERR:23514ERR:23514ERR:23514');
select tests.check('the numbering is still gap-free after the refusals', tests.seqs('a'), '1,2,3,4');
select tests.mk_thread('web_lead', 'r', 'Other thread');
select tests.check('a reply must be to a message in the same thread', tests.scalar('web_lead', format($q$ select communication_message_add(%L, 'email', 'outbound', now(), 'reply', '[]', null, %L)::text $q$, tests.id('thr:r'), tests.id('msg:a1'))), 'ERR:23514');
select tests.check('...and a real reply records which message it answers', (tests.scalar('web_lead', format($q$ select (communication_message_add(%L, 'email', 'outbound', now() - interval '10 seconds', 'Thanks', '[]', null, %L)) ->> 'message_id' $q$, tests.id('thr:a'), tests.id('msg:a1'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('...recorded against message 1', (select (select seq from communication_messages r where r.id = m.in_reply_to_message_id)::text from communication_messages m where m.thread_id = tests.id('thr:a') and m.seq = 5), '1');
select tests.check('a message with a source reference is recorded once: the same reference again answers with the same message and adds nothing',
  tests.scalar('web_lead', format($q$ select (communication_message_add(%L, 'email', 'inbound', now(), 'From a connector', '[]', null, null, 'connector_a', 'msg-001') ->> 'duplicate') $q$, tests.id('thr:a'))) ||
  tests.scalar('web_lead', format($q$ select (communication_message_add(%L, 'email', 'inbound', now(), 'From a connector', '[]', null, null, 'connector_a', 'msg-001') ->> 'duplicate') $q$, tests.id('thr:a'))) || tests.msg_count('a'), 'falsetrue6');
select tests.check('...and the same reference in ANOTHER thread is a different message (uniqueness is per thread, so it can never reveal another thread)',
  tests.scalar('web_lead', format($q$ select (communication_message_add(%L, 'email', 'inbound', now(), 'From a connector', '[]', null, null, 'connector_a', 'msg-001') ->> 'duplicate') $q$, tests.id('thr:r'))), 'false');
select tests.check('a source needs both a system and a reference', tests.scalar('web_lead', format($q$ select communication_message_add(%L, 'email', 'inbound', now(), 'x', '[]', null, null, 'connector_a', null)::text $q$, tests.id('thr:a'))), 'ERR:23514');
select tests.check('tampering below the commands (a trigger disabled by someone with the keys) is found by the drift check, naming message and thread',
  tests.try_owner(format($q$ alter table communication_messages disable trigger communication_messages_guard_trg; update communication_messages set body = 'rewritten' where id = %L; alter table communication_messages enable trigger communication_messages_guard_trg $q$, tests.id('msg:a1'))), 'ok');
select tests.check('...detected', (select count(*)::text || (min(problem)) from communication_integrity_drift() where message_id = tests.id('msg:a1')), '1body does not match its recorded hash');

-- Participants: by reference ---------------------------------------------------------------------------------------------------------------------------
select tests.mk_thread('web_lead', 'p', 'Participants');
create temp table pids as select (select institutional_id from entity_registry where entity_id = tests.id('contact:john')) as john, (select institutional_id from entity_registry where entity_id = tests.id('staff:web_lead')) as lead,
                                 (select institutional_id from entity_registry where entity_id = tests.id('client:abc')) as abc;
select tests.check('a message records who took part BY REFERENCE (a registered contact, a staff member) and, for a stranger, the address as typed',
  (tests.say('web_lead', 'p', 'p1', 'email', 'inbound', 'Hello', format('[{"role":"from","entity":"%s"},{"role":"to","entity":"%s"},{"role":"cc","address":"stranger@elsewhere.example"}]', (select john from pids), (select lead from pids))::text::jsonb) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('...stored as references, with the address only where there is no registered party', (select string_agg(role || ':' || coalesce(entity_institutional_id, '-') || ':' || coalesce(address_snapshot, '-'), ',' order by role) from communication_participants where message_id = tests.id('msg:p1')),
  (select 'cc:-:stranger@elsewhere.example,from:' || john || ':-,to:' || lead || ':-' from pids));
select tests.check('no name, email or phone of a registered party is copied: the participant table has no such columns beyond the one documented address snapshot',
  (select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_name = 'communication_participants' and column_name ~ 'name|email|phone|mail|address'), 'address_purged_at,address_snapshot');
select tests.check('a participant needs a registered party or an address', tests.say('web_lead', 'p', 'p2', 'email', 'inbound', 'x', '[{"role":"from"}]'), 'ERR:23514');
select tests.check('an unknown party is refused with the same words as one the caller cannot see', tests.say('web_lead', 'p', 'p3', 'email', 'inbound', 'x', '[{"role":"from","entity":"ZZZZZZZZZ"}]'), 'ERR:P0002');
select tests.check('a bad role is refused', tests.say('web_lead', 'p', 'p4', 'email', 'inbound', 'x', format('[{"role":"emperor","entity":"%s"}]', (select john from pids))::jsonb), 'ERR:23514');
select tests.check('a communication cannot be a participant', tests.say('web_lead', 'p', 'p5', 'email', 'inbound', 'x', format('[{"role":"other","entity":"%s"}]', tests.inst('communication_threads', 'thr:a'))::jsonb), 'ERR:23514');
select tests.check('a refused message leaves nothing behind: the numbering has no gap and no orphan participant exists', tests.seqs('p') || (select count(*)::text from communication_participants where thread_id = tests.id('thr:p')), '13');
select tests.check('participants are permanent: not editable, not deletable (the database owner included), and an address leaves only through an approved disposal',
  tests.try_owner(format($q$ update communication_participants set role = 'bcc' where message_id = %L $q$, tests.id('msg:p1'))) || tests.try_owner(format($q$ update communication_participants set entity_institutional_id = %L where message_id = %L and role = 'cc' $q$, (select john from pids), tests.id('msg:p1'))) ||
  tests.try_owner(format($q$ update communication_participants set address_snapshot = null, address_purged_at = now() where message_id = %L $q$, tests.id('msg:p1'))) || tests.try_owner(format($q$ delete from communication_participants where message_id = %L $q$, tests.id('msg:p1'))), repeat('ERR:42501', 4));

-- Relationships (links) with history -------------------------------------------------------------------------------------------------------------------
select tests.check('the lead links the thread to the client and the project (any registered entity)', (tests.clink('web_lead', 'a', 'clients', 'client:abc') ~ '^[0-9a-f-]{36}$')::text || (tests.clink('web_lead', 'a', 'projects', 'project:abc', 'related') ~ '^[0-9a-f-]{36}$')::text, 'truetrue');
select tests.check('...a duplicate live link is refused; so is linking to a communication; so is an unknown entity',
  tests.clink('web_lead', 'a', 'clients', 'client:abc') || tests.clink('web_lead', 'a', 'communication_threads', 'thr:p') || tests.scalar('web_lead', format($q$ select communication_link_add(%L, 'ZZZZZZZZZ')::text $q$, tests.id('thr:a'))), 'ERR:23505ERR:23514ERR:P0002');
select tests.check('removing a link needs a reason, keeps the row and records who and why', tests.try('web_lead', format($q$ select communication_link_remove(%L, null) $q$, (select id from communication_links where thread_id = tests.id('thr:a') and role = 'related'))) ||
  tests.try('web_lead', format($q$ select communication_link_remove(%L, 'linked by mistake') $q$, (select id from communication_links where thread_id = tests.id('thr:a') and role = 'related'))), 'ERR:23514ok');
select tests.check('...the removed link is history, not gone (and cannot be removed twice, edited or deleted)', (select count(*)::text from communication_links where thread_id = tests.id('thr:a') and removed_at is not null) ||
  tests.try('web_lead', format($q$ select communication_link_remove(%L, 'again') $q$, (select id from communication_links where thread_id = tests.id('thr:a') and role = 'related'))) ||
  tests.try_owner(format($q$ update communication_links set removed_at = null where thread_id = %L $q$, tests.id('thr:a'))) || tests.try_owner(format($q$ delete from communication_links where thread_id = %L $q$, tests.id('thr:a'))), '1ERR:23514ERR:42501ERR:42501');

-- Attachments ARE Documents ----------------------------------------------------------------------------------------------------------------------------
select tests.check('documents are registered (one internal by the lead, one restricted by the CEO) and the first is given a version', (tests.mk_doc('web_lead', 'att1', 'Quote PDF') ~ '^[0-9a-f-]{36}$')::text || (tests.mk_doc('ceo', 'att2', 'Legal letter', 'legal', 'web', null, 'restricted') ~ '^[0-9a-f-]{36}$')::text
  || (tests.add_ver('web_lead', 'att1', 'att1v1', 'quote-bytes') ~ '^[0-9a-f-]{36}$')::text, 'truetruetrue');
select tests.mk_thread('web_lead', 'd', 'Attachments');
select tests.say('web_lead', 'd', 'd1', 'email', 'outbound', 'See attached');
select tests.check('a document is attached to a message by reference; the thread keeps its classification while the document is internal',
  (tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:d1'), tests.id('doc:att1')) ) ~ '^[0-9a-f-]{36}$')::text || (select effective_classification::text from communication_threads where id = tests.id('thr:d')), 'trueinternal');
select tests.check('attachments hold no file, name, size or hash of their own - only the reference', (select coalesce(string_agg(column_name, ',' order by column_name), 'none') from information_schema.columns where table_name = 'communication_attachments' and column_name ~ 'file|name|size|hash|mime|key|path|storage|content'), 'none');
select tests.check('the same document cannot be attached to the same message twice; an unknown document and an unknown message are refused alike',
  tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:d1'), tests.id('doc:att1'))) || tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:d1'), tests.id('x:random'))) ||
  tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('x:random'), tests.id('doc:att1'))), 'ERR:23505ERR:P0002ERR:P0002');
select tests.check('a document the lead cannot see (restricted) cannot be attached by the lead - and the refusal is the same as for a document that does not exist',
  tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:d1'), tests.id('doc:att2'))), 'ERR:P0002');
select tests.remember_ok('att:ceo', tests.scalar('ceo', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:d1'), tests.id('doc:att2'))));
select tests.check('the CEO attaching the RESTRICTED document makes the whole thread restricted (a communication is never a weaker path around a document)', (select effective_classification::text from communication_threads where id = tests.id('thr:d')), 'restricted');
select tests.check('...and the messages and the registry follow the thread', (select string_agg(distinct effective_classification::text, ',') from communication_messages where thread_id = tests.id('thr:d')) || (select classification::text from entity_registry where entity_id = tests.id('msg:d1')) ||
  (select classification::text from entity_registry where entity_id = tests.id('thr:d')), 'restrictedrestrictedrestricted');
select tests.try('ceo', format($q$ select document_set_classification(%L, 'internal', null, 'downgraded after review') $q$, tests.id('doc:att2')));
select tests.check('the document is reclassified down: the thread follows', (select effective_classification::text from communication_threads where id = tests.id('thr:d')), 'internal');
select tests.try('ceo', format($q$ select document_set_classification(%L, 'confidential', null, 'upgraded') $q$, tests.id('doc:att2')));
select tests.check('...and up again', (select effective_classification::text from communication_threads where id = tests.id('thr:d')), 'confidential');
select tests.check('...the inherited changes are in the thread''s history, in order', (select string_agg(detail ->> 'from' || '>' || (detail ->> 'to'), ',' order by id) from communication_events where thread_id = tests.id('thr:d') and kind = 'classification_effective'), 'internal>restricted,restricted>internal,internal>confidential');
select tests.check('a person who cannot see the thread cannot remove its attachment (same answer as for a missing one); a reason is required',
  tests.try('web_lead', format($q$ select communication_attachment_remove(%L, 'wrong file') $q$, (select id from communication_attachments where document_id = tests.id('doc:att2')))) || tests.try('ceo', format($q$ select communication_attachment_remove(%L, null) $q$, (select id from communication_attachments where document_id = tests.id('doc:att2')))), 'ERR:P0002ERR:23514');
select tests.try('ceo', format($q$ select communication_attachment_remove(%L, 'wrong file') $q$, (select id from communication_attachments where document_id = tests.id('doc:att2'))));
select tests.check('the CEO removes it: the thread falls back to internal, and the row stays as history', (select effective_classification::text from communication_threads where id = tests.id('thr:d')) || (select count(*)::text from communication_attachments where thread_id = tests.id('thr:d')), 'internal2');
select tests.check('attachments are permanent rows: no delete, no re-pointing, no reviving a removed one', tests.try_owner(format($q$ delete from communication_attachments where thread_id = %L $q$, tests.id('thr:d'))) || tests.try_owner(format($q$ update communication_attachments set document_id = %L where thread_id = %L $q$, tests.id('doc:att1'), tests.id('thr:d'))) ||
  tests.try_owner(format($q$ update communication_attachments set removed_at = null where thread_id = %L and removed_at is not null $q$, tests.id('thr:d'))), repeat('ERR:42501', 3));
select (tests.scalar('web_lead', format($q$ select (communication_attachment_open(%L, 'read') ->> 'storage_key') $q$, (select id from communication_attachments where document_id = tests.id('doc:att1'))))) is not null;
select tests.check('opening an attachment goes through the Documents module (its authorization, its integrity gate, its log): the lead opens the quote, and BOTH histories record it',
  (select count(*)::text from communication_events where thread_id = tests.id('thr:d') and kind = 'attachment_opened') || (select count(*)::text from document_events where document_id = tests.id('doc:att1') and kind = 'opened'), '11');

-- Lifecycle ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.mk_thread('web_lead', 'l', 'Lifecycle');
select tests.say('web_lead', 'l', 'l1', 'email', 'inbound', 'Initial enquiry');
select tests.check('closing needs a reason; then nothing more can be recorded (reopen first), and the closing is dated',
  tests.try('web_lead', format($q$ select communication_close(%L, null) $q$, tests.id('thr:l'))) || tests.try('web_lead', format($q$ select communication_close(%L, 'resolved') $q$, tests.id('thr:l'))), 'ERR:23514ok');
select tests.check('...a closed thread takes no new message (and says why to someone who may see it)', tests.say('web_lead', 'l', 'l2', 'email', 'inbound', 'late reply') || tests.thr_status('l') || (select (closed_at is not null)::text from communication_threads where id = tests.id('thr:l')), 'ERR:23514closedtrue');
select tests.check('...it can be reopened (reason required), only when closed; and records again', tests.try('web_lead', format($q$ select communication_reopen(%L, 'customer replied') $q$, tests.id('thr:l'))) || tests.try('web_lead', format($q$ select communication_reopen(%L, 'again') $q$, tests.id('thr:l'))), 'okERR:42501');
select tests.check('...and records again', (tests.say('web_lead', 'l', 'l2', 'email', 'inbound', 'late reply') ~ '^[0-9a-f-]{36}$')::text || tests.thr_status('l') || tests.seqs('l'), 'trueopen1,2');
select tests.check('the thread cannot jump from open to disposed, nor be archived without a reason; archiving and restoring are separate rights',
  tests.try_owner(format($q$ update communication_threads set status = 'disposed' where id = %L $q$, tests.id('thr:l'))) || tests.try('web_staff', format($q$ select communication_archive(%L, 'tidy') $q$, tests.id('thr:l'))) || tests.try('web_lead', format($q$ select communication_archive(%L, null) $q$, tests.id('thr:l'))), 'ERR:23514ERR:42501ERR:23514');
select tests.check('archived: no new messages, no edits; the content is still readable by those cleared; restoring returns it to closed',
  tests.try('web_lead', format($q$ select communication_archive(%L, 'inactive for a year') $q$, tests.id('thr:l'))) || tests.say('web_lead', 'l', 'l3', 'email', 'inbound', 'x') || tests.try('web_lead', format($q$ select communication_update(%L, '{"review_date":"2030-01-01"}') $q$, tests.id('thr:l'))) ||
  (tests.scalar('web_lead', format($q$ select communication_read(%L) ->> 'status' $q$, tests.id('thr:l')))) || tests.try('web_lead', format($q$ select communication_restore(%L, 'needed again') $q$, tests.id('thr:l'))) || tests.thr_status('l'), 'okERR:42501ERR:42501archivedokclosed');
select tests.check('details: the subject, owner and review date change through communication_update only, by someone who may edit; nothing else can be changed there',
  tests.try('web_lead', format($q$ select communication_update(%L, '{"subject":"Renamed","review_date":"2031-01-01"}') $q$, tests.id('thr:l'))) || tests.try('web_staff', format($q$ select communication_update(%L, '{"subject":"Nope"}') $q$, tests.id('thr:l'))) ||
  tests.try('web_lead', format($q$ select communication_update(%L, '{"status":"open"}') $q$, tests.id('thr:l'))) || tests.try('web_lead', format($q$ select communication_update(%L, '{"owner_staff_id":"%s"}') $q$, tests.id('thr:l'), tests.id('x:random'))), 'okERR:42501ERR:23514ERR:23514');
select tests.check('...the history says WHICH fields changed, never the subject itself', (select detail::text from communication_events where thread_id = tests.id('thr:l') and kind = 'metadata'), '{"fields": ["review_date", "subject"]}');
select tests.check('moving a thread to another division keeps its permanent ID and its origin; its messages follow; the registry follows',
  tests.try('web_lead', format($q$ select communication_transfer(%L, %L, 'handed to Tech') $q$, tests.id('thr:l'), tests.id('div:tech'))) || tests.try('ceo', format($q$ select communication_transfer(%L, %L, 'handed to Tech') $q$, tests.id('thr:l'), tests.id('div:tech'))), 'ERR:42501ok');
select tests.check('...ID and origin division unchanged, current division moved, messages mirror it', (select concat_ws('|', (origin_division_id = tests.id('div:web'))::text, (current_division_id = tests.id('div:tech'))::text) from entity_registry where entity_id = tests.id('thr:l')) ||
  (select string_agg(distinct (division_id = tests.id('div:tech'))::text, ',') from communication_messages where thread_id = tests.id('thr:l')), 'true|truetrue');
select tests.check('...the web lead no longer works in the owning division but, as the thread''s owner, keeps their own access; division staff do not', tests.scalar('web_lead', format($q$ select count(*)::text from communication_threads where id = %L $q$, tests.id('thr:l'))) || tests.scalar('web_staff', format($q$ select count(*)::text from communication_threads where id = %L $q$, tests.id('thr:l'))), '10');
select tests.check('transfer needs a reason and a different division', tests.try('ceo', format($q$ select communication_transfer(%L, %L, null) $q$, tests.id('thr:l'), tests.id('div:web'))) || tests.try('ceo', format($q$ select communication_transfer(%L, %L, 'same') $q$, tests.id('thr:l'), tests.id('div:tech'))), 'ERR:23514ERR:23514');

-- Retention, legal holds and two-person disposal ------------------------------------------------------------------------------------------------------
select tests.mk_thread('web_lead', 'x', 'Old enquiry from a stranger');
select tests.say('web_lead', 'x', 'x1', 'email', 'inbound', 'Secret pricing discussion with the stranger', '[{"role":"from","address":"stranger@elsewhere.example"}]');
select tests.try('web_lead', format($q$ select communication_comment_add(%L, 'Internal: do not discount further', 1) $q$, tests.id('thr:x')));
select tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:x1'), tests.id('doc:att1')));
select tests.check('a new thread takes the standard communications retention class as a snapshot (5 years)', (select concat_ws('|', rc.key, t.retention_months::text) from communication_threads t join retention_classes rc on rc.id = t.retention_class_id where t.id = tests.id('thr:x')), 'communications_standard|60');
select tests.check('choosing or changing a retention class needs communications.configure; the lead cannot, the CEO can (with a reason)',
  tests.try('web_lead', format($q$ select communication_set_retention(%L, 'transient_1y', null, 'short-lived') $q$, tests.id('thr:x'))) || tests.try('ceo', format($q$ select communication_set_retention(%L, 'transient_1y', null, null) $q$, tests.id('thr:x'))) ||
  tests.try('ceo', format($q$ select communication_set_retention(%L, 'transient_1y', null, 'short-lived') $q$, tests.id('thr:x'))), 'ERR:42501ERR:23514ok');
select tests.check('it is a 12-month snapshot now, shown in the derived view; not yet eligible', (select concat_ws('|', retention_class, retention_months::text, disposal_eligible::text, disposition) from communication_retention_status where thread_id = tests.id('thr:x')), 'transient_1y|12|false|retained');
select tests.check('disposal cannot be requested while the thread is not archived, nor before retention has elapsed',
  tests.scalar('adm2', format($q$ select communication_request_disposal(%L, 'tidy')::text $q$, tests.id('thr:x'))), 'ERR:42501');
select tests.try('adm2', format($q$ select communication_archive(%L, 'inactive') $q$, tests.id('thr:x')));
select tests.check('archived but within retention: refused', tests.scalar('adm2', format($q$ select communication_request_disposal(%L, 'tidy')::text $q$, tests.id('thr:x'))), 'ERR:23514');
select tests.backdate_thread('thr:x', interval '400 days');
select tests.check('retention has now elapsed: the derived view says eligible; a legal hold removes eligibility', (select disposal_eligible::text from communication_retention_status where thread_id = tests.id('thr:x')), 'true');
select tests.check('only communications.legal_hold holders place a hold (a reason is required)', tests.scalar('adm2', format($q$ select communication_hold_place(%L, 'litigation')::text $q$, tests.id('thr:x'))) , 'ERR:42501');
select tests.remember_ok('hold:x', tests.scalar('ceo', format($q$ select communication_hold_place(%L, 'litigation')::text $q$, tests.id('thr:x'))));
select tests.check('a legal hold overrides retention: disposal cannot even be requested, and cannot be forced below the commands', tests.scalar('adm2', format($q$ select communication_request_disposal(%L, 'tidy')::text $q$, tests.id('thr:x'))) ||
  tests.try_owner(format($q$ select set_config('ada.communication_disposal', 'on', true); update communication_threads set status = 'disposed' where id = %L $q$, tests.id('thr:x'))), 'ERR:23514ERR:42501');
select tests.check('the derived view shows the hold', (select concat_ws('|', on_legal_hold::text, hold_blocks_disposal::text, disposal_eligible::text) from communication_retention_status where thread_id = tests.id('thr:x')), 'true|true|false');
select tests.check('releasing a hold needs a reason and the same right', tests.try('adm2', format($q$ select communication_hold_release(%L, 'over') $q$, tests.id('hold:x'))) || tests.try('ceo', format($q$ select communication_hold_release(%L, null) $q$, tests.id('hold:x'))) || tests.try('ceo', format($q$ select communication_hold_release(%L, 'case closed') $q$, tests.id('hold:x'))), 'ERR:42501ERR:23514ok');
select tests.check('a legal hold on an ATTACHED DOCUMENT also blocks disposal of the communication (the Documents module''s hold is honoured, not duplicated)',
  tests.try('ceo', format($q$ select document_hold_place(%L, 'document under hold') $q$, tests.id('doc:att1'))) ||
  tests.scalar('adm2', format($q$ select communication_request_disposal(%L, 'tidy')::text $q$, tests.id('thr:x'))), 'okERR:23514');
select tests.check('...the view shows it too', (select concat_ws('|', on_legal_hold::text, hold_blocks_disposal::text, disposal_eligible::text) from communication_retention_status where thread_id = tests.id('thr:x')), 'false|true|false');
select tests.try('ceo', format($q$ select document_hold_release(%L, 'released') $q$, (select id from document_holds where document_id = tests.id('doc:att1') and released_at is null)));
select tests.check('with every hold released a disposal can be requested by the person who archives, with a reason', tests.remember_ok('disp:x', tests.scalar('adm2', format($q$ select communication_request_disposal(%L, 'retention elapsed; no longer needed')::text $q$, tests.id('thr:x')))), 'ok');
select tests.check('...the requester cannot approve their own request (nor can anyone without communications.dispose); a rejection needs a note',
  tests.try('adm2', format($q$ select communication_disposal_decide(%L, true) $q$, tests.id('disp:x'))) || tests.try('web_lead', format($q$ select communication_disposal_decide(%L, true) $q$, tests.id('disp:x'))) || tests.try('ceo', format($q$ select communication_disposal_decide(%L, false) $q$, tests.id('disp:x'))), 'ERR:42501ERR:42501ERR:23514');
select tests.check('the CEO approves: the content is removed', tests.scalar('ceo', format($q$ select communication_disposal_decide(%L, true, 'approved') $q$, tests.id('disp:x'))), 'approved');
select tests.check('...bodies, subject, notes and the stranger''s address are gone; identity, metadata, hashes and the participant row remain',
  (select concat_ws('|', (m.body is null)::text, (m.body_purged_at is not null)::text, (m.body_hash ~ '^[0-9a-f]{64}$')::text, m.status, m.seq::text) from communication_messages m where m.id = tests.id('msg:x1'))
  || '|' || (select concat_ws('|', (t.subject is null)::text, (t.subject_purged_at is not null)::text, t.status::text) from communication_threads t where t.id = tests.id('thr:x'))
  || '|' || (select concat_ws('|', (c.body is null)::text, (c.purged_at is not null)::text) from communication_comments c where c.thread_id = tests.id('thr:x'))
  || '|' || (select concat_ws('|', (p.address_snapshot is null)::text, (p.address_purged_at is not null)::text) from communication_participants p where p.message_id = tests.id('msg:x1')),
  'true|true|true|purged|1|true|true|disposed|true|true|true|true');
select tests.check('...the disposal record says how much was removed', (select purge_summary::text from communication_disposals where id = tests.id('disp:x')), '{"notes": 1, "bodies": 1, "subject": true, "addresses": 1}');
select tests.check('...the registry still knows both entities (status disposed / purged): an ID is never reused', (select string_agg(status, ',' order by entity_type) from entity_registry where entity_id in (tests.id('thr:x'), tests.id('msg:x1'))), 'disposed,purged');
select tests.check('nothing of the removed content survives in the permanent audit log (it is redacted at the source)', (select count(*)::text from audit_log where table_name in ('communication_messages', 'communication_threads', 'communication_comments', 'communication_participants')
   and (new_data::text ~* 'Secret pricing|stranger@elsewhere|do not discount|Old enquiry from' or old_data::text ~* 'Secret pricing|stranger@elsewhere|do not discount|Old enquiry from')), '0');
select tests.check('a disposed thread is a closed record: nothing is added, changed, reopened, moved or read',
  tests.say('ceo', 'x', 'x2', 'email', 'inbound', 'late') || tests.try('ceo', format($q$ select communication_update(%L, '{"review_date":"2040-01-01"}') $q$, tests.id('thr:x'))) || tests.try('ceo', format($q$ select communication_reopen(%L, 'x') $q$, tests.id('thr:x'))) ||
  tests.try('ceo', format($q$ select communication_transfer(%L, %L, 'x') $q$, tests.id('thr:x'), tests.id('div:tech'))) || tests.scalar('ceo', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:x'))) ||
  tests.try_owner(format($q$ update communication_threads set review_date = current_date where id = %L $q$, tests.id('thr:x'))), 'ERR:42501ERR:42501ERR:42501ERR:42501nullERR:42501');
select tests.check('a disposal record is permanent; a decided one cannot be edited', tests.try_owner(format($q$ update communication_disposals set state = 'requested' where id = %L $q$, tests.id('disp:x'))) || tests.try_owner(format($q$ delete from communication_disposals where id = %L $q$, tests.id('disp:x'))), 'ERR:42501ERR:42501');

-- Historical retrieval ---------------------------------------------------------------------------------------------------------------------------------
select tests.mk_thread('web_lead', 'h', 'History');
select tests.say('web_lead', 'h', 'h1', 'email', 'inbound', 'Project kickoff mail', format('[{"role":"from","entity":"%s"}]', (select john from pids))::jsonb);
select tests.say('web_lead', 'h', 'h2', 'meeting', 'mutual', null, '[]', now() - interval '40 minutes');
select tests.clink('web_lead', 'h', 'clients', 'client:abc');
select tests.clink('web_lead', 'h', 'projects', 'project:abc', 'related');
select tests.backdate_thread('thr:h', interval '60 days');
select tests.say('web_lead', 'h', 'h3', 'email', 'outbound', 'Recent follow-up');
select tests.try('web_lead', format($q$ select communication_link_remove(%L, 'project handled elsewhere now') $q$, (select id from communication_links where thread_id = tests.id('thr:h') and role = 'related')));
create temp table hist as select now() - interval '30 days' as a_month_ago, now() - interval '70 days' as before_all;
select tests.check('the project''s correspondence TODAY no longer includes the thread (its link was removed); the client''s still does',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L)))::text $q$, tests.id('project:abc'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L)))::text $q$, tests.id('client:abc'))), '02');
select tests.check('"the correspondence relating to the project as it was a month ago": the thread is there, with only the messages that existed then (two, not the later follow-up)',
  tests.scalar('web_lead', format($q$ select (communications_for_entity((select institutional_id from entity_registry where entity_id = %L), p_as_of => now() - interval '30 days') -> 0 ->> 'messages') $q$, tests.id('project:abc'))), '2');
select tests.check('...and the same question about a time before the thread existed finds nothing', tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L), p_as_of => now() - interval '70 days'))::text $q$, tests.id('project:abc'))), '0');
select tests.check('...the relationship is reported with how it was then', tests.scalar('web_lead', format($q$ select (communications_for_entity((select institutional_id from entity_registry where entity_id = %L), p_as_of => now() - interval '30 days') -> 0 -> 'relationships' -> 0 ->> 'role') $q$, tests.id('project:abc'))), 'related');
select tests.check('a date window selects by when the communications happened', tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L), current_date - 1, current_date))::text $q$, tests.id('client:abc'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L), current_date - 400, current_date - 200))::text $q$, tests.id('client:abc'))), '20');
select tests.check('a period expression is interpreted by the database, not the caller: last month is a closed range ending before this month', (select (upper(period_resolve('last_month')) <= date_trunc('month', current_date)::date + 1)::text), 'true');
select tests.check('who took part: the thread is found through the registered contact - for someone who may READ it - and the answer says by which route',
  tests.scalar('web_lead', format($q$ select (communications_for_entity(%L) -> 0 -> 'relationships' -> 0 ->> 'via') $q$, (select john from pids))), 'participant');
select tests.check('the entity''s family: a client''s correspondence includes its projects'' when asked', tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true))::text $q$, tests.id('client:abc'))), '2');
select tests.check('a lookup of an unknown ID answers null', tests.scalar('web_lead', $q$ select coalesce(communications_for_entity('ZZZZZZZZZ')::text, 'null') $q$), 'null');
select tests.check('resolving a thread or a message by its permanent ID', tests.scalar('web_lead', format($q$ select (communication_lookup(%L) ->> 'kind') || (communication_lookup(%L) ->> 'kind') $q$, tests.inst('communication_threads', 'thr:h'), tests.inst('communication_messages', 'msg:h1'))), 'threadmessage');

-- Events, reads and audit ------------------------------------------------------------------------------------------------------------------------------
select tests.check('every content read is logged with who and how much (not what)', (select string_agg(detail ->> 'messages', ',') from communication_events where thread_id = tests.id('thr:l') and kind = 'read'), '2');
select tests.check('every event names the acting staff member', (select count(*)::text from communication_events where actor_staff_id is null), '0');
select tests.check('events are append-only for every caller', tests.try_owner(format($q$ update communication_events set kind = 'created' where thread_id = %L $q$, tests.id('thr:h'))) || tests.try_owner(format($q$ delete from communication_events where thread_id = %L $q$, tests.id('thr:h'))), 'ERR:42501ERR:42501');
select tests.check('audit rows for the tables exist (changes are audited) but content columns are redacted',
  (select (count(*) > 0)::text || (count(*) filter (where new_data ->> 'body' is not null and new_data ->> 'body' <> '[redacted]'))::text from audit_log where table_name = 'communication_messages'), 'true0');
select tests.check('...subjects too', (select (count(*) filter (where new_data ->> 'subject' is not null and new_data ->> 'subject' <> '[redacted]'))::text from audit_log where table_name = 'communication_threads'), '0');
select tests.check('...and participant addresses and notes', (select (count(*) filter (where new_data ->> 'address_snapshot' is not null and new_data ->> 'address_snapshot' <> '[redacted]'))::text from audit_log where table_name = 'communication_participants')
    || (select (count(*) filter (where new_data ->> 'body' is not null and new_data ->> 'body' <> '[redacted]'))::text from audit_log where table_name = 'communication_comments'), '00');

-- 360 views --------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('Client 360 and Project 360 carry a Communications section (metadata only) and it is no longer pending',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(client_360(%L) -> 'communications')::text || ((client_360(%L) -> 'pending') ? 'communications')::text $q$, tests.id('client:abc'), tests.id('client:abc'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(project_360(%L) -> 'communications')::text $q$, tests.id('project:abc'))), '2false0');
select tests.check('...the section carries no subject, body or participant', tests.scalar('web_lead', format($q$ select ((client_360(%L) -> 'communications')::text ~* 'kickoff|follow-up|stranger|@|"(body|subject|address)":')::text $q$, tests.id('client:abc'))), 'false');
select tests.check('the thread''s own 360 has identity, retention, a message index, relationships, attachments and access flags - and still no content',
  tests.scalar('web_lead', format($q$ select concat_ws('|', jsonb_array_length(communication_360(%L) -> 'messages'), (communication_360(%L) -> 'access' ->> 'can_read'), (communication_360(%L) -> 'identity' ->> 'entity_type'),
                                       ((communication_360(%L)::text) ~* 'Project kickoff|Recent follow|stranger|@|"(body|subject|address)":')::text) $q$, tests.id('thr:h'), tests.id('thr:h'), tests.id('thr:h'), tests.id('thr:h'))), '3|true|communication|false');
select tests.check('Domain 360 and Document 360 carry a Communications section as well', tests.scalar('web_lead', format($q$ select jsonb_typeof(document_360(%L) -> 'communications') $q$, tests.id('doc:att1'))), 'array');
select tests.check('the document''s communications are found through the attachment: "what was attached to this document"', tests.scalar('web_lead', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L)))::text $q$, tests.id('doc:att1'))), '2');
select tests.finish();
rollback;
