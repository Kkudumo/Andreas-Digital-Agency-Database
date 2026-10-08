-- PERMANENT REGRESSION SUITE: finance records of a restricted client (contracts, invoices, billable items, payments,
-- allocations, reversals, pending approvals) are indistinguishable from non-existent records to anyone who may not
-- know the client exists - and restricting, removing or restoring a client propagates to all of them.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.bank_account('nad');
select tests.add_staff('ceo2', 'ceo');
select tests.issued_invoice('A', 'client:abc', 5000);
select tests.remember('pay:A', tests.scalar('fin', format('select payment_record(%L, %L, 2000, ''bank_transfer'', current_date, ''REF-A'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:A'))));
select tests.remember('pay:credit', tests.scalar('fin', format('select payment_record(%L, %L, 900, ''cash'', current_date, ''REF-CREDIT'')::text', tests.id('client:abc'), tests.id('acct:nad'))));
select tests.draft_invoice('P', 'fin', 'client:abc', 1200);
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:P')));
select tests.remember('rev:A', tests.scalar('fin', format('select payment_request_reversal(%L, ''refund'', 300, ''Client asked'')::text', tests.id('pay:credit'))));
select tests.remember('bi:open', tests.scalar('fin', format('select billable_manual(%L, %L, ''Open charge'', 1, 100, ''test'')::text', tests.id('client:abc'), tests.id('div:web'))));
select tests.remember('cl:web', (select cl.id::text from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.unit_price = 5000));
insert into tests.ids values ('x:random', gen_random_uuid());

-- Controls: while the client is ordinary, the probes DO see the records -----------------------------------------------------------------------------
select tests.check('control: finance sees the contract, invoices, payments, allocations, reversal and billable items',
  tests.scalar('fin', 'select (select count(*) from contracts)::text || ((select count(*) from invoices) > 0)::text || ((select count(*) from payments) > 0)::text || ((select count(*) from payment_allocations) > 0)::text || ((select count(*) from payment_reversals) > 0)::text || ((select count(*) from billable_items) > 0)::text'), '1truetruetruetruetrue');
select tests.check('control: web lead sees the contract and invoice of the Web division', tests.scalar('web_lead', 'select (select count(*) from contracts)::text || ((select count(*) from invoices) > 0)::text'), '1true');
select tests.check('control: the approver sees the pending invoice approval', tests.scalar('ceo', 'select (count(*) > 0)::text from approval_requests where entity_table = ''invoices'' and status = ''pending'''), 'true');
select tests.check('control: the probes can tell a visible contract from a missing one', left(tests.same_for('web_lead', $q$ select can_view_contract(%L)::text $q$, tests.id('contract:1'), tests.id('x:random')), 9), 'DIFFERENT');

-- The client becomes restricted ------------------------------------------------------------------------------------------------------------------
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('propagation: contract, billable items, invoices and payments all inherit the restriction',
  (select string_agg(t, ',' order by t) from (
     select 'contracts:' || string_agg(distinct effective_classification::text, '/') t from contracts
     union all select 'billable_items:' || string_agg(distinct effective_classification::text, '/') from billable_items
     union all select 'invoices:' || string_agg(distinct effective_classification::text, '/') from invoices
     union all select 'payments:' || string_agg(distinct effective_classification::text, '/') from payments) q),
  'billable_items:restricted,contracts:restricted,invoices:restricted,payments:restricted');
select tests.check('propagation: pending approvals follow too', (select string_agg(distinct classification::text, ',') from approval_requests where status = 'pending'), 'restricted');

select tests.check('finance (no records.view_restricted) now sees none of it: contracts, versions, lines, history, projects',
  tests.scalar('fin', 'select (select count(*) from contracts)::text || (select count(*) from contract_versions) || (select count(*) from contract_lines) || (select count(*) from contract_status_history) || (select count(*) from contract_projects)'), '00000');
select tests.check('...invoices, lines, billable items, balances', tests.scalar('fin', 'select (select count(*) from invoices)::text || (select count(*) from invoice_lines) || (select count(*) from billable_items) || (select count(*) from invoice_balances)'), '0000');
select tests.check('...payments, allocations, reversals, balances', tests.scalar('fin', 'select (select count(*) from payments)::text || (select count(*) from payment_allocations) || (select count(*) from payment_reversals) || (select count(*) from payment_balances)'), '0000');
select tests.check('...pending approvals, even for the person who requested them', tests.scalar('fin', 'select count(*)::text from approval_requests where entity_table in (''invoices'', ''contract_versions'', ''payment_reversals'')'), '0');
select tests.check('web lead sees none of it either', tests.scalar('web_lead', 'select (select count(*) from contracts)::text || (select count(*) from invoices) || (select count(*) from billable_items) || (select count(*) from contract_versions)'), '0000');
select tests.check('the same client''s 360 view is null for them, and shows no finance',
  tests.scalar('fin', format('select coalesce(client_360(%L)::text, ''null'')', tests.id('client:abc'))), 'null');
select tests.check('the project 360 hides it too', tests.scalar('web_lead', format('select coalesce(project_360(%L)::text, ''null'')', tests.id('project:abc'))), 'null');
select tests.check('authorised: management sees all of it', tests.scalar('ceo', 'select (select count(*) from contracts)::text || ((select count(*) from invoices) > 0)::text || ((select count(*) from payments) > 0)::text'), '1truetrue');
select tests.check('authorised: administration (records.view_restricted + contracts.view) sees the contract but not the invoices (no invoices.view)',
  tests.scalar('admin', 'select (select count(*) from contracts)::text || (select count(*) from invoices)::text || (select count(*) from payments)::text'), '100');
select tests.check('authorised: the restricted client''s 360 shows its finance slices to management',
  tests.scalar('ceo', format('select (jsonb_array_length(client_360(%L) -> ''contracts'') = 1 and jsonb_array_length(client_360(%L) -> ''invoices'') >= 2)::text', tests.id('client:abc'), tests.id('client:abc'))), 'true');

-- Identical observable behaviour, restricted record vs random id ---------------------------------------------------------------------------
select tests.check('restricted contract: lifecycle command', tests.same_for('web_lead', $q$ select contract_transition(%L, 'cancelled', 'probe')::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: amend', tests.same_for('web_lead', $q$ select contract_amend(%L, 'probe')::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: renew', tests.same_for('fin', $q$ select contract_renew(%L)::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: add line', tests.same_for('web_lead', $q$ select contract_add_line(%L, null, 1, 1, null, 'probe')::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: set terms', tests.same_for('web_lead', $q$ select contract_set_terms(%L, '{}')::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: link project', tests.same_for('web_lead', $q$ select contract_link_project(%L, (select id from projects limit 1))::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: authorization helper', tests.same_for('web_lead', $q$ select can_view_contract(%L)::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: terms', tests.same_for('web_lead', $q$ select count(*)::text from contract_terms(%L) $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: select by id', tests.same_for('web_lead', $q$ select count(*)::text from contracts where id = %L $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted contract: select by its client', tests.same_for('web_lead', $q$ select count(*)::text from contracts where client_id = %L $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('restricted contract: billing from it', tests.same_for('fin', $q$ select billable_from_contract(%L, (select id from contract_lines limit 1))::text $q$, tests.id('contract:1'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: transition', tests.same_for('fin', $q$ select invoice_transition(%L, 'cancelled')::text $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: void', tests.same_for('fin', $q$ select invoice_void(%L, 'probe')::text $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: set terms', tests.same_for('fin', $q$ select invoice_set_terms(%L, '{}')::text $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: add lines', tests.same_for('fin', $q$ select invoice_add_lines(%L, array[]::uuid[])::text $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: authorization helper', tests.same_for('fin', $q$ select can_view_invoice(%L)::text $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: balance', tests.same_for('fin', $q$ select coalesce(invoice_balance(%L)::text, 'null') $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: paid amount', tests.same_for('fin', $q$ select coalesce(invoice_paid(%L)::text, 'null') $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: select by id', tests.same_for('fin', $q$ select count(*)::text from invoices where id = %L $q$, tests.id('inv:A'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: select by its client', tests.same_for('fin', $q$ select count(*)::text from invoices where client_id = %L $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('restricted invoice: balance view by client', tests.same_for('fin', $q$ select count(*)::text from invoice_balances where client_id = %L $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('restricted billable item: void', tests.same_for('fin', $q$ select billable_void(%L, 'probe')::text $q$, tests.id('bi:open'), tests.id('x:random')), 'same');
select tests.check('restricted billable item: invoice from it', tests.same_for('fin', $q$ select invoice_create(array[%L]::uuid[])::text $q$, tests.id('bi:open'), tests.id('x:random')), 'same');
select tests.check('restricted payment: allocate', tests.same_for('fin', $q$ select payment_allocate(%L, (select id from invoices limit 1))::text $q$, tests.id('pay:credit'), tests.id('x:random')), 'same');
select tests.check('restricted payment: request reversal', tests.same_for('fin', $q$ select payment_request_reversal(%L, 'reversal', null, 'probe')::text $q$, tests.id('pay:A'), tests.id('x:random')), 'same');
select tests.check('restricted payment: reconcile', tests.same_for('fin', $q$ select payment_reconcile(%L)::text $q$, tests.id('pay:A'), tests.id('x:random')), 'same');
select tests.check('restricted payment: authorization helper', tests.same_for('fin', $q$ select can_view_payment(%L)::text $q$, tests.id('pay:A'), tests.id('x:random')), 'same');
select tests.check('restricted payment: select by id', tests.same_for('fin', $q$ select count(*)::text from payments where id = %L $q$, tests.id('pay:A'), tests.id('x:random')), 'same');
select tests.check('restricted payment: select by its client', tests.same_for('fin', $q$ select count(*)::text from payments where client_id = %L $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('restricted payment: allocations by payment', tests.same_for('fin', $q$ select count(*)::text from payment_allocations where payment_id = %L $q$, tests.id('pay:A'), tests.id('x:random')), 'same');
select tests.check('restricted payment: reversal request by id (non-authorised)', tests.same_for('fin', $q$ select payment_reversal_decide(%L, true)::text $q$, tests.id('rev:A'), tests.id('x:random')), 'same');
select tests.check('restricted contract line: remove', tests.same_for('web_lead', $q$ select contract_remove_line(%L)::text $q$, (select id from contract_lines limit 1), tests.id('x:random')), 'same');
select tests.check('restricted invoice line: remove', tests.same_for('fin', $q$ select invoice_remove_line(%L)::text $q$, (select il.id from invoice_lines il where il.invoice_id = tests.id('inv:A')), tests.id('x:random')), 'same');
select tests.check('restricted allocation: release', tests.same_for('fin', $q$ select payment_unallocate(%L, 'probe')::text $q$, (select a.id from payment_allocations a where a.payment_id = tests.id('pay:A')), tests.id('x:random')), 'same');
select tests.check('commands against the restricted client: create a contract', tests.same_for('fin', $q$ select contract_create(%L, (select id from tests.ids where key = 'div:web'), 'Probe')::text $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('commands against the restricted client: create a contract (division lead)', tests.same_for('web_lead', $q$ select contract_create(%L, (select id from tests.ids where key = 'div:web'), 'Probe')::text $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('commands against the restricted client: manual billable charge', tests.same_for('fin', $q$ select billable_manual(%L, (select id from tests.ids where key = 'div:web'), 'Probe', 1, 1, 'probe')::text $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('commands against the restricted client: record a payment', tests.same_for('fin', $q$ select payment_record(%L, (select id from tests.ids where key = 'acct:nad'), 10, 'cash')::text $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('the approvals queue shows nothing about it to finance or the division lead',
  tests.scalar('fin', 'select count(*)::text from approval_requests where status = ''pending''') || tests.scalar('web_lead', 'select count(*)::text from approval_requests where entity_table in (''invoices'', ''contract_versions'', ''payment_reversals'')'), '00');

select tests.remember('client:abc2', tests.mkclient_id('web_lead', 'Second Visible Co', 'web'));
-- Payment references cannot reveal a restricted client's payment -------------------------------------------------------------------------------
select tests.check('a bank reference used by a restricted client''s payment is free for anyone else (no collision, no leak)',
  tests.outcome('fin', format($q$ select (payment_record(%L, %L, 50, 'cash', current_date, 'REF-A')::text is not null)::text $q$, tests.id('client:C_web'), tests.id('acct:nad'))),
  tests.outcome('fin', format($q$ select (payment_record(%L, %L, 50, 'cash', current_date, 'REF-NEVER-USED')::text is not null)::text $q$, tests.id('client:C_web'), tests.id('acct:nad'))));
select tests.scalar('fin', format($q$ select payment_record(%L, %L, 50, 'cash', current_date, 'REF-VIS')::text $q$, tests.id('client:C_web'), tests.id('acct:nad')));
select tests.check('control: the same reference IS refused when the first payment is visible to the caller (ordinary duplicate protection)',
  tests.scalar('fin', format($q$ select payment_record(%L, %L, 50, 'cash', current_date, 'REF-VIS')::text $q$, tests.id('client:abc2'), tests.id('acct:nad'))), 'ERR:23505');

-- A record created AFTER the client is restricted is born restricted ---------------------------------------------------------------------------
select tests.remember('contract:R2', tests.scalar('ceo', format('select contract_create(%L, %L, ''Born restricted'')::text', tests.id('client:abc'), tests.id('div:web'))));
select tests.check('a new contract inherits the restriction at creation', (select effective_classification::text from contracts where id = tests.id('contract:R2')), 'restricted');
select tests.check('...and is invisible to the division lead', tests.scalar('web_lead', format('select count(*)::text from contracts where id = %L', tests.id('contract:R2'))), '0');

-- Authorised work still flows (the restriction hides, it does not break) ---------------------------------------------------------------------------
select tests.check('management can still approve the restricted invoice request (another approver, since finance cannot see it)',
  tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:P'))), 'approved');
select tests.check('management can still decide the restricted refund (finance requested it)', tests.scalar('ceo', format('select payment_reversal_decide(%L, true)', tests.id('rev:A'))), 'approved');

-- Restoring the client restores visibility -----------------------------------------------------------------------------------------------------
update clients set classification = 'internal' where id = tests.id('client:abc');
select tests.check('propagation both ways: finance sees the records again', tests.scalar('fin', 'select (select count(*) from contracts)::text || ((select count(*) from invoices) > 0)::text || ((select count(*) from payments) > 0)::text'), '2truetrue');
select tests.check('...and pending approvals return to the queue', (select string_agg(distinct classification::text, ',') from approval_requests where entity_table in ('invoices', 'contract_versions', 'payment_reversals')), 'internal');

-- Removing the client -----------------------------------------------------------------------------------------------------------------------------
select tests.check('a client with open commercial records cannot be removed',
  tests.try_owner(format('update clients set deleted_at = now(), deleted_by = null, deletion_reason = ''test'' where id = %L', tests.id('client:abc'))), 'ERR:23514');
select tests.check('a client without any commercial records can be removed, and its (non-existent) finance is moot',
  tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''test'' where id = %L', tests.id('client:C_conf'))), 'ok');
-- Each kind of open record blocks removal on its own ---------------------------------------------------------------------------------------------
select tests.remember('client:abc3', tests.mkclient_id('web_lead', 'Third Visible Co', 'web'));
select tests.issued_invoice('Y', 'client:abc3', 100);
select tests.check('an issued, unpaid invoice alone blocks removing the client', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:abc3'))), 'ERR:23514');
select tests.remember('pay:Y', tests.scalar('fin', format('select payment_record(%L, %L, 100, ''cash'', current_date, null, %L)::text', tests.id('client:abc3'), tests.id('acct:nad'), tests.id('inv:Y'))));
select tests.check('once the invoice is paid in full (no credit left) the client can be removed', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:abc3'))), 'ok');

-- Closed records follow a removed client: hidden from ordinary users, kept for those allowed to see deleted records ----------------------------------------
select tests.remember('contract:X', tests.scalar('web_lead', format('select contract_create(%L, %L, ''Never signed'')::text', tests.id('client:abc2'), tests.id('div:web'))));
select tests.scalar('web_lead', format('select contract_transition(%L, ''cancelled'', ''Client changed mind'')::text', tests.id('contract:X')));
select tests.draft_invoice('X', 'fin', 'client:abc2', 400);
select tests.scalar('fin', format('select invoice_void(%L, ''Raised in error'')::text', tests.id('inv:X')));
select tests.remember('pay:X', tests.scalar('fin', format('select payment_record(%L, %L, 100, ''cash'')::text', tests.id('client:abc2'), tests.id('acct:nad'))));
select tests.check('before removal an open payment credit blocks it', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:abc2'))), 'ERR:23514');
select tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''Paid by mistake'')::text', tests.id('pay:X')));
select tests.scalar('ceo', format('select payment_reversal_decide((select id from payment_reversals where payment_id = %L), true)', tests.id('pay:X')));
select tests.check('control: finance sees the closed records while the client exists',
  tests.scalar('fin', format('select (select count(*) from contracts where client_id = %L)::text || (select count(*) from invoices where client_id = %L) || (select count(*) from payments where client_id = %L)', tests.id('client:abc2'), tests.id('client:abc2'), tests.id('client:abc2'))), '111');
select tests.check('with everything closed the client can be removed', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:abc2'))), 'ok');
select tests.check('removing the client propagates: contracts, invoices and payments disappear for finance and the division lead',
  tests.scalar('fin', format('select (select count(*) from contracts where client_id = %L)::text || (select count(*) from invoices where client_id = %L) || (select count(*) from payments where client_id = %L)', tests.id('client:abc2'), tests.id('client:abc2'), tests.id('client:abc2')))
  || tests.scalar('web_lead', format('select (select count(*) from contracts where client_id = %L)::text || (select count(*) from invoices where client_id = %L)', tests.id('client:abc2'), tests.id('client:abc2'))), '00000');
select tests.check('...and they are indistinguishable from records that never existed', tests.same_for('fin', $q$ select count(*)::text from invoices where client_id = %L $q$, tests.id('client:abc2'), tests.id('x:random')), 'same');
select tests.check('...management (records.view_deleted) still sees them', tests.scalar('ceo', format('select (select count(*) from contracts where client_id = %L)::text || (select count(*) from invoices where client_id = %L) || (select count(*) from payments where client_id = %L)', tests.id('client:abc2'), tests.id('client:abc2'), tests.id('client:abc2'))), '111');
update clients set deleted_at = null, deleted_by = null, deletion_reason = null where id = tests.id('client:abc2');
select tests.check('restoring the client restores them', tests.scalar('fin', format('select (select count(*) from invoices where client_id = %L)::text', tests.id('client:abc2'))), '1');

select tests.finish();
rollback;
