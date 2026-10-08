-- Payments: partial payments, derived balances, allocation caps, overpayment credit, reversal, refund, reconciliation.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.bank_account('nad');
select tests.bank_account('usd', 'USD');
select tests.issued_invoice('A', 'client:abc', 10000);
select tests.issued_invoice('B', 'client:abc', 4000);
select tests.check('fixtures: two issued invoices', (select string_agg(status::text || ':' || total::text, ',' order by total desc) from invoices where id in (tests.id('inv:A'), tests.id('inv:B'))), 'issued:10000.00,issued:4000.00');

-- Recording ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('a division lead cannot record payments', tests.scalar('web_lead', format('select payment_record(%L, %L, 100, ''bank_transfer'')::text', tests.id('client:abc'), tests.id('acct:nad'))), 'ERR:42501');
select tests.check('a payment for a client the user cannot see fails like a missing client',
  tests.scalar('fin', format('select payment_record(%L, %L, 100, ''bank_transfer'')::text', gen_random_uuid(), tests.id('acct:nad'))), 'ERR:P0002');
select tests.check('a payment must be positive', tests.scalar('fin', format('select payment_record(%L, %L, 0, ''bank_transfer'')::text', tests.id('client:abc'), tests.id('acct:nad'))), 'ERR:23514');
select tests.check('finance records a part payment and allocates it to invoice A on receipt',
  tests.remember_ok('pay:1', tests.scalar('fin', format('select payment_record(%L, %L, 3000, ''bank_transfer'', current_date, ''FNB-0001'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:A')))), 'ok');
select tests.check('the payment has an ADA-PAY ID, references the client and account, and carries the account''s currency',
  (select (ada_id ~ '^ADA-PAY-\d{4}-\d{4}$' and client_id = tests.id('client:abc') and received_account_id = tests.id('acct:nad') and currency = 'NAD' and status = 'received' and reconciliation = 'unreconciled')::text from payments where id = tests.id('pay:1')), 'true');
select tests.check('partial payment calculates the correct balance (10000 - 3000)', tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:A'))), '7000.00');
select tests.check('...and the invoice is now partially paid', (select status::text from invoices where id = tests.id('inv:A')), 'partially_paid');
select tests.check('the balance is never stored: no balance/paid column exists on invoices, payments or lines',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns
   where table_schema = 'public' and table_name in ('invoices', 'invoice_lines', 'payments', 'billable_items', 'contracts', 'contract_versions') and column_name ~ '(balance|outstanding|amount_paid|paid_amount|amount_due|credit)'), 'none');
select tests.check('a second part payment: balance 10000 - 3000 - 2500', tests.remember_ok('pay:2', tests.scalar('fin', format('select payment_record(%L, %L, 2500, ''card'', current_date, ''FNB-0002'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:A')))), 'ok');
select tests.check('...balance', tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:A'))), '4500.00');
select tests.check('invoice_balances view agrees (paid, balance, overdue flag)', (select paid::text || '/' || balance::text || '/' || is_overdue::text from invoice_balances where invoice_id = tests.id('inv:A')), '5500.00/4500.00/false');

-- Duplicates and double allocation ----------------------------------------------------------------------------------------------------------
select tests.check('the same bank reference cannot be recorded twice on one account (duplicate payment)',
  tests.scalar('fin', format('select payment_record(%L, %L, 3000, ''bank_transfer'', current_date, ''fnb-0001'')::text', tests.id('client:abc'), tests.id('acct:nad'))), 'ERR:23505');
select tests.check('a fully allocated payment cannot be allocated again (default amount)', tests.scalar('fin', format('select payment_allocate(%L, %L)::text', tests.id('pay:1'), tests.id('inv:B'))), 'ERR:23514');
select tests.check('...nor with an explicit amount', tests.scalar('fin', format('select payment_allocate(%L, %L, 100)::text', tests.id('pay:1'), tests.id('inv:B'))), 'ERR:23514');
select tests.check('...nor to the invoice it already settles', tests.scalar('fin', format('select payment_allocate(%L, %L, 100)::text', tests.id('pay:1'), tests.id('inv:A'))), 'ERR:23514');
select tests.check('the database refuses a double allocation even for the owner (credit cap)',
  tests.try_owner(format('insert into payment_allocations (payment_id, invoice_id, amount) values (%L, %L, 1)', tests.id('pay:1'), tests.id('inv:B'))), 'ERR:23514');
select tests.check('an allocation cannot exceed the invoice balance',
  tests.try_owner(format('insert into payment_allocations (payment_id, invoice_id, amount) select %L, %L, 4500.01 from payments where id = %L', tests.id('pay:2'), tests.id('inv:A'), tests.id('pay:2'))), 'ERR:23514');
select tests.check('users cannot write allocations or payments directly',
  tests.try('fin', $q$ insert into payment_allocations (payment_id, invoice_id, amount) select id, id, 1 from payments $q$) || tests.try('fin', $q$ update payments set amount = 1 $q$), 'ERR:42501ERR:42501');
select tests.check('a recorded payment is immutable (amount, client)', tests.try_owner(format('update payments set amount = 1 where id = %L', tests.id('pay:1'))) || tests.try_owner(format('update payments set client_id = %L where id = %L', tests.id('client:C_web'), tests.id('pay:1'))), 'ERR:42501ERR:42501');
select tests.check('payments and allocations cannot be deleted', tests.try_owner('delete from payments') || tests.try_owner('delete from payment_allocations'), 'ERR:42501ERR:42501');
select tests.check('an allocation''s amount cannot be edited', tests.try_owner(format('update payment_allocations set amount = 1 where payment_id = %L', tests.id('pay:1'))), 'ERR:42501');

-- Paying off an invoice; overpayment becomes credit ------------------------------------------------------------------------------------------
select tests.check('the remaining 4500 settles invoice A', tests.remember_ok('pay:3', tests.scalar('fin', format('select payment_record(%L, %L, 4500, ''bank_transfer'', current_date, ''FNB-0003'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:A')))), 'ok');
select tests.check('invoice A is paid, balance zero', (select status::text from invoices where id = tests.id('inv:A')) || tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:A'))), 'paid0.00');
select tests.check('a paid invoice accepts no further allocation', tests.scalar('fin', format('select payment_allocate(%L, %L, 1)::text', tests.id('pay:3'), tests.id('inv:A'))), 'ERR:23514');
select tests.check('an overpayment (6000 against a 4000 invoice) is recorded; 4000 allocated',
  tests.remember_ok('pay:4', tests.scalar('fin', format('select payment_record(%L, %L, 6000, ''bank_transfer'', current_date, ''FNB-0004'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:B')))), 'ok');
select tests.check('...the surplus is derived as client credit (2000), invoice B is paid',
  (select credit::text || '/' || allocated::text from payment_balances where payment_id = tests.id('pay:4')) || (select status::text from invoices where id = tests.id('inv:B')), '2000.00/4000.00paid');
select tests.issued_invoice('C', 'client:abc', 1500);
select tests.check('the credit can be applied to a later invoice (partial)', tests.try('fin', format('select payment_allocate(%L, %L, 1000)', tests.id('pay:4'), tests.id('inv:C'))), 'ok');
select tests.check('...credit now 1000, invoice C partially paid with balance 500',
  (select credit::text from payment_balances where payment_id = tests.id('pay:4')) || '/' || tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:C'))) || '/' || (select status::text from invoices where id = tests.id('inv:C')), '1000.00/500.00/partially_paid');
select tests.check('a payment can settle several invoices and an invoice can have several payments',
  (select count(distinct payment_id)::text || count(distinct invoice_id)::text from payment_allocations where status = 'active' and payment_id in (tests.id('pay:4'))) || (select count(distinct payment_id)::text from payment_allocations where invoice_id = tests.id('inv:A') and status = 'active'), '123');

-- Across clients and currencies --------------------------------------------------------------------------------------------------------------
select tests.issued_invoice('W', 'client:C_web', 800);
select tests.check('a payment cannot settle another client''s invoice', tests.scalar('fin', format('select payment_allocate(%L, %L, 100)::text', tests.id('pay:4'), tests.id('inv:W'))), 'ERR:23514');
select tests.check('the database refuses it for the owner too', tests.try_owner(format('insert into payment_allocations (payment_id, invoice_id, amount) values (%L, %L, 100)', tests.id('pay:4'), tests.id('inv:W'))), 'ERR:23514');
select tests.remember('pay:usd', tests.scalar('fin', format('select payment_record(%L, %L, 500, ''card'')::text', tests.id('client:abc'), tests.id('acct:usd'))));
select tests.check('a USD payment cannot settle a NAD invoice', tests.scalar('fin', format('select payment_allocate(%L, %L, 100)::text', tests.id('pay:usd'), tests.id('inv:C'))), 'ERR:23514');
select tests.remember('bi:D', tests.scalar('fin', format('select billable_manual(%L, %L, ''Draft thing'', 1, 700, ''test'')::text', tests.id('client:abc'), tests.id('div:web'))));
select tests.remember('inv:D', tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', tests.id('bi:D'))));
select tests.check('a payment cannot be allocated to an invoice that is not issued', tests.scalar('fin', format('select payment_allocate(%L, %L, 10)::text', tests.id('pay:4'), tests.id('inv:D'))), 'ERR:23514');

-- Reversal restores the outstanding balance ---------------------------------------------------------------------------------------------------
select tests.check('web lead cannot request a reversal', tests.scalar('web_lead', format('select payment_request_reversal(%L, ''reversal'', null, ''x'')::text', tests.id('pay:2'))), 'ERR:P0002');
select tests.check('a reason is required', tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'')::text', tests.id('pay:2'))), 'ERR:23514');
select tests.remember('rev:2', tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''Cheque bounced'')::text', tests.id('pay:2'))));
select tests.check('the request is in the shared approvals queue (kind payment_reversal)', (select count(*)::text from approval_requests where kind = 'payment_reversal' and status = 'pending'), '1');
select tests.check('nothing changes until it is approved (invoice A still paid)', (select status::text from invoices where id = tests.id('inv:A')), 'paid');
select tests.check('only one pending request per payment', tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''again'')::text', tests.id('pay:2'))), 'ERR:23505');
select tests.check('the requester cannot approve their own reversal (policy: no self-approval)', tests.scalar('fin', format('select payment_reversal_decide(%L, true)', tests.id('rev:2'))), 'ERR:42501');
select tests.check('web staff cannot decide', tests.scalar('web_staff', format('select payment_reversal_decide(%L, true)', tests.id('rev:2'))), 'ERR:P0002');
select tests.check('rejecting needs a note', tests.scalar('ceo', format('select payment_reversal_decide(%L, false)', tests.id('rev:2'))), 'ERR:23514');
select tests.check('management approves the reversal', tests.scalar('ceo', format('select payment_reversal_decide(%L, true, ''Confirmed with bank'')', tests.id('rev:2'))), 'approved');
select tests.check('payment reversal restores the correct outstanding balance (A: 10000 - 3000 - 4500 = 2500) and reopens the invoice',
  tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:A'))) || '/' || (select status::text from invoices where id = tests.id('inv:A')), '2500.00/partially_paid');
select tests.check('the reversed payment is no longer valid: no active allocations, no credit', (select status::text || '/' || allocated::text || '/' || credit::text from payment_balances where payment_id = tests.id('pay:2')), 'reversed/0.00/0.00');
select tests.check('the released allocation is kept on record', (select count(*)::text from payment_allocations where payment_id = tests.id('pay:2') and status = 'released' and release_reason = 'payment reversed'), '1');
select tests.check('a reversed payment cannot be allocated or reversed again',
  tests.scalar('fin', format('select payment_allocate(%L, %L, 10)::text', tests.id('pay:2'), tests.id('inv:A'))) || tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''x'')::text', tests.id('pay:2'))), 'ERR:23514ERR:23514');
select tests.check('the decided request is final', tests.scalar('ceo', format('select payment_reversal_decide(%L, true)', tests.id('rev:2'))), 'ERR:23514');
select tests.check('reversing the other payments too returns the invoice to issued with the full balance',
  (tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''Duplicate deposit'')::text', tests.id('pay:1'))) is not null)::text, 'true');
select tests.scalar('ceo', format('select payment_reversal_decide((select id from payment_reversals where payment_id = %L), true)', tests.id('pay:1')));
select tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''Wrong client'')::text', tests.id('pay:3')));
select tests.scalar('ceo', format('select payment_reversal_decide((select id from payment_reversals where payment_id = %L), true)', tests.id('pay:3')));
select tests.check('...(A: issued, balance 10000)', (select status::text from invoices where id = tests.id('inv:A')) || tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:A'))), 'issued10000.00');
select tests.check('a rejected reversal changes nothing',
  (tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''Maybe'')::text', tests.id('pay:4'))) is not null)::text, 'true');
select tests.scalar('ceo', format('select payment_reversal_decide((select id from payment_reversals where payment_id = %L), false, ''Not a mistake'')', tests.id('pay:4')));
select tests.check('...payment 4 still received with its allocations', (select status::text from payments where id = tests.id('pay:4')) || (select count(*)::text from payment_allocations where payment_id = tests.id('pay:4') and status = 'active'), 'received2');

-- Refund of unallocated credit ---------------------------------------------------------------------------------------------------------------
select tests.check('a refund cannot exceed the unallocated credit (1000)', tests.scalar('fin', format('select payment_request_reversal(%L, ''refund'', 1500, ''Client asked'')::text', tests.id('pay:4'))), 'ERR:23514');
select tests.remember('ref:4', tests.scalar('fin', format('select payment_request_reversal(%L, ''refund'', 1000, ''Client asked for the surplus back'')::text', tests.id('pay:4'))));
select tests.check('refunds use their own approval kind', (select count(*)::text from approval_requests where kind = 'refund' and status = 'pending'), '1');
select tests.check('the requester cannot approve a refund', tests.scalar('fin', format('select payment_reversal_decide(%L, true)', tests.id('ref:4'))), 'ERR:42501');
select tests.check('management approves the refund', tests.scalar('ceo', format('select payment_reversal_decide(%L, true)', tests.id('ref:4'))), 'approved');
select tests.check('the refund reduces the credit; allocations stay valid', (select refunded::text || '/' || credit::text || '/' || allocated::text from payment_balances where payment_id = tests.id('pay:4')), '1000.00/0.00/5000.00');
select tests.check('a partly refunded payment cannot be wholly reversed', tests.scalar('fin', format('select payment_request_reversal(%L, ''reversal'', null, ''x'')::text', tests.id('pay:4'))), 'ERR:23514');

select tests.issued_invoice('E', 'client:abc', 300);
select tests.check('after the refund the payment has no credit left: it cannot fund another invoice', tests.scalar('fin', format('select payment_allocate(%L, %L, 100)::text', tests.id('pay:4'), tests.id('inv:E'))), 'ERR:23514');
select tests.check('...nor can the database be made to by the owner', tests.try_owner(format('insert into payment_allocations (payment_id, invoice_id, amount) values (%L, %L, 100)', tests.id('pay:4'), tests.id('inv:E'))), 'ERR:23514');
select tests.check('a second refund cannot exceed what is left (nothing)', tests.scalar('fin', format('select payment_request_reversal(%L, ''refund'', 1, ''again'')::text', tests.id('pay:4'))), 'ERR:23514');

-- Unallocate ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('an invoice with valid payments cannot be cancelled', tests.scalar('ceo', format('select invoice_void(%L, ''mistake'')::text', tests.id('inv:C'))), 'ERR:23514');
select tests.check('finance releases an allocation (reason required)', tests.scalar('fin', format('select payment_unallocate((select id from payment_allocations where payment_id = %L and invoice_id = %L and status = ''active''), null)::text', tests.id('pay:4'), tests.id('inv:C'))), 'ERR:23514');
select tests.scalar('fin', format('select payment_unallocate((select id from payment_allocations where payment_id = %L and invoice_id = %L and status = ''active''), ''Applied to the wrong invoice'')::text', tests.id('pay:4'), tests.id('inv:C')));
select tests.check('...the invoice is issued again with its full balance and the credit returns', tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:C'))) || (select status::text from invoices where id = tests.id('inv:C')) || (select credit::text from payment_balances where payment_id = tests.id('pay:4')), '1500.00issued1000.00');
select tests.check('now the unpaid invoice can be cancelled', tests.try('ceo', format('select invoice_void(%L, ''Raised in error'')', tests.id('inv:C'))), 'ok');

-- Reconciliation ----------------------------------------------------------------------------------------------------------------------------
select tests.check('web lead cannot reconcile', tests.scalar('web_lead', format('select payment_reconcile(%L)::text', tests.id('pay:4'))), 'ERR:P0002');
select tests.check('a statement reference is required', tests.scalar('fin', format('select payment_reconcile(%L)::text', tests.id('pay:4'))), 'ERR:23514');
select tests.check('finance reconciles against the bank statement', tests.try('fin', format('select payment_reconcile(%L, ''reconciled'', ''STMT-2026-10-01'')', tests.id('pay:4'))), 'ok');
select tests.check('...recorded with who and when', (select (reconciliation = 'reconciled' and statement_ref = 'STMT-2026-10-01' and reconciled_by = tests.id('staff:fin') and reconciled_at is not null)::text from payments where id = tests.id('pay:4')), 'true');
select tests.check('disputing needs a note', tests.scalar('fin', format('select payment_reconcile(%L, ''disputed'')::text', tests.id('pay:4'))), 'ERR:23514');
select tests.check('a reversed payment is not reconciled', tests.scalar('fin', format('select payment_reconcile(%L, ''reconciled'', ''S'')::text', tests.id('pay:2'))), 'ERR:23514');

-- Visibility ----------------------------------------------------------------------------------------------------------------------------------
select tests.check('finance and management see payments; division leads, staff and auditors do not',
  tests.scalar('fin', 'select (count(*) > 0)::text from payments') || tests.scalar('ceo', 'select (count(*) > 0)::text from payments') ||
  tests.scalar('web_lead', 'select count(*)::text from payments') || tests.scalar('web_staff', 'select count(*)::text from payments') || tests.scalar('audit', 'select count(*)::text from payments'), 'truetrue000');
select tests.check('cross-division: Tech lead sees no payments, allocations, reversals or balances',
  tests.scalar('tech_lead', 'select (select count(*) from payments)::text || (select count(*) from payment_allocations) || (select count(*) from payment_reversals) || (select count(*) from payment_balances) || (select count(*) from invoice_balances)'), '00000');
select tests.check('a division lead can see the balance of their own division''s invoice (an authorisation slice), but not the payments behind it',
  tests.scalar('web_lead', format('select invoice_balance(%L)::text', tests.id('inv:A'))) || '/' || tests.scalar('web_lead', format('select count(*)::text from payment_allocations where invoice_id = %L', tests.id('inv:A'))), '10000.00/0');
select tests.check('another division sees no balance (null, like a missing invoice)', tests.same_for('tech_lead', $q$ select coalesce(invoice_balance(%L)::text, 'null') $q$, tests.id('inv:A'), gen_random_uuid()), 'same');
select tests.check('a hidden payment is indistinguishable from a missing one (allocate)', tests.same_for('web_lead', $q$ select payment_allocate(%L, (select id from invoices limit 1))::text $q$, tests.id('pay:4'), gen_random_uuid()), 'same');
select tests.check('...(reverse)', tests.same_for('web_lead', $q$ select payment_request_reversal(%L, 'reversal', null, 'probe')::text $q$, tests.id('pay:4'), gen_random_uuid()), 'same');
select tests.check('...(reconcile)', tests.same_for('web_lead', $q$ select payment_reconcile(%L)::text $q$, tests.id('pay:4'), gen_random_uuid()), 'same');
select tests.check('...(helper)', tests.same_for('web_lead', $q$ select can_view_payment(%L)::text $q$, tests.id('pay:4'), gen_random_uuid()), 'same');

-- Defence in depth: a reversed payment never counts, even if (through a fault) its allocations were not released
select tests.check('a reversed payment''s allocations do not count towards an invoice even if they were left active',
  (select invoice_valid_allocated(tests.id('inv:A'))::text),  '0');
update payments set status = 'reversed' where id = tests.id('pay:4');
select tests.check('...(payment 4 forced to reversed by the owner: invoice B, which it had paid, no longer counts it)', (select invoice_valid_allocated(tests.id('inv:B'))::text), '0');

-- Audit and structure -----------------------------------------------------------------------------------------------------------------------
select tests.check('payments, allocations and reversals are audited', (select string_agg(distinct table_name, ',' order by table_name) from audit_log where table_name in ('payments', 'payment_allocations', 'payment_reversals')), 'payment_allocations,payment_reversals,payments');
select tests.check('audit history survives reversal: the original payment insert is still there',
  (select count(*)::text from audit_log where table_name = 'payments' and action = 'INSERT' and record_id = tests.id('pay:2')), '1');
select tests.check('payment tables hold no client identity columns',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns
   where table_schema = 'public' and table_name in ('payments', 'payment_allocations', 'payment_reversals') and column_name ~ '(name|email|phone)'), 'none');
select tests.check('payments reference the client and account by id', (select count(*)::text from pg_constraint where conrelid = 'payments'::regclass and contype = 'f' and confrelid in ('clients'::regclass, 'bank_accounts'::regclass)), '2');
select tests.check('the registry knows every payment', tests.unregistered_tables(), 'none');

select tests.finish();
rollback;
