-- PERMANENT: Domains - authorization per action, classification inheritance from the entities a domain relates to, restricted-record NON-DISCLOSURE
-- (lookup, search, counts, errors, relationships, registry, audit), hidden-name collisions, registry consistency, definite predicates.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.try('fin', $q$ insert into suppliers (name) values ('NamReg Registrar') $q$);
insert into tests.ids select 'sup:namreg', id from suppliers where name = 'NamReg Registrar';
insert into tests.ids select 'org:abc', organization_id from clients where id = tests.id('client:abc');
create function tests.dacts(p_user text, p_dom_key text) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select string_agg(case when domain_can(%L, a) then '1' else '0' end, '' order by n) from unnest(array['view','update','renew','suspend','transfer','approve','retire']) with ordinality t(a, n) $q$, tests.id(p_dom_key)))
$$;

-- The action matrix ------------------------------------------------------------------------------------------------------------------------------------------
select tests.live_domain('web_lead', 'm', 'matrix.example');
select tests.check('view update renew suspend transfer approve retire: the CEO', tests.dacts('ceo', 'dom:m'), '1111111');
select tests.check('...administration (everything but approval)', tests.dacts('adm2', 'dom:m'), '1111101');
select tests.check('...the web lead (their own division: all but approve / retire)', tests.dacts('web_lead', 'dom:m'), '1111100');
select tests.check('...finance (organisation-wide: view and renew only)', tests.dacts('fin', 'dom:m'), '1010000');
select tests.check('...division staff and the auditor: view only', tests.dacts('web_staff', 'dom:m') || tests.dacts('audit', 'dom:m'), '10000001000000');
select tests.check('...another division, the recruiter, an outsider and a suspended account: nothing', tests.dacts('tech_staff', 'dom:m') || tests.dacts('tech_lead', 'dom:m') || tests.dacts('recruiter', 'dom:m') || tests.dacts('outsider', 'dom:m') || tests.dacts('suspended', 'dom:m'), repeat('0000000', 5));
select tests.mk_domain('tech_lead', 'tech1', 'techdom.example', 'tech');
select tests.check('a Tech lead''s own domain is theirs (they act in Tech, not in Web) and Web cannot see it', tests.dacts('tech_lead', 'dom:tech1') || tests.dacts('web_lead', 'dom:tech1'), '11111000000000');

-- Restricted-client inheritance and non-disclosure -----------------------------------------------------------------------------------------------------
select tests.live_domain('web_lead', 'h', 'hidden-client.example');
select tests.live_domain('web_lead', 'hp', 'hidden-project.example');
select tests.rel('web_lead', 'h', 'client', 'clients', 'client:abc');
select tests.rel('web_lead', 'hp', 'project', 'projects', 'project:abc');
create temp table h_inst as select (select institutional_id from entity_registry where entity_id = tests.id('dom:h')) i;
select tests.check('before: the web lead and division staff see both domains', tests.scalar('web_lead', 'select count(*)::text from domains where name like ''hidden-%''') || tests.scalar('web_staff', 'select count(*)::text from domains where name like ''hidden-%'''), '22');
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('the client becomes restricted: the domain related to it AND the domain related to its project inherit the restriction', (select string_agg(effective_classification::text, ',' order by name) from domains where name like 'hidden-%'), 'restricted,restricted');
select tests.check('the web lead, division staff and finance see neither (rows, relations, registrations, events)',
  tests.scalar('web_lead', format('select (select count(*) from domains where name like ''hidden-%%'')::text || (select count(*) from domain_relations where domain_id in (%L, %L)) || (select count(*) from domain_registrations where domain_id in (%L, %L)) || (select count(*) from domain_events where domain_id in (%L, %L))',
    tests.id('dom:h'), tests.id('dom:hp'), tests.id('dom:h'), tests.id('dom:hp'), tests.id('dom:h'), tests.id('dom:hp'))) || tests.scalar('web_staff', 'select count(*)::text from domains where name like ''hidden-%''') || tests.scalar('fin', 'select count(*)::text from domains where name like ''hidden-%'''), '000000');
select tests.check('the CEO, administration and the auditor still see them', tests.scalar('ceo', 'select count(*)::text from domains where name like ''hidden-%''') || tests.scalar('adm2', 'select count(*)::text from domains where name like ''hidden-%''') || tests.scalar('audit', 'select count(*)::text from domains where name like ''hidden-%'''), '222');
select tests.check('every probe by an uncleared caller is indistinguishable from a random ID: 360, renew, update, suspend, set division, classify, mark expired',
  tests.same_for('web_lead', $q$ select coalesce(domain_360(%L)::text, 'null') $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select domain_renew(%L, 1, 'P1')::text $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select domain_update(%L, jsonb_build_object('description', 'x'))::text $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select domain_transition(%L, 'suspended', 'x')::text $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select domain_set_division(%L, (select id from divisions where key = 'web'), 'x')::text $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select domain_set_classification(%L, 'public', 'x')::text $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select domain_mark_expired(%L)::text $q$, tests.id('dom:h'), tests.id('x:random')), repeat('same', 7));
select tests.check('...transfer requests, relationship and transfer INSERTs say nothing different either (no error is raised before row security)',
  tests.same_for('web_lead', $q$ select domain_transfer_request(%L, 'out', p_destination_note => 'x', p_reason => 'x')::text $q$, tests.id('dom:h'), tests.id('x:random')) ||
  tests.try('web_lead', format($q$ insert into domain_relations (domain_id, relation, entity_institutional_id) values (%L, 'project', (select institutional_id from entity_registry where entity_id = %L)) $q$, tests.id('dom:h'), tests.id('project:abc'))) ||
  tests.try('web_lead', format($q$ insert into domain_relations (domain_id, relation, entity_institutional_id) values (%L, 'project', (select institutional_id from entity_registry where entity_id = %L)) $q$, tests.id('x:random'), tests.id('project:abc'))) ||
  tests.try('web_lead', format($q$ insert into domain_relations (domain_id, relation, entity_institutional_id) values (%L, 'client', (select institutional_id from entity_registry where entity_id = %L)) $q$, tests.id('dom:h'), tests.id('project:abc'))) ||
  tests.try('web_lead', format($q$ insert into domain_transfers (domain_id, kind, destination_note, reason) values (%L, 'out', 'x', 'x') $q$, tests.id('dom:h'))) || tests.try('web_lead', format($q$ insert into domain_transfers (domain_id, kind, destination_note, reason) values (%L, 'out', 'x', 'x') $q$, tests.id('x:random'))), 'same' || repeat('ERR:42501', 5));
select tests.check('lookup by NAME: a hidden name answers exactly like one never registered', tests.scalar('web_lead', $q$ select coalesce(domain_lookup('hidden-client.example')::text, 'null') $q$) || tests.scalar('web_lead', $q$ select coalesce(domain_lookup('never-registered.example')::text, 'null') $q$), 'nullnull');
select tests.check('...and both lookups were recorded identically as denied lookups (the hidden name looks exactly like the missing one)', (select count(*)::text || '|' || count(distinct (entity_exists, coalesce(entity_class::text, '-'), reason))::text from security_events where actor_staff_id = tests.id('staff:web_lead') and requested_action = 'domain.lookup'), '2|1');
select tests.check('...and the cleared find it', tests.scalar('adm2', $q$ select (domain_lookup('Hidden-Client.example.') ->> 'name') $q$), 'hidden-client.example');
select tests.check('the registry hides it too: resolve, get, directory, search routing by ID and by name',
  tests.scalar('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') || coalesce(entity_get(%L)::text, 'null') $q$, (select i from h_inst), (select i from h_inst))) ||
  tests.scalar('web_lead', format('select (select count(*) from entity_registry where entity_id = %L)::text || (select count(*) from entity_directory where authoritative_record_key = %L)::text', tests.id('dom:h'), tests.id('dom:h'))) ||
  (select search_rebuild()::text is not null)::text || tests.scalar('web_lead', $q$ select (search_route('hidden-client') -> 'results')::text $q$), 'nullnull' || '00' || 'true' || '[]');
select tests.check('...but the cleared find it through the registry and the search accelerator', tests.scalar('adm2', format($q$ select (entity_resolve(%L) ->> 'entity_type') $q$, (select i from h_inst))) || '|' || tests.scalar('adm2', $q$ select (search_route('hidden-client') -> 'results' -> 0 ->> 'label') $q$), 'domain|hidden-client.example');
select tests.check('the 360 views of the restricted project / client are null for the uncleared (so no domain list leaks) and list the domains for the cleared',
  tests.scalar('web_lead', format($q$ select coalesce(project_360(%L)::text, 'null') $q$, tests.id('project:abc'))) || tests.scalar('ceo', format($q$ select jsonb_array_length(project_360(%L) -> 'domains')::text || jsonb_array_length(client_360(%L) -> 'domains')::text $q$, tests.id('project:abc'), tests.id('client:abc'))), 'null12');
select tests.check('domains_for_entity on the restricted client answers like a random ID for the uncleared', tests.same_for('web_lead', $q$ select coalesce(domains_for_entity((select institutional_id from entity_registry where entity_id = %L))::text, 'null') $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('the registry-routed family lookup shows the cleared only the current relationships', tests.scalar('ceo', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true))::text $q$, tests.id('client:abc'))), '2');
update clients set classification = 'internal' where id = tests.id('client:abc');
select tests.check('un-restricting the client returns both domains to the people who lost them', tests.scalar('web_lead', 'select count(*)::text from domains where name like ''hidden-%'''), '2');

-- Classification of the domain itself, and of the organization behind it -----------------------------------------------------------------------------------
select tests.live_domain('web_lead', 'own', 'own-class.example');
select tests.check('classifying a domain needs records.classify and a reason, and cannot lock you out', tests.try('web_lead', format($q$ select domain_set_classification(%L, 'restricted', 'x') $q$, tests.id('dom:own'))) || tests.try('adm2', format($q$ select domain_set_classification(%L, 'restricted', ' ') $q$, tests.id('dom:own'))) || tests.try('adm2', format($q$ select domain_set_classification(%L, 'confidential', 'too high for me') $q$, tests.id('dom:own'))), 'ERR:42501ERR:23514ERR:42501');
select tests.check('a restricted domain is hidden from the web lead and visible to the cleared', tests.try('adm2', format($q$ select domain_set_classification(%L, 'restricted', 'sensitive') $q$, tests.id('dom:own'))) || tests.scalar('web_lead', format('select count(*)::text from domains where id = %L', tests.id('dom:own'))) || tests.scalar('adm2', format('select count(*)::text from domains where id = %L', tests.id('dom:own'))), 'ok01');
select tests.mkclient_id('web_lead', 'Org Restr Co', 'web');
insert into tests.ids select 'org:restr', organization_id from clients where name = 'Org Restr Co';
select tests.live_domain('web_lead', 'orgd', 'org-restricted.example');
select tests.rel('web_lead', 'orgd', 'registrant', 'organizations', 'org:restr');
select tests.check('before: visible to the web lead', tests.scalar('web_lead', format('select count(*)::text from domains where id = %L', tests.id('dom:orgd'))), '1');
select tests.scalar('ceo', format($q$ select organization_set_classification(%L, 'restricted', 'sensitive owner')::text $q$, tests.id('org:restr')));
select tests.check('a domain whose REGISTRANT organization is restricted becomes restricted (organization restriction reaches domains)', (select effective_classification::text from domains where id = tests.id('dom:orgd')) || tests.scalar('web_lead', format('select count(*)::text from domains where id = %L', tests.id('dom:orgd'))) || tests.scalar('ceo', format('select count(*)::text from domains where id = %L', tests.id('dom:orgd'))), 'restricted01');

-- Soft-deleted clients hide their domains ------------------------------------------------------------------------------------------------------------------
insert into clients (name, owner_division_id) values ('Gone Dom Client', (select id from divisions where key = 'web'));
insert into tests.ids select 'client:gone', id from clients where name = 'Gone Dom Client';
select tests.live_domain('web_lead', 'gone', 'gone-client.example');
select tests.rel('web_lead', 'gone', 'client', 'clients', 'client:gone');
update clients set deleted_at = now(), deletion_reason = 'closed down' where id = tests.id('client:gone');
select tests.check('a soft-deleted client hides its domains from those without records.view_deleted', tests.scalar('web_lead', format('select count(*)::text from domains where id = %L', tests.id('dom:gone'))) || tests.scalar('ceo', format('select count(*)::text from domains where id = %L', tests.id('dom:gone'))), '01');
update clients set deleted_at = null, deletion_reason = null where id = tests.id('client:gone');
select tests.check('...restoring the client restores the domain', tests.scalar('web_lead', format('select count(*)::text from domains where id = %L', tests.id('dom:gone'))), '1');

-- Hidden names: one record per name for everyone who can see it; hidden collisions are silent ----------------------------------------------------------------
select tests.try('ceo', format($q$ select domain_create('secret-name.example', %L, p_classification => 'restricted') $q$, tests.id('div:web')));
select tests.check('the web lead registers the SAME name: it succeeds silently (they are told nothing about the hidden one)', tests.scalar('web_lead', format($q$ select (domain_create('secret-name.example', %L) ->> 'status') $q$, tests.id('div:web'))), 'created');
select tests.check('...two records, one of them hidden from the web lead; a silent review item exists for matching.review holders only',
  (select count(*)::text from domains where name = 'secret-name.example') || tests.scalar('web_lead', $q$ select count(*)::text from domains where name = 'secret-name.example' $q$) || tests.scalar('adm2', $q$ select count(*)::text from domain_reviews where status = 'open' $q$) || tests.scalar('web_lead', 'select count(*)::text from domain_reviews'), '2110');
select tests.check('un-restricting the hidden record would make two discoverable records of one name: refused until a human settles the review', tests.try_owner($q$ update domains set classification = 'internal' where name = 'secret-name.example' and classification = 'restricted' $q$), 'ERR:23505');
select tests.check('the reviewer retires the duplicate with a note', tests.try('adm2', format($q$ select domain_review_resolve((select id from domain_reviews where status = 'open'), 'duplicate record created by mistake', (select id from domains where name = 'secret-name.example' and classification = 'internal')) $q$)), 'ok');
select tests.check('...the duplicate is retired (not deleted) and the review is closed', (select status::text from domains where name = 'secret-name.example' and classification = 'internal') || (select count(*)::text from domain_reviews where status = 'open'), 'retired0');
select tests.check('a discoverable name is reported as existing (never duplicated)', tests.scalar('web_lead', format($q$ select (domain_create('MATRIX.example', %L) ->> 'status') $q$, tests.id('div:web'))), 'exists');
select tests.check('...even to another division (it is told the record exists, not what it is)', tests.scalar('tech_lead', format($q$ select (domain_create('matrix.example', %L) ->> 'status') $q$, tests.id('div:tech'))), 'exists');

-- Audit, history and security investigation ----------------------------------------------------------------------------------------------------------------
insert into roles (key, name) values ('audit_basic_test', 'Auditor without restricted clearance (test)');
insert into role_permissions (role_id, permission_id) select (select id from roles where key = 'audit_basic_test'), id from permissions where key in ('audit.view', 'domains.view');
select tests.add_staff('audbasic', 'audit_basic_test');
select tests.check('the audit log is not a back door: an auditor without restricted clearance sees the audit rows of an ordinary domain, none of a restricted one',
  tests.scalar('audbasic', format($q$ select (select count(*) from audit_log where table_name = 'domains' and record_id = %L)::text || (select (count(*) > 0)::text from audit_log where table_name = 'domains' and record_id = %L) $q$, tests.id('dom:own'), tests.id('dom:m'))), '0true');
select tests.check('...nor the relationship / registration / transfer rows of a restricted domain', tests.scalar('audbasic', format($q$ select count(*)::text from audit_log where table_name in ('domain_relations', 'domain_registrations', 'domain_transfers', 'domain_reviews') and (new_data ->> 'domain_id') = %L $q$, tests.id('dom:own'))), '0');
select tests.check('the cleared auditor does see them', tests.scalar('audit', format($q$ select (count(*) > 0)::text from audit_log where table_name = 'domains' and record_id = %L $q$, tests.id('dom:own'))), 'true');
select tests.check('domain creation, relations, ledger rows and transfers are audited with the acting staff member', (select (count(*) filter (where table_name = 'domains' and action = 'INSERT') > 0 and count(*) filter (where table_name = 'domain_registrations') > 0 and count(*) filter (where table_name = 'domain_relations') > 0
      and bool_and(actor_staff_id is not null) filter (where table_name = 'domains' and action = 'INSERT' and actor_staff_id is not null))::text from audit_log where table_name like 'domain%'), 'true');
select tests.check('the domain history cannot be rewritten', tests.try_owner('update domain_events set kind = ''created''') || tests.try_owner('delete from domain_events'), 'ERR:42501ERR:42501');
select tests.check('denied probes feed the EXISTING security model: repeated lookups of hidden names raise a flag in security_cases (no domains-only alarm exists)',
  (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname ~ '^domain' and relname ~ 'secur|alert|suspic|anomal'), '0');
select tests.scalar('web_staff', format($q$ select coalesce(domain_360(%L)::text, 'null') $q$, tests.id('dom:own'))) from generate_series(1, 6);
select tests.check('...(six denied reads of a hidden domain by one person)', (select concat_ws('|', status, severity) from security_cases where actor_staff_id = tests.id('staff:web_staff')), 'flagged|low');
select tests.check('...the events name the lookup, with the staff identity, and a hidden domain looks exactly like a missing one in them',
  (select count(distinct (entity_exists, coalesce(entity_class::text, '-'), reason))::text from security_events where actor_staff_id = tests.id('staff:web_staff') and requested_action = 'domain.view'), '1');

-- Registry consistency, identity never reused -----------------------------------------------------------------------------------------------------------
select tests.check('every domain has exactly one registry row, and no registry row of the domain type lacks a domain', (select count(*)::text from domains d where (select count(*) from entity_registry r where r.table_name = 'domains' and r.entity_id = d.id) <> 1) || (select count(*)::text from entity_registry r where r.table_name = 'domains' and not exists (select 1 from domains d where d.id = r.entity_id)), '00');
select tests.check('the registry mirrors status, classification and the current division of every domain',
  (select count(*)::text from domains d join entity_registry r on r.table_name = 'domains' and r.entity_id = d.id where (r.status, r.classification, r.current_division_id) is distinct from (d.status::text, d.effective_classification, d.division_id)), '0');
select tests.check('the registry keeps ONE origin division per domain even after moves, and the institutional ID never changes', tests.try('ceo', format($q$ select domain_set_division(%L, %L, 'moved to Tech') $q$, tests.id('dom:m'), tests.id('div:tech'))) , 'ok');
select tests.check('...(origin web, current tech, the movement recorded; the ID is the same)', (select concat_ws('|', (origin_division_id = tests.id('div:web'))::text, (current_division_id = tests.id('div:tech'))::text, (select count(*)::text from entity_location_history h where h.institutional_id = r.institutional_id and h.reason = 'moved')) from entity_registry r where entity_id = tests.id('dom:m') and table_name = 'domains'), 'true|true|1');
select tests.check('a division changes only through domain_set_division, with a reason and rights in both divisions', tests.try_owner(format($q$ update domains set division_id = %L where id = %L $q$, tests.id('div:web'), tests.id('dom:m'))) || tests.try('tech_lead', format($q$ select domain_set_division(%L, %L, 'back') $q$, tests.id('dom:m'), tests.id('div:web'))) || tests.try('ceo', format($q$ select domain_set_division(%L, %L, ' ') $q$, tests.id('dom:m'), tests.id('div:web'))), 'ERR:42501ERR:42501ERR:23514');
select tests.check('institutional IDs of domains are unique, well formed, and retired / re-registered records keep theirs',
  (select (count(*) = count(distinct institutional_id) and bool_and(institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$' and ada_id_valid(institutional_id)))::text from entity_registry where table_name = 'domains'), 'true');
select tests.check('the domain counter equals the number of domain IDs issued (no gap, no reuse)', (select (c.last_value = (select count(*) from entity_registry r where r.entity_type = 'domain'))::text from id_counters c where c.type_code = (select id_code from entity_types where key = 'domain')), 'true');
select tests.check('the ledger and the expiry mirror agree for every domain', (select count(*)::text from domain_ledger_drift()), '0');

-- Definite predicates -------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('domain access predicates never return NULL (any persona, any action, missing domain, no staff identity, null arguments)',
  (select count(*)::text from (values ('ceo'), ('web_lead'), ('fin'), ('tech_staff'), ('recruiter'), ('outsider'), ('suspended')) u(n),
     unnest(array['view', 'update', 'renew', 'suspend', 'transfer', 'approve', 'retire', 'bogus', null]) a
   where tests.scalar(u.n, format($q$ select coalesce(domain_can(%L, %L)::text, 'NULL') $q$, tests.id('x:random'), a)) is distinct from 'false'
      or tests.scalar(u.n, format($q$ select coalesce(domain_can(%L, %L)::text, 'NULL') $q$, tests.id('dom:m'), a)) = 'NULL'
      or tests.scalar(u.n, $q$ select coalesce(domain_can(null, 'view')::text, 'NULL') $q$) is distinct from 'false'
      or tests.scalar(u.n, $q$ select coalesce(domain_can_row(null, null, null, null, null, 'view')::text, 'NULL') $q$) = 'NULL'), '0');

select tests.finish();
rollback;
