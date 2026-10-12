-- PERMANENT: ADA Hub Pilot V0.1 - the engagement workflow under the existing security model: who may do what at each step, and a RESTRICTED client's whole
-- engagement (project, quote, invoice, payment, document, communication, ticket, asset, domain) staying invisible through search, counts, facets,
-- suggestions, the 360 views, relationship traversal and errors. A differential method: what an uncleared caller observes must be IDENTICAL with and without
-- the hidden engagement. Roles: A = web lead (manages the client and project), B = tech lead (another division), C = tech staff (insufficient), the
-- recruiter, a suspended account, a signed-in non-staff user and the anonymous role.
begin;
select tests.setup();
select tests.setup_hr();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.fakeid() returns text language sql as $$ select 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ') $$;
create function tests.seen(p_user text, p_q text) returns text language plpgsql as $$
declare v text := tests.scalar(p_user, format('select search(%L, null, 0, true)::text', p_q));
begin return case when v like 'ERR:%' then v else (v::jsonb - 'query')::text end; end $$;
create function tests.counts(p_user text) returns text language sql as $$
  select tests.scalar(p_user, $q$ select concat_ws('/', (select count(*) from clients), (select count(*) from projects), (select count(*) from quotes), (select count(*) from contracts), (select count(*) from invoices), (select count(*) from payments),
    (select count(*) from documents), (select count(*) from communication_threads), (select count(*) from tickets), (select count(*) from assets), (select count(*) from domains), (select count(*) from organizations), (select count(*) from client_contacts), (select count(*) from tasks)) $q$)
$$;

-- The visible engagement (Zeta) and the catalogue ---------------------------------------------------------------------------------------------------------------
select tests.remember('svc:wd', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Website Development', 's', 'd' from divisions where key = 'web' returning id::text $q$));
select tests.remember('price:wd1', tests.scalar('web_lead', format('select price_propose(%L, 5000, ''NAD'', current_date, ''launch'')::text', tests.id('svc:wd'))));
select tests.scalar('ceo', format('select (price_decide(%L, true)).status::text', tests.id('price:wd1')));
select tests.bank_account('main');
select tests.remember('zeta', tests.scalar('web_lead', format($q$ select (client_create('Zeta Test Company', %L, 'company', 'ZT-1') ->> 'id') $q$, tests.id('div:web'))));
select tests.remember('zed', tests.scalar('web_lead', format($q$ select add_client_contact(%L, 'Zed Zeta', 'zed@zeta.example', null, 'Director', true, true)::text $q$, tests.id('zeta'))));
select tests.remember('prj', tests.scalar('web_lead', format($q$ select (project_create(%L, %L, 'Zeta Website') ->> 'id') $q$, tests.id('zeta'), tests.id('div:web'))));
select tests.mk_doc('web_lead', 'zdoc', 'Zeta brief', 'requirements', 'web', 'prj');
select tests.mk_thread('web_lead', 'zt', 'Zeta kick-off');
select tests.say('web_lead', 'zt', 'zt1', 'email', 'inbound', 'Zeta body');
select tests.clink('web_lead', 'zt', 'clients', 'zeta');
select tests.remember('zticket', tests.scalar('web_lead', format($q$ select ticket_create('Zeta ticket', null, null, %L, %L, %L)::text $q$, tests.id('div:web'), tests.id('zeta'), tests.id('prj'))));
select tests.remember('zasset', tests.scalar('web_lead', format($q$ select asset_create('Zeta router', 'network', %L, p_client => %L, p_project => %L)::text $q$, tests.id('div:web'), tests.id('zeta'), tests.id('prj'))));
select tests.remember_ok('dom:zd', tests.scalar('web_lead', format($q$ select (domain_create('zeta-pilot.example', %L) ->> 'id') $q$, tests.id('div:web'))));
select tests.rel('web_lead', 'zd', 'client', 'clients', 'zeta');
create temp table snap (k text primary key, v text);
insert into snap select q, tests.seen('web_lead', q) from unnest(array['hidden', 'type:client', 'type:project', 'type:document', 'type:invoice', 'type:ticket', 'type:asset', 'type:domain', 'type:communication', 'type:external_organization', 'rollout', 'hidden-pilot.example', 'ltd', 'holdings']) q;
insert into snap select 'b:' || q, tests.seen('tech_lead', q) from unnest(array['hidden', 'type:client', 'type:project', 'type:ticket']) q;
insert into snap select 'sg:hid', tests.scalar('web_lead', $q$ select search_suggest('hid')::text $q$);
insert into snap select 'sg:hold', tests.scalar('web_lead', $q$ select search_suggest('hold')::text $q$);
insert into snap select 'counts:a', tests.counts('web_lead');
insert into snap select 'counts:b', tests.counts('tech_lead');
insert into snap select '360c', md5(tests.scalar('web_lead', format($q$ select client_360(%L)::text $q$, tests.id('zeta'))));
insert into snap select '360p', md5(tests.scalar('web_lead', format($q$ select project_360(%L)::text $q$, tests.id('prj'))));
insert into snap select 'rel', tests.seen('web_lead', 'related:' || (select institutional_id from entity_registry where entity_id = tests.id('zeta')));

-- The hidden engagement: a restricted client and everything of its engagement -------------------------------------------------------------------------------
select tests.remember('hc', tests.mkclient_id('ceo', 'Hidden Holdings', 'web', 'HH-1'));
update clients set classification = 'restricted' where id = tests.id('hc');
select tests.remember('hcontact', tests.scalar('ceo', format($q$ select add_client_contact(%L, 'Hilda Hidden', 'hilda@hidden.example', null, 'Director', true, true)::text $q$, tests.id('hc'))));
select tests.remember('hp', tests.scalar('ceo', format($q$ select (project_create(%L, %L, 'Hidden Rollout') ->> 'id') $q$, tests.id('hc'), tests.id('div:web'))));
select tests.remember('hquote', tests.scalar('ceo', format($q$ select quote_create(%L, %L, 'Hidden quote', %L, %L)::text $q$, tests.id('hc'), tests.id('div:web'), tests.id('hcontact'), tests.id('hp'))));
select tests.scalar('ceo', format($q$ select quote_add_line(%L, %L)::text $q$, tests.id('hquote'), tests.id('svc:wd')));
select tests.remember('hbill', tests.scalar('ceo', format($q$ select billable_manual(%L, %L, 'Hidden services', 1, 900, 'pilot test')::text $q$, tests.id('hc'), tests.id('div:web'))));
select tests.remember('hinv', tests.scalar('ceo', format($q$ select invoice_create(array[%L]::uuid[], %L)::text $q$, tests.id('hbill'), tests.id('hcontact'))));
select tests.remember('hpay', tests.scalar('ceo', format($q$ select payment_record(%L, %L, 100, 'cash', current_date, 'HIDDEN-PAY')::text $q$, tests.id('hc'), tests.id('acct:main'))));
select tests.mk_doc('ceo', 'hdoc', 'Hidden brief', 'report', 'web', 'hp');
select tests.mk_thread('ceo', 'ht', 'Hidden talks');
select tests.say('ceo', 'ht', 'ht1', 'email', 'inbound', 'Hidden body');
select tests.clink('ceo', 'ht', 'clients', 'hc');
select tests.remember('hticket', tests.scalar('ceo', format($q$ select ticket_create('Hidden ticket', null, null, %L, %L, %L)::text $q$, tests.id('div:web'), tests.id('hc'), tests.id('hp'))));
select tests.remember('hasset', tests.scalar('ceo', format($q$ select asset_create('Hidden router', 'network', %L, p_client => %L, p_project => %L)::text $q$, tests.id('div:web'), tests.id('hc'), tests.id('hp'))));
select tests.remember_ok('dom:hd', tests.scalar('ceo', format($q$ select (domain_create('hidden-pilot.example', %L) ->> 'id') $q$, tests.id('div:web'))));
select tests.rel('ceo', 'hd', 'client', 'clients', 'hc');
select tests.check('the hidden engagement exists: the CEO reads every part of it', tests.scalar('ceo', format($q$ select concat_ws('|', (select count(*) from projects where id = %L), (select count(*) from quotes where id = %L), (select count(*) from invoices where id = %L), (select count(*) from documents where id = %L),
  (select count(*) from communication_threads where id = %L), (select count(*) from tickets where id = %L), (select count(*) from assets where id = %L), (select count(*) from domains where id = %L)) $q$,
  tests.id('hp'), tests.id('hquote'), tests.id('hinv'), tests.id('doc:hdoc'), tests.id('thr:ht'), tests.id('hticket'), tests.id('hasset'), tests.id('dom:hd'))), '1|1|1|1|1|1|1|1');
select tests.check('the cleared (the CEO) find the hidden engagement in search: client, project, document, ticket, asset, domain', tests.scalar('ceo', $q$ select (select string_agg(t, ',' order by t) from (select distinct x ->> 'entity_type' t from jsonb_array_elements(search('hidden')->'results') x where x ->> 'entity_type' in ('client','project','document','ticket','asset','domain')) z) $q$), 'asset,client,document,domain,project,ticket');

-- Differential: what the uncleared caller observes is IDENTICAL with and without the hidden engagement --------------------------------------------------------------
create temp table after_snap (k text primary key, v text);
insert into after_snap select q, tests.seen('web_lead', q) from unnest(array['hidden', 'type:client', 'type:project', 'type:document', 'type:invoice', 'type:ticket', 'type:asset', 'type:domain', 'type:communication', 'type:external_organization', 'rollout', 'hidden-pilot.example', 'ltd', 'holdings']) q;
insert into after_snap select 'b:' || q, tests.seen('tech_lead', q) from unnest(array['hidden', 'type:client', 'type:project', 'type:ticket']) q;
insert into after_snap select 'sg:hid', tests.scalar('web_lead', $q$ select search_suggest('hid')::text $q$);
insert into after_snap select 'sg:hold', tests.scalar('web_lead', $q$ select search_suggest('hold')::text $q$);
insert into after_snap select 'counts:a', tests.counts('web_lead');
insert into after_snap select 'counts:b', tests.counts('tech_lead');
insert into after_snap select '360c', md5(tests.scalar('web_lead', format($q$ select client_360(%L)::text $q$, tests.id('zeta'))));
insert into after_snap select '360p', md5(tests.scalar('web_lead', format($q$ select project_360(%L)::text $q$, tests.id('prj'))));
insert into after_snap select 'rel', tests.seen('web_lead', 'related:' || (select institutional_id from entity_registry where entity_id = tests.id('zeta')));
select tests.check('search answers (names, types, domain, words), totals, facets and ranking for the web lead are identical with and without the hidden engagement',
  coalesce((select string_agg(s.k, ',' order by s.k) from snap s join after_snap a using (k) where s.k not like 'b:%' and s.k not like 'sg:%' and s.k not like 'counts:%' and s.k not in ('360c', '360p', 'rel') and s.v is distinct from a.v), 'none'), 'none');
select tests.check('... and for a user of another division', coalesce((select string_agg(s.k, ',' order by s.k) from snap s join after_snap a using (k) where s.k like 'b:%' and s.v is distinct from a.v), 'none'), 'none');
select tests.check('autocomplete suggestions are identical', coalesce((select string_agg(s.k, ',') from snap s join after_snap a using (k) where s.k like 'sg:%' and s.v is distinct from a.v), 'none'), 'none');
select tests.check('row counts of every engagement table (the counts a UI would show) are identical for two uncleared users', coalesce((select string_agg(s.k, ',') from snap s join after_snap a using (k) where s.k like 'counts:%' and s.v is distinct from a.v), 'none'), 'none');
select tests.check('Client 360 and Project 360 of a visible engagement are byte-identical with and without the hidden engagement', coalesce((select string_agg(s.k, ',') from snap s join after_snap a using (k) where s.k in ('360c', '360p') and s.v is distinct from a.v), 'none'), 'none');
select tests.check('relationship traversal (related:) from a visible client is identical', coalesce((select 'changed' from snap s join after_snap a using (k) where s.k = 'rel' and s.v is distinct from a.v), 'none'), 'none');
select tests.check('the uncleared caller finds none of the hidden engagement by any name, number or domain: searching for each returns nothing',
  (select string_agg(coalesce(tests.scalar('web_lead', format('select (search(%L)->>''total'')', q)), '?'), ',') from unnest(array['hidden', 'holdings', 'hilda', 'hilda@hidden.example', 'rollout', 'HH-1', 'HIDDEN-PAY']) q), '0,0,0,0,0,0,0');
select tests.check('nor by institutional ID of the hidden client, project, invoice, document, ticket, asset, domain, thread: every lookup is empty',
  (select string_agg(tests.scalar('web_lead', format('select (search(%L)->>''total'')', (select institutional_id from entity_registry where entity_id = tests.id(k)))), ',')
     from unnest(array['hc', 'hp', 'hinv', 'doc:hdoc', 'hticket', 'hasset', 'dom:hd', 'thr:ht']) k), '0,0,0,0,0,0,0,0');
select tests.check('nor through related: from the hidden client (the traversal anchor is itself invisible)', tests.scalar('web_lead', format('select (search(%L)->>''total'')', 'related:' || (select institutional_id from entity_registry where entity_id = tests.id('hc')))), '0');
select tests.check('the hidden engagement is invisible by direct SELECT too (clients, projects, quotes, invoices, payments, documents, threads, tickets, assets, domains, contacts)',
  tests.scalar('web_lead', format($q$ select concat_ws('|', (select count(*) from clients where id = %L), (select count(*) from projects where id = %L), (select count(*) from quotes where id = %L), (select count(*) from invoices where id = %L), (select count(*) from payments where id = %L),
   (select count(*) from documents where id = %L), (select count(*) from communication_threads where id = %L), (select count(*) from tickets where id = %L), (select count(*) from assets where id = %L), (select count(*) from domains where id = %L), (select count(*) from client_contacts where id = %L)) $q$,
   tests.id('hc'), tests.id('hp'), tests.id('hquote'), tests.id('hinv'), tests.id('hpay'), tests.id('doc:hdoc'), tests.id('thr:ht'), tests.id('hticket'), tests.id('hasset'), tests.id('dom:hd'), tests.id('hcontact'))), '0|0|0|0|0|0|0|0|0|0|0');

-- The 360 views and the workflow operations answer a hidden id exactly as a missing one --------------------------------------------------------------------------
select tests.check('the 360 views answer a hidden id exactly as a non-existent id (client, project, asset, document, communication, domain, organization)',
  concat_ws(',', tests.same_for('web_lead', 'select client_360(%L)::text', tests.id('hc'), tests.id('x:random')), tests.same_for('web_lead', 'select project_360(%L)::text', tests.id('hp'), tests.id('x:random')),
    tests.same_for('web_lead', 'select asset_360(%L)::text', tests.id('hasset'), tests.id('x:random')), tests.same_for('web_lead', 'select organization_360(%L)::text', (select organization_id from clients where id = tests.id('hc')), tests.id('x:random')),
    tests.same_for('tech_lead', 'select client_360(%L)::text', tests.id('hc'), tests.id('x:random')), tests.same_for('tech_lead', 'select project_360(%L)::text', tests.id('hp'), tests.id('x:random'))),
  'same,same,same,same,same,same');
select tests.check('pilot_record of the hidden quote, invoice, payment and ticket reads as null for the uncleared, and the same as a made-up id',
  (select string_agg(tests.scalar('web_lead', format($q$ select coalesce(pilot_record(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = tests.id(k)))), ',') from unnest(array['hquote', 'hinv', 'hpay', 'hticket']) k) || '|' || tests.scalar('web_lead', format($q$ select coalesce(pilot_record(%L)::text, 'null') $q$, tests.fakeid())), 'null,null,null,null|null');
select tests.check('workflow steps attempted on hidden records answer exactly as on missing ones: quote, project, contact, ticket, message, link, transition, invoice, payment, asset, task, member',
  concat_ws(',',
    tests.same_for('web_lead', format($t$ select quote_create(%%L, %L, 'x')::text $t$, tests.id('div:web')), tests.id('hc'), tests.id('x:random')),
    tests.same_for('web_lead', format($t$ select (project_create(%%L, %L, 'Sneaky'))::text $t$, tests.id('div:web')), tests.id('hc'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select add_client_contact(%L, 'Sneaky Person', 'sneaky@x.example', null, 'x', false, false)::text $t$, tests.id('hc'), tests.id('x:random')),
    tests.same_for('web_lead', format($t$ select ticket_create('x', null, null, %L, %%L)::text $t$, tests.id('div:web')), tests.id('hc'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select quote_transition(%L, 'sent')::text $t$, tests.id('hquote'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select invoice_transition(%L, 'issued')::text $t$, tests.id('hinv'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select project_transition(%L, 'active')::text $t$, tests.id('hp'), tests.id('x:random')),
    tests.same_for('web_lead', format($t$ select project_add_member(%%L, %L, 'contributor')::text $t$, tests.id('web_lead')), tests.id('hp'), tests.id('x:random')),
    tests.same_for('web_lead', format($t$ select project_add_division(%%L, %L)::text $t$, tests.id('div:tech')), tests.id('hp'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select task_create(%L, 'Sneaky task')::text $t$, tests.id('hp'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select asset_transition(%L, 'acquired')::text $t$, tests.id('hasset'), tests.id('x:random')),
    tests.same_for('web_lead', format($t$ select document_link_add(%%L, 'clients', %L)::text $t$, tests.id('zeta')), tests.id('doc:hdoc'), tests.id('x:random')),
    tests.same_for('web_lead', $t$ select (invoice_balance(%L))::text $t$, tests.id('hinv'), tests.id('x:random')),
    tests.same_for('web_lead', format($t$ select domain_relation_add(%L, 'client', (select institutional_id from entity_registry where entity_id = %%L))::text $t$, tests.id('dom:zd')), tests.id('hc'), tests.id('x:random'))),
  'same,same,same,same,same,same,same,same,same,same,same,same,same,same');
select tests.check('nothing was changed by the refused attempts: still one project and one contact on the hidden client, no Sneaky rows anywhere',
  tests.scalar('ceo', format($q$ select concat_ws('|', (select count(*) from projects where client_id = %L), (select count(*) from client_contacts where client_id = %L), (select count(*) from projects where name = 'Sneaky'), (select count(*) from tasks where title = 'Sneaky task')) $q$, tests.id('hc'), tests.id('hc'))), '1|1|0|0');

-- Who may do what at each step ------------------------------------------------------------------------------------------------------------------------------------
select tests.check('User C (tech staff) and the recruiter can neither create a client, a project, a quote, an invoice nor a payment',
  concat_ws(',', tests.try('tech_staff', format($q$ select (project_create(%L, %L, 'C project'))::text $q$, tests.id('zeta'), tests.id('div:web'))), tests.try('recruiter', format($q$ select (project_create(%L, %L, 'R project'))::text $q$, tests.id('zeta'), tests.id('div:web'))),
    tests.try('tech_staff', format($q$ select quote_create(%L, %L, 'q')::text $q$, tests.id('zeta'), tests.id('div:web'))), tests.try('tech_staff', format($q$ select payment_record(%L, %L, 1, 'cash', current_date, 'x')::text $q$, tests.id('zeta'), tests.id('acct:main'))),
    tests.try('web_lead', format($q$ select payment_record(%L, %L, 1, 'cash', current_date, 'x')::text $q$, tests.id('zeta'), tests.id('acct:main')))),
  'ERR:P0002,ERR:P0002,ERR:42501,ERR:42501,ERR:42501');
select tests.check('User B (another division) cannot create a project in the Web division, nor on the Web client, and sees neither it nor its documents', 
  concat_ws(',', tests.try('tech_lead', format($q$ select (project_create(%L, %L, 'B project'))::text $q$, tests.id('zeta'), tests.id('div:web'))), tests.scalar('tech_lead', format('select count(*)::text from projects where id = %L', tests.id('prj'))),
    tests.scalar('tech_lead', format('select count(*)::text from documents where id = %L', tests.id('doc:zdoc')))), 'ERR:P0002,0,0');
select tests.check('a suspended account, a signed-in non-staff user and the anonymous role get nothing from the catalogue, the 360 views or the workflow operations',
  concat_ws(',', tests.scalar('suspended', 'select pilot_catalogue()::text'), tests.scalar('outsider', 'select pilot_catalogue()::text'), tests.scalar_anon('select pilot_catalogue()::text'),
    tests.scalar('suspended', format($q$ select client_360(%L)::text $q$, tests.id('zeta'))), tests.scalar('outsider', format($q$ select project_360(%L)::text $q$, tests.id('prj'))), tests.scalar_anon(format($q$ select client_360(%L)::text $q$, tests.id('zeta'))),
    tests.scalar('outsider', format($q$ select (project_create(%L, %L, 'O project'))::text $q$, tests.id('zeta'), tests.id('div:web'))), tests.scalar_anon(format($q$ select (project_create(%L, %L, 'A project'))::text $q$, tests.id('zeta'), tests.id('div:web')))),
  '{"staff": [], "services": [], "divisions": [], "bank_accounts": []},{"staff": [], "services": [], "divisions": [], "bank_accounts": []},ERR:42501,ERR:42501,ERR:P0002,ERR:42501');
select tests.finish();
rollback;
