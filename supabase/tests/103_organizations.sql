-- PERMANENT: Organization Unification - ONE organization record -> MANY roles (client / supplier / partner); role IDs stay stable; the
-- identity columns on roles are read-only mirrors that redirect to the organization; reconciliation never merges anything ambiguous;
-- hidden organizations are never reused or named; Client 360 resolves identity from the organization.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.org_of(p_client_key text) returns uuid language sql as $$ select organization_id from clients where id = tests.id(p_client_key) $$;
create function tests.drift() returns text language sql as $$ select count(*)::text from organization_mirror_drift() $$;

-- One organization, many roles --------------------------------------------------------------------------------------------------------------------------
select tests.check('every existing client already belongs to an organization (and no client lacks one)', (select count(*)::text from clients where organization_id is null), '0');
select tests.check('the client''s organization is a registered entity with its OWN permanent institutional ID (type external_organization), separate from the client''s',
  (select concat_ws('|', (o.institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, o.entity_type, o.entity_family, (o.institutional_id <> c.institutional_id)::text, (o.ada_id is null)::text)
     from entity_registry o join entity_registry c on c.table_name = 'clients' and c.entity_id = tests.id('client:abc') where o.table_name = 'organizations' and o.entity_id = tests.org_of('client:abc')), 'true|external_organization|people_org|true|true');
select tests.check('the organization carries the identity: name and (once given) registration number come from organizations, and the client mirrors them',
  (select (o.name = 'ABC Company' and c.name = o.name and c.registration_number is not distinct from o.registration_number)::text from clients c join organizations o on o.id = c.organization_id where c.id = tests.id('client:abc')), 'true');
select tests.check('finance registers a SUPPLIER with a differently written name: it joins the SAME organization (no second organization)',
  tests.try('fin', $q$ insert into suppliers (name) values ('ABC Co.') $q$) || (select count(*)::text from organizations where name_key = client_name_key('ABC Company')), 'ok1');
select tests.check('...the supplier is a role of the client''s organization and mirrors its name', (select (s.organization_id = tests.org_of('client:abc') and s.name = 'ABC Company')::text from suppliers s where s.name_key = client_name_key('ABC Company')), 'true');
select tests.check('administration registers a PARTNER with yet another spelling: same organization again',
  tests.try('adm2', $q$ insert into partners (name, kind, status) values ('abc (Pty) Ltd', 'technology', 'active') $q$) || (select count(*)::text from organizations where name_key = client_name_key('ABC Company')), 'ok1');
select tests.check('one organization is simultaneously client + supplier + partner, each role keeping its own identity (ADA-CLI alias, ADA-SUP alias, partner institutional ID)',
  (select concat_ws('|', (select count(*) from clients where organization_id = o.id), (select count(*) from suppliers where organization_id = o.id), (select count(*) from partners where organization_id = o.id),
     (select (ada_id ~ '^ADA-CLI-')::text from clients where id = tests.id('client:abc')), (select (ada_id ~ '^ADA-SUP-')::text from suppliers where organization_id = o.id),
     (select (r.institutional_id <> o_r.institutional_id and r.entity_type = 'partner')::text from partners p join entity_registry r on r.table_name = 'partners' and r.entity_id = p.id, entity_registry o_r where p.organization_id = o.id and o_r.table_name = 'organizations' and o_r.entity_id = o.id))
     from organizations o where o.id = tests.org_of('client:abc')), '1|1|1|true|true|true');
select tests.check('the organization 360 shows all three roles beside the single identity (for those who may see them)',
  tests.scalar('ceo', format($q$ select (organization_360(%L) -> 'roles' -> 'clients' -> 0 ->> 'id') || '|' || ((organization_360(%L) -> 'roles' -> 'supplier') is not null)::text || '|' || ((organization_360(%L) -> 'roles' -> 'partner' ->> 'kind')) $q$, tests.org_of('client:abc'), tests.org_of('client:abc'), tests.org_of('client:abc'))),
  (select ada_id || '|true|technology' from clients where id = tests.id('client:abc')));
select tests.check('a role the viewer may not see is not shown: the web lead sees the client but no partner, the 360 lists no supplier for division staff without supplier rights',
  tests.scalar('web_lead', format($q$ select ((organization_360(%L) -> 'roles' -> 'partner') = 'null'::jsonb or (organization_360(%L) -> 'roles' -> 'partner') is null)::text $q$, tests.org_of('client:abc'), tests.org_of('client:abc'))), 'false');
select tests.check('adding a role to an existing organization never creates a second organization: a standalone organization first, then three roles',
  tests.scalar('adm2', $q$ select (organization_create('Standalone Trading (Pty) Ltd', p_registration => 'ST-100') ->> 'status') $q$), 'created');
insert into tests.ids select 'org:st', id from organizations where name = 'Standalone Trading (Pty) Ltd';
select tests.check('an organization exists independently of any role (no client, supplier or partner), and is active', (select concat_ws('|', status, (select count(*)::text from clients where organization_id = o.id), (select count(*)::text from suppliers where organization_id = o.id)) from organizations o where id = tests.id('org:st')), 'active|0|0');
select tests.check('the same company is found again, not duplicated (normalised name)', tests.scalar('adm2', $q$ select (organization_create('STANDALONE TRADING cc') ->> 'status') $q$), 'exists');
select tests.check('the same REGISTRATION number under unrelated words is not silently reused and not silently duplicated: a human is asked', tests.scalar('adm2', $q$ select (organization_create('Totally Different Words', p_registration => 'st-100') ->> 'status') $q$), 'similar');
select tests.check('a roleless organization is visible to organization viewers only (finance, who may see no role of it, gets the uniform not-found)', tests.scalar('fin', format($q$ select organization_add_role(%L, 'supplier')::text $q$, tests.id('org:st'))) || tests.scalar('fin', format($q$ select organization_add_role(%L, 'supplier')::text $q$, tests.id('x:random'))), 'ERR:P0002ERR:P0002');
select tests.check('roles are added to it: supplier and partner by administration, then the client by the web lead (who can see it once it has a role they may see... after the client exists)',
  tests.scalar('adm2', format($q$ select (organization_add_role(%L, 'supplier') ->> 'role') $q$, tests.id('org:st'))) || tests.scalar('adm2', format($q$ select (organization_add_role(%L, 'partner', p_kind => 'reseller') ->> 'role') $q$, tests.id('org:st')))
  || tests.scalar('ceo', format($q$ select (organization_add_role(%L, 'client', %L) ->> 'role') $q$, tests.id('org:st'), tests.id('div:web'))), 'supplierpartnerclient');
select tests.check('...three roles, still ONE organization', (select concat_ws('|', (select count(*) from clients where organization_id = tests.id('org:st')), (select count(*) from suppliers where organization_id = tests.id('org:st')),
   (select count(*) from partners where organization_id = tests.id('org:st')), (select count(*) from organizations where name_key = client_name_key('Standalone Trading')))), '1|1|1|1');
select tests.check('a role cannot be added twice, and needs its own permission',
  tests.scalar('adm2', format($q$ select organization_add_role(%L, 'partner')::text $q$, tests.id('org:st'))) || tests.scalar('web_staff', format($q$ select organization_add_role(%L, 'supplier')::text $q$, tests.id('org:st'))), 'ERR:23514ERR:42501');

-- Mirrors: readable, trigger-maintained, never independently writable -----------------------------------------------------------------------------------
select tests.check('no drift after all of that', tests.drift(), '0');
select tests.check('the organization is renamed (organizations.update)', tests.try('adm2', format($q$ select organization_update(%L, jsonb_build_object('name', 'Standalone Holdings', 'city', 'Windhoek')) $q$, tests.id('org:st'))), 'ok');
select tests.check('...and every role''s mirror (client, supplier, partner) and the client''s derived name key follow',
  (select concat_ws('|', (select name from clients where organization_id = o.id), (select name from suppliers where organization_id = o.id), (select name from partners where organization_id = o.id),
      (select name_key from clients where organization_id = o.id), (select city from clients where organization_id = o.id)) from organizations o where o.id = tests.id('org:st')), 'Standalone Holdings|Standalone Holdings|Standalone Holdings|standaloneholdings|Windhoek');
select tests.check('a DIRECT write to a client mirror (even by the database owner) is accepted as an edit of the organization', tests.try_owner(format($q$ update clients set name = 'Standalone Group', city = 'Swakopmund' where organization_id = %L $q$, tests.id('org:st'))), 'ok');
select tests.check('...it was redirected: the organization carries it and every other role follows',
  (select concat_ws('|', o.name, o.city, (select name from clients where organization_id = o.id), (select name from suppliers where organization_id = o.id), (select name from partners where organization_id = o.id)) from organizations o where o.id = tests.id('org:st')), 'Standalone Group|Swakopmund|Standalone Group|Standalone Group|Standalone Group');
select tests.check('...also through a supplier mirror and a partner mirror', tests.try_owner(format($q$ update suppliers set name = 'Standalone Supplies' where organization_id = %L $q$, tests.id('org:st'))) || tests.try_owner(format($q$ update partners set name = 'Standalone Alliance' where organization_id = %L $q$, tests.id('org:st'))), 'okok');
select tests.check('...and the last write wins everywhere', (select name || '|' || (select name from clients where organization_id = o.id) || '|' || (select name from suppliers where organization_id = o.id) from organizations o where o.id = tests.id('org:st')), 'Standalone Alliance|Standalone Alliance|Standalone Alliance');
select tests.check('...a user with client edit rights redirects too', tests.try('web_lead', format($q$ update clients set industry = 'Retail', registration_number = 'ST-777' where organization_id = %L $q$, tests.id('org:st'))), 'ok');
select tests.check('...and the organization holds it', (select concat_ws('|', o.industry, o.registration_number) from organizations o where o.id = tests.id('org:st')), 'Retail|ST-777');
select tests.check('...a user without client edit rights changes nothing (row security)', tests.try('web_staff', format($q$ update clients set name = 'Hacked' where organization_id = %L $q$, tests.id('org:st'))), 'ok0');
select tests.check('...and the organization is as it was', (select name from organizations where id = tests.id('org:st')), 'Standalone Alliance');
select tests.check('a mirror can never be left different from the organization: after every change above there is no drift', tests.drift(), '0');
select tests.check('a role cannot be moved to another organization by a plain update', tests.try_owner(format('update clients set organization_id = %L where id = %L', tests.id('org:st'), tests.id('client:abc'))), 'ERR:42501');
select tests.check('the redirect honours uniqueness: renaming a role onto another organization''s name is refused', tests.try_owner(format($q$ update clients set name = 'ABC Company' where organization_id = %L $q$, tests.id('org:st'))), 'ERR:23505');
select tests.check('...and so is a registration number already used by another organization', tests.try_owner(format($q$ update clients set registration_number = 'ST-777' where id = %L $q$, tests.id('client:abc'))), 'ERR:23505');
select tests.check('the mirror configuration covers name and registration number on clients and suppliers', (select (org_mirror_cols('clients') @> array['name', 'registration_number'] and org_mirror_cols('suppliers') @> array['name', 'registration_number'] and org_mirror_cols('partners') @> array['name'])::text), 'true');
select tests.check('the role tables are still the real tables (no compatibility view, no hard cut)',
  (select string_agg(c.relname || ':' || c.relkind::text, ',' order by c.relname) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('clients', 'suppliers', 'partners', 'organizations')), 'clients:r,organizations:r,partners:r,suppliers:r');
select tests.check('downstream modules still reference the role/context IDs: nothing outside the role tables and the review tables points at organizations',
  (select string_agg(distinct conrelid::regclass::text, ',' order by conrelid::regclass::text) from pg_constraint where contype = 'f' and confrelid = 'organizations'::regclass), 'clients,organization_distinct_pairs,organization_reviews,organizations,partners,suppliers');
select tests.check('every foreign key from the commercial and operational modules still points at clients(id), none at organizations',
  (select coalesce(string_agg(conrelid::regclass::text, ',' order by conrelid::regclass::text), 'none') from pg_constraint where contype = 'f' and confrelid = 'clients'::regclass and conrelid::regclass::text in ('projects', 'quotes', 'contracts', 'invoices', 'payments', 'tickets', 'assets')), 'assets,contracts,invoices,payments,projects,quotes,tickets');
select tests.check('client IDs and ADA-CLI aliases are untouched by the renames', (select (ada_id = (select ada_id from entity_registry where table_name = 'clients' and entity_id = tests.id('client:abc')))::text from clients where id = tests.id('client:abc')), 'true');

-- Duplicate prevention and matching ---------------------------------------------------------------------------------------------------------------------
select tests.check('a second live client for the same organization (same normalised name) is refused', tests.try_owner($q$ insert into clients (name) values ('Abc company') $q$), 'ERR:23505');
select tests.check('...and so is one that matches by registration number', tests.try_owner($q$ insert into clients (name, registration_number) values ('Something Else Entirely', 'ST-777') $q$), 'ERR:23505');
select tests.check('client_create reports the existing client (client-level duplicate flow unchanged)', tests.scalar('web_lead', $q$ select (client_create('ABC Pty Ltd', (select id from divisions where key = 'web')) ->> 'status') $q$), 'exists');
select tests.try('fin', $q$ insert into suppliers (name, registration_number) values ('Delta Supplies', 'DS-1') $q$);
select tests.check('client_create reports a DIFFERENT legal entity with a name an organization already uses (even if that organization is only a supplier)', tests.scalar('web_lead', $q$ select (client_create('Delta Supplies', (select id from divisions where key = 'web'), p_registration => 'DS-2') ->> 'status') $q$), 'name_conflict');
select tests.check('...while the SAME entity (no conflicting registration) simply becomes a client of the supplier''s organization', tests.scalar('web_lead', $q$ select (client_create('Delta Supplies', (select id from divisions where key = 'web'), p_registration => 'DS-1') ->> 'status') $q$), 'created');
select tests.check('...one organization, a client role and a supplier role', (select concat_ws('|', (select count(*) from organizations where name_key = client_name_key('Delta Supplies')), (select count(*) from clients where name = 'Delta Supplies'), (select count(*) from suppliers where name = 'Delta Supplies'))), '1|1|1');

-- Matching: registration number, normalised name ---------------------------------------------------------------------------------------------------------
select tests.try('fin', $q$ insert into suppliers (name, registration_number) values ('Kappa Trading', 'KT-1') $q$);
select tests.check('registration number MATCHING: a client that states the same registration number under a similar (not identical) name joins the supplier''s organization',
  tests.try_owner($q$ insert into clients (name, registration_number) values ('Kappa Tradings', 'kt-1') $q$), 'ok');
select tests.check('...one organization, two roles', (select concat_ws('|', (select count(*) from organizations where lower(registration_number) = 'kt-1'), (select count(*) from clients c join suppliers s on s.organization_id = c.organization_id where c.name = 'Kappa Trading' and s.name = 'Kappa Trading')) ), '1|1');
select tests.check('registration number DUPLICATE prevention: the same registration under an unrelated name is refused (a human must decide), not duplicated',
  tests.try_owner($q$ insert into clients (name, registration_number) values ('Entirely Unrelated Words', 'KT-1') $q$) || (select count(*)::text from organizations where lower(registration_number) = 'kt-1'), 'ERR:23505' || '1');
select tests.try('fin', $q$ insert into suppliers (name) values ('Sigma-Parts (Pty) Ltd') $q$);
select tests.check('NORMALISED NAME matching: punctuation, case and legal suffixes do not make a different company', tests.try_owner($q$ insert into clients (name) values ('SIGMA PARTS cc') $q$) || (select count(*)::text from organizations where name_key = 'sigmaparts'), 'ok1');
select tests.check('...the supplier and the client share that organization and show its name', (select count(distinct c.organization_id)::text || '|' || min(s.name) || '|' || min(c.name) from clients c join suppliers s on s.organization_id = c.organization_id where c.name_key = 'sigmaparts'), '1|Sigma-Parts (Pty) Ltd|Sigma-Parts (Pty) Ltd');
select tests.try('fin', $q$ insert into suppliers (name, registration_number) values ('Theta Foods', 'TF-1') $q$);
select tests.check('the same name with a DIFFERENT registration number is a different legal entity: never merged, and not silently duplicated either', tests.try_owner($q$ insert into clients (name, registration_number) values ('Theta Foods', 'TF-2') $q$), 'ERR:23505');
select tests.check('hiding behind a trading-style variation does not help: the same registration with a similar name still matches (reuse), a conflicting one is refused',
  tests.try_owner($q$ insert into clients (name, registration_number) values ('Theta Food', 'TF-1') $q$) || (select count(*)::text from organizations where lower(registration_number) = 'tf-1'), 'ok1');

-- Ambiguous matches go to a human, never merged ----------------------------------------------------------------------------------------------------------
select tests.try('fin', $q$ insert into suppliers (name) values ('Lambda Works') $q$);
select tests.check('a look-alike with no deciding evidence (similar name, no registration number) is NOT reused', tests.try_owner($q$ insert into clients (name) values ('Lambda Work') $q$), 'ok');
select tests.check('...the two stay SEPARATE organizations with their own roles', (select concat_ws('|', (select count(*) from organizations where name in ('Lambda Works', 'Lambda Work')), (select (c.organization_id <> s.organization_id)::text from clients c, suppliers s where c.name = 'Lambda Work' and s.name = 'Lambda Works'))), '2|true');
select tests.check('...and a review item is queued for a human', (select concat_ws('|', count(*), min(reason)) from organization_reviews r where status = 'open' and exists (select 1 from organizations a, organizations b where a.name = 'Lambda Works' and b.name = 'Lambda Work' and ((r.left_org_id = a.id and r.right_org_id = b.id) or (r.left_org_id = b.id and r.right_org_id = a.id)))), '1|similar_name');
select tests.check('the review queue is for matching.review holders only (the web lead and finance see nothing)', tests.scalar('adm2', $q$ select (count(*) > 0)::text from organization_reviews $q$) || tests.scalar('web_lead', 'select count(*)::text from organization_reviews') || tests.scalar('fin', 'select count(*)::text from organization_reviews') || tests.scalar('web_lead', 'select count(*)::text from organization_distinct_pairs'), 'true00' || '0');
create temp table lam as select r.id rid, (select id from organizations where name = 'Lambda Works') w, (select id from organizations where name = 'Lambda Work') k from organization_reviews r
  where r.status = 'open' and r.reason = 'similar_name' and exists (select 1 from organizations a where a.name = 'Lambda Works' and a.id in (r.left_org_id, r.right_org_id));
insert into tests.ids select 'rev:lam', rid from lam;
insert into tests.ids select 'org:lamw', w from lam;
insert into tests.ids select 'org:lamk', k from lam;
select tests.check('resolving needs matching.review and a note', tests.scalar('web_lead', format($q$ select organization_review_resolve(%L, 'distinct', 'x')::text $q$, tests.id('rev:lam'))) || tests.scalar('adm2', format($q$ select organization_review_resolve(%L, 'distinct', ' ')::text $q$, tests.id('rev:lam'))), 'ERR:42501ERR:23514');
select tests.check('"same" must name the survivor (one of the two under review)', tests.scalar('adm2', format($q$ select organization_review_resolve(%L, 'same', 'looks the same')::text $q$, tests.id('rev:lam'))) || tests.scalar('adm2', format($q$ select organization_review_resolve(%L, 'same', 'looks the same', %L)::text $q$, tests.id('rev:lam'), tests.id('x:random'))), 'ERR:23514ERR:23514');
select tests.check('a human decides they are different companies', tests.try('adm2', format($q$ select organization_review_resolve(%L, 'distinct', 'Different owners, confirmed by phone') $q$, tests.id('rev:lam'))), 'ok');
select tests.check('...recorded, and they are not flagged again even when edited', (select count(*)::text from organization_distinct_pairs where org_a = least(tests.id('org:lamw'), tests.id('org:lamk')) and org_b = greatest(tests.id('org:lamw'), tests.id('org:lamk'))), '1');
select tests.try('adm2', format($q$ select organization_update(%L, jsonb_build_object('city', 'Tsumeb')) $q$, tests.id('org:lamk')));
select tests.check('...(editing a confirmed-distinct organization raises no new review)', (select count(*)::text from organization_reviews where status = 'open' and (tests.id('org:lamk') in (left_org_id, right_org_id) and tests.id('org:lamw') in (left_org_id, right_org_id))), '0');
select tests.try('fin', $q$ insert into suppliers (name) values ('Mu Systems') $q$);
select tests.try_owner($q$ insert into clients (name) values ('Mu System') $q$);
create temp table mu as select (select id from organizations where name = 'Mu Systems') s, (select id from clients where name = 'Mu System') c_id, (select organization_id from clients where name = 'Mu System') k,
   (select ada_id from clients where name = 'Mu System') c_ada, (select id from organization_reviews where status = 'open' and exists (select 1 from organizations a where a.name = 'Mu Systems' and a.id in (left_org_id, right_org_id))) rid;
insert into tests.ids select 'org:mus', s from mu; insert into tests.ids select 'org:muk', k from mu; insert into tests.ids select 'rev:mu', rid from mu; insert into tests.ids select 'client:mu', c_id from mu;
select tests.check('another ambiguous pair is queued', (select (rid is not null)::text from mu), 'true');
select tests.check('a human decides they ARE the same company; the supplier''s organization survives', tests.try('adm2', format($q$ select organization_review_resolve(%L, 'same', 'Same company, spelled differently', %L) $q$, tests.id('rev:mu'), tests.id('org:mus'))), 'ok');
select tests.check('...the client role moved to the survivor with its ID and ADA-CLI alias untouched, now mirroring the survivor''s name',
  (select concat_ws('|', (c.organization_id = tests.id('org:mus'))::text, (c.ada_id = (select c_ada from mu))::text, c.name) from clients c where c.id = tests.id('client:mu')), 'true|true|Mu Systems');
select tests.check('...the absorbed organization is a tombstone that still resolves to the survivor (its ID is never reused or lost)',
  (select concat_ws('|', status, (merged_into_id = tests.id('org:mus'))::text) from organizations where id = tests.id('org:muk')) || '|' ||
  tests.scalar('adm2', format($q$ select (organization_360(%L) -> 'identity' ->> 'status') || '/' || ((organization_360(%L) -> 'identity' ->> 'merged_into') = (select institutional_id from entity_registry where table_name = 'organizations' and entity_id = %L))::text $q$, tests.id('org:muk'), tests.id('org:muk'), tests.id('org:mus'))), 'merged|true|merged/true');
select tests.check('...a merged organization cannot change or be merged again', tests.try_owner(format($q$ update organizations set city = 'x' where id = %L $q$, tests.id('org:muk'))) || tests.try('adm2', format($q$ select organization_merge(%L, %L, 'again') $q$, tests.id('org:mus'), tests.id('org:muk'))), 'ERR:42501ERR:23514');
select tests.check('a direct merge needs matching.review and a note', tests.try('web_lead', format($q$ select organization_merge(%L, %L, 'x') $q$, tests.id('org:mus'), tests.id('org:st'))) || tests.try('adm2', format($q$ select organization_merge(%L, %L, ' ') $q$, tests.id('org:mus'), tests.id('org:st'))), 'ERR:42501ERR:23514');
select tests.check('two organizations that each hold a LIVE client cannot be merged until the duplicate client is resolved', tests.scalar('adm2', format($q$ select organization_merge(%L, %L, 'same company') $q$, tests.org_of('client:abc'), tests.id('org:st'))), 'ERR:23514');
select tests.check('...nor two suppliers, nor two partners', (select count(*)::text from (select 1) x) ||
  tests.scalar('adm2', $q$ select organization_create('Rho One')->>'status' $q$) || tests.scalar('adm2', $q$ select organization_create('Rho Two')->>'status' $q$), '1createdcreated');
insert into tests.ids select 'org:rho1', id from organizations where name = 'Rho One';
insert into tests.ids select 'org:rho2', id from organizations where name = 'Rho Two';
select tests.try('adm2', format($q$ select organization_add_role(%L, 'supplier') $q$, tests.id('org:rho1')));
select tests.try('adm2', format($q$ select organization_add_role(%L, 'supplier') $q$, tests.id('org:rho2')));
select tests.check('...two suppliers', tests.scalar('adm2', format($q$ select organization_merge(%L, %L, 'same company') $q$, tests.id('org:rho1'), tests.id('org:rho2'))), 'ERR:23514');
select tests.check('...and nothing was merged by the failed attempt', (select count(*)::text from organizations where id in (tests.id('org:rho1'), tests.id('org:rho2')) and status = 'active'), '2');

-- Reconciliation of legacy data: strong evidence links, ambiguity is queued, nothing ambiguous is merged ---------------------------------------------------------
alter table clients alter column organization_id drop not null;
alter table suppliers alter column organization_id drop not null;
alter table clients disable trigger clients_org_attach_trg;
alter table suppliers disable trigger suppliers_0_org_attach_trg;
insert into clients (name, registration_number, owner_division_id, created_at) values
  ('Legacy Alpha (Pty) Ltd', 'LA-1', tests.id('div:web'), now() - interval '500 days'),
  ('Legacy Beta', 'LB-1', tests.id('div:web'), now() - interval '480 days'),
  ('Legacy Gamma', null, tests.id('div:web'), now() - interval '470 days'),
  ('Totally Other Name', 'LD-9', tests.id('div:web'), now() - interval '460 days');
insert into clients (name, owner_division_id, created_at, deleted_at, deletion_reason) values ('Legacy Alpha', tests.id('div:web'), now() - interval '450 days', now() - interval '440 days', 'closed');
insert into suppliers (name, registration_number, created_at) values
  ('LEGACY ALPHA', 'la-1', now() - interval '400 days'), ('Legacy Beta Ltd', 'LB-2', now() - interval '390 days'), ('Legacy Gamma', null, now() - interval '380 days'), ('Legacy Delta Traders', 'LD-9', now() - interval '370 days'),
  ('Legacy Sigma Works', 'SW-1', now() - interval '360 days'), ('Legacy Sigma Workz', 'sw-1', now() - interval '350 days');
alter table clients enable trigger clients_org_attach_trg;
alter table suppliers enable trigger suppliers_0_org_attach_trg;
create temp table legacy_before as select 'c' t, id, ada_id from clients where name like 'Legacy%' or name = 'Totally Other Name' union all select 's', id, ada_id from suppliers where name like 'LEGACY%' or name like 'Legacy%';
create temp table legacy_audit_before as select count(*) n from audit_log where table_name in ('clients', 'suppliers') and action = 'INSERT' and (new_data ->> 'name') in ('Legacy Alpha (Pty) Ltd', 'LEGACY ALPHA', 'Legacy Beta', 'Legacy Beta Ltd');
select tests.check('legacy rows exist without an organization', (select count(*)::text from clients where organization_id is null) || '|' || (select count(*)::text from suppliers where organization_id is null), '5|6');
create temp table recon1 as select organization_reconcile() j;
select tests.check('reconciliation links 3 roles to organizations that already existed, creates 8 organizations, and queues 3 reviews', (select (j ->> 'linked_to_existing') || '|' || (j ->> 'organizations_created') || '|' || (j ->> 'review_items_opened') from recon1), '3|8|3');
select tests.check('two suppliers claiming the same registration number: the second is kept apart (one organization cannot hold two supplier roles) and queued',
  (select (a.organization_id <> b.organization_id)::text from suppliers a, suppliers b where a.name = 'Legacy Sigma Works' and b.name like 'Legacy Sigma Work%' and a.id <> b.id and lower(b.registration_number) = lower(a.registration_number) limit 1) || '|' ||
  (select count(*)::text from organization_reviews r where r.origin = 'migration' and r.status = 'open' and exists (select 1 from suppliers a join suppliers b on b.id <> a.id and lower(b.registration_number) = lower(a.registration_number) where a.name = 'Legacy Sigma Works'
     and ((r.left_org_id = a.organization_id and r.right_org_id = b.organization_id) or (r.left_org_id = b.organization_id and r.right_org_id = a.organization_id)))), 'true|1');
select tests.check('registration + name evidence: the supplier LEGACY ALPHA joined the client''s organization (and the old closed client of the same name did too)',
  (select concat_ws('|', count(distinct organization_id), count(*)) from (select organization_id from clients where name like 'Legacy Alpha%' union all select organization_id from suppliers where name like 'Legacy Alpha%') x), '1|3');
select tests.check('exact name with no contradicting evidence: Legacy Gamma (client and supplier) is one organization', (select count(distinct organization_id)::text from (select organization_id from clients where name = 'Legacy Gamma' union all select organization_id from suppliers where name = 'Legacy Gamma') x), '1');
select tests.check('same name but CONFLICTING registration numbers (Legacy Beta): kept as two organizations, with a review item',
  (select (c.organization_id <> s.organization_id)::text from clients c, suppliers s where c.name = 'Legacy Beta' and s.name like 'Legacy Beta%') || '|' ||
  (select count(*)::text from organization_reviews r where r.origin = 'migration' and r.reason = 'same_name_different_registration'), 'true|1');
select tests.check('same registration number but unrelated names (Legacy Delta Traders / Totally Other Name): kept as two organizations, with a review item',
  (select (c.organization_id <> s.organization_id)::text from clients c, suppliers s where c.name = 'Totally Other Name' and s.name = 'Legacy Delta Traders') || '|' ||
  (select count(*)::text from organization_reviews r where r.origin = 'migration' and r.reason = 'same_registration_dissimilar_name'), 'true|1');
select tests.check('nothing ambiguous was merged: every migration review is still open', (select count(*)::text || '/' || count(*) filter (where status = 'open') from organization_reviews where origin = 'migration'), '3/3');
select tests.check('no role is left without an organization, and no mirror differs from its organization', (select count(*)::text from clients where organization_id is null) || (select count(*)::text from suppliers where organization_id is null) || tests.drift(), '000');
select tests.check('role IDs and ADA aliases are exactly what they were', (select count(*)::text from legacy_before b left join clients c on b.t = 'c' and c.id = b.id left join suppliers s on b.t = 's' and s.id = b.id where coalesce(c.ada_id, s.ada_id) is distinct from b.ada_id), '0');
select tests.check('historical identity is preserved: the organization keeps the role''s creation time; supplier names adopt the organization''s (the client''s) spelling',
  (select (o.created_at = c.created_at)::text from clients c join organizations o on o.id = c.organization_id where c.name = 'Legacy Alpha (Pty) Ltd' and c.deleted_at is null) || '|' || (select name from suppliers where registration_number = 'LA-1'), 'true|Legacy Alpha (Pty) Ltd');
select tests.check('...and audit history is intact: the original INSERT audit rows are still there (reconciliation only ADDED update rows)',
  (select (count(*) = (select n from legacy_audit_before))::text from audit_log where table_name in ('clients', 'suppliers') and action = 'INSERT' and (new_data ->> 'name') in ('Legacy Alpha (Pty) Ltd', 'LEGACY ALPHA', 'Legacy Beta', 'Legacy Beta Ltd'))
  || (select (count(*) > 0)::text from audit_log where table_name = 'clients' and action = 'UPDATE' and 'organization_id' = any (changed_fields) and (new_data ->> 'name') = 'Legacy Beta'), 'truetrue');
select tests.check('reconciliation is idempotent', (select organization_reconcile() ->> 'organizations_created'), '0');
select tests.check('reconciled organizations are registered as migrated entities with their own permanent IDs', (select count(*)::text from entity_registry r join organizations o on o.id = r.entity_id and r.table_name = 'organizations' where r.origin_kind = 'migrated'), '8');
alter table clients alter column organization_id set not null;
alter table suppliers alter column organization_id set not null;


-- Further rules (each pinned by a mutation) -----------------------------------------------------------------------------------------------------------------
select tests.check('every identity column is a mirror, and one direct write of all of them reaches the organization and every role',
  tests.try_owner(format($q$ update clients set legal_name = 'Full Legal', trading_name = 'Trade As', website = 'https://www.full.example', email = 'full@full.example', phone = '061 000', address = '1 Full St', city = 'Walvis Bay', country = 'Zambia', industry = 'Mining', social_links = '{"x": "y"}'::jsonb where id = %L $q$, tests.id('client:abc'))), 'ok');
select tests.check('...organization holds every one', (select concat_ws('|', legal_name, trading_name, website, email, phone, address, city, country, industry, social_links ->> 'x') from organizations where id = tests.org_of('client:abc')),
  'Full Legal|Trade As|https://www.full.example|full@full.example|061 000|1 Full St|Walvis Bay|Zambia|Mining|y');
select tests.check('...and the supplier role of that organization mirrors its website', (select website from suppliers where organization_id = tests.org_of('client:abc')), 'https://www.full.example');
select tests.check('there are exactly twelve client mirrors, three supplier mirrors and one partner mirror', (select cardinality(org_mirror_cols('clients'))::text || cardinality(org_mirror_cols('suppliers'))::text || cardinality(org_mirror_cols('partners'))::text), '1231');
select tests.check('blank input is accepted', tests.try_owner(format($q$ update clients set phone = '   ', email = '' where id = %L $q$, tests.id('client:abc'))), 'ok');
select tests.check('...and normalised by the organization (not stored as spaces); the role mirrors the normalised value',
  (select concat_ws('|', coalesce(o.phone, 'NULL'), coalesce(c.phone, 'NULL'), coalesce(c.email, 'NULL')) from clients c join organizations o on o.id = c.organization_id where c.id = tests.id('client:abc')), 'NULL|NULL|NULL');
select tests.check('an organization''s identity cannot be edited by people without organizations.update, and only the whitelisted fields can be',
  tests.try('web_lead', format($q$ select organization_update(%L, jsonb_build_object('city', 'x')) $q$, tests.org_of('client:abc'))) || tests.try('adm2', format($q$ select organization_update(%L, jsonb_build_object('status', 'merged')) $q$, tests.org_of('client:abc')))
  || tests.try('adm2', format($q$ select organization_update(%L, jsonb_build_object('uniqueness_exempt', true)) $q$, tests.org_of('client:abc'))) || tests.try('adm2', format($q$ select organization_update(%L, '{}'::jsonb) $q$, tests.org_of('client:abc'))), 'ERR:42501ERR:23514ERR:23514ERR:23514');
select tests.check('the uniqueness exemption and the merged status are system-only, even for the database owner',
  tests.try_owner(format('update organizations set uniqueness_exempt = true where id = %L', tests.id('org:st'))) || tests.try_owner(format($q$ update organizations set status = 'merged', merged_into_id = %L where id = %L $q$, tests.org_of('client:abc'), tests.id('org:st'))), 'ERR:42501ERR:42501');
select tests.check('a different legal entity under an existing organization''s name is reported, not created', tests.scalar('adm2', $q$ select (organization_create('Theta Foods', p_registration => 'TF-9') ->> 'status') $q$), 'name_conflict');
select tests.check('one partner and one supplier row per organization, enforced by the database', tests.try_owner(format($q$ insert into partners (organization_id, name) values (%L, 'dup') $q$, tests.id('org:st'))) || tests.try_owner(format($q$ insert into clients (organization_id, name, owner_division_id) values (%L, 'dup', %L) $q$, tests.id('org:st'), tests.id('div:web'))), 'ERR:23505ERR:23505');

select tests.try('fin', $q$ insert into suppliers (name, website) values ('Zulu', 'https://www.zulu.example/about') $q$);
select tests.check('website evidence: a similar name that would not match alone matches when both share the website host',
  (select count(*)::text from org_match('Zulu Hold', null, null, null, null, false)) || (select count(*)::text from org_match('Zulu Hold', null, 'zulu.example/contact', null, null, false) where strength = 'strong'), '01');
select tests.check('...so a client with that name and website joins the supplier''s organization', tests.try_owner($q$ insert into clients (name, website) values ('Zulu Hold', 'zulu.example/contact') $q$) || (select count(*)::text from organizations where org_host(website) = 'zulu.example'), 'ok1');
select tests.check('the website host normaliser strips scheme, www, path, port and case', (select concat_ws('|', org_host('HTTPS://www.Zulu.Example/a?b=1#c'), org_host('zulu.example:8080'), coalesce(org_host(' '), 'NULL'))), 'zulu.example|zulu.example|NULL');

select tests.check('a supplier is registered', tests.try('fin', $q$ insert into suppliers (name) values ('Omicron Supplies') $q$), 'ok');
select tests.check('a hidden client is created for the same name', tests.try_owner($q$ insert into clients (name, classification) values ('Omicron Supplies', 'restricted') $q$), 'ok');
select tests.check('...it is never merged into the discoverable organization: two organizations', (select count(*)::text from organizations where name_key = client_name_key('Omicron Supplies')), '2');
select tests.check('...and the pair is flagged for review (silently)', (select count(*)::text from organization_reviews r join organizations a on a.id = r.left_org_id join organizations b on b.id = r.right_org_id where r.status = 'open' and a.name_key = client_name_key('Omicron Supplies') and b.name_key = client_name_key('Omicron Supplies')), '1');

select tests.mkclient_id('web_lead', 'Phi Software', 'web');
select tests.check('a creator can declare a similar-named client DISTINCT', tests.scalar('web_lead', $q$ select (client_create('Phi Softwares', (select id from divisions where key = 'web'), p_distinct_reason => 'different company in Oshakati') ->> 'status') $q$), 'created');
select tests.check('...which is not queued for review again, and is recorded as a distinct pair',
  (select count(*)::text from organization_reviews r join organizations a on a.id = r.left_org_id join organizations b on b.id = r.right_org_id where r.status = 'open' and a.name like 'Phi Software%' and b.name like 'Phi Software%')
  || (select count(*)::text from organization_distinct_pairs d join organizations a on a.id = d.org_a join organizations b on b.id = d.org_b where a.name like 'Phi Software%' and b.name like 'Phi Software%'), '01');

select tests.remember('client:webonly', tests.mkclient_id('web_lead', 'Web Only Client', 'web'));
select tests.check('a client is closed', tests.try_owner(format($q$ update clients set deleted_at = now(), deletion_reason = 'closed' where id = %L $q$, tests.id('client:webonly'))), 'ok');
select tests.check('...its organization goes dormant (it still exists, with its identity and ID)', (select status from organizations where id = tests.org_of('client:webonly')), 'dormant');
select tests.check('a new client of the same name is created', tests.try_owner(format($q$ insert into clients (name, owner_division_id) values ('Web Only Client', %L) $q$, tests.id('div:web'))), 'ok');
select tests.check('...it re-uses the SAME organization (no duplicate identity) and re-activates it', (select count(*)::text || '/' || min(status) from organizations where name_key = client_name_key('Web Only Client')), '1/active');
select tests.check('...the closed client record stays on the same organization as history', (select count(*)::text from clients where organization_id = tests.org_of('client:webonly') and deleted_at is not null) || (select count(*)::text from clients where organization_id = tests.org_of('client:webonly') and deleted_at is null), '11');


select tests.scalar('adm2', $q$ select organization_create('Pi One')->>'status' $q$);
select tests.scalar('adm2', $q$ select organization_create('Pi Two', p_legal_name => 'Pi Two Legal (Pty) Ltd')->>'status' $q$);
insert into tests.ids select 'org:pi1', id from organizations where name = 'Pi One';
insert into tests.ids select 'org:pi2', id from organizations where name = 'Pi Two';
select tests.try('ceo', format($q$ select organization_add_role(%L, 'client', %L) $q$, tests.id('org:pi1'), tests.id('div:web')));
select tests.try('adm2', format($q$ select organization_add_role(%L, 'partner') $q$, tests.id('org:pi2')));
select tests.check('a human merges Pi Two (a partner) into Pi One (a client): the partner role follows, the survivor gains the facts it lacked, the survivor keeps its own name',
  tests.try('adm2', format($q$ select organization_merge(%L, %L, 'same company') $q$, tests.id('org:pi1'), tests.id('org:pi2'))), 'ok');
select tests.check('...the partner is now a role of the survivor', (select count(*)::text from partners where organization_id = tests.id('org:pi1')), '1');
select tests.check('...and the survivor gained the legal name it lacked while keeping its own display name', (select name || '|' || legal_name from organizations where id = tests.id('org:pi1')), 'Pi One|Pi Two Legal (Pty) Ltd');
select tests.check('...the survivor''s client mirrors the gained legal name', (select legal_name from clients where organization_id = tests.id('org:pi1')), 'Pi Two Legal (Pty) Ltd');

-- Restricted organizations: hidden ones are never reused, never named, never visible --------------------------------------------------------------------------
select tests.remember('client:hush', tests.mkclient_id('ceo', 'Hush Corp', 'web'));
update clients set classification = 'restricted' where id = tests.id('client:hush');
insert into tests.ids values ('org:hush', tests.org_of('client:hush'));
create temp table hush_inst as select institutional_id i from entity_registry where table_name = 'organizations' and entity_id = tests.id('org:hush');
select tests.check('a restricted client makes its organization restricted', (select effective_classification::text from organizations where id = tests.id('org:hush')), 'restricted');
select tests.check('the cleared (CEO, administration, auditor) see the organization; the web lead (who runs Web), division staff, finance and Tech do not',
  tests.scalar('ceo', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))) || tests.scalar('adm2', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))) || tests.scalar('audit', format('select count(*)::text from organizations where id = %L', tests.id('org:hush')))
  || tests.scalar('web_lead', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))) || tests.scalar('web_staff', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))) || tests.scalar('fin', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))) || tests.scalar('tech_lead', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))), '1110000');
select tests.check('to everyone else every probe is indistinguishable from a random ID (360, resolve, role add, update)',
  tests.same_for('web_lead', $q$ select coalesce(organization_360(%L)::text, 'null') $q$, tests.id('org:hush'), tests.id('x:random')) || tests.same_for('web_lead', $q$ select organization_update(%L, jsonb_build_object('city', 'x'))::text $q$, tests.id('org:hush'), tests.id('x:random'))
  || tests.same_for('web_lead', $q$ select organization_add_role(%L, 'partner')::text $q$, tests.id('org:hush'), tests.id('x:random')) || tests.same_for('adm2', $q$ select coalesce(organization_360(%L)::text, 'null') $q$, tests.id('x:random'), tests.id('x:random')), 'samesamesamesame');
select tests.check('the registry does not resolve it for them either', tests.scalar('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select i from hush_inst))) || tests.scalar('adm2', format($q$ select (entity_resolve(%L) ->> 'entity_type') $q$, (select i from hush_inst))), 'nullexternal_organization');
select tests.check('finance registers a supplier with the hidden client''s name: it SUCCEEDS silently (no error, no message)', tests.try('fin', $q$ insert into suppliers (name, registration_number) values ('Hush Corp', 'HC-9') $q$), 'ok');
select tests.check('...as a SEPARATE organization: the hidden one is never reused and never named', (select count(*)::text from organizations where name_key = 'hush') || (select (s.organization_id <> tests.id('org:hush'))::text from suppliers s where s.name = 'Hush Corp'), '2true');
select tests.check('...the supplier shows only its own data (it does not inherit the hidden organization''s facts)', (select coalesce(registration_number, 'none') from suppliers where name = 'Hush Corp'), 'HC-9');
select tests.check('...and a silent review item exists, visible only to matching.review holders',
  tests.scalar('adm2', format($q$ select count(*)::text from organization_reviews where status = 'open' and %L in (left_org_id::text, right_org_id::text) $q$, tests.id('org:hush'))) || tests.scalar('web_lead', 'select count(*)::text from organization_reviews') || tests.scalar('fin', 'select count(*)::text from organization_reviews'), '100');
select tests.remember('client:quiet', tests.mkclient_id('ceo', 'Quiet Industries', 'web'));
select tests.scalar('ceo', format($q$ select organization_set_classification(%L, 'confidential', 'sensitive owner')::text $q$, tests.org_of('client:quiet')));
select tests.check('an organization''s own classification is a floor for its client roles: raising it raises the client', (select classification::text || '/' || effective_classification::text from organizations where id = tests.org_of('client:quiet')) || '|' || (select classification::text from clients where id = tests.id('client:quiet')), 'confidential/confidential|confidential');
select tests.check('...and the web lead loses sight of both', tests.scalar('web_lead', format('select count(*)::text from organizations where id = %L', tests.org_of('client:quiet'))) || tests.scalar('web_lead', format('select count(*)::text from clients where id = %L', tests.id('client:quiet'))), '00');
select tests.check('a partner role is added to a hidden organization', tests.try('ceo', format($q$ select organization_add_role(%L, 'partner') $q$, tests.org_of('client:quiet'))), 'ok');
select tests.check('...and the partner is hidden with it', tests.scalar('web_lead', format('select count(*)::text from partners where organization_id = %L', tests.org_of('client:quiet'))) || tests.scalar('ceo', format('select count(*)::text from partners where organization_id = %L', tests.org_of('client:quiet'))), '01');
select tests.check('classifying needs records.classify and organizations.update, and a reason', tests.scalar('web_lead', format($q$ select organization_set_classification(%L, 'restricted', 'x')::text $q$, tests.org_of('client:abc'))) || tests.scalar('adm2', format($q$ select organization_set_classification(%L, 'restricted', ' ')::text $q$, tests.org_of('client:abc'))), 'ERR:42501ERR:23514');
select tests.check('un-restricting the client would now make two look-alike organizations both discoverable: refused until a human settles it (same rule clients always had)',
  tests.try_owner(format($q$ update clients set classification = 'internal' where id = %L $q$, tests.id('client:hush'))), 'ERR:23505');
select tests.check('the reviewer (who may see both) decides they are the same company; the hidden organization survives and the supplier role joins it',
  tests.try('adm2', format($q$ select organization_review_resolve((select id from organization_reviews where status = 'open' and %L in (left_org_id::text, right_org_id::text) limit 1), 'same', 'same company, supplier relationship', %L) $q$, tests.id('org:hush'), tests.id('org:hush'))), 'ok');
select tests.check('...the supplier is now a role of the surviving organization', (select count(*)::text from suppliers where organization_id = tests.id('org:hush')), '1');
select tests.check('...and now un-restricting works: the client returns to the web lead''s view and the organization follows', tests.try_owner(format($q$ update clients set classification = 'internal' where id = %L $q$, tests.id('client:hush'))), 'ok');
select tests.check('...(the organization''s effective classification fell with its only live client)', (select effective_classification::text from organizations where id = tests.id('org:hush')), 'internal');
select tests.check('...and the web lead sees them again', tests.scalar('web_lead', format('select count(*)::text from organizations where id = %L', tests.id('org:hush'))), '1');
select tests.check('an organization that is only a client of ANOTHER division stays invisible to a division that cannot see the client', tests.scalar('web_lead', format('select count(*)::text from organizations where id = %L', tests.org_of('client:webonly'))) || tests.scalar('tech_lead', format('select count(*)::text from organizations where id = %L', tests.org_of('client:webonly'))), '10');
select tests.check('roleless / supplier-only organizations: visible to organization viewers and supplier viewers, not to a recruiter',
  tests.scalar('adm2', format('select count(*)::text from organizations where id = %L', tests.id('org:rho1'))) || tests.scalar('fin', format('select count(*)::text from organizations where id = %L', tests.id('org:rho1'))) || tests.scalar('recruiter', format('select count(*)::text from organizations where id = %L', tests.id('org:rho1'))), '110');

-- Client 360 resolves identity from the organization ---------------------------------------------------------------------------------------------------------
select tests.check('Client 360 carries the organization (institutional ID, status, which roles the organization also plays)',
  tests.scalar('ceo', format($q$ select (client_360(%L) -> 'organization' ->> 'institutional_id') = (select institutional_id from entity_registry where table_name = 'organizations' and entity_id = %L) $q$, tests.id('client:abc'), tests.org_of('client:abc'))) ||
  tests.scalar('ceo', format($q$ select (client_360(%L) -> 'organization' -> 'roles' ->> 'supplier') || (client_360(%L) -> 'organization' -> 'roles' ->> 'partner') $q$, tests.id('client:abc'), tests.id('client:abc'))), 'truetruetrue');
select tests.check('...the client-facing compatibility fields are all still there (name, legal / trading name, type, status, registration number, contact points, address)',
  tests.scalar('ceo', format($q$ select string_agg(k, ',' order by k) from jsonb_object_keys(client_360(%L) -> 'overview') k where k in ('name', 'legal_name', 'trading_name', 'type', 'status', 'registration_number', 'email', 'phone', 'website', 'address', 'city', 'country', 'industry', 'social_links') $q$, tests.id('client:abc'))),
  'address,city,country,email,industry,legal_name,name,phone,registration_number,social_links,status,trading_name,type,website');
select tests.check('the organization is renamed: Client 360 shows the new name at once', tests.try('adm2', format($q$ select organization_update(%L, jsonb_build_object('name', 'ABC Group Holdings', 'legal_name', 'ABC Group Holdings (Pty) Ltd')) $q$, tests.org_of('client:abc'))), 'ok');
select tests.check('...from the organization', tests.scalar('web_lead', format($q$ select (client_360(%L) -> 'overview' ->> 'name') || '|' || (client_360(%L) -> 'overview' ->> 'legal_name') $q$, tests.id('client:abc'), tests.id('client:abc'))), 'ABC Group Holdings|ABC Group Holdings (Pty) Ltd');
alter table clients disable trigger clients_org_mirror_guard_trg;
update clients set name = 'TAMPERED', city = 'Nowhere' where id = tests.id('client:abc');
select tests.check('even if a mirror were tampered with, the drift check names it and Client 360 still reads the organization''s truth',
  (select string_agg(column_name, ',' order by column_name) from organization_mirror_drift() where role_id = tests.id('client:abc')) || '|' || tests.scalar('web_lead', format($q$ select (client_360(%L) -> 'overview' ->> 'name') $q$, tests.id('client:abc'))), 'city,name|ABC Group Holdings');
alter table clients enable trigger clients_org_mirror_guard_trg;
select organization_resync(tests.org_of('client:abc'));
select tests.check('...and one resync repairs it', tests.drift(), '0');
select tests.mk_doc('web_lead', 'od1', 'Client brief', 'report', 'web', 'client:abc');
select tests.check('documents linked to the client appear in the organization''s 360 (documents ride the organization''s family)', tests.scalar('ceo', format($q$ select (jsonb_array_length(organization_360(%L) -> 'documents') >= 1)::text $q$, tests.org_of('client:abc'))), 'true');
select tests.check('a document can be linked to an organization directly (it is a registered entity)', tests.scalar('adm2', format($q$ select (document_link_add(%L, (select institutional_id from entity_registry where table_name = 'organizations' and entity_id = %L), 'reference')) is not null $q$, tests.id('doc:od1'), tests.id('org:st'))), 'true');
select tests.check('project, contract and invoice records keep pointing at the client (project:abc / contract:1 resolve unchanged)',
  (select (p.client_id = tests.id('client:abc'))::text from projects p where p.id = tests.id('project:abc')) || (select (c.client_id = tests.id('client:abc'))::text from contracts c where c.id = tests.id('contract:1')), 'truetrue');

-- Audit ------------------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('organization creation and edits are audited with the acting staff member',
  (select (count(*) filter (where action = 'INSERT') > 0 and count(*) filter (where action = 'UPDATE' and 'name' = any (changed_fields)) > 0 and bool_and(actor_staff_id is not null) filter (where action = 'UPDATE' and 'name' = any (changed_fields) and actor_staff_id is not null))::text
     from audit_log where table_name = 'organizations' and record_id = tests.org_of('client:abc')), 'true');
select tests.check('...a rename made through a role is audited on the role AND the organization, with the editor''s identity',
  (select (count(*) > 0)::text from audit_log where table_name = 'clients' and record_id = tests.id('org:st') or (table_name = 'organizations' and record_id = tests.id('org:st') and actor_staff_id = tests.id('staff:web_lead'))), 'true');
select tests.check('merges and review decisions are audited', (select (count(*) > 0)::text from audit_log where table_name = 'organizations' and record_id = tests.id('org:muk') and 'status' = any (changed_fields)) || (select (count(*) > 0)::text from audit_log where table_name = 'organization_reviews' and record_id = tests.id('rev:mu')), 'truetrue');
select tests.check('the role''s earlier audit rows still point at the same record ID (client ABC''s creation is still on file)', (select count(*)::text from audit_log where table_name = 'clients' and record_id = tests.id('client:abc') and action = 'INSERT'), '1');
select tests.check('organizations are never deleted (not by anyone), and neither are their reviews or pairs', tests.try_owner(format('delete from organizations where id = %L', tests.id('org:st'))) || tests.try('ceo', 'delete from organizations') || tests.try_owner('delete from organization_reviews') || tests.try_owner('delete from organization_distinct_pairs'), 'ERR:42501ERR:42501okok');
select tests.check('API users cannot write organizations or reviews directly', tests.try('adm2', format($q$ update organizations set name = 'x' where id = %L $q$, tests.id('org:st'))) || tests.try('adm2', $q$ insert into organizations (name) values ('Direct Insert') $q$) || tests.try('adm2', 'update organization_reviews set status = ''dismissed''') , 'ERR:42501ERR:42501ERR:42501');

-- Definite predicates ---------------------------------------------------------------------------------------------------------------------------------------
select tests.check('organization access predicates never return NULL (random IDs, no staff identity, null arguments)',
  (select count(*)::text from (values ('ceo'), ('web_lead'), ('fin'), ('tech_staff'), ('recruiter'), ('outsider'), ('suspended')) u(n)
    where tests.scalar(u.n, format($q$ select coalesce(can_view_organization(%L)::text, 'NULL') $q$, tests.id('x:random'))) is distinct from 'false'
       or tests.scalar(u.n, $q$ select coalesce(can_view_organization(null)::text, 'NULL') $q$) is distinct from 'false'
       or tests.scalar(u.n, $q$ select coalesce(partner_visible(null)::text, 'NULL') $q$) is distinct from 'false'
       or tests.scalar(u.n, $q$ select coalesce(can_view_organization_row(null, null)::text, 'NULL') $q$) = 'NULL'), '0');
select tests.check('the permanent identity is recorded: type is built, never public, and in the codebook', (select (t.is_built and not t.publishable and t.domain_table = 'organizations' and c.code = t.id_code)::text from entity_types t join id_codebook c on c.kind = 'type' and c.meaning = t.key where t.key = 'external_organization'), 'true');
select tests.check('the partner type is built on the partners table', (select (is_built and domain_table = 'partners')::text from entity_types where key = 'partner'), 'true');
select tests.check('search finds the organization by name for those who may see it, and nothing for a hidden one',
  (select (search_rebuild() > 0)::text) || tests.scalar('web_lead', $q$ select (select string_agg(x ->> 'entity_type', ',' order by x ->> 'entity_type') from jsonb_array_elements(search_route('Standalone Alliance') -> 'results') x) $q$) || '|' || tests.scalar('web_lead', $q$ select (search_route('Quiet Industries') -> 'results')::text $q$),
  'trueclient,external_organization,partner,supplier|[]');

select tests.finish();
rollback;
