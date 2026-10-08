-- Invoices: Contract/Project -> Billable items -> Invoice -> Approval -> Issued, with snapshots and locking.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
insert into tests.ids select 'cl:web', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.unit_price = 5000;
insert into tests.ids select 'cl:cctv', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.unit_price = 1200;

-- Billable items from the contract ------------------------------------------------------------------------------------------------------------------
select tests.check('the fixture contract is active', (select status::text from contracts where id = tests.id('contract:1')), 'active');
select tests.check('a division lead (invoices.view only) cannot create billable items',
  tests.scalar('web_lead', format('select billable_from_contract(%L, %L)::text', tests.id('contract:1'), tests.id('cl:web'))), 'ERR:42501');
select tests.check('web staff cannot see the contract at all', tests.scalar('web_staff', format('select billable_from_contract(%L, %L)::text', tests.id('contract:1'), tests.id('cl:web'))), 'ERR:P0002');
select tests.remember('bi:web', tests.scalar('fin', format('select billable_from_contract(%L, %L)::text', tests.id('contract:1'), tests.id('cl:web'))));
select tests.check('the billable item carries the CONTRACTED price, client and service (references, not copies of identity)',
  (select (b.unit_price = 5000 and b.quantity = 1 and b.client_id = tests.id('client:abc') and b.contract_id = tests.id('contract:1') and b.service_id = tests.id('svc:web') and b.source = 'contract')::text from billable_items b where b.id = tests.id('bi:web')), 'true');
select tests.check('the same line cannot be billed twice', tests.scalar('fin', format('select billable_from_contract(%L, %L)::text', tests.id('contract:1'), tests.id('cl:web'))), 'ERR:23514');
select tests.check('over-billing a line is refused', tests.scalar('fin', format('select billable_from_contract(%L, %L, 5)::text', tests.id('contract:1'), tests.id('cl:cctv'))), 'ERR:23514');
select tests.remember('bi:cctv1', tests.scalar('fin', format('select billable_from_contract(%L, %L, 2)::text', tests.id('contract:1'), tests.id('cl:cctv'))));
select tests.check('a partial quantity carries its share of the line discount (N$500 x 2/4)', (select discount_amount::text from billable_items where id = tests.id('bi:cctv1')), '250.00');
select tests.remember('bi:cctv2', tests.scalar('fin', format('select billable_from_contract(%L, %L)::text', tests.id('contract:1'), tests.id('cl:cctv'))));
select tests.check('the last portion takes the rest of the discount, so billed discounts add up to the contract exactly',
  (select sum(discount_amount)::text || '/' || round(sum(quantity * unit_price - discount_amount), 2)::text from billable_items where contract_line_origin_id = (select origin_line_id from contract_lines where id = tests.id('cl:cctv'))), '500.00/4300.00');

-- Later catalogue price changes do not alter the contract or its billable items --------------------------------------------------------------------
select tests.remember('price:web2', tests.scalar('web_lead', format('select price_propose(%L, 6000, ''NAD'', current_date + 1, ''Increase'')::text', tests.id('svc:web'))));
select tests.scalar('ceo', format('select (price_decide(%L, true)).status::text', tests.id('price:web2')));
select tests.check('control: the catalogue price DID change for tomorrow', (select amount::text from price_on(tests.id('svc:web'), current_date + 1)), '6000.00');

-- Invoice from billable items ----------------------------------------------------------------------------------------------------------------------
select tests.check('web staff cannot invoice (they cannot even see the item)', tests.scalar('web_staff', format('select invoice_create(array[%L]::uuid[])::text', tests.id('bi:web'))), 'ERR:P0002');
select tests.check('a division lead cannot create invoices', tests.scalar('web_lead', format('select invoice_create(array[%L]::uuid[])::text', tests.id('bi:web'))), 'ERR:42501');
select tests.check('an empty invoice is refused', tests.scalar('fin', 'select invoice_create(array[]::uuid[])::text'), 'ERR:23514');
select tests.remember('inv:1', tests.scalar('fin', format('select invoice_create(array[%L, %L]::uuid[])::text', tests.id('bi:web'), tests.id('bi:cctv1'))));
select tests.check('the invoice has an ADA-INV ID and references the SAME client, contract, division and billing contact (the contract''s authorised contact)',
  (select (ada_id ~ '^ADA-INV-\d{4}-\d{4}$' and client_id = tests.id('client:abc') and contract_id = tests.id('contract:1') and division_id = tests.id('div:web')
           and billing_contact_id = tests.id('contact:john') and status = 'draft' and currency = 'NAD' and payment_terms_days = 30)::text from invoices where id = tests.id('inv:1')), 'true');
select tests.check('contract -> invoice preserves contracted prices and discounts (5000 + 2x1200 - 250)',
  (select string_agg(unit_price::text || 'x' || quantity::text || '-' || discount_amount::text, ',' order by unit_price desc) || '/' || max(i.total)::text from invoice_lines l join invoices i on i.id = l.invoice_id where l.invoice_id = tests.id('inv:1')), '5000.00x1.00-0.00,1200.00x2.00-250.00/7150.00');
select tests.check('the invoice lines point at the catalogue price versions the contract used',
  (select count(*)::text from invoice_lines where invoice_id = tests.id('inv:1') and price_id in (tests.id('price:web'), tests.id('price:cctv'))), '2');
select tests.check('billable items on an invoice are no longer open', (select string_agg(status::text, ',') from billable_items where id in (tests.id('bi:web'), tests.id('bi:cctv1'))), 'invoiced,invoiced');
select tests.check('an item already invoiced cannot go on another invoice', tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', tests.id('bi:web'))), 'ERR:23514');
select tests.check('an invoiced item cannot be voided', tests.scalar('fin', format('select billable_void(%L, ''x'')::text', tests.id('bi:web'))), 'ERR:23514');
select tests.check('billable items are snapshots: editing one is refused even for the owner', tests.try_owner(format('update billable_items set unit_price = 1 where id = %L', tests.id('bi:web'))), 'ERR:42501');

-- Submit, approval, issue --------------------------------------------------------------------------------------------------------------------------
select tests.check('a division lead cannot submit (no invoices.update/create)', tests.scalar('web_lead', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:1'))), 'ERR:42501');
select tests.check('finance submits for approval', tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:1'))), 'pending_approval');
select tests.check('the invoice is in the shared approvals queue', (select count(*)::text from approval_requests where kind = 'invoice' and status = 'pending' and entity_ada_id = (select ada_id from invoices where id = tests.id('inv:1'))), '1');
select tests.check('lines cannot be changed while awaiting approval', tests.scalar('fin', format('select invoice_add_lines(%L, array[%L]::uuid[])::text', tests.id('inv:1'), tests.id('bi:cctv2'))), 'ERR:42501');
select tests.check('the content is locked while awaiting approval (owner)', tests.try_owner(format('update invoices set notes = ''x'' where id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('the requester cannot approve their own invoice while another qualified approver exists (separation of duties)',
  tests.scalar('fin', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:1'))), 'ERR:42501');
select tests.check('an invoice cannot be issued before it is approved', tests.scalar('fin', format('select invoice_transition(%L, ''issued'')::text', tests.id('inv:1'))), 'ERR:23514');
select tests.check('an approver must say why to send it back', tests.scalar('ceo', format('select invoice_transition(%L, ''draft'')::text', tests.id('inv:1'))), 'ERR:23514');
select tests.check('management sends it back', tests.scalar('ceo', format('select invoice_transition(%L, ''draft'', ''Check the PO number'')::text', tests.id('inv:1'))), 'draft');
select tests.check('...recorded as a rejection in the approvals history', (select status::text from approval_requests where kind = 'invoice' order by requested_at desc limit 1), 'rejected');
select tests.scalar('fin', format('select invoice_set_terms(%L, ''{"po_reference": "PO-778", "payment_terms_days": 14}'')::text', tests.id('inv:1')));
select tests.check('unknown invoice terms are refused', tests.scalar('fin', format('select invoice_set_terms(%L, ''{"total": 1}'')::text', tests.id('inv:1'))), 'ERR:22023');
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:1')));
select tests.check('the requester can withdraw', tests.scalar('fin', format('select invoice_transition(%L, ''draft'')::text', tests.id('inv:1'))), 'draft');
select tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', tests.id('inv:1')));
select tests.check('management approves', tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', tests.id('inv:1'))), 'approved');
select tests.check('an approver is recorded', (select (approved_by = tests.id('staff:ceo') and approved_at is not null)::text from invoices where id = tests.id('inv:1')), 'true');
select tests.check('only invoices.issue holders can issue', tests.scalar('web_lead', format('select invoice_transition(%L, ''issued'')::text', tests.id('inv:1'))), 'ERR:42501');
update finance_settings set vat_registered = true, vat_number = 'VAT-NA-123', vat_rate = 15;
select tests.check('finance issues the invoice', tests.scalar('fin', format('select invoice_transition(%L, ''issued'')::text', tests.id('inv:1'))), 'issued');
select tests.check('issue date and due date follow the invoice''s own payment terms (14 days)', (select (issue_date = current_date and due_date = current_date + 14)::text from invoices where id = tests.id('inv:1')), 'true');
select tests.check('the invoice took the legal/billing SNAPSHOT at issue',
  (select concat_ws('|', client_name_snapshot, billing_contact_name_snapshot, billing_contact_email_snapshot, seller_vat_number_snapshot) from invoices where id = tests.id('inv:1')), 'ABC Company|John Director|john@abc.example|VAT-NA-123');
select tests.check('invoice 1 was created before VAT was switched on, so it carries no tax (the rate in force at creation is what counts)',
  (select tax_total::text || '/' || total::text from invoices where id = tests.id('inv:1')), '0.00/7150.00');

-- Snapshots survive changes to the central records -------------------------------------------------------------------------------------------------
update clients set name = 'ABC Renamed Holdings' where id = tests.id('client:abc');
update people set full_name = 'Jonathan Director', email = 'jon@abc.example' where id = (select person_id from client_contacts where id = tests.id('contact:john'));
select tests.check('renaming the client / contact does not change the issued invoice',
  (select concat_ws('|', client_name_snapshot, billing_contact_name_snapshot, billing_contact_email_snapshot) from invoices where id = tests.id('inv:1')), 'ABC Company|John Director|john@abc.example');
select tests.check('...while the live record shows the new name (one record, referenced)', (select name from clients where id = tests.id('client:abc')), 'ABC Renamed Holdings');

-- Locked after issue, for every caller ---------------------------------------------------------------------------------------------------------------
select tests.check('an issued invoice''s total is immutable (owner)', tests.try_owner(format('update invoices set total = 1 where id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('...its snapshots', tests.try_owner(format('update invoices set client_name_snapshot = ''x'' where id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('...its due date', tests.try_owner(format('update invoices set due_date = current_date + 90 where id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('...its lines (update)', tests.try_owner(format('update invoice_lines set unit_price = 1 where invoice_id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('...(delete)', tests.try_owner(format('delete from invoice_lines where invoice_id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('...(insert)', tests.try_owner(format('insert into invoice_lines (invoice_id, billable_item_id, description, quantity, unit_price) values (%L, %L, ''x'', 1, 1)', tests.id('inv:1'), tests.id('bi:cctv2'))), 'ERR:42501');
select tests.check('an invoice cannot be deleted', tests.try_owner(format('delete from invoices where id = %L', tests.id('inv:1'))), 'ERR:42501');
select tests.check('its client cannot be changed', tests.try_owner(format('update invoices set client_id = %L where id = %L', tests.id('client:C_web'), tests.id('inv:1'))), 'ERR:42501');
select tests.check('the status graph is enforced for every caller (issued -> draft)', tests.try_owner(format('update invoices set status = ''draft'' where id = %L', tests.id('inv:1'))), 'ERR:23514');
select tests.check('users cannot write invoices directly', tests.try('fin', $q$ update invoices set status = 'paid' $q$) || tests.try('fin', $q$ update invoice_lines set quantity = 9 $q$) || tests.try('fin', $q$ insert into billable_items (client_id, division_id, source, description, quantity, unit_price, currency, manual_reason) select client_id, division_id, 'manual', 'x', 1, 1, 'NAD', 'x' from invoices $q$), 'ERR:42501ERR:42501ERR:42501');
select tests.check('after a later catalogue price change the issued invoice is unchanged (5000 and 1200)',
  (select string_agg(unit_price::text, ',' order by unit_price) from invoice_lines where invoice_id = tests.id('inv:1')), '1200.00,5000.00');

-- Second invoice with VAT -------------------------------------------------------------------------------------------------------------------------
select tests.remember('inv:2', tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', tests.id('bi:cctv2'))));
select tests.check('VAT in force at creation is applied per line: 2 x 1200 - 250 = 2150 net, 322.50 tax',
  (select subtotal::text || '/' || discount_total::text || '/' || tax_total::text || '/' || total::text from invoices where id = tests.id('inv:2')), '2400.00/250.00/322.50/2472.50');
select tests.check('a draft invoice can be cancelled (reason required)', tests.scalar('fin', format('select invoice_void(%L, null)::text', tests.id('inv:2'))), 'ERR:23514');
select tests.scalar('fin', format('select invoice_void(%L, ''Wrong client reference'')::text', tests.id('inv:2')));
select tests.check('cancelling releases the billable item', (select status::text from billable_items where id = tests.id('bi:cctv2')), 'open');
select tests.check('...the cancelled invoice keeps its lines on record, deactivated', (select count(*)::text from invoice_lines where invoice_id = tests.id('inv:2') and not active), '1');
select tests.check('...and the released item can be invoiced again', tests.remember_ok('inv:3', tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', tests.id('bi:cctv2')))), 'ok');
select tests.check('a cancelled invoice is terminal', tests.try_owner(format('update invoices set status = ''draft'' where id = %L', tests.id('inv:2'))), 'ERR:23514');
select tests.check('issued invoices need invoices.void to cancel', tests.scalar('fin', format('select invoice_void(%L, ''x'')::text', tests.id('inv:1'))), 'ERR:42501');

-- Project billing and manual charges ---------------------------------------------------------------------------------------------------------------
select tests.check('a project covered by an active contract must be billed through the contract',
  tests.scalar('fin', format('select billable_from_project((select id from project_services where project_id = %L limit 1))::text', tests.id('project:abc'))), 'ERR:23514');
select tests.remember('project:cctv', tests.scalar('tech_lead', format('insert into projects (client_id, lead_division_id, name) values (%L, %L, ''ABC CCTV'') returning id::text', tests.id('client:abc'), tests.id('div:tech'))));
select tests.try('tech_lead', format('select project_add_service(%L, %L, 6)', tests.id('project:cctv'), tests.id('svc:cctv')));
select tests.check('a contract-less project is billed from its service lines at the price snapshot',
  tests.remember_ok('bi:proj', tests.scalar('fin', format('select billable_from_project((select id from project_services where project_id = %L limit 1), 4)::text', tests.id('project:cctv')))), 'ok');
select tests.check('...(project, service and price version are references)', (select (project_id = tests.id('project:cctv') and service_id = tests.id('svc:cctv') and price_id = tests.id('price:cctv') and unit_price = 1200 and division_id = tests.id('div:tech'))::text from billable_items where id = tests.id('bi:proj')), 'true');
select tests.check('the remaining 2 can be billed but not 3', tests.scalar('fin', format('select billable_from_project((select id from project_services where project_id = %L limit 1), 3)::text', tests.id('project:cctv'))), 'ERR:23514');
select tests.check('a manual charge needs a reason', tests.scalar('fin', format('select billable_manual(%L, %L, ''Call-out fee'', 1, 300, null)::text', tests.id('client:abc'), tests.id('div:tech'))), 'ERR:23514');
select tests.check('a manual charge is recorded with its reason', tests.remember_ok('bi:manual', tests.scalar('fin', format('select billable_manual(%L, %L, ''Call-out fee'', 1, 300, ''Emergency visit'')::text', tests.id('client:abc'), tests.id('div:tech')))), 'ok');
select tests.check('items from several divisions need an explicit invoicing division',
  tests.scalar('fin', format('select invoice_create(array[%L, %L]::uuid[])::text', tests.id('bi:proj'), tests.id('bi:cctv2'))), 'ERR:23514');
select tests.check('...which can be given', tests.remember_ok('inv:4', tests.scalar('fin', format('select invoice_create(array[%L, %L]::uuid[], null, %L)::text', tests.id('bi:proj'), tests.id('bi:manual'), tests.id('div:tech')))), 'ok');

-- Visibility -----------------------------------------------------------------------------------------------------------------------------------
select tests.check('web lead sees Web''s invoice; Tech lead does not',
  tests.scalar('web_lead', format('select count(*)::text from invoices where id = %L', tests.id('inv:1'))) || tests.scalar('tech_lead', format('select count(*)::text from invoices where id = %L', tests.id('inv:1'))), '10');
select tests.check('cross-division: Tech lead sees no Web invoices, lines or billable items',
  tests.scalar('tech_lead', format('select (select count(*) from invoices where division_id = %L)::text || (select count(*) from invoice_lines where invoice_id = %L) || (select count(*) from billable_items where division_id = %L)', tests.id('div:web'), tests.id('inv:1'), tests.id('div:web'))), '000');
select tests.check('web staff, auditor and recruiter see no invoices',
  tests.scalar('web_staff', 'select count(*)::text from invoices') || tests.scalar('audit', 'select count(*)::text from invoices') || tests.scalar('recruiter', 'select count(*)::text from invoices'), '000');
select tests.check('a hidden invoice is indistinguishable from a missing one (transition)', tests.same_for('tech_lead', $q$ select invoice_transition(%L, 'pending_approval')::text $q$, tests.id('inv:1'), gen_random_uuid()), 'same');
select tests.check('...(void)', tests.same_for('tech_lead', $q$ select invoice_void(%L, 'probe')::text $q$, tests.id('inv:1'), gen_random_uuid()), 'same');
select tests.check('...(terms)', tests.same_for('tech_lead', $q$ select invoice_set_terms(%L, '{}')::text $q$, tests.id('inv:1'), gen_random_uuid()), 'same');
select tests.check('...(create from a hidden billable item)', tests.same_for('web_staff', $q$ select invoice_create(array[%L]::uuid[])::text $q$, tests.id('bi:web'), gen_random_uuid()), 'same');
select tests.check('...(helper)', tests.same_for('tech_lead', $q$ select can_view_invoice(%L)::text $q$, tests.id('inv:1'), gen_random_uuid()), 'same');
select tests.check('control: probes tell a visible invoice from a missing one', left(tests.same_for('web_lead', $q$ select can_view_invoice(%L)::text $q$, tests.id('inv:1'), gen_random_uuid()), 9), 'DIFFERENT');

-- Billing continuity across contract amendments -------------------------------------------------------------------------------------------------
select tests.scalar('web_lead', format('select contract_amend(%L, ''Add storage'')::text', tests.id('contract:1')));
select tests.scalar('web_lead', format('select contract_add_line(%L, null, 1, 900, null, ''Cloud storage'')::text', tests.id('contract:1')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:1')));
select tests.scalar('ceo', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:1')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''sent'')::text', tests.id('contract:1')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''signed'')::text', tests.id('contract:1')));
select tests.check('after the amendment, lines already fully billed stay fully billed (billing follows the line across versions)',
  tests.scalar('fin', format('select billable_from_contract(%L, (select cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = %L and v.version_no = 2 and cl.unit_price = 5000))::text', tests.id('contract:1'), tests.id('contract:1'))), 'ERR:23514');
select tests.check('...and the new line can be billed', tests.try('fin', format('select billable_from_contract(%L, (select cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = %L and v.version_no = 2 and cl.unit_price = 900))', tests.id('contract:1'), tests.id('contract:1'))), 'ok');
select tests.check('a terminated contract can no longer be billed',
  tests.scalar('ceo', format('select contract_transition(%L, ''terminated'', ''End'')::text', tests.id('contract:1'))) || tests.scalar('fin', format('select billable_from_contract(%L, %L)::text', tests.id('contract:1'), tests.id('cl:web'))), 'terminatedERR:23514');

-- Audit and structure ---------------------------------------------------------------------------------------------------------------------------
select tests.check('invoice lifecycle changes are audited', (select (count(*) >= 6)::text from audit_log where table_name = 'invoices' and record_ada_id = (select ada_id from invoices where id = tests.id('inv:1'))), 'true');
select tests.check('invoice tables hold no client/contact identity except the documented issue snapshots',
  (select coalesce(string_agg(table_name || '.' || column_name, ',' order by table_name, column_name), 'none') from information_schema.columns
   where table_schema = 'public' and table_name in ('invoices', 'invoice_lines', 'billable_items') and column_name ~ '(name|email|phone)' and column_name not like '%\_snapshot' and column_name not in ('description')), 'none');
select tests.check('every invoice reference to client/contact/contract/project/division is a foreign key to the central record',
  (select coalesce(string_agg(a.attrelid::regclass || '.' || a.attname, ',' order by a.attname), 'none') from pg_attribute a where a.attrelid in ('invoices'::regclass, 'billable_items'::regclass)
   and a.attname in ('client_id', 'billing_contact_id', 'contract_id', 'project_id', 'division_id', 'service_id', 'price_id') and not exists
   (select 1 from pg_constraint c where c.conrelid = a.attrelid and c.contype = 'f' and c.conkey[1] = a.attnum)), 'none');
select tests.check('the registry knows every invoice', tests.unregistered_tables(), 'none');

select tests.finish();
rollback;
