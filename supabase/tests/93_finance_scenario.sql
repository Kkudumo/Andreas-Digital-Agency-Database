-- Acceptance scenario: ENQUIRY -> LEAD -> CLIENT/CONTACT -> QUOTE -> CONTRACT -> PROJECT -> BILLABLE ITEMS -> INVOICE -> APPROVAL
-- -> ISSUED -> PARTIAL PAYMENT -> PAID. One client, one person, one quote, one contract, one project, one invoice, many payments,
-- all linked by ids; no stage re-types who the client is.
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
insert into services (division_id, name, summary, description, status, published_at) select id, 'Website Development', 's', 'd', 'published', now() from divisions where key = 'web';
insert into tests.ids select 'svc:web', id from services where name = 'Website Development';
select tests.remember('p:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 8000, 'NAD', current_date, 'launch')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web'), true)).status::text $q$);
update finance_settings set vat_registered = true, vat_rate = 15, vat_number = 'VAT-NA-555';

select tests.check('1. the website submits an enquiry',
  ((tests.enq('main', 'Dana Delta', 'dana@deltaretail.example', '+264811000777', 'Delta Retail', (select ada_id from services where name = 'Website Development'), 'We want an online shop')::jsonb ->> 'reference') ~ '^ADA-ENQ-')::text, 'true');
insert into tests.ids select 'lead:1', lead_id from enquiries order by created_at desc limit 1;
select tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:1'), null, 'Delta Retail')::text $q$);
insert into tests.ids select 'client:delta', client_id from leads where id = tests.id('lead:1');
insert into tests.ids select 'contact:dana', cc.id from client_contacts cc where cc.client_id = tests.id('client:delta');
select tests.check('2. Web qualified it: one client, one contact', (select count(*)::text from clients where name_key = client_name_key('Delta Retail')) || (select count(*)::text from client_contacts where client_id = tests.id('client:delta')), '11');

select tests.remember('quote:1', tests.scalar('web_lead', $q$ select quote_create_from_lead((select id from tests.ids where key = 'lead:1'))::text $q$));
select tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), null, 1, 2000, null, 'Hosting set-up')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'approved')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'sent')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'accepted')::text $q$);
select tests.remember('prj:1', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:1'))::text $q$));
select tests.check('3. the accepted quote totals N$10,000 (8,000 catalogue + 2,000 custom)', (select total::text from quotes where id = tests.id('quote:1')), '10000.00');

-- Contract from the quote -----------------------------------------------------------------------------------------------------------------------
select tests.remember('contract:1', tests.scalar('web_lead', $q$ select contract_create_from_quote((select id from tests.ids where key = 'quote:1'))::text $q$));
select tests.check('4. the contract references the same client, contact, quote and (through the quote) the same project',
  (select (c.client_id = tests.id('client:delta') and v.contact_id = tests.id('contact:dana') and c.quote_id = tests.id('quote:1')
           and exists (select 1 from contract_projects cp where cp.contract_id = c.id and cp.project_id = tests.id('prj:1')) and v.total = 10000)::text
   from contracts c join contract_versions v on v.contract_id = c.id where c.id = tests.id('contract:1')), 'true');
select tests.scalar('web_lead', $q$ select contract_set_terms((select id from tests.ids where key = 'contract:1'), '{"payment_terms_days": 21, "end_date": null}')::text $q$);
select tests.scalar('web_lead', $q$ select contract_transition((select id from tests.ids where key = 'contract:1'), 'internal_review')::text $q$);
select tests.scalar('ceo', $q$ select contract_transition((select id from tests.ids where key = 'contract:1'), 'approved')::text $q$);
select tests.scalar('web_lead', $q$ select contract_transition((select id from tests.ids where key = 'contract:1'), 'sent')::text $q$);
select tests.scalar('web_lead', $q$ select contract_transition((select id from tests.ids where key = 'contract:1'), 'signed')::text $q$);
select tests.check('5. the contract is active', tests.scalar('web_lead', $q$ select contract_transition((select id from tests.ids where key = 'contract:1'), 'active')::text $q$), 'active');

-- The catalogue changes; nothing already agreed does ---------------------------------------------------------------------------------------------
select tests.remember('p:web2', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 9500, 'NAD', current_date + 1, 'increase')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web2'), true)).status::text $q$);

-- Billing in two steps: the web build now, hosting later -------------------------------------------------------------------------------------------
insert into tests.ids select 'cl:web', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.service_id is not null;
insert into tests.ids select 'cl:host', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.service_id is null;
select tests.remember('bi:1', tests.scalar('fin', $q$ select billable_from_contract((select id from tests.ids where key = 'contract:1'), (select id from tests.ids where key = 'cl:web'))::text $q$));
select tests.remember('inv:1', tests.scalar('fin', $q$ select invoice_create(array[(select id from tests.ids where key = 'bi:1')])::text $q$));
select tests.check('6. invoice 1 bills the agreed N$8,000 + 15% VAT, not the new catalogue price; payment terms come from the contract',
  (select (subtotal = 8000 and tax_total = 1200 and total = 9200 and payment_terms_days = 21 and contract_id = tests.id('contract:1') and project_id is null
           and billing_contact_id = tests.id('contact:dana'))::text from invoices where id = tests.id('inv:1')), 'true');
select tests.scalar('fin', $q$ select invoice_transition((select id from tests.ids where key = 'inv:1'), 'pending_approval')::text $q$);
select tests.check('7. the requester cannot approve; management does', tests.scalar('fin', $q$ select invoice_transition((select id from tests.ids where key = 'inv:1'), 'approved')::text $q$) || tests.scalar('ceo', $q$ select invoice_transition((select id from tests.ids where key = 'inv:1'), 'approved')::text $q$), 'ERR:42501approved');
select tests.check('8. finance issues it', tests.scalar('fin', $q$ select invoice_transition((select id from tests.ids where key = 'inv:1'), 'issued')::text $q$), 'issued');
select tests.check('8b. ...with the legal snapshot and the contract''s 21-day terms', (select client_name_snapshot || '|' || seller_vat_number_snapshot || '|' || (due_date - issue_date)::text from invoices where id = tests.id('inv:1')), 'Delta Retail|VAT-NA-555|21');

-- Payments: two part payments settle the invoice -----------------------------------------------------------------------------------------------------
select tests.remember('pay:1', tests.scalar('fin', format('select payment_record(%L, %L, 4000, ''bank_transfer'', current_date, ''EFT-1'', %L)::text', tests.id('client:delta'), tests.id('acct:nad'), tests.id('inv:1'))));
select tests.check('9. a part payment leaves the derived balance 5,200 and the invoice partially paid',
  tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:1'))) || (select status::text from invoices where id = tests.id('inv:1')), '5200.00partially_paid');
select tests.remember('pay:2', tests.scalar('fin', format('select payment_record(%L, %L, 5200, ''bank_transfer'', current_date, ''EFT-2'')::text', tests.id('client:delta'), tests.id('acct:nad'))));
select tests.scalar('fin', format('select payment_allocate(%L, %L)::text', tests.id('pay:2'), tests.id('inv:1')));
select tests.check('10. the second payment, allocated, settles it: paid, balance 0', tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:1'))) || (select status::text from invoices where id = tests.id('inv:1')), '0.00paid');

-- Second billing step -----------------------------------------------------------------------------------------------------------------------------
select tests.remember('bi:2', tests.scalar('fin', $q$ select billable_from_contract((select id from tests.ids where key = 'contract:1'), (select id from tests.ids where key = 'cl:host'))::text $q$));
select tests.remember('inv:2', tests.scalar('fin', $q$ select invoice_create(array[(select id from tests.ids where key = 'bi:2')])::text $q$));
select tests.check('11. the whole contract is now billed: nothing more can be billed from it',
  tests.scalar('fin', $q$ select billable_from_contract((select id from tests.ids where key = 'contract:1'), (select id from tests.ids where key = 'cl:web'))::text $q$) || tests.scalar('fin', $q$ select billable_from_contract((select id from tests.ids where key = 'contract:1'), (select id from tests.ids where key = 'cl:host'))::text $q$), 'ERR:23514ERR:23514');

-- The chain: one of each, all linked by ids ---------------------------------------------------------------------------------------------------------
select tests.check('12. ONE client, ONE person behind the contact, ONE quote, ONE contract, ONE project',
  (select count(*)::text from clients where name_key = client_name_key('Delta Retail')) || (select count(*)::text from people where email = 'dana@deltaretail.example')
  || (select count(*)::text from quotes where client_id = tests.id('client:delta')) || (select count(*)::text from contracts where client_id = tests.id('client:delta'))
  || (select count(*)::text from projects where client_id = tests.id('client:delta')), '11111');
select tests.check('13. the invoices and payments point at that same client and contract by id',
  (select (count(*) = 2 and count(distinct client_id) = 1 and bool_and(contract_id = tests.id('contract:1')))::text from invoices where client_id = tests.id('client:delta'))
  || (select (count(*) = 2 and count(distinct client_id) = 1)::text from payments where client_id = tests.id('client:delta')), 'truetrue');
select tests.check('14. nothing in the chain stores the client''s name, email or phone (only the documented issue snapshot)',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns
   where table_schema = 'public' and table_name in ('contracts', 'contract_versions', 'contract_lines', 'billable_items', 'invoices', 'invoice_lines', 'payments', 'payment_allocations', 'payment_reversals')
     and column_name ~ '(name|email|phone)' and column_name not like '%\_snapshot' and column_name not in ('description')), 'none');

-- 360 views are authorisation slices of the same records -----------------------------------------------------------------------------------------------
create temp table c360 as select tests.scalar('ceo', format('select client_360(%L)::text', tests.id('client:delta')))::jsonb as j;
select tests.check('15. client 360 (management): contract, two invoices, two payments, derived totals (only issued invoices count as invoiced)',
  (select (jsonb_array_length(j -> 'contracts') = 1 and jsonb_array_length(j -> 'invoices') = 2 and jsonb_array_length(j -> 'payments') = 2
           and (j -> 'finance_summary' ->> 'invoiced')::numeric = 9200 and (j -> 'finance_summary' ->> 'paid')::numeric = 9200
           and (j -> 'finance_summary' ->> 'outstanding')::numeric = 0)::text from c360), 'true');
create temp table c360_web as select tests.scalar('web_lead', format('select client_360(%L)::text', tests.id('client:delta')))::jsonb as j;
select tests.check('16. the division lead sees contracts and invoices of their division but NO payments (a narrower slice of the same records)',
  (select (jsonb_array_length(j -> 'contracts') = 1 and jsonb_array_length(j -> 'invoices') = 2 and jsonb_array_length(j -> 'payments') = 0)::text from c360_web), 'true');
create temp table p360 as select tests.scalar('ceo', format('select project_360(%L)::text', tests.id('prj:1')))::jsonb as j;
select tests.check('17. project 360 shows the contract that covers it', (select (jsonb_array_length(j -> 'contracts') = 1 and (j -> 'contracts' -> 0 ->> 'total')::numeric = 10000)::text from p360), 'true');
select tests.check('18. the agreed prices are untouched by the later catalogue change (still 8000 and 2000)',
  (select string_agg(unit_price::text, ',' order by unit_price) from invoice_lines where invoice_id in (tests.id('inv:1'), tests.id('inv:2'))), '2000.00,8000.00');
select tests.check('19. the catalogue itself did change', (select amount::text from price_on(tests.id('svc:web'), current_date + 1)), '9500.00');
select tests.check('20. every step is on record: contract trail, approvals and audit',
  (select count(*)::text from contract_status_history where contract_id = tests.id('contract:1') and scope = 'contract') || '/' ||
  (select count(*)::text from approval_requests where status = 'approved' and kind in ('quote', 'contract', 'invoice')) || '/' ||
  (select (count(*) > 20)::text from audit_log where table_name in ('contracts', 'contract_versions', 'invoices', 'payments', 'payment_allocations')), '6/3/true');

select tests.finish();
rollback;
