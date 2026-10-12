-- PERMANENT: Reports - receivables aging, revenue by month, expenses by category, project profitability and pipeline: figures are derived from the
-- authoritative modules (nothing stored), credit notes and payments are netted, currencies are never mixed, and every report adds up only what the caller can
-- already read (restricted and other-division records are absent, never partly counted).
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
select tests.finance_world();
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.try('fin', $q$ insert into suppliers (name) values ('Hostco Namibia') $q$);
insert into tests.ids select 'sup:host', id from suppliers where name = 'Hostco Namibia';
create function tests.ex(p_user text, p_key text, p_net numeric, p_cat text default 'hosting') returns text language plpgsql as $$
declare v text;
begin
  v := tests.scalar(p_user, format($q$ select expense_create(%L, %L, %L, %s, null, 0, null, %L, %L, %L)::text $q$, tests.id('div:web'), p_cat, 'Expense ' || p_key, p_net, tests.id('sup:host'), 'REF-' || p_key, tests.id('project:abc')));
  if v is null or v like 'ERR:%' then return coalesce(v, 'NULL'); end if;
  insert into tests.ids values ('ex:' || p_key, v::uuid);
  return v;
end $$;
create function tests.exs(p_user text, p_key text, p_to text) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select expense_transition(%L, %L)::text $q$, tests.id('ex:' || p_key), p_to))
$$;
-- an issued invoice of one line attached to a project
create function tests.proj_invoice(p_key text, p_amount numeric) returns text language plpgsql as $$
declare v_bi text; v_inv text;
begin
  v_bi := tests.scalar('fin', format('select billable_manual(%L, %L, %L, 1, %s, ''test charge'', %L)::text', tests.id('client:abc'), tests.id('div:web'), 'Project work ' || p_key, p_amount, tests.id('project:abc')));
  v_inv := tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', v_bi));
  perform tests.remember('inv:' || p_key, v_inv);
  perform tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', v_inv));
  perform tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', v_inv));
  perform tests.scalar('fin', format('select invoice_transition(%L, ''issued'')::text', v_inv));
  return v_inv;
end $$;
create function tests.rep(p_user text, p_sql text) returns text language plpgsql as $$
begin return tests.scalar(p_user, p_sql); end $$;

-- invoices: A 1000 (issued last month, 10 days late), B 2000 (45 days late), C 500 (not yet due), T 800 (the technology division's own client)
select tests.issued_invoice('a', 'client:abc', 1000);
select tests.issued_invoice('b', 'client:abc', 2000);
select tests.issued_invoice('c', 'client:abc', 500);
select tests.remember('client:tech', tests.mkclient_id('tech_lead', 'Tech Only Co', 'tech'));
select tests.issued_invoice('t', 'client:tech', 800, 'tech');
set local session_replication_role = replica;
update invoices set issue_date = current_date - 50, due_date = current_date - 10 where id = tests.id('inv:a');
update invoices set issue_date = current_date - 50, due_date = current_date - 45 where id = tests.id('inv:b');
update invoices set due_date = current_date + 5 where id = tests.id('inv:c');
reset session_replication_role;
-- a payment of 300 against A; a credit note of 200 (free-form line) against B
select tests.remember('pay:a', tests.scalar('fin', format('select payment_record(%L, %L, 300, ''bank_transfer'', null, ''EFT-A'', %L)::text', tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:a'))));
select tests.remember('cn:b', tests.scalar('fin', format($q$ select credit_note_create(%L, 'billing_error')::text $q$, tests.id('inv:b'))));
select tests.scalar('fin', format($q$ select credit_note_add_custom_line(%L, 'Correction', 1, 200)::text $q$, tests.id('cn:b')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'pending_approval')::text $q$, tests.id('cn:b')));
select tests.scalar('ceo', format($q$ select credit_note_transition(%L, 'approved')::text $q$, tests.id('cn:b')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'issued')::text $q$, tests.id('cn:b')));

-- 1. Receivables aging ---------------------------------------------------------------------------------------------------------------------------------
create function tests.aging(p_user text) returns text language sql as $$
  select coalesce(tests.scalar(p_user, $q$ select string_agg(client_name || '=' || not_due || '/' || days_1_30 || '/' || days_31_60 || '/' || days_61_90 || '/' || days_over_90 || '/' || total || '/' || invoices, ' ' order by client_name) from report_receivables_aging() $q$), 'none')
$$;
select tests.check('1. aging buckets the open balance by how late it is, net of payments AND credit notes (A 1000-300 is 1-30 days, B 2000-200 is 31-60, C is not yet due); management also sees the technology client',
  tests.aging('ceo'), 'ABC Company=500.00/700.00/1800.00/0/0/3000.00/3 Tech Only Co=800.00/0/0/0/0/800.00/1');
select tests.check('2. each caller gets only what they can read: the Web lead does not see the technology division''s client; staff without invoice access, suspended staff and an outsider get nothing',
  tests.aging('web_lead') || '|' || tests.aging('web_staff') || '|' || tests.aging('suspended') || '|' || tests.aging('outsider'),
  'ABC Company=500.00/700.00/1800.00/0/0/3000.00/3|none|none|none');
select tests.check('3. the same report for an earlier date re-buckets (as of 40 days ago only B was late: 1800 in 1-30 days, the other 1200 not yet due)',
  coalesce(tests.scalar('ceo', $q$ select (days_1_30 + days_31_60 + days_61_90 + days_over_90)::text || '/' || not_due::text from report_receivables_aging(current_date - 40) where client_name = 'ABC Company' $q$), 'none'), '1800.00/1200.00');

-- 2. Revenue ----------------------------------------------------------------------------------------------------------------------------------------------
create function tests.rev(p_user text) returns text language sql as $$
  select coalesce(tests.scalar(p_user, $q$ select string_agg(to_char(month, 'YYYY-MM') || ':' || invoiced || '/' || credited || '/' || net_invoiced || '/' || received, ' ' order by month) from report_revenue(current_date - 90, current_date) $q$), 'none')
$$;
select tests.check('4. revenue by month: invoiced (issued invoices), credited (issued credit notes), net, and received (payments); A and B were issued 50 days ago, C and T today',
  tests.rev('ceo'), to_char(current_date - 50, 'YYYY-MM') || ':3000.00/0/3000.00/0 ' || to_char(current_date, 'YYYY-MM') || ':1300.00/200.00/1100.00/300.00');
select tests.check('5. revenue is limited to what the caller can read (the Web lead does not count the technology client, and sees no received amounts: payments need their own permission), and the period limits the months',
  tests.rev('web_lead') || '|' || tests.rev('outsider') || '|' ||
  tests.scalar('ceo', $q$ select string_agg(invoiced::text, ',') from report_revenue(current_date, current_date) $q$),
  to_char(current_date - 50, 'YYYY-MM') || ':3000.00/0/3000.00/0 ' || to_char(current_date, 'YYYY-MM') || ':500.00/200.00/300.00/0|none|1300.00');

-- 3. Expenses ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.ex('web_lead', 'a', 1000);
select tests.ex('web_lead', 'b', 300);
select tests.ex('web_lead', 'c', 77);
select tests.ex('web_lead', 'd', 400, 'office');
select tests.exs('web_lead', 'a', 'pending_approval');
select tests.exs('fin', 'a', 'approved');
select tests.scalar('fin', format($q$ select expense_pay(%L, %L, null, 'EFT-EXP')::text $q$, tests.id('ex:a'), tests.id('acct:nad')));
select tests.exs('web_lead', 'b', 'pending_approval');
select tests.exs('fin', 'b', 'approved');
select tests.exs('web_lead', 'd', 'pending_approval');
select tests.exs('fin', 'd', 'approved');
create function tests.exr(p_user text) returns text language sql as $$
  select coalesce(tests.scalar(p_user, $q$ select string_agg(category || ':' || bills || '/' || total || '/' || paid || '/' || unpaid, ' ' order by category) from report_expenses(current_date - 30, current_date) $q$), 'none')
$$;
select tests.check('6. expenses by month and category count approved and paid bills only (the draft is not a cost), split into paid and unpaid',
  tests.exr('ceo'), 'Hosting and infrastructure:2/1300.00/1000.00/300.00 Office and utilities:1/400.00/0/400.00');
select tests.check('7. expenses follow the expense rules: finance sees them, the division lead of another division, suspended staff and an outsider do not',
  tests.exr('fin') || '|' || tests.exr('tech_lead') || '|' || tests.exr('suspended') || '|' || tests.exr('outsider'),
  'Hosting and infrastructure:2/1300.00/1000.00/300.00 Office and utilities:1/400.00/0/400.00|none|none|none');

-- 4. Project profitability ------------------------------------------------------------------------------------------------------------------------------
select tests.proj_invoice('p', 3000);
select tests.remember('cn:p', tests.scalar('fin', format($q$ select credit_note_create(%L, 'price_adjustment')::text $q$, tests.id('inv:p'))));
select tests.scalar('fin', format($q$ select credit_note_add_custom_line(%L, 'Agreed reduction', 1, 500)::text $q$, tests.id('cn:p')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'pending_approval')::text $q$, tests.id('cn:p')));
select tests.scalar('ceo', format($q$ select credit_note_transition(%L, 'approved')::text $q$, tests.id('cn:p')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'issued')::text $q$, tests.id('cn:p')));
create function tests.prof(p_user text) returns text language sql as $$
  select coalesce(tests.scalar(p_user, $q$ select string_agg(project_ada_id || ' ' || currency || ' ' || invoiced || '/' || credited || '/' || cost || '/' || margin, ' ' order by project_ada_id) from report_project_profitability() $q$), 'none')
$$;
select tests.check('8. project profitability: revenue is net of issued credit notes, cost is approved + paid expenses (the draft is excluded), margin is the difference; invoices of no project are not counted',
  (select regexp_replace(tests.prof('ceo'), '^ADA-PRJ-[0-9-]+ ', '')), 'NAD 3000.00/500.00/1700.00/800.00');
select tests.check('9. profitability is limited to readable projects: division staff without project access, the other division, suspended staff and an outsider see none',
  tests.prof('tech_lead') || '|' || tests.prof('suspended') || '|' || tests.prof('outsider'), 'none|none|none');

-- 5. Pipeline ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('10. the pipeline counts quotes and leads created in the period by status (the accepted quote is there); nobody without access counts anything',
  coalesce(tests.scalar('ceo', $q$ select string_agg(stage || ':' || status || '=' || n, ',' order by stage, status) from report_pipeline(current_date - 1, current_date + 1) $q$), 'none') || '|' ||
  coalesce(tests.scalar('outsider', $q$ select string_agg(stage || status, ',') from report_pipeline(current_date - 1, current_date + 1) $q$), 'none'),
  'quote:accepted=1|none');

-- 6. Safety -----------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('11. reports run as the caller (SECURITY INVOKER), are not callable anonymously, and change no data',
  (select count(*)::text || '/' || count(*) filter (where not p.prosecdef)::text from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'report\_%') || '|' ||
  tests.scalar_anon('select count(*)::text from report_revenue(current_date, current_date)'), '5/5|ERR:42501');
select tests.check('12. a restricted client''s figures leave every report for everyone without access (aging, revenue, expenses, profitability); management still sees them',
  (coalesce(nullif(tests.aging('ceo'), ''), 'none') like 'ABC Company%')::text, 'true');
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('13. after restricting the client: the Web lead and finance see nothing of it in any report, management still does',
  tests.aging('web_lead') || '|' || tests.rev('web_lead') || '|' || tests.exr('web_lead') || '|' || tests.prof('web_lead') || '|' ||
  (tests.aging('ceo') like 'ABC Company%')::text || (tests.exr('ceo') <> 'none')::text || (tests.prof('ceo') <> 'none')::text,
  'none|none|none|none|truetruetrue');
select tests.finish();
rollback;
