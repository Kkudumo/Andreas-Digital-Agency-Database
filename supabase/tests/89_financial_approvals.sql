-- Financial approvals run through the SAME approval engine as prices and quotes: requester + action + amount +
-- division + policy -> required approvers -> approval record. No finance-specific permission system exists.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.bank_account('nad');

-- No parallel approval system -------------------------------------------------------------------------------------------------------------------
select tests.check('contracts, invoices and payment reversals all decide through approval_gate()',
  (select string_agg(proname, ',' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and prosrc like '%approval_gate(%'
    and proname in ('contract_transition', 'invoice_transition', 'payment_reversal_decide', 'quote_transition', 'price_decide')), 'contract_transition,invoice_transition,payment_reversal_decide,price_decide,quote_transition');
select tests.check('there is no finance-specific approval table or hardcoded "own" approval permission',
  (select coalesce(string_agg(x, ','), 'none') from (select table_name::text x from information_schema.tables where table_schema = 'public' and table_name ~ '(approval|approver)' and table_name not in ('approval_requests', 'approval_decisions', 'approval_policies')
    union all select key from permissions where key ~ '(approve_own|self_approve)') q), 'none');
select tests.check('every financial approval lands in the one queue with its own kind',
  (select string_agg(distinct kind, ',' order by kind) from approval_requests where kind in ('contract')), 'contract');

-- Policy selection -----------------------------------------------------------------------------------------------------------------------------
select tests.check('only management configures approval policies', tests.try('fin', $q$ insert into approval_policies (kind, min_amount, required_permission, min_approvers) values ('invoice', 50000, 'finance.approve', 2) $q$), 'ERR:42501');
select tests.check('management sets a higher tier: invoices from N$50,000 need finance.approve and two approvers',
  tests.try('ceo', $q$ insert into approval_policies (kind, min_amount, required_permission, allow_self_approval, min_approvers) values ('invoice', 50000, 'finance.approve', false, 2) $q$), 'ok');
select tests.check('...a division-specific rule for Tech: invoices from N$10,000 need finance.approve',
  tests.try('ceo', format($q$ insert into approval_policies (kind, division_id, min_amount, required_permission, allow_self_approval, min_approvers) values ('invoice', %L, 10000, 'finance.approve', false, 1) $q$, tests.id('div:tech'))), 'ok');
select tests.check('...a discount rule: discounts from N$400 need discounts.approve',
  tests.try('ceo', $q$ insert into approval_policies (kind, min_amount, required_permission, allow_self_approval, min_approvers) values ('discount', 400, 'discounts.approve', false, 1) $q$), 'ok');
select tests.check('a small invoice selects the default policy (one approver, invoices.approve)',
  (select required_permission || '/' || min_approvers::text from approval_policy('invoice', tests.id('div:web'), 1000)), 'invoices.approve/1');
select tests.check('a large invoice selects the higher tier',
  (select required_permission || '/' || min_approvers::text from approval_policy('invoice', tests.id('div:web'), 60000)), 'finance.approve/2');
select tests.check('the boundary amount belongs to the higher tier', (select min_approvers::text from approval_policy('invoice', tests.id('div:web'), 50000)), '2');
select tests.check('just below the boundary stays on the default', (select min_approvers::text from approval_policy('invoice', tests.id('div:web'), 49999.99)), '1');
select tests.check('the division-specific rule wins in its division and does not leak into others',
  (select required_permission from approval_policy('invoice', tests.id('div:tech'), 12000)) || '/' || (select required_permission from approval_policy('invoice', tests.id('div:web'), 12000)), 'finance.approve/invoices.approve');
select tests.check('discount policy selects by the discount amount',
  (select coalesce(required_permission, 'none') from approval_policy('discount', tests.id('div:web'), 399)) || '/' || (select required_permission from approval_policy('discount', tests.id('div:web'), 400)), 'none/discounts.approve');
select tests.check('refunds and reversals have their own default policy: finance.approve, no self-approval',
  (select string_agg(kind || ':' || required_permission || ':' || allow_self_approval::text, ',' order by kind) from approval_policies where kind in ('refund', 'payment_reversal')), 'payment_reversal:finance.approve:false,refund:finance.approve:false');
select tests.check('deactivated policies are ignored (history is kept)',
  (select (select count(*) from approval_policy('invoice', tests.id('div:web'), 60000) where required_permission is not null)::text), '1');

-- Self-approval: exactly the existing rule, recorded, not hardcoded to the CEO --------------------------------------------------------------
-- (1) Management raises an invoice. Finance ALSO holds invoices.approve, so separation of duties applies to management too.
select tests.draft_invoice('S1', 'ceo', 'client:abc', 1000);
select tests.scalar('ceo', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:S1')));
select tests.check('management cannot approve its own invoice while another qualified approver (finance) exists',
  tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:S1'))), 'ERR:42501');
select tests.check('...finance approves it instead', tests.scalar('fin', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:S1'))), 'approved');
-- (2) A policy that requires finance.approve, allowed for self-approval only while the requester is the SOLE approver
select tests.check('management allows self-approval for invoices only while the requester is the sole qualified approver',
  tests.try('ceo', $q$ update approval_policies set required_permission = 'finance.approve', allow_self_approval = true, self_approval_only_if_sole_approver = true where kind = 'invoice' and min_amount is null $q$), 'ok');
select tests.draft_invoice('S2', 'ceo', 'client:abc', 2000);
select tests.scalar('ceo', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:S2')));
select tests.check('the sole qualified approver (management) may approve their own invoice',
  tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:S2'))), 'approved');
select tests.check('...and the self-approval is RECORDED on the request and the decision',
  (select (r.self_approved and d.is_self)::text from approval_requests r join approval_decisions d on d.request_id = r.id where r.entity_id = tests.id('inv:S2')), 'true');
-- (3) not hardcoded to the CEO: if management does not hold invoices.approve, finance is the sole holder and may self-approve
select tests.check('policy back to invoices.approve (self allowed if sole)',
  tests.try('ceo', $q$ update approval_policies set required_permission = 'invoices.approve' where kind = 'invoice' and min_amount is null $q$), 'ok');
select tests.draft_invoice('S3', 'fin', 'client:abc', 3000);
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:S3')));
select tests.check('while management is active, finance cannot approve its own invoice', tests.scalar('fin', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:S3'))), 'ERR:42501');
delete from role_permissions where role_id = tests.id('role:ceo') and permission_id = tests.id('perm:invoices.approve');
select tests.check('with invoices.approve held by finance alone, finance is the only qualified approver and may self-approve (the rule follows the permission, not the job title)',
  tests.scalar('fin', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:S3'))), 'approved');
select tests.check('...recorded as a self-approval by finance', (select (r.self_approved and d.is_self and d.approver_id = tests.id('staff:fin'))::text from approval_requests r join approval_decisions d on d.request_id = r.id where r.entity_id = tests.id('inv:S3')), 'true');
insert into role_permissions (role_id, permission_id) values (tests.id('role:ceo'), tests.id('perm:invoices.approve'));
-- (4) Policies that forbid self-approval win even for a sole approver
select tests.check('payment reversals forbid self-approval even for management as the sole finance.approve holder',
  tests.remember_ok('rev:1', tests.scalar('ceo', format('select payment_record(%L, %L, 800, ''cash'')::text', tests.id('client:abc'), tests.id('acct:nad')))), 'ok');
select tests.remember('rev:req', tests.scalar('ceo', format('select payment_request_reversal(%L, ''reversal'', null, ''Cash miscounted'')::text', tests.id('rev:1'))));
select tests.check('...management cannot approve their own reversal', tests.scalar('ceo', format('select payment_reversal_decide(%L, true)', tests.id('rev:req'))), 'ERR:42501');
select tests.check('...unless management explicitly changes the policy', tests.try('ceo', $q$ update approval_policies set allow_self_approval = true where kind = 'payment_reversal' $q$), 'ok');
select tests.check('...then the sole approver may', tests.scalar('ceo', format('select payment_reversal_decide(%L, true)', tests.id('rev:req'))), 'approved');
select tests.check('...and that self-approval is recorded', (select self_approved::text from approval_requests where entity_table = 'payment_reversals' and entity_id = tests.id('rev:req')), 'true');
update approval_policies set allow_self_approval = false where kind = 'payment_reversal';

-- Thresholds in action: a second approver ---------------------------------------------------------------------------------------------------
select tests.draft_invoice('BIG', 'fin', 'client:abc', 60000);
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:BIG')));
select tests.check('a large invoice needs finance.approve: finance cannot approve it', tests.scalar('fin', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:BIG'))), 'ERR:42501');
select tests.check('the policy needs two approvers but only one qualified person exists, so it says so rather than approving',
  tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:BIG'))), 'ERR:23514');
select tests.add_staff('ceo2', 'ceo');
select tests.check('with a second qualified approver, the first approval keeps the invoice pending',
  tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:BIG'))), 'pending_approval');
select tests.check('...the same person cannot approve twice', tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:BIG'))), 'ERR:23505');
select tests.check('...the request records 1 of 2', (select (select count(*) from approval_decisions d where d.request_id = r.id)::text || '/' || r.required_approvals::text from approval_requests r where r.entity_id = tests.id('inv:BIG')), '1/2');
select tests.check('the second approver completes it', tests.scalar('ceo2', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:BIG'))), 'approved');
select tests.check('...two approvals are on record, neither a self-approval',
  (select count(*)::text || (bool_or(is_self))::text from approval_decisions d join approval_requests r on r.id = d.request_id where r.entity_id = tests.id('inv:BIG') and d.decision = 'approve'), '2false');
select tests.check('...and the request is closed as approved', (select status::text from approval_requests where entity_id = tests.id('inv:BIG')), 'approved');
select tests.draft_invoice('BIG2', 'fin', 'client:abc', 70000);
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:BIG2')));
select tests.check('...(sending back needs a note)', tests.scalar('ceo2', format('select invoice_transition(%L, ''draft'')::text', tests.id('inv:BIG2'))), 'ERR:23514');
select tests.check('...a qualified approver sends it back', tests.scalar('ceo2', format('select invoice_transition(%L, ''draft'', ''Wrong amount'')::text', tests.id('inv:BIG2'))), 'draft');
select tests.check('...and it is on record as rejected', (select status::text from approval_requests where entity_id = tests.id('inv:BIG2') order by requested_at desc limit 1), 'rejected');
select tests.draft_invoice('S4', 'ceo', 'client:abc', 900);
select tests.scalar('ceo', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:S4')));
select tests.check('once a second qualified approver exists, management cannot approve their own invoice either',
  tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:S4'))), 'ERR:42501');

-- Discount above threshold -----------------------------------------------------------------------------------------------------------------------
select tests.add_staff('fin2', 'finance_officer');
select tests.draft_invoice('D1', 'fin', 'client:abc', 2000, 100);
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:D1')));
select tests.check('a discount below the threshold needs only the invoice policy: a second finance officer approves',
  tests.scalar('fin2', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:D1'))), 'approved');
select tests.draft_invoice('D2', 'fin', 'client:abc', 2000, 500);
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:D2')));
select tests.check('a discount of N$500 (>= N$400) also needs discounts.approve: the second finance officer cannot approve it',
  tests.scalar('fin2', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:D2'))), 'ERR:42501');
select tests.check('...management, who holds both permissions, can', tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:D2'))), 'approved');
select tests.check('the discount policy applies to contracts too: a two-approver discount policy keeps a discounted contract pending after one approval',
  tests.try('ceo', $q$ update approval_policies set min_approvers = 2 where kind = 'discount' $q$), 'ok');
select tests.remember('contract:D', tests.scalar('web_lead', format('select contract_create(%L, %L, ''Discounted'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
select tests.scalar('web_lead', format('select contract_add_line(%L, %L, 1, 3000, ''Special'', ''Discounted service'', 600)::text', tests.id('contract:D'), tests.id('svc:web')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:D')));
select tests.check('first approval of the discounted contract', tests.scalar('ceo', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:D'))), 'internal_review');
select tests.check('...second approver completes it', tests.scalar('ceo2', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:D'))), 'approved');
select tests.remember('quote:D', tests.scalar('web_lead', format('select quote_create(%L, %L, ''Discounted quote'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
select tests.scalar('web_lead', format('select quote_add_line(%L, %L, 1, null, null, null, 500)::text', tests.id('quote:D'), tests.id('svc:web')));
select tests.scalar('web_lead', format('select quote_transition(%L, ''pending_approval'')::text', tests.id('quote:D')));
select tests.check('discount policy also applies to quotes: the first approval keeps a discounted quote pending', tests.scalar('ceo', format('select quote_transition(%L, ''approved'')::text', tests.id('quote:D'))), 'pending_approval');
select tests.check('...the second approver completes it', tests.scalar('ceo2', format('select quote_transition(%L, ''approved'')::text', tests.id('quote:D'))), 'approved');
update approval_policies set min_approvers = 1 where kind = 'discount';

-- Contract thresholds ---------------------------------------------------------------------------------------------------------------------------
select tests.check('management can require two approvers for contracts from N$20,000 (division-scoped to Web)',
  tests.try('ceo', format($q$ insert into approval_policies (kind, division_id, min_amount, required_permission, allow_self_approval, min_approvers) values ('contract', %L, 20000, 'contracts.approve', false, 2) $q$, tests.id('div:web'))), 'ok');
select tests.check('a contract of N$25,000 selects it; one of N$9,300 does not', (select min_approvers::text from approval_policy('contract', tests.id('div:web'), 25000)) || (select min_approvers::text from approval_policy('contract', tests.id('div:web'), 9300)), '21');
select tests.check('Tech''s contracts are unaffected', (select min_approvers::text from approval_policy('contract', tests.id('div:tech'), 25000)), '1');

-- Approvals queue visibility -----------------------------------------------------------------------------------------------------------------------
select tests.check('the queue is not readable by people with no approval permission or relationship',
  tests.scalar('web_staff', 'select count(*)::text from approval_requests where kind in (''invoice'', ''contract'', ''refund'', ''payment_reversal'')'), '0');
select tests.check('approvers see the requests they can decide', tests.scalar('ceo', 'select (count(*) > 0)::text from approval_requests where kind = ''invoice'''), 'true');
select tests.check('approval history survives: every decision is append-only', tests.try_owner('delete from approval_decisions') || tests.try_owner('update approval_decisions set note = ''x'''), 'ERR:42501ERR:42501');

select tests.finish();
rollback;
