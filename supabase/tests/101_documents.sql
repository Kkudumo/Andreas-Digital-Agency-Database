-- PERMANENT: Documents as an institutional records layer - identity, record vs content, storage by reference, relationships (no copies),
-- controlled versions and signed-version immutability, integrity, retention, legal holds and disposal, historical retrieval, audit.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());

-- Identity ----------------------------------------------------------------------------------------------------------------------------------------
select tests.check('web lead registers a document: it comes back with a generated institutional ID, active, origin division = web',
  (tests.mk_doc('web_lead', 'plan', 'Project plan', 'report', 'web') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the document is a registered entity (family operations) with a well-formed 9-character opaque ID and no legacy alias',
  (select concat_ws('|', (institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, (ada_id is null)::text, entity_family, entity_type, table_name, (origin_division_id = tests.id('div:web'))::text, origin_kind, status)
     from entity_registry where entity_id = tests.id('doc:plan')), 'true|true|operations|document|documents|true|created|active');
select tests.check('the ID is not derived from anything mutable: no title, division or year text in it',
  (select (institutional_id !~* 'plan|web|2026|2025')::text from entity_registry where entity_id = tests.id('doc:plan')), 'true');
select tests.check('documents have no ID input, no number column and no generator of their own',
  (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'documents' and column_name ~ 'institutional|doc_no|number|ada_id|code|reference')
  || (select coalesce(string_agg(proname, ','), 'none') from pg_proc where pronamespace = 'public'::regnamespace and proname ~ '^document.*(mint|id_gen|next_id|number)'), 'nonenone');
select tests.check('registering takes no identifier argument (nobody can choose a document ID)',
  (select (pg_get_function_arguments(oid) !~* 'institutional|p_id\M|ada_id')::text from pg_proc where proname = 'document_register'), 'true');
select tests.check('the document type is in the codebook and may one day be public (publishable)', (select (c.code = t.id_code and t.publishable and t.is_built and t.domain_table = 'documents')::text from entity_types t join id_codebook c on c.kind = 'type' and c.meaning = t.key where t.key = 'document'), 'true');
create temp table plan_id as select institutional_id i from entity_registry where entity_id = tests.id('doc:plan');
select tests.check('the registry resolves the document for those who may see it, and routes to document_360',
  tests.scalar('web_lead', format($q$ select (entity_get(%L) -> 'record' -> 'record' ->> 'title') $q$, (select i from plan_id))), 'Project plan');
select tests.check('...and an outsider, another division and the suspended see nothing (null, same as a random ID)',
  tests.scalar('tech_staff', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select i from plan_id))) || tests.scalar('suspended', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select i from plan_id))) || tests.scalar('outsider', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select i from plan_id))), 'nullnullnull');
select tests.check('identity facts are permanent: nobody changes the ID, the origin or the registry entry (not even the owner)',
  tests.try_owner(format($q$ update entity_registry set institutional_id = 'AAAAAAAAA' where entity_id = %L $q$, tests.id('doc:plan'))) || tests.try_owner(format($q$ update entity_registry set origin_division_id = %L where entity_id = %L $q$, tests.id('div:tech'), tests.id('doc:plan'))) || tests.try_owner(format('delete from entity_registry where entity_id = %L', tests.id('doc:plan'))), 'ERR:42501ERR:42501ERR:42501');
select tests.check('API users can never write the registry', tests.try('ceo', format($q$ update entity_registry set status = 'x' where entity_id = %L $q$, tests.id('doc:plan'))), 'ERR:42501');

-- Origin vs ownership ------------------------------------------------------------------------------------------------------------------------------
create temp table before_move as select institutional_id i, origin_division_id o from entity_registry where entity_id = tests.id('doc:plan');
select tests.check('web lead cannot hand it to Tech (no document rights there)', tests.try('web_lead', format('select document_transfer(%L, %L, ''reorg'')', tests.id('doc:plan'), tests.id('div:tech'))), 'ERR:42501');
select tests.check('a division changes only through document_transfer (not even the owner edits it directly)', tests.try_owner(format('update documents set division_id = %L where id = %L', tests.id('div:tech'), tests.id('doc:plan'))), 'ERR:42501');
select tests.check('the CEO moves it to Tech, with a reason', tests.try('ceo', format('select document_transfer(%L, %L, ''Tech now owns this'')', tests.id('doc:plan'), tests.id('div:tech'))), 'ok');
select tests.check('...ID and origin are unchanged; the registry shows the new current division and the movement',
  (select concat_ws('|', (r.institutional_id = b.i)::text, (r.origin_division_id = b.o)::text, (r.current_division_id = tests.id('div:tech'))::text, (select count(*)::text from entity_location_history h where h.institutional_id = r.institutional_id and h.reason = 'moved'))
     from entity_registry r, before_move b where r.entity_id = tests.id('doc:plan')), 'true|true|true|1');
select tests.check('...web division staff (not the owner) no longer see it, the Tech lead now does; the owner keeps access until ownership is reassigned',
  tests.scalar('web_staff', format('select count(*)::text from documents where id = %L', tests.id('doc:plan'))) || tests.scalar('tech_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:plan'))) || tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:plan'))), '011');
select tests.check('...the move is in the document''s history, with who and why', (select (detail ->> 'reason' = 'Tech now owns this' and actor_staff_id = tests.id('staff:ceo'))::text from document_events where document_id = tests.id('doc:plan') and kind = 'transferred'), 'true');
select tests.check('a transfer needs a reason', tests.try('ceo', format('select document_transfer(%L, %L, '' '')', tests.id('doc:plan'), tests.id('div:web'))), 'ERR:23514');
select tests.try('ceo', format('select document_transfer(%L, %L, ''back'')', tests.id('doc:plan'), tests.id('div:web')));
select tests.check('changing the owner (a person) does not touch the ID either', tests.try('web_lead', format($q$ select document_update(%L, jsonb_build_object('owner_staff_id', %L)) $q$, tests.id('doc:plan'), tests.id('staff:web_staff'))) || (select (institutional_id = (select i from plan_id))::text from entity_registry where entity_id = tests.id('doc:plan')), 'oktrue');

-- Types, titles, validation -------------------------------------------------------------------------------------------------------------------------
select tests.check('unknown type, blank title and an unknown division are refused',
  tests.mk_doc('web_lead', 'bad1', 'x', 'spaceship') || tests.mk_doc('web_lead', 'bad2', ' ', 'report') || tests.scalar('web_lead', format($q$ select document_register('x', 'report', %L)::text $q$, tests.id('x:random'))), 'ERR:23514ERR:23514ERR:P0002');
select tests.check('registering needs documents.create in THAT division', tests.mk_doc('web_staff', 'bad3', 'x', 'report', 'tech') || tests.mk_doc('tech_staff', 'bad4', 'x', 'report', 'web'), 'ERR:42501ERR:42501');
select tests.check('an API user without staff identity registers nothing', tests.scalar('outsider', format($q$ select document_register('x', 'report', %L)::text $q$, tests.id('div:web'))), 'ERR:42501');

-- Storage by reference ----------------------------------------------------------------------------------------------------------------------------
select tests.check('web staff (division_staff) can upload a first version', (tests.add_ver('web_staff', 'plan', 'plan1', 'plan content v1', 'First draft') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the version carries a SHA-256, size, type, and a storage REFERENCE (provider + opaque key) - none of which is the ID',
  (select concat_ws('|', (content_hash = tests.h('plan content v1'))::text, (size_bytes = length('plan content v1') + 1)::text, mime_type, state::text, (storage_provider = 'memstore')::text, (storage_key !~ (select i from plan_id))::text) from document_versions where id = tests.id('ver:plan1')), 'true|true|application/pdf|draft|true|true');
select tests.check('metadata viewers cannot read the storage provider or key (column privileges), even through select *',
  tests.scalar('web_lead', 'select storage_key from document_versions limit 1') || tests.scalar('web_lead', 'select count(*)::text from (select * from document_versions) x') || tests.scalar('web_lead', 'select storage_provider from document_versions limit 1'), 'ERR:42501ERR:42501ERR:42501');
select tests.check('...but can read everything else about the versions', tests.scalar('web_lead', format($q$ select count(version_no)::text from document_versions where document_id = %L $q$, tests.id('doc:plan'))), '1');
select tests.check('a malformed hash, an empty key or a made-up media type are refused',
  tests.scalar('web_lead', format($q$ select document_add_version(%L, 'memstore', 'k', 'nothex', 5, 'application/pdf')::text $q$, tests.id('doc:plan'))) || tests.scalar('web_lead', format($q$ select document_add_version(%L, 'memstore', ' ', %L, 5, 'application/pdf')::text $q$, tests.id('doc:plan'), tests.h('q'))) || tests.scalar('web_lead', format($q$ select document_add_version(%L, 'memstore', 'k', %L, 5, 'not a type')::text $q$, tests.id('doc:plan'), tests.h('q'))), 'ERR:23514ERR:23514ERR:23514');
select tests.check('the same bytes cannot be uploaded twice as a new version', tests.add_ver('web_lead', 'plan', 'dup', 'plan content v1'), 'ERR:23514');
select tests.check('content columns are permanent for every caller - even the owner of the database',
  tests.try_owner(format($q$ update document_versions set content_hash = %L where id = %L $q$, tests.h('other'), tests.id('ver:plan1'))) || tests.try_owner(format('update document_versions set size_bytes = 1 where id = %L', tests.id('ver:plan1'))) || tests.try_owner(format($q$ update document_versions set mime_type = 'text/plain' where id = %L $q$, tests.id('ver:plan1'))) || tests.try_owner(format($q$ update document_versions set original_filename = 'x' where id = %L $q$, tests.id('ver:plan1'))), 'ERR:42501ERR:42501ERR:42501ERR:42501');
select tests.check('...the storage reference cannot be re-pointed by a plain update (only relocation)', tests.try_owner(format($q$ update document_versions set storage_key = 'elsewhere' where id = %L $q$, tests.id('ver:plan1'))), 'ERR:42501');
select tests.check('versions are never deleted', tests.try_owner(format('delete from document_versions where id = %L', tests.id('ver:plan1'))), 'ERR:42501');
select tests.check('authorised reading returns the storage reference', tests.scalar('web_staff', format($q$ select (document_open(%L, 'read') ->> 'storage_key') $q$, tests.id('doc:plan'))), 'obj/plan1');
select tests.check('...and writes an access record naming the reader', (select count(*)::text from document_events where document_id = tests.id('doc:plan') and kind = 'opened' and actor_staff_id = tests.id('staff:web_staff')), '1');
select tests.check('download is allowed and logged separately', tests.scalar('web_staff', format($q$ select (document_open(%L, 'download') ->> 'mode') $q$, tests.id('doc:plan'))), 'download');
select tests.check('...as a download event', (select count(*)::text from document_events where document_id = tests.id('doc:plan') and kind = 'downloaded'), '1');
select tests.check('who read or downloaded what is not visible to everyone who can see the document: finance sees none of it, the auditor and approvers see it',
  tests.scalar('fin', format($q$ select count(*)::text from document_events where document_id = %L and kind in ('opened', 'downloaded') $q$, tests.id('doc:plan'))) || tests.scalar('audit', format($q$ select count(*)::text from document_events where document_id = %L and kind in ('opened', 'downloaded') $q$, tests.id('doc:plan'))) || tests.scalar('web_lead', format($q$ select count(*)::text from document_events where document_id = %L and kind in ('opened', 'downloaded') $q$, tests.id('doc:plan'))), '022');
select tests.check('relocating the bytes to another store (documents.configure)', tests.try('adm2', format($q$ select document_relocate_content(%L, 'othercloud', 'new/location/1') $q$, tests.id('ver:plan1'))), 'ok');
select tests.check('...changes the reference, not the hash, state or identity', tests.scalar('web_staff', format($q$ select (document_open(%L, 'read', 1) ->> 'storage_provider') || '|' || (document_open(%L, 'read', 1) ->> 'content_hash') = 'othercloud|' || %L $q$, tests.id('doc:plan'), tests.id('doc:plan'), tests.h('plan content v1'))), 'true');
select tests.check('...only documents.configure holders may relocate', tests.try('web_lead', format($q$ select document_relocate_content(%L, 'x', 'y') $q$, tests.id('ver:plan1'))), 'ERR:42501');
select tests.check('...and the identity is unchanged', (select (institutional_id = (select i from plan_id))::text from entity_registry where entity_id = tests.id('doc:plan')), 'true');

-- Version lifecycle: draft -> review -> approved -> signed; amendments ------------------------------------------------------------------------------------------
select tests.check('submitting for review', tests.try('web_staff', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:plan1'))), 'ok');
select tests.check('...opens an approval request', (select count(*)::text from approval_requests where entity_id = tests.id('ver:plan1') and status = 'pending' and kind = 'document_version'), '1');
select tests.check('web staff cannot approve (no documents.approve)', tests.try('web_staff', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:plan1'))), 'ERR:42501');
select tests.check('a version cannot jump states (draft/review -> signed)', tests.try('web_lead', format($q$ select document_version_transition(%L, 'signed', 'x', current_date) $q$, tests.id('ver:plan1'))), 'ERR:23514');
select tests.check('the lead approves (a different person from the requester)', tests.try('web_lead', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:plan1'))), 'ok');
select tests.check('...state approved', (select state::text from document_versions where id = tests.id('ver:plan1')), 'approved');
select tests.check('...the approval is recorded with who approved it', (select (approved_by = tests.id('staff:web_lead') and approved_at is not null)::text from document_versions where id = tests.id('ver:plan1')), 'true');
select tests.check('an approved version is frozen (label and note cannot change)', tests.try_owner(format($q$ update document_versions set label = 'sneaky' where id = %L $q$, tests.id('ver:plan1'))), 'ERR:42501');
select tests.check('signing needs a date that is not in the future, and a note naming who signed',
  tests.try('web_lead', format($q$ select document_version_transition(%L, 'signed', 'Signed by client', current_date + 3) $q$, tests.id('ver:plan1'))) || tests.try('web_lead', format($q$ select document_version_transition(%L, 'signed', ' ', current_date) $q$, tests.id('ver:plan1'))), 'ERR:23514ERR:23514');
select tests.check('the lead records the signature', tests.try('web_lead', format($q$ select document_version_transition(%L, 'signed', 'Signed by John Director', current_date - 1) $q$, tests.id('ver:plan1'))), 'ok');
select tests.check('...with who signed it and when', (select (state = 'signed' and signed_on = current_date - 1 and signed_by = tests.id('staff:web_lead'))::text from document_versions where id = tests.id('ver:plan1')), 'true');
select tests.check('a signed version is immutable for every caller: no edit, no state change, no withdrawal',
  tests.try_owner(format($q$ update document_versions set label = 'x' where id = %L $q$, tests.id('ver:plan1'))) || tests.try_owner(format($q$ update document_versions set state = 'withdrawn' where id = %L $q$, tests.id('ver:plan1'))) || tests.try_owner(format($q$ update document_versions set signed_on = current_date where id = %L $q$, tests.id('ver:plan1')))
  || tests.try('web_lead', format($q$ select document_version_transition(%L, 'withdrawn', 'oops') $q$, tests.id('ver:plan1'))), 'ERR:42501ERR:42501ERR:42501ERR:23514');
select tests.check('an amendment is a NEW version', (tests.add_ver('web_lead', 'plan', 'plan2', 'plan content v2 amended', 'Amendment 1') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('...that records which signed version it amends, while the signed one is untouched', (select concat_ws('|', (select version_no::text from document_versions where id = v2.amends_version_id), v2.state::text, (select state::text from document_versions where id = tests.id('ver:plan1')))
     from document_versions v2 where v2.id = tests.id('ver:plan2')), '1|draft|signed');
select tests.check('separation of duties: the person who submitted a version cannot approve it', tests.try('web_lead', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:plan2'))) || tests.try('web_lead', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:plan2'))), 'okERR:42501');
select tests.check('the CEO (a different person) can approve it', tests.try('ceo', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:plan2'))), 'ok');
select tests.check('a third working version is added', (tests.add_ver('web_lead', 'plan', 'plan3', 'plan content v3 draft') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('withdrawing needs a reason', tests.try('web_lead', format($q$ select document_version_transition(%L, 'withdrawn', ' ') $q$, tests.id('ver:plan3'))) || tests.try('web_lead', format($q$ select document_version_transition(%L, 'withdrawn', 'superseded by v2') $q$, tests.id('ver:plan3'))), 'ERR:23514ok');
select tests.check('a withdrawn version is final', tests.try_owner(format($q$ update document_versions set state = 'draft' where id = %L $q$, tests.id('ver:plan3'))), 'ERR:42501');
select tests.check('version numbers are consecutive and unique per document', (select string_agg(version_no::text, ',' order by version_no) from document_versions where document_id = tests.id('doc:plan')), '1,2,3');
select tests.check('every state change is in the history with the acting staff identity',
  (select string_agg(detail ->> 'to', ',' order by id) from document_events where document_id = tests.id('doc:plan') and kind = 'version_state' and actor_staff_id is not null), 'review,approved,signed,review,approved,withdrawn');
select tests.check('a fourth, secret draft is added', (tests.add_ver('web_lead', 'plan', 'plan4', 'plan content v4 secret draft') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the version state graph is enforced for every caller: a draft cannot be made signed even with the signature fields filled in',
  tests.try_owner(format($q$ update document_versions set state = 'signed', signed_by = %L, signed_at = now(), signed_on = current_date where id = %L $q$, tests.id('staff:web_lead'), tests.id('ver:plan4'))), 'ERR:23514');
select tests.check('...nor approved without a recorded approver', tests.try_owner(format($q$ update document_versions set state = 'review' where id = %L $q$, tests.id('ver:plan4'))) || tests.try_owner(format($q$ update document_versions set state = 'approved' where id = %L $q$, tests.id('ver:plan4'))) || tests.try_owner(format($q$ update document_versions set state = 'draft' where id = %L $q$, tests.id('ver:plan4'))), 'okERR:23514ok');
select tests.check('drafts are private to the people working on them: the auditor (read-only) sees only approved, signed and withdrawn versions; the working lead sees all',
  tests.scalar('audit', format($q$ select string_agg(version_no::text, ',' order by version_no) from document_versions where document_id = %L $q$, tests.id('doc:plan'))) || '/' || tests.scalar('web_lead', format($q$ select string_agg(version_no::text, ',' order by version_no) from document_versions where document_id = %L $q$, tests.id('doc:plan'))), '1,2,3/1,2,3,4');
select tests.check('...and opening the document without a version picked never serves a draft to a viewer', tests.scalar('audit', format($q$ select (document_open(%L, 'read') ->> 'version_no') $q$, tests.id('doc:plan'))), '2');

-- Integrity -------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('a matching check is recorded as a match', tests.scalar('adm2', format($q$ select document_record_integrity_check(%L, %L) $q$, tests.id('ver:plan1'), tests.h('plan content v1'))), 'match');
select tests.check('only documents.configure holders (or the storage service) can record a check', tests.scalar('web_lead', format($q$ select document_record_integrity_check(%L, %L) $q$, tests.id('ver:plan1'), tests.h('plan content v1'))), 'ERR:42501');
select tests.check('a tampered file is detected as a mismatch', tests.scalar('adm2', format($q$ select document_record_integrity_check(%L, %L) $q$, tests.id('ver:plan1'), tests.h('tampered'))), 'mismatch');
select tests.check('...which is permanent evidence', (select count(*)::text from document_integrity_checks where version_id = tests.id('ver:plan1') and result = 'mismatch' and expected_hash = tests.h('plan content v1')), '1');
select tests.check('...and opens an investigation case through the existing security model (kind integrity, high, open)',
  (select concat_ws('|', c.status, c.severity, c.reason) from security_cases c join security_case_events ce on ce.case_id = c.id join security_events e on e.id = ce.event_id where e.kind = 'integrity' limit 1), 'open|high|stored content no longer matches its recorded hash');
select tests.check('...content that failed verification is withheld from everyone until it is re-verified', tests.scalar('web_staff', format($q$ select document_open(%L, 'read', 1)::text $q$, tests.id('doc:plan'))), 'ERR:55000');
select tests.check('...a later matching check clears the hold', tests.scalar('adm2', format($q$ select document_record_integrity_check(%L, %L) $q$, tests.id('ver:plan1'), tests.h('plan content v1'))), 'match');
select tests.check('...and the content is served again', tests.scalar('web_staff', format($q$ select (document_open(%L, 'read', 1) ->> 'version_no') $q$, tests.id('doc:plan'))), '1');
select tests.check('the storage service has its own entry point (service_role only); staff cannot use it', tests.try('adm2', format($q$ select document_service_integrity_check(%L, %L) $q$, tests.id('ver:plan1'), tests.h('plan content v1'))), 'ERR:42501');
select tests.check('a metadata edit is a metadata change', tests.try('web_lead', format($q$ select document_update(%L, jsonb_build_object('title', 'Project plan (renamed)')) $q$, tests.id('doc:plan'))), 'ok');
select tests.check('...not a content change: every hash is as it was', (select (string_agg(content_hash, ',' order by version_no) = string_agg(tests.h(c), ',' order by version_no))::text from document_versions v join (values (1, 'plan content v1'), (2, 'plan content v2 amended'), (3, 'plan content v3 draft'), (4, 'plan content v4 secret draft')) t(n, c) on t.n = v.version_no where v.document_id = tests.id('doc:plan')), 'true');
select tests.check('metadata changes are recorded as such (field names only)', (select (detail -> 'fields') ? 'title' from document_events where document_id = tests.id('doc:plan') and kind = 'metadata' order by id desc limit 1)::text, 'true');
select tests.check('unknown or identity fields cannot be edited through document_update', tests.try('web_lead', format($q$ select document_update(%L, jsonb_build_object('institutional_id', 'AAAAAAAAA')) $q$, tests.id('doc:plan'))) || tests.try('web_lead', format($q$ select document_update(%L, jsonb_build_object('division_id', %L)) $q$, tests.id('doc:plan'), tests.id('div:tech'))), 'ERR:23514ERR:23514');

-- Relationships: references, never copies -------------------------------------------------------------------------------------------------------------
select tests.check('no entity details are copied into documents or links (no name / email / phone / title columns)',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name in ('documents', 'document_links', 'document_versions', 'document_events', 'document_access')
     and column_name ~ '(client|project|supplier|contact|person|customer|organi[sz]ation|invoice|contract)_?(name|email|phone|title)|^(email|phone)'), 'none');
select tests.check('the web lead links the document to the client, the project, the contract and the signing contact''s person record',
  (tests.scalar('web_lead', format($q$ select document_link_add(%L, (select institutional_id from entity_registry where entity_id = %L))::text $q$, tests.id('doc:plan'), tests.id('client:abc'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.remember('link:proj', tests.scalar('web_lead', format($q$ select document_link_add(%L, (select institutional_id from entity_registry where entity_id = %L), 'supporting')::text $q$, tests.id('doc:plan'), tests.id('project:abc'))));
select tests.remember('link:ctr', tests.scalar('web_lead', format($q$ select document_link_add(%L, (select ada_id from entity_registry where entity_id = %L), 'evidence')::text $q$, tests.id('doc:plan'), tests.id('contract:1'))));
select tests.check('a link is a reference by institutional ID to a registered entity (client, project, contract)',
  (select string_agg(r.entity_type || ':' || dl.role, ',' order by r.entity_type) from document_links dl join entity_registry r on r.institutional_id = dl.entity_institutional_id where dl.document_id = tests.id('doc:plan')), 'client:subject,contract:evidence,project:supporting');
select tests.check('the same link twice is refused', tests.try('web_lead', format($q$ select document_link_add(%L, (select institutional_id from entity_registry where entity_id = %L))::text $q$, tests.id('doc:plan'), tests.id('client:abc'))), 'ERR:23505');
create temp table conf_inst as select institutional_id i from entity_registry where entity_id = tests.id('client:C_conf');
select tests.check('a link to a hidden record behaves exactly like a link to a record that does not exist (same error)', (tests.scalar('web_lead', format($q$ select document_link_add(%L, %L)::text $q$, tests.id('doc:plan'), (select i from conf_inst))) = tests.scalar('web_lead', format($q$ select document_link_add(%L, 'ZZZZZZZZZ')::text $q$, tests.id('doc:plan'))))::text, 'true');
select tests.check('no one can write document_links directly with a hidden target (row security)', tests.try('web_lead', format($q$ insert into document_links (document_id, entity_institutional_id) values (%L, %L) $q$, tests.id('doc:plan'), (select i from conf_inst))), 'ERR:42501');
select tests.check('...and the CEO (who may know that client) can link to it', tests.try('ceo', format($q$ select document_link_add(%L, %L) $q$, tests.id('doc:plan'), (select i from conf_inst))), 'ok');
select tests.check('...nor update or delete a link directly', tests.try('web_lead', format($q$ update document_links set role = 'reference' where document_id = %L $q$, tests.id('doc:plan'))) || tests.try_owner(format('delete from document_links where document_id = %L', tests.id('doc:plan'))), 'ERR:42501ERR:42501');
select tests.check('the document inherits the highest classification of what it is linked to: the confidential client makes it confidential',
  (select effective_classification::text from documents where id = tests.id('doc:plan')), 'confidential');
select tests.check('...so the web lead (who cannot see confidential records) no longer sees the document at all', tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:plan'))), '0');
select tests.check('removing the link needs a reason', tests.try('ceo', format($q$ select document_link_remove((select id from document_links where document_id = %L and entity_institutional_id = %L), ' ') $q$, tests.id('doc:plan'), (select i from conf_inst))) || tests.try('ceo', format($q$ select document_link_remove((select id from document_links where document_id = %L and entity_institutional_id = %L), 'linked by mistake') $q$, tests.id('doc:plan'), (select i from conf_inst))), 'ERR:23514ok');
select tests.check('...and lowers the classification again', (select effective_classification::text from documents where id = tests.id('doc:plan')), 'internal');
select tests.check('...and the web lead sees it again', tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:plan'))), '1');
select tests.check('removal is soft: the link stays in history with who removed it and why', (select concat_ws('|', (removed_at is not null)::text, removal_reason, (removed_by = tests.id('staff:ceo'))::text) from document_links where document_id = tests.id('doc:plan') and entity_institutional_id = (select i from conf_inst)), 'true|linked by mistake|true');
select tests.check('a removed link cannot be removed again', tests.try('ceo', format($q$ select document_link_remove((select id from document_links where document_id = %L and entity_institutional_id = %L), 'again') $q$, tests.id('doc:plan'), (select i from conf_inst))), 'ERR:23514');

-- Retrieval through the graph (no table or blob scans) -------------------------------------------------------------------------------------------------------
select tests.check('Project 360 has a Documents section listing the document, with its current version and no storage reference',
  tests.scalar('web_lead', format($q$ select (project_360(%L) -> 'documents' -> 0 ->> 'title') || '|' || (project_360(%L) -> 'documents' -> 0 -> 'version' -> 'current' ->> 'version_no') || '|' || (project_360(%L)::text !~ 'obj/|memstore|othercloud|storage_key')::text $q$, tests.id('project:abc'), tests.id('project:abc'), tests.id('project:abc'))), 'Project plan (renamed)|4|true');
select tests.check('...the project''s section is not a flattened copy: it lists the document once, not once per section', tests.scalar('web_lead', format($q$ select jsonb_array_length(project_360(%L) -> 'documents')::text $q$, tests.id('project:abc'))), '1');
select tests.check('Client 360 shows the same document (direct link) and Documents is no longer a pending module',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(client_360(%L) -> 'documents')::text || ((client_360(%L) -> 'pending') ? 'documents')::text $q$, tests.id('client:abc'), tests.id('client:abc'))), '1false');
select tests.check('the request resolves through the registry by institutional ID or legacy alias',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true))::text $q$, tests.id('client:abc'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(documents_for_entity((select ada_id from entity_registry where entity_id = %L)))::text $q$, tests.id('project:abc'))), '11');
select tests.check('the client itself has the document by a direct link; including children does not duplicate it',
  tests.scalar('ceo', format($q$ select jsonb_array_length(documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => false))::text $q$, tests.id('client:abc'))), '1');
select tests.check('an unknown or hidden entity returns null, identically', tests.scalar('web_lead', format($q$ select coalesce(documents_for_entity(%L)::text, 'null') $q$, (select i from conf_inst))) || tests.scalar('web_lead', $q$ select coalesce(documents_for_entity('ZZZZZZZZZ')::text, 'null') $q$), 'nullnull');
select tests.check('time expressions are interpreted by period_resolve (last month / this quarter)',
  (select (period_resolve('last_month', date '2026-10-08') = daterange('2026-09-01', '2026-09-30', '[]') and period_resolve('this_quarter', date '2026-10-08') = daterange('2026-10-01', '2026-12-31', '[]'))::text), 'true');

-- Historical review -----------------------------------------------------------------------------------------------------------------------------------
select tests.backdate_doc('doc:plan', interval '100 days');
select tests.mk_doc('web_lead', 'hist', 'Service agreement', 'contract', 'web', 'project:abc');
select tests.add_ver('web_lead', 'hist', 'h1', 'agreement draft');
select tests.try('web_lead', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:h1')));
select tests.try('ceo', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:h1')));
select tests.try('ceo', format($q$ select document_version_transition(%L, 'signed', 'Signed by both parties', current_date - 40) $q$, tests.id('ver:h1')));
select tests.backdate_doc('doc:hist', interval '40 days');
select tests.add_ver('web_lead', 'hist', 'h2', 'agreement amendment 1', 'Amendment 1');
select tests.check('"the signed contract": the signed version of the project''s contract is found through the project link, as it stood 20 days ago',
  tests.scalar('web_lead', format($q$ select (documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_as_of => now() - interval '20 days', p_signed_only => true) -> 0 -> 'version' -> 'signed' ->> 'version_no') $q$, tests.id('project:abc'))), '1');
select tests.check('...at that time the amendment did not exist yet (the current version was the signed one); today the amendment draft is the working version',
  tests.scalar('web_lead', format($q$ select (document_version_as_of(%L, now() - interval '20 days') -> 'current' ->> 'version_no') || '/' || (document_version_as_of(%L) -> 'current' ->> 'version_no') || '/' || (document_version_as_of(%L) -> 'signed' ->> 'version_no') $q$, tests.id('doc:hist'), tests.id('doc:hist'), tests.id('doc:hist'))), '1/2/1');
select tests.check('...a viewer who cannot work drafts still sees the signed version as current today (the draft amendment is private)', tests.scalar('audit', format($q$ select (document_version_as_of(%L) -> 'current' ->> 'version_no') $q$, tests.id('doc:hist'))), '1');
select tests.check('before the agreement existed it is not part of the answer: 60 days ago only the older plan document was attached to the project', tests.scalar('web_lead', format($q$ select (select string_agg(x ->> 'title', ',') from jsonb_array_elements(documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_as_of => now() - interval '60 days')) x) $q$, tests.id('project:abc'))), 'Project plan (renamed)');
select tests.check('date filters use the document date', tests.scalar('web_lead', format($q$ select jsonb_array_length(documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_from => current_date + 10))::text $q$, tests.id('project:abc'))), '0');
select tests.check('a link can be removed with a reason', tests.try('web_lead', format($q$ select document_link_remove(%L, 'moved to the contract only') $q$, tests.id('link:proj'))), 'ok');
select tests.check('...and the removed link still answers "what was attached then" (one second before the removal... both documents; 60 days ago the plan)', tests.scalar('web_lead', format($q$ select jsonb_array_length(documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_as_of => now() - interval '60 days'))::text $q$, tests.id('project:abc'))), '1');
select tests.check('...but not today', tests.scalar('web_lead', format($q$ select (select string_agg(x ->> 'title', ',' order by x ->> 'title') from jsonb_array_elements(documents_for_entity((select institutional_id from entity_registry where entity_id = %L))) x) $q$, tests.id('project:abc'))), 'Service agreement');

-- Archive / restore / hold / retention / disposal ---------------------------------------------------------------------------------------------------------------
select tests.check('a type''s retention class is applied at registration and snapshotted on the document',
  (select concat_ws('|', rc.key, d.retention_months::text) from documents d join retention_classes rc on rc.id = d.retention_class_id where d.id = tests.id('doc:plan')) || '/' || (select concat_ws('|', rc.key, d.retention_months::text) from documents d join retention_classes rc on rc.id = d.retention_class_id where d.id = tests.id('doc:hist')), 'general_5y|60/contract_10y|120');
select tests.check('changing a retention class later is allowed (configure)', tests.try('adm2', $q$ update retention_classes set period_months = 1 where key = 'general_5y' $q$), 'ok');
select tests.check('...and does not shorten a record already held', (select retention_months::text from documents where id = tests.id('doc:plan')), '60');
select tests.check('retention changes only through document_set_retention, which needs documents.configure and a reason',
  tests.try_owner(format('update documents set retention_months = 1 where id = %L', tests.id('doc:plan'))) || tests.try('web_lead', format($q$ select document_set_retention(%L, 'transient_1y', null, 'x') $q$, tests.id('doc:plan'))) || tests.try('adm2', format($q$ select document_set_retention(%L, 'transient_1y', null, ' ') $q$, tests.id('doc:plan'))), 'ERR:42501ERR:42501ERR:23514');
select tests.check('a short-lived working copy is registered', (tests.mk_doc('web_lead', 'tmp', 'Working copy', 'other', 'web') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.add_ver('web_lead', 'tmp', 'tmp1', 'working copy content');
select tests.check('retention start and class are set by an administrator (start 800 days ago, 12 months)', tests.try('adm2', format($q$ select document_set_retention(%L, 'transient_1y', current_date - 800, 'working copy') $q$, tests.id('doc:tmp'))), 'ok');
select tests.check('...the derived view gives the end date', (select retention_ends_on::text from document_retention_status where document_id = tests.id('doc:tmp')), (current_date - 800 + interval '12 months')::date::text);
select tests.check('the derived retention view says: not archived yet, so not disposable; no stored flag exists',
  (select concat_ws('|', disposition, disposal_eligible::text, on_legal_hold::text) from document_retention_status where document_id = tests.id('doc:tmp')) || (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'documents' and column_name ~ 'eligible|disposition|on_hold'), 'retained|false|falsenone');
select tests.check('disposal cannot be requested for an active document', tests.scalar('adm2', format($q$ select document_request_disposal(%L, 'obsolete')::text $q$, tests.id('doc:tmp'))), 'ERR:42501');
select tests.check('archiving needs documents.archive and a reason', tests.try('web_staff', format($q$ select document_archive(%L, 'x') $q$, tests.id('doc:tmp'))) || tests.try('web_lead', format($q$ select document_archive(%L, ' ') $q$, tests.id('doc:tmp'))) || tests.try('web_lead', format($q$ select document_archive(%L, 'no longer used') $q$, tests.id('doc:tmp'))), 'ERR:42501ERR:23514ok');
select tests.check('an archived document cannot be edited or given new versions, but can still be read by those entitled',
  tests.try('web_lead', format($q$ select document_update(%L, jsonb_build_object('title', 'x')) $q$, tests.id('doc:tmp'))) || tests.add_ver('web_lead', 'tmp', 'tmp2', 'more') || tests.scalar('web_lead', format($q$ select (document_open(%L, 'read') ->> 'version_no') $q$, tests.id('doc:tmp'))), 'ERR:42501ERR:42501' || '1');
select tests.check('restoring is possible, and recorded', tests.try('web_lead', format($q$ select document_restore(%L, 'needed again') $q$, tests.id('doc:tmp'))) || tests.try('web_lead', format($q$ select document_archive(%L, 'archived again') $q$, tests.id('doc:tmp'))), 'okok');
select tests.check('a legal hold can be placed only by documents.legal_hold holders', tests.try('web_lead', format($q$ select document_hold_place(%L, 'litigation') $q$, tests.id('doc:tmp'))) || tests.try('ceo', format($q$ select document_hold_place(%L, 'litigation: Acme dispute') $q$, tests.id('doc:tmp'))), 'ERR:42501ok');
select tests.check('a legal hold overrides retention: disposal cannot even be requested', tests.scalar('adm2', format($q$ select document_request_disposal(%L, 'obsolete')::text $q$, tests.id('doc:tmp'))), 'ERR:23514');
select tests.check('...and no caller, not even the database owner, can dispose a held document',
  tests.try_owner(format($q$ select set_config('ada.document_disposal', 'on', true); update documents set status = 'disposed' where id = %L $q$, tests.id('doc:tmp'))), 'ERR:42501');
select tests.check('the derived view shows the hold', (select concat_ws('|', on_legal_hold::text, disposal_eligible::text) from document_retention_status where document_id = tests.id('doc:tmp')), 'true|false');
select tests.check('releasing the hold needs a reason', tests.try('ceo', format($q$ select document_hold_release((select id from document_holds where document_id = %L), ' ') $q$, tests.id('doc:tmp'))) || tests.try('ceo', format($q$ select document_hold_release((select id from document_holds where document_id = %L), 'dispute settled') $q$, tests.id('doc:tmp'))), 'ERR:23514ok');
select tests.check('a disposal can be requested once retention has elapsed, with no hold', tests.remember_ok('disp:tmp', tests.scalar('adm2', format($q$ select document_request_disposal(%L, 'retention elapsed; no longer needed')::text $q$, tests.id('doc:tmp')))), 'ok');
select tests.check('...the requester cannot approve their own request (and needs documents.dispose anyway)', tests.try('adm2', format($q$ select document_disposal_decide(%L, true) $q$, tests.id('disp:tmp'))), 'ERR:42501');
select tests.check('...nothing was disposed automatically', (select status::text from documents where id = tests.id('doc:tmp')), 'archived');
select tests.check('a rejection needs a note', tests.try('ceo', format($q$ select document_disposal_decide(%L, false) $q$, tests.id('disp:tmp'))), 'ERR:23514');
select tests.check('the CEO approves the disposal', tests.scalar('ceo', format($q$ select document_disposal_decide(%L, true, 'approved') $q$, tests.id('disp:tmp'))), 'approved');
select tests.check('...the document is disposed, its content references are detached and handed to the storage service',
  (select status::text from documents where id = tests.id('doc:tmp')) || '|' || (select count(*)::text from document_versions where document_id = tests.id('doc:tmp') and content_purged_at is not null and storage_key is null)
  || '|' || (select (purge_manifest -> 0 ->> 'key') from document_disposals where document_id = tests.id('doc:tmp')), 'disposed|1|obj/tmp1');
select tests.check('...the identity, metadata and hash remain (a tombstone)',
  (select count(*)::text from entity_registry where entity_id = tests.id('doc:tmp') and status = 'disposed') || (select (content_hash = tests.h('working copy content'))::text from document_versions where document_id = tests.id('doc:tmp')), '1true');
select tests.check('...and the content can no longer be opened', tests.scalar('web_lead', format($q$ select coalesce(document_open(%L, 'read')::text, 'null') $q$, tests.id('doc:tmp'))), 'null');
select tests.check('...a disposed document is closed: no edits, no restore, no versions', tests.try('ceo', format($q$ select document_update(%L, jsonb_build_object('title', 'x')) $q$, tests.id('doc:tmp'))) || tests.try('ceo', format($q$ select document_restore(%L, 'x') $q$, tests.id('doc:tmp'))) || tests.try_owner(format($q$ update documents set title = 'x' where id = %L $q$, tests.id('doc:tmp'))), 'ERR:42501ERR:42501ERR:42501');
select tests.check('the storage service confirms the physical deletion (service role only)', tests.try('ceo', format('select document_disposal_confirm(%L)', tests.id('disp:tmp'))) || tests.try_owner(format('select document_disposal_confirm(%L)', tests.id('disp:tmp'))), 'ERR:42501ok');
select tests.check('...recorded as executed', (select state from document_disposals where id = tests.id('disp:tmp')), 'executed');
select tests.mk_doc('web_lead', 'pol', 'Founding policy', 'policy', 'web');
select tests.try('web_lead', format($q$ select document_archive(%L, 'superseded') $q$, tests.id('doc:pol')));
select tests.check('a permanent record (policy) is never disposed, even once archived', tests.scalar('adm2', format($q$ select document_request_disposal(%L, 'tidy up')::text $q$, tests.id('doc:pol'))), 'ERR:23514');
select tests.check('documents and links are never deleted by anyone', tests.try_owner(format('delete from documents where id = %L', tests.id('doc:plan'))) || tests.try('ceo', format('delete from documents where id = %L', tests.id('doc:plan'))), 'ERR:42501ERR:42501');

-- Audit ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('creation, version, link, approval, signing, archive and disposal are in the document''s own history, in order, with staff identity',
  (select string_agg(distinct kind, ',' order by kind) from document_events where document_id in (tests.id('doc:plan'), tests.id('doc:tmp'))),
  'archived,created,disposal_decided,disposal_executed,disposal_requested,downloaded,hold_placed,hold_released,integrity,link_added,link_removed,metadata,opened,relocated,restored,retention,transferred,version_added,version_state');
select tests.check('every event names the acting staff member (only the storage service''s own confirmation has none)', (select count(*)::text from document_events where actor_staff_id is null and kind <> 'disposal_executed' and document_id in (tests.id('doc:plan'), tests.id('doc:tmp'), tests.id('doc:hist'))), '0');
select tests.check('history cannot be rewritten', tests.try_owner(format('update document_events set kind = ''created'' where document_id = %L', tests.id('doc:plan'))) || tests.try_owner(format('delete from document_events where document_id = %L', tests.id('doc:plan'))), 'ERR:42501ERR:42501');
select tests.check('the audit log records document changes with the actor and the institutional ID of the record',
  (select (count(*) filter (where table_name = 'documents') > 3 and count(*) filter (where table_name = 'document_versions') > 5 and count(*) filter (where table_name = 'document_links') > 2
     and bool_and(actor_staff_id is not null) filter (where table_name = 'documents' and action = 'UPDATE' and actor_staff_id is not null)
     and bool_and(record_institutional_id is not null) filter (where table_name = 'documents'))::text from audit_log where table_name like 'document%'), 'true');

select tests.finish();
rollback;
