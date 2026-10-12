-- PERMANENT: ADA Hub Pilot V0.1 - authorization and non-disclosure ACROSS THE WHOLE WORKFLOW (the Zeta engagement of 110, with a restricted engagement beside it).
-- Identities: A = web_lead (manages the client and project) · B = tech_lead (another division) · C = web_staff (same division, too few permissions) ·
-- suspended staff · outsider (a login with no staff record) · anonymous.
-- Method (as in 109): what an uncleared caller can observe must be IDENTICAL with and without the hidden records, and asking about a hidden id must be
-- indistinguishable from asking about an id that never existed - for Client 360, Project 360, Search (results, totals, facets, suggestions, related:), every
-- record loader and every workflow write.
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
insert into tests.ids values ('x:random', gen_random_uuid());
insert into services (division_id, name, summary, description, status, published_at) select id, 'Website Development', 's', 'd', 'published', now() from divisions where key = 'web';
insert into tests.ids select 'svc:web', id from services where name = 'Website Development';
select tests.remember('price:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'list')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:web'), true)).status::text $q$);

-- The visible engagement (Zeta), built by A ----------------------------------------------------------------------------------------------------------
select tests.remember('c:zeta', tests.mkclient_id('web_lead', 'Zeta Test Company', 'web'));
select tests.remember('ct:zeta', tests.scalar('web_lead', format('select add_client_contact(%L, ''Zoe Zeta'', ''zoe@zeta.example'', null, ''Director'', true, true)::text', tests.id('c:zeta'))));
select tests.remember('p:zeta', tests.scalar('web_lead', format($q$ insert into projects (client_id, lead_division_id, name) values (%L, %L, 'Zeta Website') returning id::text $q$, tests.id('c:zeta'), tests.id('div:web'))));
select tests.remember('q:zeta', tests.scalar('web_lead', format('select quote_create(%L, %L, ''Zeta website'', %L, %L)::text', tests.id('c:zeta'), tests.id('div:web'), tests.id('ct:zeta'), tests.id('p:zeta'))));
select tests.scalar('web_lead', format('select quote_add_line(%L, %L)::text', tests.id('q:zeta'), tests.id('svc:web')));
select tests.scalar('web_lead', format($q$ select quote_transition(%L, 'pending_approval')::text $q$, tests.id('q:zeta')));
select tests.scalar('ceo', format($q$ select quote_transition(%L, 'approved')::text $q$, tests.id('q:zeta')));
select tests.scalar('web_lead', format($q$ select quote_transition(%L, 'sent')::text $q$, tests.id('q:zeta')));
select tests.scalar('web_lead', format($q$ select quote_transition(%L, 'accepted')::text $q$, tests.id('q:zeta')));
select tests.issued_invoice('zeta', 'c:zeta', 5000);
select tests.remember('pay:zeta', tests.scalar('fin', format('select payment_record(%L, %L, 2000, ''bank_transfer'', current_date, ''EFT-Z'', %L)::text', tests.id('c:zeta'), tests.id('acct:nad'), tests.id('inv:zeta'))));
select tests.mk_doc('web_lead', 'zeta', 'Zeta brief', 'report', 'web', 'p:zeta');
select tests.mk_thread('web_lead', 'zeta', 'Zeta kick-off');
select tests.say('web_lead', 'zeta', 'z1', 'email', 'inbound', 'visible body');
select tests.clink('web_lead', 'zeta', 'projects', 'p:zeta');
select tests.mk_asset('web_lead', 'zeta', 'Zeta server', 'web', 'Dell', 'SN-Z1', null, 'in_stock', 'c:zeta', 'p:zeta');
select tests.remember('t:zeta', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'Zeta slow', p_asset => %L, p_project => %L, p_client => %L, p_division => %L)::text $q$, tests.id('asset:zeta'), tests.id('p:zeta'), tests.id('c:zeta'), tests.id('div:web'))));
create temp table zinst as select tests.inst_of('clients', 'c:zeta') as client, tests.inst_of('projects', 'p:zeta') as project;

-- What each uncleared identity can observe of the visible engagement, BEFORE any restricted record exists ------------------------------------------------
create function tests.observe(p_user text) returns text language plpgsql as $$
declare v text; z zinst%rowtype;
begin
  select * into z from zinst;
  v := concat_ws('~',
    tests.scalar(p_user, format('select client_360(%L)::text', tests.id('c:zeta'))),
    tests.scalar(p_user, format('select project_360(%L)::text', tests.id('p:zeta'))),
    tests.scalar(p_user, $q$ select (search('zeta', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('type:client', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('type:project', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('type:document', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('type:communication', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('type:invoice', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('type:payment', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, $q$ select (search('ltd', null, 0, true) - 'query')::text $q$),
    tests.scalar(p_user, format($q$ select (search('related:%s', null, 0, true) - 'query')::text $q$, z.client)),
    tests.scalar(p_user, $q$ select search_suggest('zet')::text $q$),
    tests.scalar(p_user, $q$ select search_suggest('qua')::text $q$),
    tests.scalar(p_user, $q$ select (select count(*) from clients)::text || '/' || (select count(*) from projects) || '/' || (select count(*) from quotes) || '/' || (select count(*) from invoices)
                                  || '/' || (select count(*) from payments) || '/' || (select count(*) from documents) || '/' || (select count(*) from communication_threads)
                                  || '/' || (select count(*) from tickets) || '/' || (select count(*) from assets) || '/' || (select count(*) from organizations) $q$));
  return v;
end $$;
create temp table obs_before (u text primary key, v text);
insert into obs_before select u, tests.observe(u) from unnest(array['tech_lead', 'web_staff', 'suspended', 'outsider']) u;
create temp table obs_a_before as select tests.observe('web_lead') as v;

-- The restricted engagement (Quasar): client + project + quote + invoice + payment + document + communication + asset + ticket + domain ------------------
select tests.remember('c:quasar', tests.mkclient_id('ceo', 'Quasar Holdings Ltd', 'web', 'QH-9'));
-- finance bills it while it is still ordinary; THEN it becomes restricted (the finance records inherit the classification)
select tests.issued_invoice('quasar', 'c:quasar', 7000);
select tests.remember('pay:quasar', tests.scalar('fin', format('select payment_record(%L, %L, 1000, ''bank_transfer'', current_date, ''EFT-Q'', %L)::text', tests.id('c:quasar'), tests.id('acct:nad'), tests.id('inv:quasar'))));
update clients set classification = 'restricted' where id = tests.id('c:quasar');
select tests.remember('p:quasar', tests.scalar('ceo', format($q$ insert into projects (client_id, lead_division_id, name) values (%L, %L, 'Quasar Rollout') returning id::text $q$, tests.id('c:quasar'), tests.id('div:web'))));
select tests.remember('q:quasar', tests.scalar('ceo', format('select quote_create(%L, %L, ''Quasar quote'', null, %L)::text', tests.id('c:quasar'), tests.id('div:web'), tests.id('p:quasar'))));
select tests.scalar('ceo', format('select quote_add_line(%L, %L)::text', tests.id('q:quasar'), tests.id('svc:web')));
select tests.mk_doc('ceo', 'quasar', 'Quasar brief', 'report', 'web', 'p:quasar');
select tests.mk_thread('ceo', 'quasar', 'Quasar talks');
select tests.say('ceo', 'quasar', 'q1', 'email', 'inbound', 'HIDDEN-BODY-QUASAR');
select tests.clink('ceo', 'quasar', 'projects', 'p:quasar');
select tests.mk_asset('ceo', 'quasar', 'Quasar server', 'web', 'Dell', 'SN-Q1', null, 'in_stock', 'c:quasar', 'p:quasar');
select tests.remember('t:quasar', tests.scalar('ceo', format($q$ select ticket_create(p_title => 'Quasar slow', p_asset => %L, p_project => %L, p_client => %L, p_division => %L)::text $q$, tests.id('asset:quasar'), tests.id('p:quasar'), tests.id('c:quasar'), tests.id('div:web'))));
-- a restricted PROJECT of the VISIBLE client, a restricted document and thread of the visible project
select tests.remember('p:zhid', tests.scalar('ceo', format($q$ insert into projects (client_id, lead_division_id, name, classification) values (%L, %L, 'Zeta Secret Programme', 'restricted') returning id::text $q$, tests.id('c:zeta'), tests.id('div:web'))));
select tests.mk_doc('ceo', 'zhid', 'Zeta restricted annex', 'report', 'web', 'p:zeta', 'restricted');
select tests.mk_thread('ceo', 'zhid', 'Zeta restricted talks', 'web', 'restricted');
select tests.clink('ceo', 'zhid', 'projects', 'p:zeta');
select tests.check('the restricted records ARE in the system (only authorization hides them)',
  (select count(*)::text from clients where id = tests.id('c:quasar')) || (select count(*)::text from projects where id in (tests.id('p:quasar'), tests.id('p:zhid')))
  || (select count(*)::text from documents where id in (tests.id('doc:quasar'), tests.id('doc:zhid'))) || (select count(*)::text from communication_threads where id in (tests.id('thr:quasar'), tests.id('thr:zhid'))), '1222');

-- Differential: nothing an uncleared caller can observe of the visible engagement changed ----------------------------------------------------------------
select tests.check('Client 360, Project 360, search results / totals / facets / suggestions / related:, and every visible count are IDENTICAL with and without the restricted records, for B, C, suspended and an outsider',
  (select coalesce(string_agg(b.u, ','), 'none') from obs_before b where b.v is distinct from tests.observe(b.u)), 'none');
select tests.check('sanity: the observations are not empty for the people who may see Zeta (A sees the engagement; the differential is not vacuous)',
  (select (length(v) > 2000)::text from obs_a_before), 'true');
select tests.check('A (cleared) sees the SAME visible engagement as before in Client 360 (the restricted project of the visible client is hidden from A as well - A is a Web lead, not management)',
  (select (tests.scalar('web_lead', format('select (client_360(%L) -> ''projects'')::text', tests.id('c:zeta'))) not like '%Zeta Secret Programme%')::text), 'true');
select tests.check('management (cleared) DOES see the restricted records, through the same functions (the restricted client, its project, the restricted project of the visible client, and its derived money)',
  (tests.scalar('ceo', format('select (client_360(%L) -> ''projects'')::text like ''%%Quasar%%''', tests.id('c:quasar')))) || '|' ||
  (tests.scalar('ceo', format('select (client_360(%L) -> ''projects'')::text like ''%%Zeta Secret Programme%%''', tests.id('c:zeta')))) || '|' ||
  (tests.scalar('ceo', format('select (client_360(%L) -> ''finance_summary'' ->> ''outstanding'')', tests.id('c:quasar')))), 'true|true|6000.00');

-- Asking about a hidden id is indistinguishable from asking about an id that never existed ---------------------------------------------------------------
create function tests.probe(p_template text, p_hidden text) returns text language plpgsql as $$
declare u text; r text := ''; a uuid := tests.id(p_hidden); b uuid := tests.id('x:random'); s text;
begin
  foreach u in array array['tech_lead', 'web_staff', 'suspended', 'outsider'] loop
    s := tests.same_for(u, p_template, a, b);
    if s <> 'same' then r := r || u || ' ' || s || '; '; end if;
  end loop;
  return coalesce(nullif(r, ''), 'same');
end $$;
select tests.check('Client 360 of a hidden client = of a random id', tests.probe('select client_360(%L)::text', 'c:quasar'), 'same');
select tests.check('Project 360 of a hidden project (of a hidden client, and of a visible client) = of a random id', tests.probe('select project_360(%L)::text', 'p:quasar') || tests.probe('select project_360(%L)::text', 'p:zhid'), 'samesame');
select tests.check('quote, invoice, payment, ticket, asset loaders say the same for a hidden id as for a random one',
  tests.probe('select can_view_quote(%L)::text', 'q:quasar') || tests.probe('select invoice_load(%L)::text', 'inv:quasar') || tests.probe('select payment_load(%L)::text', 'pay:quasar')
  || tests.probe('select ticket_load(%L)::text', 't:quasar') || tests.probe('select asset_load(%L)::text', 'asset:quasar'), 'samesamesamesamesame');
select tests.check('opening a hidden document / reading a hidden thread says the same as for a random id',
  tests.probe('select document_open(%L)::text', 'doc:quasar') || tests.probe('select document_open(%L)::text', 'doc:zhid') || tests.probe('select communication_read(%L)::text', 'thr:quasar') || tests.probe('select communication_read(%L)::text', 'thr:zhid'), 'samesamesamesame');
select tests.check('workflow WRITES against a hidden record fail exactly as against a random id (quote line, quote transition, invoice transition, ticket assign / comment, payment allocation)',
  tests.probe(format('select quote_add_line(%%L, %L)::text', tests.id('svc:web')), 'q:quasar') || tests.probe($q$ select quote_transition(%L, 'sent')::text $q$, 'q:quasar')
  || tests.probe($q$ select invoice_transition(%L, 'void')::text $q$, 'inv:quasar') || tests.probe($q$ select ticket_comment_add(%L, 'x')::text $q$, 't:quasar')
  || tests.probe(format('select payment_allocate(%%L, %L)::text', tests.id('inv:quasar')), 'pay:quasar'), 'samesamesamesamesame');
select tests.check('linking a document / thread / asset INTO a hidden project says the same as into a random id',
  tests.probe(format('select document_link_add(%L, (select institutional_id from entity_registry where entity_id = %%L))::text', tests.id('doc:zeta')), 'p:quasar')
  || tests.probe(format('select communication_link_add(%L, (select institutional_id from entity_registry where entity_id = %%L))::text', tests.id('thr:zeta')), 'p:quasar'), 'samesame');
select tests.check('creating a quote or a ticket for a hidden client / project says the same as for a random id',
  tests.probe(format('select quote_create(%%L, %L, ''x'')::text', tests.id('div:web')), 'c:quasar') || tests.probe(format($q$ select ticket_create(p_title => 'x', p_project => %%L, p_division => %L)::text $q$, tests.id('div:web')), 'p:quasar'), 'samesame');

-- Search by name and by identity: nothing about the restricted engagement ----------------------------------------------------------------------------------
create temp table qinst as select tests.inst_of('clients', 'c:quasar') as client, tests.inst_of('projects', 'p:quasar') as project, tests.inst_of('documents', 'doc:quasar') as doc,
  tests.inst_of('communication_threads', 'thr:quasar') as thr, tests.inst_of('tickets', 't:quasar') as ticket, tests.inst_of('assets', 'asset:quasar') as asset,
  tests.inst_of('invoices', 'inv:quasar') as invoice, tests.inst_of('payments', 'pay:quasar') as payment;
create function tests.quiet(p_user text) returns text language plpgsql as $$
declare q record; r text := ''; ids text[]; i text; v text; fake text := 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ');
begin
  select * into q from qinst;
  ids := array[q.client, q.project, q.doc, q.thr, q.ticket, q.asset, q.invoice, q.payment];
  foreach i in array ids loop
    v := tests.scalar(p_user, format($q$ select (search(%L, null, 0, true) - 'query')::text $q$, i));
    if v is distinct from tests.scalar(p_user, format($q$ select (search(%L, null, 0, true) - 'query')::text $q$, fake)) then r := r || 'id:' || i || ' '; end if;
    v := tests.scalar(p_user, format($q$ select (search(%L, null, 0, true) - 'query')::text $q$, 'related:' || i));
    if v is distinct from tests.scalar(p_user, format($q$ select (search(%L, null, 0, true) - 'query')::text $q$, 'related:' || fake)) then r := r || 'rel:' || i || ' '; end if;
    v := tests.scalar(p_user, format($q$ select entity_resolve(%L)::text $q$, i));
    if v is distinct from tests.scalar(p_user, format($q$ select entity_resolve(%L)::text $q$, fake)) then r := r || 'res:' || i || ' '; end if;
  end loop;
  foreach i in array array['quasar', 'type:client quasar', 'type:project rollout', 'type:document quasar', 'quasar holdings', 'QH-9', 'type:ticket quasar', 'type:asset SN-Q1', 'EFT-Q', 'type:payment EFT-Q', 'type:invoice'] loop
    v := tests.scalar(p_user, format($q$ select (search(%L, null, 0, true) - 'query')::text $q$, i));
    if v is distinct from tests.scalar(p_user, format($q$ select (search(%L, null, 0, true) - 'query')::text $q$, 'nothingwillmatchthis')) then r := r || 'q:' || i || ' '; end if;
  end loop;
  v := tests.scalar(p_user, $q$ select search_suggest('quas')::text $q$);
  if v is distinct from tests.scalar(p_user, $q$ select search_suggest('nothingwil')::text $q$) then r := r || 'suggest '; end if;
  return coalesce(nullif(r, ''), 'quiet');
end $$;
select tests.check('B, C, suspended and an outsider get the same answer for every restricted institutional id, related: query, registry lookup, name, registration number and prefix as for an id / term that never existed',
  (select string_agg(u || '=' || tests.quiet(u), ' ' order by u) from unnest(array['tech_lead', 'web_staff', 'suspended', 'outsider']) u),
  'outsider=quiet suspended=quiet tech_lead=quiet web_staff=quiet');
select tests.check('anonymous (no login) reaches nothing: search, suggestions, both 360s and the registry all refuse or return nothing',
  tests.scalar_anon($q$ select search('zeta')::text $q$) || '|' || tests.scalar_anon($q$ select search_suggest('zet')::text $q$) || '|' || tests.scalar_anon(format('select client_360(%L)::text', tests.id('c:zeta'))) || '|' ||
  tests.scalar_anon(format('select project_360(%L)::text', tests.id('p:zeta'))), 'ERR:42501|ERR:42501|ERR:42501|ERR:42501');
select tests.check('the cleared people DO find the restricted engagement (positive control): management by name, id and related:',
  tests.scalar('ceo', $q$ select (search('type:client quasar') ->> 'total') $q$) || '|' || tests.scalar('ceo', format($q$ select (search(%L) -> 'results' -> 0 ->> 'entity_type') $q$, (select client from qinst))) || '|' ||
  tests.scalar('ceo', format($q$ select (search(%L) ->> 'total')::int > 3 $q$, 'related:' || (select client from qinst))), '1|client|true');

-- Message bodies and document content never travel with the 360 views --------------------------------------------------------------------------------------
select tests.check('Project 360 / Client 360 show communication METADATA only: no message body, for A or for management',
  (tests.scalar('web_lead', format('select project_360(%L)::text like ''%%visible body%%''', tests.id('p:zeta')))) || '|' || (tests.scalar('ceo', format('select project_360(%L)::text like ''%%HIDDEN-BODY-QUASAR%%''', tests.id('p:quasar')))), 'false|false');
select tests.check('a person without communications.read (finance) cannot read the body even of a thread about a client they bill; the permission, not client visibility, decides',
  (coalesce(tests.scalar('fin', format('select communication_read(%L)::text', tests.id('thr:zeta'))), '') not like '%visible body%')::text, 'true');

-- Unauthorised WORKFLOW ACTIONS on the VISIBLE engagement ----------------------------------------------------------------------------------------------------
select tests.check('B (another division) cannot quote, bill, take payment, raise a ticket on or attach to the Zeta engagement',
  (select string_agg(r::text, ',' order by r) from (values
     (tests.scalar('tech_lead', format('select quote_create(%L, %L, ''x'')::text', tests.id('c:zeta'), tests.id('div:web'))) like 'ERR:%'),
     (tests.scalar('tech_lead', format($q$ select invoice_transition(%L, 'void')::text $q$, tests.id('inv:zeta'))) like 'ERR:%'),
     (tests.scalar('tech_lead', format('select payment_record(%L, %L, 10, ''cash'')::text', tests.id('c:zeta'), tests.id('acct:nad'))) like 'ERR:%'),
     (tests.scalar('tech_lead', format($q$ select ticket_create(p_title => 'x', p_project => %L, p_division => %L)::text $q$, tests.id('p:zeta'), tests.id('div:tech'))) like 'ERR:%'),
     (tests.scalar('tech_lead', format('select document_link_add(%L, %L)::text', tests.id('doc:zeta'), (select client from zinst))) like 'ERR:%')) v(r)), 'true,true,true,true,true');
select tests.check('C (same division, insufficient permissions) cannot approve a quote, issue an invoice, record a payment or convert/accept anything',
  (tests.scalar('web_staff', format($q$ select quote_transition(%L, 'approved')::text $q$, tests.id('q:zeta'))) like 'ERR:%')::text ||
  (tests.scalar('web_staff', format($q$ select invoice_transition(%L, 'pending_approval')::text $q$, tests.id('inv:zeta'))) like 'ERR:%')::text ||
  (tests.scalar('web_staff', format('select payment_record(%L, %L, 10, ''cash'')::text', tests.id('c:zeta'), tests.id('acct:nad'))) like 'ERR:%')::text ||
  (tests.scalar('web_staff', format('select quote_convert_to_project(%L)::text', tests.id('q:zeta'))) like 'ERR:%')::text, 'truetruetruetrue');
select tests.check('suspended staff and an outsider cannot create a client, quote, ticket, document or thread, or start a search that returns anything',
  (select string_agg((tests.mkclient(u, 'Nope Ltd', 'web') like 'ERR:%')::text || (tests.scalar(u, format('select quote_create(%L, %L, ''x'')::text', tests.id('c:zeta'), tests.id('div:web'))) like 'ERR:%')::text
     || (tests.scalar(u, format($q$ select ticket_create(p_title => 'x', p_division => %L)::text $q$, tests.id('div:web'))) like 'ERR:%')::text
     || (tests.mk_doc(u, 'nope_' || u, 'x', 'report', 'web') like 'ERR:%')::text || (tests.mk_thread(u, 'nope_' || u, 'x') like 'ERR:%')::text
     || (coalesce(tests.scalar(u, $q$ select (search('zeta') ->> 'total') $q$), '0') in ('0') or tests.scalar(u, $q$ select (search('zeta') ->> 'total') $q$) like 'ERR:%')::text, ',' order by u) from unnest(array['suspended', 'outsider']) u),
  'truetruetruetruetruetrue,truetruetruetruetruetrue');
select tests.check('no one but a cleared person created a client "Nope Ltd"', (select count(*)::text from clients where name = 'Nope Ltd'), '0');

-- A restricted organization is not duplicated by an uncleared user (existence is not revealed either way) ----------------------------------------------------
select tests.check('B asks for the restricted company by name: no match, no hint (identical to asking for a company that does not exist)',
  (tests.scalar('tech_lead', $q$ select client_lookup('Quasar Holdings Ltd')::text $q$) = tests.scalar('tech_lead', $q$ select client_lookup('Nothing Of The Sort Ltd')::text $q$))::text, 'true');
select tests.check('B creates the company the restricted one is named like: it succeeds exactly as for any fresh name (no refusal, no hint), a SEPARATE organization is made and only a cleared reviewer sees the resulting duplicate review',
  (tests.mkclient('tech_lead', 'Quasar Holdings Ltd', 'tech') ~ '"status": "created"')::text || '|' || (tests.mkclient('tech_lead', 'Fresh Unrelated Ltd', 'tech') ~ '"status": "created"')::text || '|' ||
  tests.scalar('tech_lead', 'select count(*)::text from organization_reviews') || '|' || (tests.scalar('ceo', 'select count(*)::text from organization_reviews') >= '1')::text, 'true|true|0|true');

-- Audit stays intact and out of reach ------------------------------------------------------------------------------------------------------------------------
select tests.check('audit rows about the restricted engagement are invisible to B, C, suspended and an outsider (zero rows, not an error)',
  (select string_agg(tests.scalar(u, $q$ select count(*)::text from audit_log where new_data::text like '%Quasar%' $q$), ',' order by u) from unnest(array['tech_lead', 'web_staff', 'suspended', 'outsider']) u), '0,0,0,0');
select tests.check('nobody can edit or delete history: audit rows, issued invoices, allocated payments',
  tests.try('ceo', $q$ delete from audit_log $q$) || tests.try('ceo', $q$ update audit_log set action = 'x' $q$) || tests.try('fin', format($q$ delete from invoices where id = %L $q$, tests.id('inv:zeta'))) || tests.try('fin', format($q$ update payments set amount = 1 where id = %L $q$, tests.id('pay:zeta'))),
  'ERR:42501ERR:42501ERR:42501ERR:42501');

select tests.finish();
rollback;
