-- PERMANENT: Documents - access is a decision per action (never a label), classification and restricted-client inheritance, CRITICAL documents
-- that leak nothing anywhere, explicit grants, hidden-record behaviour, the approved public projection and its allow-list, search as an
-- accelerator only, integration with the security investigation model, and definite (never NULL) access predicates.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.acts(p_user text, p_doc_key text) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select string_agg(case when document_can(%L, a) then '1' else '0' end, '' order by n) from unnest(array['view','read','download','upload','edit','comment','share','approve','publish','archive']) with ordinality t(a, n) $q$, tests.id(p_doc_key)))
$$;

-- The action matrix: permission in the owning division, ownership, never the label ---------------------------------------------------------------------------------
select tests.mk_doc('web_lead', 'D1', 'Web handover notes', 'report', 'web', 'project:abc');
select tests.add_ver('web_lead', 'D1', 'D1v1', 'handover notes v1');
select tests.try('web_lead', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:D1v1')));
select tests.try('ceo', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:D1v1')));
select tests.check('action matrix (view read download upload edit comment share approve publish archive): the owning lead', tests.acts('web_lead', 'doc:D1'), '1111111101');
select tests.check('...division staff: can look, read, download, upload and comment, but not edit (not the owner), share, approve or archive', tests.acts('web_staff', 'doc:D1'), '1111010000');
select tests.check('...finance (organisation-wide, internal records): everything except share / approve / publish / archive', tests.acts('fin', 'doc:D1'), '1111110000');
select tests.check('...the auditor: view and read only - no download, no change', tests.acts('audit', 'doc:D1'), '1100000000');
select tests.check('...administration: all but approve and publish', tests.acts('adm2', 'doc:D1'), '1111111001');
select tests.check('...the CEO: everything the lifecycle allows', tests.acts('ceo', 'doc:D1'), '1111111111');
select tests.check('...another division, the recruiter, an outsider (no staff record) and a suspended account: nothing at all',
  tests.acts('tech_staff', 'doc:D1') || tests.acts('tech_lead', 'doc:D1') || tests.acts('recruiter', 'doc:D1') || tests.acts('outsider', 'doc:D1') || tests.acts('suspended', 'doc:D1'), repeat('0000000000', 5));
select tests.check('entity visibility, metadata visibility, content access and modification are different questions: the auditor sees the record and the version list but is refused the download and any change',
  tests.scalar('audit', format($q$ select (select count(*) from documents where id = %L)::text || (document_open(%L, 'download') is null)::text || (select count(*) from document_versions where document_id = %L)::text $q$, tests.id('doc:D1'), tests.id('doc:D1'), tests.id('doc:D1'))) ||
  tests.try('audit', format($q$ select document_update(%L, jsonb_build_object('title', 'x')) $q$, tests.id('doc:D1'))), '1true1ERR:42501');
select tests.check('a denied download by someone who may view is a null (not an error) and is recorded as a lookup event', (select count(*)::text from security_events where requested_action = 'document.download' and actor_staff_id = tests.id('staff:audit')), '1');
select tests.check('the owner has view / read / download / upload / edit / comment on their own document but not share / approve / publish', tests.try_owner(format('update documents set owner_staff_id = %L where id = %L', tests.id('staff:web_staff'), tests.id('doc:D1'))) || tests.acts('web_staff', 'doc:D1'), 'ok1111110000');
select tests.try_owner(format('update documents set owner_staff_id = %L where id = %L', tests.id('staff:web_lead'), tests.id('doc:D1')));
select tests.check('registering above your own clearance, or a classification other than the type''s default without records.classify, is refused',
  tests.mk_doc('web_lead', 'x1', 'x', 'report', 'web', null, 'restricted') || tests.mk_doc('adm2', 'x2', 'x', 'report', 'web', null, 'confidential') || tests.mk_doc('adm2', 'x3', 'x', 'hr_record', 'web'), 'ERR:42501ERR:42501ERR:42501');
select tests.check('...while a type whose default is restricted works for those cleared for it', (tests.mk_doc('ceo', 'L1', 'Supplier dispute file', 'legal', 'web', 'client:abc') ~ '^[0-9a-f-]{36}$')::text, 'true');

-- Classification: restricted / confidential documents are unknown to the uncleared ---------------------------------------------------------------------------------
select tests.add_ver('ceo', 'L1', 'L1v1', 'legal file content');
select tests.check('a restricted document is visible to the cleared (CEO, administration, auditor) and not to the web lead or division staff',
  tests.scalar('ceo', format('select count(*)::text from documents where id = %L', tests.id('doc:L1'))) || tests.scalar('adm2', format('select count(*)::text from documents where id = %L', tests.id('doc:L1'))) || tests.scalar('audit', format('select count(*)::text from documents where id = %L', tests.id('doc:L1')))
  || tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:L1'))) || tests.scalar('web_staff', format('select count(*)::text from documents where id = %L', tests.id('doc:L1'))), '11100');
select tests.check('to the uncleared, every probe of it is indistinguishable from a random ID (360, open, update, version, link, share, comment, archive, classify, publish)',
  tests.same_for('web_lead', $q$ select coalesce(document_360(%L)::text, 'null') $q$, tests.id('doc:L1'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select coalesce(document_open(%L)::text, 'null') $q$, tests.id('doc:L1'), tests.id('x:random'))
  || tests.same_for('web_lead', $q$ select document_update(%L, jsonb_build_object('title', 'x'))::text $q$, tests.id('doc:L1'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select document_comment_add(%L, 'hi')::text $q$, tests.id('doc:L1'), tests.id('x:random'))
  || tests.same_for('web_lead', $q$ select document_archive(%L, 'x')::text $q$, tests.id('doc:L1'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select document_share(%L, null, (select id from divisions where key = 'web'), array['read'], null, 'x')::text $q$, tests.id('doc:L1'), tests.id('x:random'))
  || tests.same_for('web_lead', $q$ select document_set_classification(%L, 'public', null, 'x')::text $q$, tests.id('doc:L1'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select document_link_add(%L, 'ZZZZZZZZZ')::text $q$, tests.id('doc:L1'), tests.id('x:random'))
  || tests.same_for('web_lead', $q$ select document_add_version(%L, 'm', 'k', repeat('a', 64), 5, 'application/pdf')::text $q$, tests.id('doc:L1'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select document_publication_request(%L, 1, 'x')::text $q$, tests.id('doc:L1'), tests.id('x:random')),
  repeat('same', 10));
select tests.check('...and for versions, links and holds of it', tests.same_for('web_lead', $q$ select document_version_transition(%L, 'review')::text $q$, tests.id('ver:L1v1'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select document_record_integrity_check(%L, null)::text $q$, tests.id('ver:L1v1'), tests.id('x:random'))
  || tests.same_for('web_lead', $q$ select document_hold_release(%L, 'x')::text $q$, tests.id('x:random'), tests.id('x:random')), 'samesamesame');
select tests.check('the whole visible register shows no trace of it (documents, versions, links, events, comments, counts)',
  tests.scalar('web_lead', 'select (select count(*) from documents where title like ''Supplier%'')::text || (select count(*) from document_versions where document_id = ' || quote_literal(tests.id('doc:L1')) || ')::text || (select count(*) from document_links where document_id = ' || quote_literal(tests.id('doc:L1')) || ')::text || (select count(*) from document_events where document_id = ' || quote_literal(tests.id('doc:L1')) || ')::text'), '0000');
select tests.check('...and not in the registry, the directory or the location history for them',
  tests.scalar('web_lead', format('select (select count(*) from entity_registry where entity_id = %L)::text || (select count(*) from entity_directory where authoritative_record_key = %L)::text', tests.id('doc:L1'), tests.id('doc:L1'))), '00');
select tests.check('...and the document does not appear in Client 360 / Documents-for-entity for the web lead, but does for the CEO',
  tests.scalar('web_lead', format($q$ select (select count(*) from jsonb_array_elements(client_360(%L) -> 'documents') x where x ->> 'title' like 'Supplier%%')::text $q$, tests.id('client:abc'))) || tests.scalar('ceo', format($q$ select (select count(*) from jsonb_array_elements(client_360(%L) -> 'documents') x where x ->> 'title' like 'Supplier%%')::text $q$, tests.id('client:abc'))), '01');

-- Restricted-client inheritance (both directions) ---------------------------------------------------------------------------------------------------------------
select tests.check('before: the web lead and staff see the handover notes linked to the project', tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))) || tests.scalar('web_staff', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))), '11');
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('the client becomes restricted: the document linked to its project inherits it', (select effective_classification::text from documents where id = tests.id('doc:D1')), 'restricted');
select tests.check('...and the web lead, staff and finance lose sight of it in every table', tests.scalar('web_lead', format('select (select count(*) from documents where id = %L)::text || (select count(*) from document_versions where document_id = %L)::text || (select count(*) from document_links where document_id = %L)::text || (select count(*) from document_events where document_id = %L)::text', tests.id('doc:D1'), tests.id('doc:D1'), tests.id('doc:D1'), tests.id('doc:D1'))) || tests.scalar('fin', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))), '00000');
select tests.check('...open and 360 become denials indistinguishable from a random ID', tests.same_for('web_lead', $q$ select coalesce(document_open(%L)::text, 'null') $q$, tests.id('doc:D1'), tests.id('x:random')) || tests.same_for('web_staff', $q$ select coalesce(document_360(%L)::text, 'null') $q$, tests.id('doc:D1'), tests.id('x:random')), 'samesame');
select tests.check('the CEO, administration and the auditor still see it', tests.scalar('ceo', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))) || tests.scalar('adm2', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))) || tests.scalar('audit', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))), '111');
update clients set classification = 'internal' where id = tests.id('client:abc');
select tests.check('the client is un-restricted: the document returns to the people who lost it', (select effective_classification::text from documents where id = tests.id('doc:D1')) || tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:D1'))), 'internal1');
select tests.check('classification propagates through the registry mirror too (registry classification follows the document)', (select classification::text from entity_registry where entity_id = tests.id('doc:D1')), 'internal');

-- CRITICAL documents: no trace for anyone without an explicit entitlement --------------------------------------------------------------------------------------
select tests.mk_doc('ceo', 'C1', 'Board resolution on acquisition', 'report', 'web', 'project:abc', null, true);
select tests.add_ver('ceo', 'C1', 'C1v1', 'critical board content');
select tests.check('a critical document is visible to its owner and to documents.view_critical holders (the CEO), and to nobody else - not even people cleared for everything else',
  tests.scalar('ceo', format('select count(*)::text from documents where id = %L', tests.id('doc:C1'))) || tests.scalar('audit', format('select count(*)::text from documents where id = %L', tests.id('doc:C1'))) || tests.scalar('adm2', format('select count(*)::text from documents where id = %L', tests.id('doc:C1')))
  || tests.scalar('web_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:C1'))) || tests.scalar('fin', format('select count(*)::text from documents where id = %L', tests.id('doc:C1'))), '10000');
select tests.check('without a clearance the type default does not make a document critical; only documents.view_critical holders can choose it', tests.mk_doc('web_lead', 'C2', 'x', 'report', 'web', null, null, true), 'ERR:42501');
select tests.check('no leakage anywhere for the auditor: documents, versions, links, events, registry, directory, 360, open',
  tests.scalar('audit', format($q$ select (select count(*) from documents where title like 'Board%%')::text || (select count(*) from document_versions where document_id = %L)::text || (select count(*) from document_links where document_id = %L)::text || (select count(*) from document_events where document_id = %L)::text
      || (select count(*) from entity_registry where entity_id = %L)::text || (select count(*) from entity_directory where authoritative_record_key = %L)::text || coalesce(document_360(%L)::text, 'null') || coalesce(document_open(%L)::text, 'null') $q$,
      tests.id('doc:C1'), tests.id('doc:C1'), tests.id('doc:C1'), tests.id('doc:C1'), tests.id('doc:C1'), tests.id('doc:C1'), tests.id('doc:C1'))), '000000nullnull');
create temp table c1_inst as select institutional_id i from entity_registry where entity_id = tests.id('doc:C1');
select tests.check('...resolving its institutional ID, getting it, or routing a search by it returns nothing, exactly like an ID that was never issued',
  tests.scalar('audit', format($q$ select coalesce(entity_resolve(%L)::text, 'null') || coalesce(entity_get(%L)::text, 'null') || (search_route(%L) -> 'results')::text $q$, (select i from c1_inst), (select i from c1_inst), (select i from c1_inst))),
  tests.scalar('audit', $q$ select coalesce(entity_resolve('ZZZZZZZZZ')::text, 'null') || coalesce(entity_get('ZZZZZZZZZ')::text, 'null') || (search_route('ZZZZZZZZZ') -> 'results')::text $q$));
select tests.check('...the related project''s Documents section, Project 360 and documents-for-entity do not list it for others',
  tests.scalar('web_lead', format($q$ select (select count(*) from jsonb_array_elements(project_360(%L) -> 'documents') x where x ->> 'title' like 'Board%%')::text || (select count(*) from jsonb_array_elements(documents_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true)) x where x ->> 'title' like 'Board%%')::text $q$, tests.id('project:abc'), tests.id('project:abc'))) ||
  tests.scalar('ceo', format($q$ select (select count(*) from jsonb_array_elements(project_360(%L) -> 'documents') x where x ->> 'title' like 'Board%%')::text $q$, tests.id('project:abc'))), '001');
select tests.check('...the audit log and the history show nothing about it to an auditor (audit.view is not a back door)',
  tests.scalar('audit', format($q$ select (select count(*) from audit_log where table_name = 'documents' and record_id = %L)::text || (select count(*) from audit_log where table_name = 'document_versions' and new_data ->> 'document_id' = %L)::text || (select count(*) from audit_log where table_name = 'document_links' and new_data ->> 'document_id' = %L)::text $q$, tests.id('doc:C1'), tests.id('doc:C1')::text, tests.id('doc:C1')::text)) ||
  tests.scalar('ceo', format($q$ select (select (count(*) > 0)::text from audit_log where table_name = 'documents' and record_id = %L) $q$, tests.id('doc:C1'))), '000true');
select tests.check('...and the security records do not reveal that a critical document exists: a probe of it is recorded exactly like a probe of a random ID',
  tests.scalar('web_lead', format($q$ select coalesce(document_open(%L)::text, 'null') $q$, tests.id('doc:C1'))) || tests.scalar('web_lead', format($q$ select coalesce(document_open(%L)::text, 'null') $q$, tests.id('x:random'))), 'nullnull');
select tests.check('...(entity_exists, class and reason are identical)',
  (select count(distinct (entity_exists, coalesce(entity_class::text, '-'), reason))::text from security_events where actor_staff_id = tests.id('staff:web_lead') and requested_action = 'document.read' and requested_input in ((select i from c1_inst), tests.id('x:random')::text, tests.id('doc:C1')::text)), '1');
select tests.check('the non-owner CEO can open it; every open is recorded', tests.scalar('ceo', format($q$ select (document_open(%L, 'read') ->> 'version_no') $q$, tests.id('doc:C1'))), '1');
select tests.check('critical documents are not publishable and not in the public API, whatever their classification',
  tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, 'x')::text $q$, tests.id('doc:C1'))), 'ERR:23514');

-- Explicit grants: named, per-action, expiring; never a way around classification --------------------------------------------------------------------------------
select tests.check('sharing needs documents.share; a viewer without it cannot share', tests.try('web_staff', format($q$ select document_share(%L, %L, null, array['read'], null, 'x') $q$, tests.id('doc:D1'), tests.id('staff:tech_staff'))), 'ERR:42501');
select tests.check('sharing a critical document needs an expiry and a reason', tests.try('ceo', format($q$ select document_share(%L, %L, null, array['read'], null, 'board review') $q$, tests.id('doc:C1'), tests.id('staff:web_lead'))) || tests.try('ceo', format($q$ select document_share(%L, %L, null, array['read'], now() + interval '2 days', ' ') $q$, tests.id('doc:C1'), tests.id('staff:web_lead'))), 'ERR:23514ERR:23514');
select tests.check('a share can grant only view / read / download / comment, to an active staff member or a division',
  tests.try('ceo', format($q$ select document_share(%L, %L, null, array['approve'], now() + interval '2 days', 'x') $q$, tests.id('doc:C1'), tests.id('staff:web_lead'))) || tests.try('ceo', format($q$ select document_share(%L, %L, null, array['read'], now() + interval '2 days', 'x') $q$, tests.id('doc:C1'), tests.id('x:random'))) || tests.try('ceo', format($q$ select document_share(%L, null, null, array['read'], now() + interval '2 days', 'x') $q$, tests.id('doc:C1'))), 'ERR:23514ERR:23514ERR:23514');
select tests.remember('grant:C1', tests.scalar('ceo', format($q$ select document_share(%L, %L, null, array['read'], now() + interval '2 days', 'board review')::text $q$, tests.id('doc:C1'), tests.id('staff:web_lead'))));
select tests.check('the grantee can now discover and read the critical document, but not download, edit, or share it (grants are per action)', tests.acts('web_lead', 'doc:C1'), '1100000000');
select tests.check('...and everyone else is still excluded', tests.acts('web_staff', 'doc:C1') || tests.acts('audit', 'doc:C1'), '00000000000000000000');
select tests.check('...the grant and its use are in the history, with names', (select string_agg(kind, ',' order by id) from document_events where document_id = tests.id('doc:C1') and kind in ('shared', 'opened')) , 'opened,shared');
select tests.check('revoking the grant removes access at once', tests.try('ceo', format($q$ select document_unshare(%L, 'review finished') $q$, tests.id('grant:C1'))) || tests.acts('web_lead', 'doc:C1'), 'ok0000000000');
select tests.remember('grant:C1b', tests.scalar('ceo', format($q$ select document_share(%L, %L, null, array['read'], now() + interval '2 days', 'again')::text $q$, tests.id('doc:C1'), tests.id('staff:web_lead'))));
update document_access set expires_at = now() - interval '1 second' where id = tests.id('grant:C1b');
select tests.check('an expired grant grants nothing', tests.acts('web_lead', 'doc:C1'), '0000000000');
select tests.check('a grant does not override classification: a legal (restricted) document shared with the uncleared web lead stays hidden',
  tests.try('ceo', format($q$ select document_share(%L, %L, null, array['read', 'download'], null, 'for review') $q$, tests.id('doc:L1'), tests.id('staff:web_lead'))) || tests.acts('web_lead', 'doc:L1'), 'ok0000000000');
select tests.mk_doc('tech_lead', 'T1', 'Tech runbook', 'report', 'tech');
select tests.check('division grants: sharing a Tech document with the whole Web division (view + read + download)', tests.try('tech_lead', format($q$ select document_share(%L, null, %L, array['read', 'download'], null, 'cross-team handover') $q$, tests.id('doc:T1'), tests.id('div:web'))) || tests.acts('web_staff', 'doc:T1') || tests.acts('audit', 'doc:T1'), 'ok' || '1110000000' || '1100000000');

-- Comments ------------------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('comments need documents.comment and visibility; they are append-only', tests.try('web_staff', format($q$ select document_comment_add(%L, 'Looks good') $q$, tests.id('doc:D1'))) || tests.try('audit', format($q$ select document_comment_add(%L, 'x') $q$, tests.id('doc:D1'))) || tests.try_owner('update document_comments set body = ''x''') || tests.try_owner('delete from document_comments'), 'okERR:42501ERR:42501ERR:42501');
select tests.check('...and are visible only with the document', tests.scalar('web_lead', format('select count(*)::text from document_comments where document_id = %L', tests.id('doc:D1'))) || tests.scalar('tech_staff', format('select count(*)::text from document_comments where document_id = %L', tests.id('doc:D1'))), '10');

-- Publication: publishable != published; an approved, allow-listed, revocable projection ----------------------------------------------------------------------
select tests.check('nothing is public by default: a new document has no projection and the public API lists nothing', tests.pub('main', 'documents'), '[]');
select tests.check('the public API requires the documents.read capability', tests.pub('limited', 'documents') || tests.pub('tech', 'documents'), 'ERR:42501ERR:42501');
select tests.mk_doc('ceo', 'P1', 'Annual report FINAL (internal draft title)', 'report', 'web', null, 'public');
select tests.add_ver('ceo', 'P1', 'P1v1', 'annual report public content');
select tests.check('a version must be approved or signed before it can be published', tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, 'Annual Report 2026')::text $q$, tests.id('doc:P1'))), 'ERR:23514');
select tests.try('ceo', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:P1v1')));
select tests.try('web_lead', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:P1v1')));
select tests.check('documents not classified public, of a type that is never public, or critical cannot be published',
  tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, 'x')::text $q$, tests.id('doc:D1'))) || (tests.mk_doc('ceo', 'P2', 'A public contract', 'contract', 'web', null, 'public') ~ '^[0-9a-f-]{36}$')::text, 'ERR:23514true');
select tests.add_ver('ceo', 'P2', 'P2v1', 'contract content');
select tests.try('ceo', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:P2v1')));
select tests.try('web_lead', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:P2v1')));
select tests.check('...a contract-type document is refused even when public and approved', tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, 'Contract')::text $q$, tests.id('doc:P2'))), 'ERR:23514');
select tests.check('only documents.publish holders request a publication, and a public title is required (the internal title is never published)',
  tests.scalar('web_lead', format($q$ select document_publication_request(%L, 1, 'x')::text $q$, tests.id('doc:P1'))) || tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, ' ')::text $q$, tests.id('doc:P1'))), 'ERR:42501ERR:23514');
select tests.remember('pub:P1', tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, 'Annual Report 2026', 'Our annual report for 2026')::text $q$, tests.id('doc:P1'))));
select tests.check('requested but not approved: still not public', tests.pub('main', 'documents'), '[]');
select tests.check('the requester cannot approve their own publication', tests.try('ceo', format($q$ select document_publication_decide(%L, true) $q$, tests.id('pub:P1'))), 'ERR:42501');
select tests.check('someone without documents.approve cannot decide', tests.try('web_staff', format($q$ select document_publication_decide(%L, true) $q$, tests.id('pub:P1'))), 'ERR:42501');
select tests.check('a second person approves (approved is not yet published)', tests.scalar('web_lead', format($q$ select document_publication_decide(%L, true, 'ok to publish')::text $q$, tests.id('pub:P1'))), 'approved');
select tests.check('...an approved projection is still not public', tests.pub('main', 'documents'), '[]');
select tests.check('publishing is a separate, explicit act by a documents.publish holder', tests.try('web_lead', format($q$ select document_publish(%L) $q$, tests.id('pub:P1'))) || tests.scalar('ceo', format($q$ select (document_publish(%L) ~ '^pd_[0-9a-f]{20}$')::text $q$, tests.id('pub:P1'))), 'ERR:42501true');
select tests.check('the public API now serves it - allow-listed fields only, under the public title',
  (select string_agg(k, ',' order by k) from jsonb_object_keys((tests.pub('main', 'documents')::jsonb) -> 0) k) || '|' || (select string_agg(k, ',' order by k) from jsonb_object_keys((tests.pub('main', 'documents')::jsonb) -> 0 -> 'file') k) || '|' || ((tests.pub('main', 'documents')::jsonb) -> 0 ->> 'title'),
  'description,document_date,file,published_at,ref,title,type|mime_type,sha256,size_bytes|Annual Report 2026');
select tests.check('...and the projection exposes no institutional ID, storage reference, internal title, uploader, classification, notes, or other versions',
  (tests.pub('main', 'documents') !~* ('internal draft title|memstore|obj/|classification|uploaded|institutional|FINAL|' || (select institutional_id from entity_registry where entity_id = tests.id('doc:P1'))))::text, 'true');
select tests.check('the public reference is random, not the institutional ID', (select (public_ref !~ institutional_id and public_ref ~ '^pd_[0-9a-f]{20}$')::text from document_publications p join entity_registry r on r.entity_id = p.document_id where p.id = tests.id('pub:P1')), 'true');
select tests.check('a single document is fetched by public reference through the same projection; an unknown reference is empty',
  (tests.pub('main', 'document', quote_literal((select public_ref from document_publications where id = tests.id('pub:P1')))) ::jsonb ->> 'title') || '|' || coalesce(tests.pub('main', 'document', quote_literal('pd_unknown')), 'null'), 'Annual Report 2026|null');
select tests.check('the institutional ID cannot be used to fetch from the public API', coalesce(tests.pub('main', 'document', quote_literal((select institutional_id from entity_registry where entity_id = tests.id('doc:P1')))), ''), '');
select tests.check('publication emits an event carrying only the public reference', (select (payload ? 'public_ref' and (payload - 'public_ref') = '{}'::jsonb)::text from events where event_type = 'document.published' order by id desc limit 1), 'true');
select tests.check('what is published is fixed: the projection''s title, description and version cannot be edited (not even by the owner)', tests.try_owner(format($q$ update document_publications set public_title = 'Other' where id = %L $q$, tests.id('pub:P1'))) || tests.try_owner(format($q$ update document_publications set version_id = %L where id = %L $q$, tests.id('ver:P1v1'), tests.id('pub:P1'))), 'ERR:42501ERR:42501');
select tests.check('the storage reference for delivery exists only for the delivery service, and only while live', (tests.try_owner(format($q$ select document_public_content_ref((select public_ref from document_publications where id = %L)) $q$, tests.id('pub:P1')))) || tests.try('ceo', format($q$ select document_public_content_ref('x') $q$)), 'okERR:42501');
select tests.check('a newer version does not change what is public: the projection stays on the approved version',
  tests.add_ver('ceo', 'P1', 'P1v2', 'annual report - NEW unapproved content')::text ~ '^[0-9a-f-]{36}$' ||
  ((tests.pub('main', 'documents')::jsonb) -> 0 -> 'file' ->> 'sha256' = tests.h('annual report public content'))::text, 'true' || 'true');
select tests.check('an unrelated public-class document that was never approved stays out of the public API', (tests.mk_doc('ceo', 'P3', 'Draft brochure', 'report', 'web', null, 'public') ~ '^[0-9a-f-]{36}$')::text || jsonb_array_length(tests.pub('main', 'documents')::jsonb)::text, 'true1');
select tests.check('a publication cannot be requested twice while one is live', tests.scalar('ceo', format($q$ select document_publication_request(%L, 1, 'Again')::text $q$, tests.id('doc:P1'))), 'ERR:23514');
select tests.check('re-classifying the document withdraws the projection automatically (and says why)', tests.try('ceo', format($q$ select document_set_classification(%L, 'internal', null, 'now internal') $q$, tests.id('doc:P1'))), 'ok');
select tests.check('...the public API no longer serves it', tests.pub('main', 'documents'), '[]');
select tests.check('...the projection records the automatic withdrawal and an unpublished event is emitted',
  (select (state = 'unpublished' and unpublish_reason like 'withdrawn automatically%')::text from document_publications where id = tests.id('pub:P1')) || (select count(*)::text from events where event_type = 'document.unpublished'), 'true1');
select tests.check('...and nothing is public again unless re-requested and re-approved', tests.try('ceo', format($q$ select document_publish(%L) $q$, tests.id('pub:P1'))), 'ERR:23514');
select tests.check('a withdrawn projection can never be reopened', tests.try_owner(format($q$ update document_publications set state = 'published' where id = %L $q$, tests.id('pub:P1'))), 'ERR:23514');
select tests.try('ceo', format($q$ select document_set_classification(%L, 'public', null, 'public again') $q$, tests.id('doc:P1')));
select tests.try('ceo', format($q$ select document_version_transition(%L, 'review') $q$, tests.id('ver:P1v2')));
select tests.try('web_lead', format($q$ select document_version_transition(%L, 'approved') $q$, tests.id('ver:P1v2')));
select tests.remember('pub:P1b', tests.scalar('ceo', format($q$ select document_publication_request(%L, 2, 'Annual Report 2026 (revised)')::text $q$, tests.id('doc:P1'))));
select tests.try('web_lead', format($q$ select document_publication_decide(%L, true) $q$, tests.id('pub:P1b')));
select tests.try('ceo', format($q$ select document_publish(%L) $q$, tests.id('pub:P1b')));
select tests.check('a fresh, separately approved projection of the newer version goes live', ((tests.pub('main', 'documents')::jsonb) -> 0 ->> 'title') || '|' || ((tests.pub('main', 'documents')::jsonb) -> 0 -> 'file' ->> 'sha256' = tests.h('annual report - NEW unapproved content'))::text, 'Annual Report 2026 (revised)|true');
select tests.check('archiving the document withdraws it too', tests.try('ceo', format($q$ select document_archive(%L, 'superseded report') $q$, tests.id('doc:P1'))) || tests.pub('main', 'documents'), 'ok[]');
select tests.check('the archived document is restored', tests.try('ceo', format($q$ select document_restore(%L, 'back') $q$, tests.id('doc:P1'))), 'ok');
select tests.remember('pub:P1c', tests.scalar('ceo', format($q$ select document_publication_request(%L, 2, 'Third try')::text $q$, tests.id('doc:P1'))));
select tests.check('a rejected publication needs a note', tests.try('web_lead', format($q$ select document_publication_decide(%L, false) $q$, tests.id('pub:P1c'))) || tests.try('web_lead', format($q$ select document_publication_decide(%L, false, 'not now') $q$, tests.id('pub:P1c'))), 'ERR:23514ok');
select tests.check('...a rejection is final', tests.try('web_lead', format($q$ select document_publication_decide(%L, true) $q$, tests.id('pub:P1c'))), 'ERR:23514');
select tests.check('...nothing public', tests.pub('main', 'documents'), '[]');
select tests.check('a registry-routed projection: publications resolve through an active registry entry (a disposed or removed entry is never served)', (select count(*)::text from document_publication_live), '0');

-- Search: an accelerator, rebuildable, never the only place anything exists ----------------------------------------------------------------------------------
select tests.try_owner('select search_rebuild()');
select tests.check('free-text search finds documents the caller may see, by title', tests.scalar('web_lead', $q$ select (search_route('handover') -> 'results' -> 0 ->> 'label') $q$), 'Web handover notes');
select tests.mk_doc('tech_lead', 'T2', 'Tech private notes', 'report', 'tech');
select tests.try_owner('select search_rebuild()');
select tests.check('...and never a restricted, critical or other-division (unshared) document for those not entitled',
  tests.scalar('web_lead', $q$ select (search_route('Supplier dispute') -> 'results')::text || (search_route('Board resolution') -> 'results')::text || (search_route('Tech private') -> 'results')::text $q$), '[][][]');
select tests.check('...while a document explicitly shared with their division is found', tests.scalar('web_lead', $q$ select (search_route('Tech runbook') -> 'results' -> 0 ->> 'label') $q$), 'Tech runbook');
select tests.check('...but the cleared CEO finds the restricted one, and the owner-entitled CEO the critical one', tests.scalar('ceo', $q$ select (search_route('Supplier dispute') -> 'results' -> 0 ->> 'label') || '|' || (search_route('Board resolution') -> 'results' -> 0 ->> 'label') $q$), 'Supplier dispute file|Board resolution on acquisition');
select tests.check('the auditor (cleared for restricted) finds the legal file, not the critical one', tests.scalar('audit', $q$ select (search_route('Supplier dispute') -> 'results' -> 0 ->> 'label') || '|' || (search_route('Board resolution') -> 'results')::text $q$), 'Supplier dispute file|[]');
select tests.check('the index holds labels only - no relationships, classification, storage or content', (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_name = 'search_index'), 'institutional_id,entity_type,table_name,entity_id,label,refreshed_at');
delete from search_index;
select tests.check('the index is rebuildable: emptied, it routes nothing, and relationships still resolve from document_links', tests.scalar('web_lead', $q$ select (search_route('handover') -> 'results')::text $q$) || tests.scalar('web_lead', format($q$ select jsonb_array_length(documents_for_entity((select institutional_id from entity_registry where entity_id = %L)))::text $q$, tests.id('project:abc'))), '[]' || '1');
select tests.try_owner('select search_rebuild()');
select tests.check('...and a rebuild restores the same answers', tests.scalar('web_lead', $q$ select (search_route('handover') -> 'results' -> 0 ->> 'label') $q$), 'Web handover notes');
select tests.check('searching by a document''s institutional ID goes straight through the registry', tests.scalar('web_lead', format($q$ select (search_route(%L) ->> 'route') || (search_route(%L) -> 'results' -> 0 ->> 'entity_type') $q$, (select institutional_id from entity_registry where entity_id = tests.id('doc:D1')), (select institutional_id from entity_registry where entity_id = tests.id('doc:D1')))), 'registrydocument');

-- Security investigation: the existing model, not a documents-only alarm ---------------------------------------------------------------------------------------
select tests.check('there is no separate documents security mechanism (no document security / alert / suspicious tables)', (select coalesce(string_agg(relname, ','), 'none') from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname ~ '^document' and relname ~ 'secur|alert|suspic|anomal'), 'none');
select tests.scalar('web_staff', format($q$ select coalesce(document_open(%L)::text, 'null') $q$, tests.id('doc:L1'))) from generate_series(1, 6);
select tests.check('repeated denied access to documents raises a flag in the SAME security case model (one live case per actor)',
  (select concat_ws('|', status, severity, (event_count >= 5)::text) from security_cases where actor_staff_id = tests.id('staff:web_staff')), 'flagged|low|true');
select tests.check('...its events are the document lookups, with the staff identity', (select count(*)::text from security_events e join security_case_events ce on ce.event_id = e.id join security_cases c on c.id = ce.case_id where c.actor_staff_id = tests.id('staff:web_staff') and e.requested_action = 'document.read' and e.actor_staff_id = tests.id('staff:web_staff')), '6');
select tests.check('...and the case is visible to security reviewers only', tests.scalar('web_lead', 'select count(*)::text from security_cases') || tests.scalar('audit', $q$ select (count(*) > 0)::text from security_cases $q$), '0true');
select tests.check('a failed integrity check opens a case through the same model (kind integrity, immediate)', (select count(*)::text from security_policies where kind = 'integrity' and case_status = 'open'), '1');

-- Definite access predicates (a NULL would be read as "permitted" by some callers) ---------------------------------------------------------------------------------
select tests.check('document_can never returns NULL, for any persona, action, missing document or missing staff identity',
  (select count(*)::text from (values ('ceo'), ('web_lead'), ('web_staff'), ('tech_staff'), ('audit'), ('outsider'), ('suspended'), ('recruiter')) u(n),
     unnest(array['view', 'discover', 'read', 'download', 'upload', 'edit', 'comment', 'share', 'approve', 'publish', 'archive', 'restore', 'request_disposal', 'dispose', 'bogus', null]) a
   where tests.scalar(u.n, format($q$ select coalesce(document_can(%L, %L)::text, 'NULL') $q$, tests.id('x:random'), a)) is distinct from 'false'
      or tests.scalar(u.n, format($q$ select coalesce(document_can(%L, %L)::text, 'NULL') $q$, tests.id('doc:D1'), a)) = 'NULL'), '0');
select tests.check('document_can_row with missing owner / null inputs is a definite boolean: false with no division, and the division rule alone (not NULL) with no owner', tests.scalar('web_lead', $q$ select coalesce(document_can_row(null, null, null, 'internal', false, false, 'active', 'edit')::text, 'NULL') || coalesce(document_can_row(gen_random_uuid(), null, (select id from divisions where key = 'web'), 'internal', false, false, 'active', 'edit')::text, 'NULL') $q$), 'falsetrue');
select tests.try_owner(format('update documents set owner_staff_id = null where id = %L', tests.id('doc:D1')));
select tests.check('a document with no owner gives ownership rights to nobody (a NULL owner never equals an unknown caller)', tests.acts('outsider', 'doc:D1') || tests.acts('web_staff', 'doc:D1'), '00000000001111010000');
select tests.try_owner(format('update documents set owner_staff_id = %L where id = %L', tests.id('staff:web_lead'), tests.id('doc:D1')));

-- Recovery -----------------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('the backup manifest accounts for documents, versions, links, history, holds, publications and registry entries',
  (select (m ->> 'documents')::int = (select count(*) from documents) and (m ->> 'versions')::int = (select count(*) from document_versions) and (m ->> 'links')::int = (select count(*) from document_links) and (m ->> 'events')::int = (select count(*) from document_events)
      and length(m ->> 'versions_md5') = 32 and length(m ->> 'registry_md5') = 32 from (select document_backup_manifest() m) x)::text, 'true');
select tests.check('the manifest is for the service role only', tests.scalar('ceo', 'select document_backup_manifest()::text'), 'ERR:42501');
create temp table man0 as select md5(document_backup_manifest()::text) m;
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('the manifest changes when classification changes (so a lossy restore would be noticed)', ((select md5(document_backup_manifest()::text)) <> (select m from man0))::text, 'true');
update clients set classification = 'internal' where id = tests.id('client:abc');
select tests.check('...and returns to the same fingerprint when it is restored', ((select md5(document_backup_manifest()::text)) = (select m from man0))::text, 'true');

select tests.finish();
rollback;
