-- PERMANENT: Expenses - identity, the controlled lifecycle (draft -> pending_approval -> approved -> paid, rejected, cancelled), approval and separation of duties,
-- references instead of copies, immutability after submission and payment, derived (never stored) project cost and payables, classification inherited from the
-- project / client, non-disclosure, history, search and document links.
-- (Every command runs in its own statement, and the checks read the state afterwards: a query cannot see rows changed by a function called in the same query.)
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
select tests.bank_account('usd', 'USD');
select tests.finance_world();
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.try('fin', $q$ insert into suppliers (name) values ('Hostco Namibia') $q$);
insert into tests.ids select 'sup:host', id from suppliers where name = 'Hostco Namibia';
create table tests.outs (k text primary key, v text);
create function tests.o(p_key text, p_val text) returns void language sql as $$ insert into tests.outs values (p_key, p_val) on conflict (k) do update set v = excluded.v $$;
create function tests.g(p_key text) returns text language sql stable as $$ select v from tests.outs where k = p_key $$;
create function tests.ex(p_user text, p_key text, p_desc text, p_net numeric, p_ref text default null, p_project text default 'project:abc', p_cat text default 'hosting', p_tax numeric default 0, p_div text default 'web') returns text language plpgsql as $$
declare v text;
begin
  v := tests.scalar(p_user, format($q$ select expense_create(%L, %L, %L, %s, null, %s, null, %L, %L, %L)::text $q$, tests.id('div:' || p_div), p_cat, p_desc, p_net, p_tax, tests.id('sup:host'), p_ref, tests.id(p_project)));
  if v is null or v like 'ERR:%' then return coalesce(v, 'NULL'); end if;
  insert into tests.ids values ('ex:' || p_key, v::uuid) on conflict (key) do update set id = excluded.id;
  return v;
end $$;
create function tests.exs(p_user text, p_key text, p_to text, p_note text default null) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select expense_transition(%L, %L, %L)::text $q$, tests.id('ex:' || p_key), p_to, p_note))
$$;
create function tests.expay(p_user text, p_key text, p_acct text default 'acct:nad', p_ref text default null) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select expense_pay(%L, %L, null, %L)::text $q$, tests.id('ex:' || p_key), tests.id(p_acct), p_ref))
$$;
create function tests.exv(p_user text, p_key text, p_reason text) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select expense_void(%L, %L)::text $q$, tests.id('ex:' || p_key), p_reason))
$$;

-- 1. Identity, references, derived fields ---------------------------------------------------------------------------------------------------------------
select tests.ex('web_lead', 'a', 'Hosting for the ABC site', 1500, 'HC-1001', 'project:abc', 'hosting', 225);
select tests.check('1. an expense is created as a draft: ADA-EXP id, total derived (net + tax), client derived from the project, registered with an institutional id',
  (select (ada_id ~ '^ADA-EXP-2026-' and status = 'draft' and total = 1725.00 and client_id = tests.id('client:abc') and currency = 'NAD' and created_by = tests.id('staff:web_lead')
           and exists (select 1 from entity_registry r where r.table_name = 'expenses' and r.entity_id = e.id))::text from expenses e where e.id = tests.id('ex:a')), 'true');
select tests.check('2. creating is refused without expenses.create in that division (another division, no permission, suspended, outsider), and for an unknown category',
  tests.ex('tech_lead', 'z1', 'x', 10) || tests.ex('web_staff', 'z2', 'x', 10) || tests.ex('suspended', 'z3', 'x', 10) || tests.ex('outsider', 'z4', 'x', 10) || tests.ex('web_lead', 'z5', 'x', 10, null, 'project:abc', 'nonsense'),
  'ERR:42501ERR:42501ERR:42501ERR:42501ERR:22023');
select tests.o('dup', tests.ex('web_lead', 'dup', 'again', 100, 'hc-1001'));
select tests.o('b', tests.ex('web_lead', 'b', 'Domain renewal', 300, 'HC-1002', 'project:abc', 'hosting'));
select tests.check('3. the same supplier bill cannot be recorded twice (case-insensitive), a different bill can', tests.g('dup') || '|' || (tests.g('b') ~ '^[0-9a-f-]{36}$')::text, 'ERR:23505|true');
select tests.check('4. amounts must be positive and tax cannot be negative',
  tests.ex('web_lead', 'n0', 'x', 0) || tests.ex('web_lead', 'n1', 'x', -5) || tests.ex('web_lead', 'n2', 'x', 10, null, 'project:abc', 'hosting', -1), 'ERR:23514ERR:23514ERR:23514');
select tests.o('oh', tests.ex('web_lead', 'oh', 'Office broadband', 800, null, null, 'office'));
select tests.check('5. an expense needs no project (overheads), and then has no client',
  (tests.g('oh') ~ '^[0-9a-f-]{36}$')::text || (select (client_id is null and project_id is null)::text from expenses where id = tests.id('ex:oh')), 'truetrue');

-- 2. Editing a draft ------------------------------------------------------------------------------------------------------------------------------------
select tests.o('upd', tests.try('web_lead', format($q$ select expense_update(%L, '{"amount_net": 1600, "description": "Hosting (annual)"}'::jsonb) $q$, tests.id('ex:a'))));
select tests.check('6. a draft can be edited (the total follows); unknown fields, a non-viewer and a stranger are refused',
  tests.g('upd') || (select total::text from expenses where id = tests.id('ex:a'))
  || tests.try('web_lead', format($q$ select expense_update(%L, '{"status": "paid"}'::jsonb) $q$, tests.id('ex:a')))
  || tests.try('web_staff', format($q$ select expense_update(%L, '{"description": "x"}'::jsonb) $q$, tests.id('ex:a'))), 'ok1825.00ERR:22023ERR:P0002');
select tests.check('7. direct writes are impossible for every caller: no insert / update privilege for API users, and nobody (the owner included) can delete',
  tests.try('ceo', format($q$ update expenses set amount_net = 1 where id = %L $q$, tests.id('ex:a'))) || tests.try('ceo', format($q$ delete from expenses where id = %L $q$, tests.id('ex:a')))
  || tests.try('ceo', $q$ insert into expenses (division_id, category_id, description, currency, amount_net) select id, (select id from expense_categories limit 1), 'x', 'NAD', 1 from divisions limit 1 $q$)
  || tests.try_owner(format($q$ delete from expenses where id = %L $q$, tests.id('ex:a'))), 'ERR:42501ERR:42501ERR:42501ERR:42501');

-- 3. Submit, approve, separation of duties -----------------------------------------------------------------------------------------------------------------
select tests.o('a_sub', tests.exs('web_lead', 'a', 'pending_approval'));
select tests.check('8. submitting records the requester and opens ONE pending approval request (kind expense)',
  tests.g('a_sub') || '|' || (select (status = 'pending_approval' and requested_by = tests.id('staff:web_lead'))::text from expenses where id = tests.id('ex:a')) || '|' ||
  (select count(*)::text || (min(kind)) || (min(status::text)) from approval_requests where entity_table = 'expenses' and entity_id = tests.id('ex:a')), 'pending_approval|true|1expensepending');
select tests.o('a_lock', tests.try('web_lead', format($q$ select expense_update(%L, '{"description": "sneaky"}'::jsonb) $q$, tests.id('ex:a'))) || tests.exs('web_lead', 'a', 'approved'));
select tests.check('9. once submitted the content is locked (even through the update command), and the requester cannot approve their own', tests.g('a_lock'), 'ERR:42501ERR:42501');
select tests.o('a_app', tests.exs('fin', 'a', 'approved', 'ok'));
select tests.check('10. an approver with the permission approves it; the request records the decision',
  tests.g('a_app') || '|' || (select (status = 'approved' and approved_by = tests.id('staff:fin') and approved_at is not null)::text from expenses where id = tests.id('ex:a')) || '|' ||
  (select status::text || (decided_by = tests.id('staff:fin'))::text from approval_requests where entity_table = 'expenses' and entity_id = tests.id('ex:a')), 'approved|true|approvedtrue');
select tests.ex('fin', 'self', 'Own purchase', 500, 'HC-2001');
select tests.exs('fin', 'self', 'pending_approval');
select tests.o('self1', tests.exs('fin', 'self', 'approved'));
select tests.o('self2', tests.exs('ceo', 'self', 'approved'));
select tests.check('11. nobody approves their own expense while another qualified approver exists (separation of duties); someone else can', tests.g('self1') || '|' || tests.g('self2'), 'ERR:42501|approved');
select tests.ex('web_lead', 'rej', 'Dubious item', 90, 'HC-3001');
select tests.exs('web_lead', 'rej', 'pending_approval');
select tests.o('rej1', tests.exs('fin', 'rej', 'rejected'));
select tests.o('rej2', tests.exs('fin', 'rej', 'rejected', 'not ours'));
select tests.o('rej3', tests.exs('web_lead', 'rej', 'draft'));
select tests.check('12. rejecting needs a note, is final (it cannot be reopened) and is recorded on the approval request',
  tests.g('rej1') || '|' || tests.g('rej2') || '|' || tests.g('rej3') || '|' || (select status::text from expenses where id = tests.id('ex:rej')) || '|' ||
  (select status::text from approval_requests where entity_table = 'expenses' and entity_id = tests.id('ex:rej') order by requested_at desc limit 1), 'ERR:23514|rejected|ERR:23514|rejected|rejected');
select tests.ex('web_lead', 'back', 'Needs detail', 120, 'HC-4001');
select tests.exs('web_lead', 'back', 'pending_approval');
select tests.o('bk1', tests.exs('fin', 'back', 'draft'));
select tests.o('bk2', tests.exs('fin', 'back', 'draft', 'add the invoice number'));
select tests.o('bk3', tests.exs('web_lead', 'back', 'pending_approval'));
select tests.o('bk4', tests.exs('web_lead', 'back', 'draft', 'wrong project'));
select tests.check('13. an approver sends it back with a note (needed); the requester may withdraw their own submission',
  tests.g('bk1') || '|' || tests.g('bk2') || '|' || tests.g('bk3') || '|' || tests.g('bk4'), 'ERR:23514|draft|pending_approval|draft');
select tests.o('cn1', tests.exs('web_lead', 'back', 'cancelled'));
select tests.o('cn2', tests.exs('web_lead', 'back', 'cancelled', 'duplicate of another bill'));
select tests.o('cn3', tests.ex('web_lead', 'back2', 'Re-entered', 120, 'HC-4001'));
select tests.check('14. a cancelled draft needs a reason and frees its supplier bill number', tests.g('cn1') || '|' || tests.g('cn2') || '|' || (tests.g('cn3') ~ '^[0-9a-f-]{36}$')::text, 'ERR:23514|cancelled|true');

-- 4. Payment ------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('15. only a holder of expenses.pay pays, from an account in the same currency, not in the future',
  tests.expay('web_lead', 'a') || '|' || tests.expay('fin', 'a', 'acct:usd') || '|' ||
  tests.scalar('fin', format($q$ select expense_pay(%L, %L, current_date + 3)::text $q$, tests.id('ex:a'), tests.id('acct:nad'))), 'ERR:42501|ERR:23514|ERR:23514');
select tests.o('pay1', tests.try('fin', format($q$ select expense_pay(%L, %L, current_date, 'EFT-HC1') $q$, tests.id('ex:a'), tests.id('acct:nad'))));
select tests.check('16. a paid expense records date, account and reference, and is final (no transition, no cancel, no second payment)',
  tests.g('pay1') || '|' || (select (status = 'paid' and paid_on = current_date and paid_from_account_id = tests.id('acct:nad') and payment_reference = 'EFT-HC1')::text from expenses where id = tests.id('ex:a')) || '|' ||
  tests.exs('ceo', 'a', 'cancelled', 'x') || '|' || tests.exv('ceo', 'a', 'x') || '|' || tests.expay('fin', 'a'), 'ok|true|ERR:23514|ERR:23514|ERR:23514');
select tests.o('v1', tests.exv('fin', 'self', 'x'));
select tests.o('v2', tests.exv('ceo', 'self', ''));
select tests.o('v3', tests.exv('ceo', 'self', 'bought twice'));
select tests.check('17. an approved unpaid expense can be cancelled only with expenses.void and a reason',
  tests.g('v1') || '|' || tests.g('v2') || '|' || tests.g('v3') || '|' || (select status::text from expenses where id = tests.id('ex:self')), 'ERR:42501|ERR:23514||cancelled');

-- 5. Derived, never stored --------------------------------------------------------------------------------------------------------------------------
select tests.ex('web_lead', 'c', 'Subcontractor design', 4000, 'SC-1', 'project:abc', 'subcontractors');
select tests.exs('web_lead', 'c', 'pending_approval');
select tests.exs('ceo', 'c', 'approved');
select tests.ex('web_lead', 'd', 'Pending licence', 250, 'SW-9', 'project:abc', 'software');
select tests.exs('web_lead', 'd', 'pending_approval');
select tests.check('18. project cost is derived: paid 1,825 + approved 4,000 = cost 5,825; 250 awaits approval; the cancelled and rejected ones are not in it',
  tests.scalar('ceo', format($q$ select paid::text || '/' || approved_unpaid::text || '/' || awaiting_approval::text || '/' || cost::text from project_costs where project_id = %L and currency = 'NAD' $q$, tests.id('project:abc'))), '1825.00/4000.00/250.00/5825.00');
select tests.check('19. payables are derived: 4,000 approved and unpaid to the supplier', tests.scalar('ceo', format($q$ select owed::text || '/' || bills::text from expense_payables where supplier_id = %L and currency = 'NAD' $q$, tests.id('sup:host'))), '4000.00/1');
select tests.check('20. nothing derived is stored on the expense (no balance, owed or cost columns) and the interim planning field is untouched',
  (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name ~ '(balance|owed|cost|payable|outstanding)')
  || '|' || (select (count(*) = 2)::text from information_schema.columns where table_schema = 'public' and table_name = 'project_financials' and column_name in ('cost_to_date', 'budget')), 'none|true');

-- 6. Who sees what; the history -------------------------------------------------------------------------------------------------------------------------
select tests.check('21. visibility follows expenses.view in the division: management, finance, the division lead and the auditor see all of them; division staff, another division, suspended staff and an outsider none',
  (select string_agg(u || '=' || (tests.scalar(u, 'select count(*)::text from expenses') = (select count(*)::text from expenses))::text, ' ' order by u) from unnest(array['ceo', 'fin', 'web_lead', 'audit']) u) || ' ' ||
  (select string_agg(u || '=' || tests.scalar(u, 'select count(*)::text from expenses'), ' ' order by u) from unnest(array['web_staff', 'tech_lead', 'suspended', 'outsider']) u),
  'audit=true ceo=true fin=true web_lead=true outsider=0 suspended=0 tech_lead=0 web_staff=0');
select tests.check('22. the history is complete and append-only: created, edited, submitted, approved, paid are all on record and nobody can alter it',
  (select string_agg(kind, ',' order by id) from expense_events where expense_id = tests.id('ex:a')) || '|' ||
  tests.try('ceo', $q$ update expense_events set note = 'x' $q$) || tests.try_owner($q$ delete from expense_events $q$), 'created,updated,submitted,approved,paid|ERR:42501ERR:42501');

-- 7. Restricted records ----------------------------------------------------------------------------------------------------------------------------
insert into projects (client_id, lead_division_id, name) values (tests.id('client:C_conf'), tests.id('div:web'), 'Confidential build');
insert into tests.ids select 'project:conf', id from projects where name = 'Confidential build';
select tests.ex('ceo', 'conf', 'Confidential subcontractor', 9999, 'CF-1', 'project:conf', 'subcontractors');
create temp table ex_before as select tests.scalar('web_lead', 'select count(*)::text from expenses') as wl, tests.scalar('web_lead', $q$ select search('type:expense')->>'total' $q$) as ws,
  tests.scalar('web_lead', 'select (select count(*) from project_costs)::text || (select count(*) from expense_payables)') as wv;
select tests.ex('ceo', 'conf2', 'Another confidential cost', 1, 'CF-2', 'project:conf', 'other');
select tests.check('23. an expense of a confidential client''s project inherits the classification and is invisible to those without clearance: the same count, search total and derived views as before it existed',
  (select (effective_classification = 'confidential')::text from expenses where id = tests.id('ex:conf')) || '|' ||
  (tests.scalar('web_lead', 'select count(*)::text from expenses') = (select wl from ex_before))::text || '|' || (tests.scalar('web_lead', $q$ select search('type:expense')->>'total' $q$) = (select ws from ex_before))::text || '|' ||
  (tests.scalar('web_lead', 'select (select count(*) from project_costs)::text || (select count(*) from expense_payables)') = (select wv from ex_before))::text, 'true|true|true|true');
select tests.check('24. asking about it (submit, pay) is indistinguishable from asking about an id that never existed, for every uncleared caller',
  (select string_agg(tests.same_for(u, $q$ select expense_transition(%L, 'pending_approval')::text $q$, tests.id('ex:conf'), tests.id('x:random')) || tests.same_for(u, format($q$ select expense_pay(%%L, %L)::text $q$, tests.id('acct:nad')), tests.id('ex:conf'), tests.id('x:random')), ',' order by u)
     from unnest(array['web_lead', 'web_staff', 'tech_lead', 'suspended', 'outsider']) u), 'samesame,samesame,samesame,samesame,samesame');
select tests.check('25. creating an expense on a project the caller cannot see answers as for an unknown project',
  (select string_agg(tests.same_for(u, format($q$ select expense_create(%L, 'hosting', 'x', 10, null, 0, null, null, null, %%L)::text $q$, tests.id('div:web')), tests.id('project:conf'), tests.id('x:random')), ',' order by u) from unnest(array['web_lead', 'tech_lead', 'suspended']) u), 'same,same,same');
select tests.check('26. management (cleared) sees it, through the same functions (positive control)', tests.scalar('ceo', format($q$ select (select count(*) from expenses where id = %L)::text $q$, tests.id('ex:conf'))), '1');
-- restricting / un-restricting a client re-derives its expenses and the history of their approvals
select tests.ex('web_lead', 'pw', 'Web-client cost', 700, 'WC-1', 'project:P_web', 'hosting');
select tests.exs('web_lead', 'pw', 'pending_approval');
update clients set classification = 'restricted' where id = tests.id('client:C_web');
select tests.check('27. restricting the client hides its expenses from the division lead at once, and the approval request follows',
  tests.scalar('web_lead', format($q$ select count(*)::text from expenses where id = %L $q$, tests.id('ex:pw'))) || '|' || (select classification::text from approval_requests where entity_table = 'expenses' and entity_id = tests.id('ex:pw')) || '|' ||
  tests.scalar('web_lead', format($q$ select count(*)::text from approval_requests where entity_id = %L $q$, tests.id('ex:pw'))), '0|restricted|0');
update clients set classification = 'internal' where id = tests.id('client:C_web');
select tests.check('28. ...and un-restricting restores both', tests.scalar('web_lead', format($q$ select count(*)::text from expenses where id = %L $q$, tests.id('ex:pw'))) || '|' || (select classification::text from approval_requests where entity_table = 'expenses' and entity_id = tests.id('ex:pw')), '1|internal');

-- 8. Search, documents, relationships --------------------------------------------------------------------------------------------------------------------
select tests.check('29. expenses are searchable by type, by the supplier''s bill number and by ADA number; the result is metadata only',
  tests.scalar('ceo', format($q$ select (search('HC-1001')->'results'->0->>'entity_type') || '|' || (search(%L)->'results'->0->>'entity_type') $q$, (select ada_id from expenses where id = tests.id('ex:a')))) || '|' ||
  (tests.scalar('ceo', $q$ select search('type:expense')->>'total' $q$) = (select count(*)::text from expenses))::text, 'expense|expense|true');
select tests.check('30. the search index holds no amount or description of an expense', (select count(*)::text from search_index i where i.entity_type = 'expense' and (i.terms ~* '1825|1,825|hosting|subcontractor' or i.label ~* '1825|hosting')), '0');
select tests.check('31. `related:<project>` returns its expenses to those who may see them, and none to those who may not',
  tests.scalar('ceo', format($q$ select (select count(*) from jsonb_array_elements(search(%L)->'results') x where x->>'entity_type' = 'expense')::text $q$, 'related:' || tests.inst_of('projects', 'project:abc'))) || '|' ||
  tests.scalar('web_staff', format($q$ select (select count(*) from jsonb_array_elements(search(%L)->'results') x where x->>'entity_type' = 'expense')::text $q$, 'related:' || tests.inst_of('projects', 'project:abc'))),
  (select count(*)::text from expenses where project_id = tests.id('project:abc') and status <> 'cancelled' or project_id = tests.id('project:abc') and status = 'cancelled') || '|0');
select tests.mk_doc('web_lead', 'receipt', 'Hosting invoice from Hostco', 'invoice', 'web', null);
select tests.check('32. a receipt is attached through the documents module (a link by institutional id); someone who cannot see the expense cannot attach it',
  tests.try('web_lead', format($q$ select document_link_add(%L, %L) $q$, tests.id('doc:receipt'), tests.inst_of('expenses', 'ex:a'))) || '|' ||
  tests.try('web_staff', format($q$ select document_link_add(%L, %L) $q$, tests.id('doc:receipt'), tests.inst_of('expenses', 'ex:a'))), 'ok|ERR:42501');
select tests.check('33. expenses are in the audit trail and their approvals in the shared queue',
  (select (count(*) filter (where table_name = 'expenses') >= 5)::text from audit_log) || '|' || (select (count(*) >= 5)::text from approval_requests where entity_table = 'expenses'), 'true|true');

select tests.finish();
rollback;
