-- PERMANENT: the operational dashboard (dashboard_summary): every figure is derived from the authoritative records and equals what the caller's own
-- row-level security lets them count; restricted records contribute nothing to anyone else's numbers; money is never added across currencies; the function
-- writes and stores nothing.
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
select tests.bank_account('usd', 'USD');
select tests.finance_world();
insert into tests.ids values ('x:none', gen_random_uuid());
select tests.try('fin', $q$ insert into suppliers (name) values ('NamReg Registrar') $q$);
insert into tests.ids select 'sup:namreg', id from suppliers where name = 'NamReg Registrar';

-- A working week of data -----------------------------------------------------------------------------------------------------------------------------
select tests.remember('q:open', tests.scalar('web_lead', format('select quote_create(%L, %L, ''Open quote'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
select tests.scalar('web_lead', format('select quote_add_line(%L, %L)::text', tests.id('q:open'), tests.id('svc:web')));
select tests.scalar('web_lead', format($q$ select quote_transition(%L, 'pending_approval')::text $q$, tests.id('q:open')));      -- an approval waiting for management
select tests.issued_invoice('d1', 'client:abc', 1000);
select tests.issued_invoice('d2', 'client:abc', 2500);
select tests.remember('pay:d1', tests.scalar('fin', format('select payment_record(%L, %L, 400, ''bank_transfer'', current_date, ''EFT-D1'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:d1'))));
select tests.scalar('fin', format('select payment_record(%L, %L, 50, ''cash'', current_date, ''USD-1'')::text', tests.id('client:abc'), tests.id('acct:usd')));   -- a second currency, unallocated
set local session_replication_role = replica;
update invoices set issue_date = current_date - 40, due_date = current_date - 10 where id = tests.id('inv:d1');                                                                      -- one invoice is overdue
update projects set due_date = current_date - 3 where id = tests.id('project:abc');                                                                   -- one project is overdue
reset session_replication_role;
select tests.remember('t:d1', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'Dash ticket', p_client => %L, p_project => %L, p_division => %L, p_priority => 'high')::text $q$, tests.id('client:abc'), tests.id('project:abc'), tests.id('div:web'))));
select tests.mk_asset('web_lead', 'd1', 'Dash laptop', 'web', 'Dell', 'SN-D1', null, 'in_stock', 'client:abc', 'project:abc');
select tests.live_domain('web_lead', 'dd', 'dash-due.example', 10);

-- 1. hand-computed figures for management -------------------------------------------------------------------------------------------------------------
create temp table dash_ceo as select tests.scalar('ceo', 'select dashboard_summary()::text')::jsonb as j;
select tests.check('1. receivables are derived: outstanding 1,000 - 400 + 2,500 = 3,100 over two invoices; overdue 600 over one; received 400 NAD and 50 USD, never summed together',
  (select (j #>> '{receivables,outstanding,0,value}') || '/' || (j #>> '{receivables,outstanding,0,count}') || '/' || (j #>> '{receivables,overdue,0,value}') || '/' || (j #>> '{receivables,overdue,0,count}') || '/'
          || (select string_agg((e ->> 'currency') || ':' || (e ->> 'value'), ',' order by e ->> 'currency') from jsonb_array_elements(j #> '{receivables,received_30d}') e) from dash_ceo),
  '3100.00/2/600.00/1/NAD:400.00,USD:50.00');
select tests.check('2. unallocated credit is the money received but not yet allocated: 400 NAD allocated to invoice 1 only through payment_record (so 0 NAD), 50 USD unallocated',
  (select string_agg((e ->> 'currency') || ':' || (e ->> 'value'), ',' order by e ->> 'currency') from dash_ceo, jsonb_array_elements(j #> '{receivables,unallocated_credit}') e), 'USD:50.00');
select tests.check('3. pipeline: the open quote waits for approval; the accepted quote of the finance fixture is counted once in the last 30 days',
  (select (j #>> '{pipeline,open_quotes,0,status}') || ':' || (j #>> '{pipeline,open_quotes,0,count}') || '|' || (j #>> '{pipeline,accepted_30d,0,count}') || ':' || (j #>> '{pipeline,accepted_30d,0,value}') from dash_ceo), 'pending_approval:1|1:9300.00');
select tests.check('4. approvals: one request awaits management; the requester sees it as theirs, not as waiting for them',
  (select (j #>> '{approvals,awaiting_decision}') from dash_ceo) || '|' ||
  tests.scalar('web_lead', $q$ select (dashboard_summary() #>> '{approvals,awaiting_decision}') || ':' || (dashboard_summary() #>> '{approvals,my_requests_pending}') $q$), '1|0:1');
select tests.check('5. projects, tickets, assets, contracts, domains show what exists today',
  (select (j #>> '{projects,overdue}') || '|' || (j #>> '{tickets,open_by_priority,high}') || '|' || (j #>> '{watch,assets_by_status,in_stock}') || '|' || (j #>> '{contracts,active}') || '|' || (j #>> '{watch,domains_due,due_soon}') from dash_ceo), '1|1|1|1|1');

-- 2. the figures equal what the caller can count for themselves ---------------------------------------------------------------------------------------
create function tests.parity(p_user text) returns text language plpgsql as $$
declare d jsonb := tests.scalar(p_user, 'select dashboard_summary()::text')::jsonb; v text;
begin
  v := tests.scalar(p_user, $q$ select
      (select count(*) from quotes where status in ('draft', 'pending_approval', 'approved', 'sent'))::text || '/' ||
      (select count(*) from projects where deleted_at is null and status in ('proposed', 'approved', 'active', 'on_hold'))::text || '/' ||
      (select count(*) from invoices where status in ('issued', 'partially_paid'))::text || '/' ||
      (select count(*) from tickets where status in ('open', 'in_progress', 'waiting'))::text || '/' ||
      (select count(*) from assets where status in ('acquired', 'in_stock', 'assigned', 'in_maintenance'))::text || '/' ||
      (select count(*) from contracts where status = 'active')::text $q$);
  return case when v = coalesce((select sum((e ->> 'count')::int) from jsonb_array_elements(d #> '{pipeline,open_quotes}') e), 0)::text || '/' ||
                      coalesce((select sum(value::int) from jsonb_each_text(d #> '{projects,by_status}')), 0)::text || '/' ||
                      coalesce((select sum((e ->> 'count')::int) from jsonb_array_elements(d #> '{receivables,outstanding}') e), 0)::text || '/' ||
                      coalesce((select sum(value::int) from jsonb_each_text(d #> '{tickets,open_by_priority}')), 0)::text || '/' ||
                      coalesce((select sum(value::int) from jsonb_each_text(d #> '{watch,assets_by_status}')), 0)::text || '/' ||
                      (d #>> '{contracts,active}') then 'same' else 'DIFFERENT: dashboard vs own counts ' || v end;
end $$;
select tests.check('6. for every kind of user the dashboard totals equal that user''s own counts of quotes, projects, invoices, tickets, assets and contracts',
  (select string_agg(u || '=' || tests.parity(u), ' ' order by u) from unnest(array['ceo', 'admin', 'fin', 'audit', 'web_lead', 'web_staff', 'tech_lead', 'tech_staff']) u),
  'admin=same audit=same ceo=same fin=same tech_lead=same tech_staff=same web_lead=same web_staff=same');
select tests.check('7. a division lead has no payments in their numbers (finance is organization-wide) and a person with no finance rights sees empty receivables',
  tests.scalar('web_lead', $q$ select (dashboard_summary() #>> '{receivables,received_30d}') $q$) || '|' || tests.scalar('tech_staff', $q$ select (dashboard_summary() #>> '{receivables,outstanding}') $q$), '[]|[]');

-- 3. restricted records change nobody else's numbers -----------------------------------------------------------------------------------------------------
create temp table dash_before (u text primary key, j text);
insert into dash_before select u, tests.scalar(u, 'select dashboard_summary()::text') from unnest(array['web_lead', 'web_staff', 'tech_lead', 'tech_staff', 'fin', 'audit', 'admin', 'suspended', 'outsider']) u;
select tests.remember('c:hid', tests.mkclient_id('ceo', 'Hidden Dash Ltd', 'web'));
select tests.remember('p:hid', tests.scalar('ceo', format($q$ insert into projects (client_id, lead_division_id, name, due_date) values (%L, %L, 'Hidden Dash Project', current_date - 9) returning id::text $q$, tests.id('c:hid'), tests.id('div:web'))));
select tests.remember('q:hid', tests.scalar('ceo', format('select quote_create(%L, %L, ''Hidden quote'', null, %L)::text', tests.id('c:hid'), tests.id('div:web'), tests.id('p:hid'))));
select tests.scalar('ceo', format('select quote_add_line(%L, %L)::text', tests.id('q:hid'), tests.id('svc:web')));
select tests.issued_invoice('hid', 'c:hid', 7777);
select tests.remember('t:hid', tests.scalar('ceo', format($q$ select ticket_create(p_title => 'Hidden dash ticket', p_client => %L, p_project => %L, p_division => %L, p_priority => 'urgent')::text $q$, tests.id('c:hid'), tests.id('p:hid'), tests.id('div:web'))));
select tests.mk_asset('ceo', 'hid', 'Hidden dash server', 'web', 'Dell', 'SN-HD1', null, 'in_stock', 'c:hid', 'p:hid');
update clients set classification = 'restricted' where id = tests.id('c:hid');
select tests.check('8. the restricted engagement exists (a project, a quote, an invoice of 7,777, an urgent ticket, an asset)',
  (select count(*)::text from projects where id = tests.id('p:hid')) || (select count(*)::text from invoices where id = tests.id('inv:hid')) || (select count(*)::text from tickets where id = tests.id('t:hid')) || (select count(*)::text from assets where id = tests.id('asset:hid')), '1111');
select tests.check('9. the dashboards of everyone who cannot see it are byte-for-byte unchanged (division staff, another division, finance, and suspended staff and an outsider, whose answer is null); the organization-wide auditor and administration officer are cleared to see restricted records and are not part of this comparison',
  (select coalesce(string_agg(b.u, ','), 'none') from dash_before b where b.u not in ('audit', 'admin') and b.j is distinct from tests.scalar(b.u, 'select dashboard_summary()::text')), 'none');
select tests.check('10. management, who can see it, now counts it (positive control: the comparison is not vacuous)',
  (select (tests.scalar('ceo', $q$ select (dashboard_summary() #>> '{tickets,open_by_priority,urgent}') $q$) = '1' and
           (tests.scalar('ceo', $q$ select (dashboard_summary() #>> '{projects,by_status,proposed}') $q$)::int = (select (j #>> '{projects,by_status,proposed}')::int + 1 from dash_ceo)) and
           tests.scalar('ceo', $q$ select (dashboard_summary() #>> '{receivables,outstanding,0,value}') $q$) = '10877.00')::text), 'true');

-- 4. nothing is stored, nothing is granted --------------------------------------------------------------------------------------------------------------
select tests.check('11. only active staff get numbers: suspended staff and an outsider get null, anonymous is refused',
  coalesce(tests.scalar('suspended', 'select dashboard_summary()::text'), 'null') || '|' || coalesce(tests.scalar('outsider', 'select dashboard_summary()::text'), 'null') || '|' || tests.scalar_anon('select dashboard_summary()::text'), 'null|null|ERR:42501');
select tests.check('12. it is a read-only SECURITY INVOKER function, not executable by anon; the migration added no table',
  (select (not p.prosecdef and p.provolatile = 's' and not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p where p.proname = 'dashboard_summary' and p.pronamespace = 'public'::regnamespace)
  || (select count(*)::text from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname ~* 'dashboard'), 'true0');

select tests.finish();
rollback;
