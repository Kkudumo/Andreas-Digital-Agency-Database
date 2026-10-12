-- PERMANENT: Credit notes - identity, references instead of copies, caps (per invoice line and per invoice), lifecycle and approval, issue snapshot and
-- immutability, application to the invoice and to others, derived (never stored) balances, invoice status following payments + credit, classification
-- inheritance and non-disclosure, search, audit.
-- (Every command runs in its own statement, and the checks read the state afterwards.)
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
select tests.finance_world();
insert into tests.ids values ('x:random', gen_random_uuid());
create table tests.outs (k text primary key, v text);
create function tests.o(p_key text, p_val text) returns void language sql as $$ insert into tests.outs values (p_key, p_val) on conflict (k) do update set v = excluded.v $$;
create function tests.g(p_key text) returns text language sql stable as $$ select v from tests.outs where k = p_key $$;
-- an issued invoice of one manual line: quantity q at price p (finance prepares, management approves, finance issues)
create function tests.inv_qty(p_key text, p_client text, p_qty numeric, p_price numeric) returns text language plpgsql as $$
declare v_client uuid := tests.id(p_client); v_bi text; v_inv text; v_person uuid;
begin
  if not exists (select 1 from client_contacts where client_id = v_client and is_active) then
    insert into people (full_name, email) values ('Billing ' || p_key, lower(p_key) || '.billing@example.test') returning id into v_person;
    insert into client_contacts (client_id, person_id, is_billing, is_primary) values (v_client, v_person, true, true);
  end if;
  v_bi := tests.scalar('fin', format('select billable_manual(%L, %L, %L, %s, %s, ''test charge'')::text', v_client, tests.id('div:web'), 'Licences ' || p_key, p_qty, p_price));
  v_inv := tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', v_bi));
  perform tests.remember('inv:' || p_key, v_inv);
  perform tests.scalar('fin', format($q$ select invoice_transition(%L, 'pending_approval')::text $q$, v_inv));
  perform tests.scalar('ceo', format($q$ select invoice_transition(%L, 'approved')::text $q$, v_inv));
  perform tests.scalar('fin', format($q$ select invoice_transition(%L, 'issued')::text $q$, v_inv));
  insert into tests.ids select 'il:' || p_key, id from invoice_lines where invoice_id = v_inv::uuid;
  return v_inv;
end $$;
create function tests.cn(p_user text, p_key text, p_inv text, p_reason text default 'billing_error', p_note text default null) returns text language plpgsql as $$
declare v text;
begin
  v := tests.scalar(p_user, format($q$ select credit_note_create(%L, %L, %L)::text $q$, tests.id('inv:' || p_inv), p_reason, p_note));
  if v is null or v like 'ERR:%' then return coalesce(v, 'NULL'); end if;
  insert into tests.ids values ('cn:' || p_key, v::uuid) on conflict (key) do update set id = excluded.id;
  return v;
end $$;
create function tests.cnl(p_user text, p_cn text, p_invline text, p_qty numeric default null) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select credit_note_add_line(%L, %L, %s)::text $q$, tests.id('cn:' || p_cn), tests.id('il:' || p_invline), coalesce(p_qty::text, 'null')))
$$;
create function tests.cnc(p_user text, p_cn text, p_desc text, p_qty numeric, p_price numeric) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select credit_note_add_custom_line(%L, %L, %s, %s)::text $q$, tests.id('cn:' || p_cn), p_desc, p_qty, p_price))
$$;
create function tests.cns(p_user text, p_cn text, p_to text, p_note text default null) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select credit_note_transition(%L, %L, %L)::text $q$, tests.id('cn:' || p_cn), p_to, p_note))
$$;
-- a credit note taken all the way to issued
create function tests.cn_issued(p_key text, p_inv text, p_invline text, p_qty numeric default null) returns text language plpgsql as $$
begin
  perform tests.cn('fin', p_key, p_inv);
  perform tests.cnl('fin', p_key, p_invline, p_qty);
  perform tests.cns('fin', p_key, 'pending_approval');
  perform tests.cns('ceo', p_key, 'approved');
  return tests.cns('fin', p_key, 'issued');
end $$;
create function tests.bal(p_inv text) returns text language sql stable as $$
  select (select balance::text || '/' || coalesce(credited, 0)::text || '/' || status::text from invoice_balances where invoice_id = tests.id('inv:' || p_inv))
$$;

select tests.inv_qty('d1', 'client:abc', 1, 1000);
select tests.inv_qty('q4', 'client:abc', 4, 250);
select tests.inv_qty('d2', 'client:abc', 1, 500);

-- 1. Identity, references ----------------------------------------------------------------------------------------------------------------------------
select tests.cn('fin', 'a', 'd1', 'price_adjustment', 'agreed reduction');
select tests.check('1. a credit note is created as a draft against an issued invoice: ADA-CRN id; client, division and currency come from the invoice; registered with an institutional id',
  (select (ada_id ~ '^ADA-CRN-2026-' and status = 'draft' and invoice_id = tests.id('inv:d1') and client_id = tests.id('client:abc') and division_id = tests.id('div:web') and currency = 'NAD' and total = 0
           and exists (select 1 from entity_registry r where r.table_name = 'credit_notes' and r.entity_id = c.id))::text from credit_notes c where c.id = tests.id('cn:a')), 'true');
select tests.check('2. creating is refused without credit_notes.create (the division lead may see the invoice but not credit it; division staff, suspended staff and an outsider cannot even see it), for an invoice that is not issued, for an unknown reason, and for "other" without a note',
  tests.cn('web_lead', 'z1', 'd1') || tests.cn('web_staff', 'z2', 'd1') || tests.cn('suspended', 'z3', 'd1') || tests.cn('outsider', 'z4', 'd1') || '|' ||
  tests.cn('fin', 'z5', 'd1', 'nonsense') || tests.cn('fin', 'z6', 'd1', 'other'), 'ERR:42501ERR:P0002ERR:P0002ERR:P0002|ERR:23514ERR:23514');
select tests.remember('inv:draft', tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', tests.scalar('fin', format('select billable_manual(%L, %L, ''Unissued'', 1, 10, ''t'')::text', tests.id('client:abc'), tests.id('div:web'))))));
select tests.check('3. a draft invoice cannot be credited', tests.cn('fin', 'z7', 'draft'), 'ERR:23514');

-- 2. Lines, totals, caps -------------------------------------------------------------------------------------------------------------------------------
select tests.o('l1', tests.cnl('fin', 'a', 'd1'));
select tests.check('4. a line taken from an invoice line copies its price and tax rate; the whole quantity by default; totals are derived',
  (tests.g('l1') ~ '^[0-9a-f-]{36}$')::text || (select (quantity = 1 and unit_price = 1000 and total = 1000.00)::text from credit_note_lines l join credit_notes c on c.id = l.credit_note_id where c.id = tests.id('cn:a')), 'truetrue');
select tests.o('l1b', tests.cnl('fin', 'a', 'd1'));
select tests.check('5. the same invoice line cannot be credited twice beyond its quantity', tests.g('l1b'), 'ERR:23514');
select tests.cn('fin', 'b', 'q4');
select tests.o('p1', tests.cnl('fin', 'b', 'q4', 3));
select tests.o('p2', tests.cnl('fin', 'b', 'q4', 2));
select tests.check('6. a part quantity is allowed (3 of 4) and a second line may not exceed the rest', (tests.g('p1') ~ '^[0-9a-f-]{36}$')::text || '|' || tests.g('p2') || '|' || (select total::text from credit_notes where id = tests.id('cn:b')), 'true|ERR:23514|750.00');
select tests.o('c1', tests.cnc('fin', 'b', 'Goodwill', 1, 400));
select tests.check('7. a free-form line is allowed, but a credit note over the invoice total is refused at submission',
  (tests.g('c1') ~ '^[0-9a-f-]{36}$')::text || '|' || tests.cns('fin', 'b', 'pending_approval'), 'true|ERR:23514');
select tests.o('rm', tests.scalar('fin', format('select credit_note_remove_line(%L)::text', tests.g('c1'))));
select tests.check('8. a draft line can be removed (the total follows); the credit note then fits the invoice and can be submitted',
  tests.g('rm') || '|' || (select total::text from credit_notes where id = tests.id('cn:b')), '|750.00');
select tests.o('b1', tests.cns('fin', 'b', 'pending_approval'));
select tests.o('b2', tests.cns('fin', 'b', 'approved'));
select tests.o('b3', tests.cns('ceo', 'b', 'approved'));
select tests.check('9. submitting opens ONE approval request (kind credit_note); the requester cannot approve their own while another qualified approver exists; someone else can',
  tests.g('b1') || '|' || tests.g('b2') || '|' || tests.g('b3') || '|' || (select count(*)::text || min(kind) from approval_requests where entity_table = 'credit_notes' and entity_id = tests.id('cn:b')), 'pending_approval|ERR:42501|approved|1credit_note');
-- the cap counts credit notes that are submitted, approved or issued
select tests.cn('fin', 'c', 'q4');
select tests.o('c_line', tests.cnl('fin', 'c', 'q4'));
select tests.cn('fin', 'd', 'q4');
select tests.cnc('fin', 'd', 'Too much', 5, 100);
select tests.o('c_sub', tests.cns('fin', 'c', 'pending_approval'));
select tests.o('d_sub', tests.cns('fin', 'd', 'pending_approval'));
select tests.check('10. the rest of the quantity (1 of 4) is creditable and fits the invoice total exactly; one more credit note over the total is refused at submission',
  (select (quantity = 1)::text from credit_note_lines where credit_note_id = tests.id('cn:c')) || '|' || tests.g('c_sub') || '|' || tests.g('d_sub'), 'true|pending_approval|ERR:23514');
select tests.o('c_can0', tests.cns('fin', 'c', 'cancelled'));
select tests.o('c_can1', tests.cns('fin', 'c', 'cancelled', 'raised by mistake'));
select tests.o('d_sub2', tests.cns('fin', 'd', 'pending_approval'));
select tests.check('11. cancelling needs a reason and frees the cap for the next credit note', tests.g('c_can0') || '|' || tests.g('c_can1') || '|' || tests.g('d_sub2'), 'ERR:23514|cancelled|ERR:23514');
select tests.o('d_rm', tests.scalar('fin', format('select credit_note_remove_line(%L)::text', (select id::text from credit_note_lines where credit_note_id = tests.id('cn:d')))));
select tests.cnc('fin', 'd', 'Small concession', 1, 250);
select tests.o('d_sub3', tests.cns('fin', 'd', 'pending_approval'));
select tests.check('12. ...a credit note that now fits the remaining 250 is accepted', tests.g('d_sub3'), 'pending_approval');

-- 3. Issue: snapshot, application to the invoice, immutability ---------------------------------------------------------------------------------------
select tests.o('b_iss0', tests.cns('web_lead', 'b', 'issued'));
select tests.o('b_iss', tests.cns('fin', 'b', 'issued'));
select tests.check('13. only a holder of credit_notes.issue issues it; the issue snapshots the client and ADA identity once',
  tests.g('b_iss0') || '|' || tests.g('b_iss') || '|' || (select (status = 'issued' and issue_date = current_date and client_name_snapshot = 'ABC Company' and issued_by = tests.id('staff:fin') and seller_legal_name_snapshot is not null)::text from credit_notes where id = tests.id('cn:b')),
  'ERR:42501|issued|true');
select tests.check('14. on issue the credit is applied to its own invoice: balance 250, credited 750, the invoice is partially settled; nothing is left unapplied',
  tests.bal('q4') || '|' || (select applied::text || '/' || unapplied::text from credit_note_balances where credit_note_id = tests.id('cn:b')), '250.00/750.00/partially_paid|750.00/0.00');
select tests.check('15. an issued credit note is a legal record: lines locked, cannot be cancelled, edited or deleted by anyone',
  tests.scalar('fin', format('select credit_note_remove_line(%L)::text', tests.g('p1'))) || tests.cns('ceo', 'b', 'cancelled', 'x') || tests.try('ceo', format($q$ update credit_notes set reason_note = 'x' where id = %L $q$, tests.id('cn:b')))
  || tests.try_owner(format($q$ update credit_notes set client_name_snapshot = 'Other' where id = %L $q$, tests.id('cn:b'))) || tests.try_owner(format($q$ delete from credit_notes where id = %L $q$, tests.id('cn:b'))), 'ERR:42501ERR:23514ERR:42501ERR:42501ERR:42501');
select tests.o('d_app', tests.cns('ceo', 'd', 'approved'));
select tests.o('d_iss', tests.cns('fin', 'd', 'issued'));
select tests.cn('fin', 'z8', 'q4');
select tests.cnc('fin', 'z8', 'nothing left', 1, 1);
select tests.remember('pay:p16', tests.scalar('fin', format('select payment_record(%L, %L, 10, ''cash'')::text', tests.id('client:abc'), tests.id('acct:nad'))));
select tests.check('16. the last 250 completes the credit: the invoice is fully settled (status paid, balance 0); a payment can no longer be allocated to it, and a credit note on it cannot exceed what was invoiced',
  tests.g('d_iss') || '|' || tests.bal('q4') || '|' || tests.scalar('fin', format('select payment_allocate(%L, %L)::text', tests.id('pay:p16'), tests.id('inv:q4'))) || '|' ||
  tests.cns('fin', 'z8', 'pending_approval'), 'issued|0.00/1000.00/paid|ERR:23514|ERR:23514');
-- a full credit of an unpaid invoice
select tests.cn_issued('a', 'd1', 'd1');
select tests.check('17. a credit note for the whole of an unpaid invoice settles it: balance 0, credited 1,000, status paid; a payment can no longer be allocated to it',
  tests.bal('d1') || '|' || tests.scalar('fin', format('select payment_record(%L, %L, 50, ''cash'', null, null, %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:d1'))), '0.00/1000.00/paid|ERR:23514');
select tests.cn_issued('a', 'd1', 'd1');

-- 4. Credit beyond what is owed: unapplied credit, applied elsewhere -----------------------------------------------------------------------------------------
select tests.remember('pay:d2', tests.scalar('fin', format('select payment_record(%L, %L, 500, ''bank_transfer'', null, ''EFT-D2'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:d2'))));
select tests.cn('fin', 'u', 'd2', 'goodwill');
select tests.cnc('fin', 'u', 'Goodwill after payment', 1, 300);
select tests.cns('fin', 'u', 'pending_approval');
select tests.cns('ceo', 'u', 'approved');
select tests.o('u_iss', tests.cns('fin', 'u', 'issued'));
select tests.check('18. credit on an invoice that is already fully paid is not applied to it: it is customer credit (unapplied 300) and the invoice is untouched',
  tests.g('u_iss') || '|' || tests.bal('d2') || '|' || (select applied::text || '/' || unapplied::text from credit_note_balances where credit_note_id = tests.id('cn:u')), 'issued|0.00/0/paid|0/300.00');
select tests.inv_qty('d3', 'client:abc', 1, 400);
select tests.o('al1', tests.scalar('fin', format('select credit_note_allocate(%L, %L)::text', tests.id('cn:u'), tests.id('inv:d3'))));
select tests.check('19. unapplied credit is applied to another open invoice of the same client: d3 now owes 100 and is partially settled',
  (tests.g('al1') ~ '^[0-9a-f-]{36}$')::text || '|' || tests.bal('d3') || '|' || (select unapplied::text from credit_note_balances where credit_note_id = tests.id('cn:u')), 'true|100.00/300.00/partially_paid|0.00');
select tests.remember('pay:x', tests.scalar('fin', format('select payment_record(%L, %L, 200, ''bank_transfer'', null, ''EFT-X'')::text', tests.id('client:abc'), tests.id('acct:nad'))));
select tests.o('x200', tests.scalar('fin', format('select payment_allocate(%L, %L, 200)::text', tests.id('pay:x'), tests.id('inv:d3'))));
select tests.o('x100', tests.scalar('fin', format('select payment_allocate(%L, %L, 100)::text', tests.id('pay:x'), tests.id('inv:d3'))));
select tests.check('20. a payment can no longer be allocated beyond what is still owed after credit (200 against 100 owed is refused; 100 is accepted and settles the invoice)',
  tests.g('x200') || '|' || (tests.g('x100') ~ '^[0-9a-f-]{36}$')::text || '|' || tests.bal('d3'), 'ERR:23514|true|0.00/300.00/paid');
select tests.o('rel', tests.scalar('fin', format($q$ select credit_note_unallocate(%L, 'applied to the wrong invoice')::text $q$, tests.g('al1'))));
select tests.check('21. a release needs a reason and puts the credit back: d3 owes 300 again (400 less the 100 paid in cash) and the 300 is unapplied credit once more',
  tests.bal('d3') || '|' || (select unapplied::text from credit_note_balances where credit_note_id = tests.id('cn:u')) || '|' ||
  tests.scalar('fin', format($q$ select credit_note_unallocate(%L, '')::text $q$, tests.g('al1'))), '300.00/0/partially_paid|300.00|ERR:23514');
select tests.o('big', tests.scalar('fin', format('select credit_note_allocate(%L, %L, 1000)::text', tests.id('cn:u'), tests.id('inv:d3'))));
select tests.check('22. an application cannot exceed the credit left on the credit note, nor what is owed on the invoice', tests.g('big'), 'ERR:23514');
select tests.inv_qty('w1', 'client:C_web', 1, 100);
select tests.check('23. credit is never applied to another client''s invoice', tests.scalar('fin', format('select credit_note_allocate(%L, %L, 50)::text', tests.id('cn:u'), tests.id('inv:w1'))), 'ERR:23514');
select tests.o('al2', tests.scalar('fin', format('select credit_note_allocate(%L, %L, 150)::text', tests.id('cn:u'), tests.id('inv:d3'))));
select tests.check('24. a partial application leaves the rest as credit: 150 applied to d3 (cash 100 also paid: 150 still owed), 150 unapplied',
  tests.bal('d3') || '|' || (select applied::text || '/' || unapplied::text from credit_note_balances where credit_note_id = tests.id('cn:u')), '150.00/150.00/partially_paid|150.00/150.00');

-- 5. Other rules ------------------------------------------------------------------------------------------------------------------------------------------
select tests.inv_qty('d4', 'client:abc', 1, 80);
select tests.cn('fin', 'v', 'd4');
select tests.cnl('fin', 'v', 'd4');
select tests.cns('fin', 'v', 'pending_approval');
select tests.check('25. an invoice with a credit note in progress cannot be cancelled', tests.try('ceo', format($q$ select invoice_void(%L, 'oops') $q$, tests.id('inv:d4'))), 'ERR:23514');
select tests.check('26. a client with credit still unapplied cannot be removed',
  (tests.msg_owner(format($q$ update clients set deleted_at = now() where id = %L $q$, tests.id('client:abc'))) ~ 'credit')::text, 'true');
select tests.check('27. nothing derived is stored on credit notes (no balance, applied, unapplied or owed column)',
  (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name in ('credit_notes', 'credit_note_lines') and column_name ~ '(balance|applied|unapplied|owed|outstanding)'), 'none');
select tests.check('28. direct writes are impossible for API users (no insert / update / delete on credit notes, lines or applications)',
  tests.try('ceo', format($q$ update credit_notes set total = 1 where id = %L $q$, tests.id('cn:v'))) || tests.try('fin', format($q$ delete from credit_note_lines where credit_note_id = %L $q$, tests.id('cn:v')))
  || tests.try('fin', format($q$ insert into credit_note_allocations (credit_note_id, invoice_id, amount) values (%L, %L, 1) $q$, tests.id('cn:u'), tests.id('inv:d3'))), 'ERR:42501ERR:42501ERR:42501');

-- 6. 360 views, dashboard ---------------------------------------------------------------------------------------------------------------------------------
create temp table c360 as select tests.scalar('ceo', format('select client_360(%L)::text', tests.id('client:abc')))::jsonb as j;
select tests.check('29. Client 360 shows the credited amount and the credit notes, and the finance summary adds up (outstanding = invoiced - paid - credited)',
  (select ((j -> 'finance_summary' ->> 'credited')::numeric > 0 and jsonb_array_length(j -> 'credit_notes') >= 4
           and (j -> 'finance_summary' ->> 'outstanding')::numeric = (j -> 'finance_summary' ->> 'invoiced')::numeric - (j -> 'finance_summary' ->> 'paid')::numeric - (j -> 'finance_summary' ->> 'credited')::numeric)::text from c360), 'true');
select tests.check('30. the dashboard''s outstanding receivables already count credit (they are derived from invoice_balance)',
  (tests.scalar('ceo', $q$ select (dashboard_summary() #>> '{receivables,outstanding,0,value}') $q$) = tests.scalar('ceo', $q$ select sum(invoice_balance(id))::text from invoices where status in ('issued', 'partially_paid') $q$))::text, 'true');

-- 7. Restricted clients, visibility ----------------------------------------------------------------------------------------------------------------------
select tests.cn_issued('w', 'w1', 'w1');
select tests.check('31. visibility follows credit_notes.view in the division: management, finance, the division lead and the auditor see all; division staff, another division, suspended and an outsider none',
  (select string_agg(u || '=' || (tests.scalar(u, 'select count(*)::text from credit_notes') = (select count(*)::text from credit_notes))::text, ' ' order by u) from unnest(array['ceo', 'fin', 'web_lead', 'audit']) u) || ' ' ||
  (select string_agg(u || '=' || tests.scalar(u, 'select count(*)::text from credit_notes'), ' ' order by u) from unnest(array['web_staff', 'tech_lead', 'suspended', 'outsider']) u),
  'audit=true ceo=true fin=true web_lead=true outsider=0 suspended=0 tech_lead=0 web_staff=0');
create temp table cn_before as select tests.scalar('web_lead', 'select count(*)::text from credit_notes') as n, tests.scalar('web_lead', $q$ select search('type:credit_note')->>'total' $q$) as s;
update clients set classification = 'restricted' where id = tests.id('client:C_web');
select tests.check('32. restricting the client hides its credit note (and its approval history) from the division lead at once; search follows; un-restricting restores it',
  tests.scalar('web_lead', format($q$ select count(*)::text from credit_notes where id = %L $q$, tests.id('cn:w'))) || '|' ||
  (tests.scalar('web_lead', 'select count(*)::text from credit_notes')::int = (select n::int - 1 from cn_before))::text || '|' ||
  (tests.scalar('web_lead', $q$ select search('type:credit_note')->>'total' $q$)::int = (select s::int - 1 from cn_before))::text || '|' ||
  (select classification::text from approval_requests where entity_table = 'credit_notes' and entity_id = tests.id('cn:w')), '0|true|true|restricted');
select tests.check('33. asking about it is indistinguishable from asking about an id that never existed, for every uncleared caller',
  (select string_agg(tests.same_for(u, $q$ select credit_note_transition(%L, 'cancelled')::text $q$, tests.id('cn:w'), tests.id('x:random')) || tests.same_for(u, $q$ select credit_note_allocate(%L, null, 1)::text $q$, tests.id('cn:w'), tests.id('x:random')), ',' order by u)
     from unnest(array['web_lead', 'web_staff', 'tech_lead', 'suspended', 'outsider']) u), 'samesame,samesame,samesame,samesame,samesame');
select tests.check('34. creating a credit note against an invoice of a restricted client answers as for an unknown invoice',
  (select string_agg(tests.same_for(u, $q$ select credit_note_create(%L, 'goodwill')::text $q$, tests.id('inv:w1'), tests.id('x:random')), ',' order by u) from unnest(array['web_lead', 'tech_lead', 'suspended']) u), 'same,same,same');
update clients set classification = 'internal' where id = tests.id('client:C_web');
select tests.check('35. ...restored', tests.scalar('web_lead', format($q$ select count(*)::text from credit_notes where id = %L $q$, tests.id('cn:w'))) || '|' || (select classification::text from approval_requests where entity_table = 'credit_notes' and entity_id = tests.id('cn:w')), '1|internal');

-- 8. Search and audit ------------------------------------------------------------------------------------------------------------------------------------
select tests.check('36. credit notes are searchable by type and ADA number (metadata only) and appear in `related:<client>`; the index holds no amount',
  tests.scalar('fin', $q$ select search('type:credit_note')->>'total' $q$) || '|' ||
  tests.scalar('fin', format($q$ select (search(%L)->'results'->0->>'entity_type') $q$, (select ada_id from credit_notes where id = tests.id('cn:b')))) || '|' ||
  (tests.scalar('fin', format($q$ select (select count(*) from jsonb_array_elements(search(%L)->'results') x where x->>'entity_type' = 'credit_note')::text $q$, 'related:' || tests.inst_of('clients', 'client:abc'))) = (select count(*)::text from credit_notes where client_id = tests.id('client:abc')))::text || '|' ||
  (select count(*)::text from search_index where entity_type = 'credit_note' and (terms ~ '[0-9]{3}' or label ~ '[0-9]{4}[0-9]'))
  , (select count(*)::text from credit_notes) || '|credit_note|true|0');
select tests.check('37. every step is in the audit trail and the approvals queue',
  (select (count(*) filter (where table_name = 'credit_notes') >= 10 and count(*) filter (where table_name = 'credit_note_allocations') >= 3)::text from audit_log) || '|' || (select (count(*) >= 5)::text from approval_requests where entity_table = 'credit_notes'), 'true|true');

select tests.finish();
rollback;
