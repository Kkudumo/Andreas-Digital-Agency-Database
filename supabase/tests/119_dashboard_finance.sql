-- PERMANENT: Dashboard finance figures - spend (expenses by state), unapplied customer credit, credit notes awaiting approval and recurring-billing schedules are
-- derived from the records, grouped by currency, and counted only for those who may read the records.
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
select tests.finance_world();
select tests.try('fin', $q$ insert into suppliers (name) values ('Hostco Namibia') $q$);
insert into tests.ids select 'sup:host', id from suppliers where name = 'Hostco Namibia';
insert into tests.ids select 'cl:cctv', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.service_id = tests.id('svc:cctv');
create function tests.ex(p_key text, p_net numeric) returns void language plpgsql as $$
begin
  insert into tests.ids values ('ex:' || p_key, tests.scalar('web_lead', format($q$ select expense_create(%L, 'hosting', %L, %s, null, 0, null, %L, %L, null)::text $q$, tests.id('div:web'), 'Expense ' || p_key, p_net, tests.id('sup:host'), 'R-' || p_key))::uuid);
end $$;
select tests.ex('p', 500); select tests.ex('a', 300); select tests.ex('d', 200);
select tests.scalar('web_lead', format($q$ select expense_transition(%L, 'pending_approval')::text $q$, tests.id('ex:p')));
select tests.scalar('web_lead', format($q$ select expense_transition(%L, 'pending_approval')::text $q$, tests.id('ex:a')));
select tests.scalar('fin', format($q$ select expense_transition(%L, 'approved')::text $q$, tests.id('ex:a')));
select tests.scalar('web_lead', format($q$ select expense_transition(%L, 'pending_approval')::text $q$, tests.id('ex:d')));
select tests.scalar('fin', format($q$ select expense_transition(%L, 'approved')::text $q$, tests.id('ex:d')));
select tests.scalar('fin', format($q$ select expense_pay(%L, %L)::text $q$, tests.id('ex:d'), tests.id('acct:nad')));
-- an invoice that is paid in full, then a credit note against it: the credit has nothing left to settle, so it stays as customer credit; a second credit note waits for approval
select tests.issued_invoice('i1', 'client:abc', 1000);
select tests.scalar('fin', format($q$ select payment_record(%L, %L, 1000, 'bank_transfer', null, 'EFT-1', %L)::text $q$, tests.id('client:abc'), tests.id('acct:nad'), tests.id('inv:i1')));
select tests.remember('cn:1', tests.scalar('fin', format($q$ select credit_note_create(%L, 'goodwill')::text $q$, tests.id('inv:i1'))));
select tests.scalar('fin', format($q$ select credit_note_add_custom_line(%L, 'Goodwill', 1, 200)::text $q$, tests.id('cn:1')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'pending_approval')::text $q$, tests.id('cn:1')));
select tests.scalar('ceo', format($q$ select credit_note_transition(%L, 'approved')::text $q$, tests.id('cn:1')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'issued')::text $q$, tests.id('cn:1')));
select tests.remember('cn:2', tests.scalar('fin', format($q$ select credit_note_create(%L, 'goodwill')::text $q$, tests.id('inv:i1'))));
select tests.scalar('fin', format($q$ select credit_note_add_custom_line(%L, 'More goodwill', 1, 100)::text $q$, tests.id('cn:2')));
select tests.scalar('fin', format($q$ select credit_note_transition(%L, 'pending_approval')::text $q$, tests.id('cn:2')));
select tests.scalar('fin', format($q$ select billing_schedule_create(%L, %L, 1, '2026-01-01', 1)::text $q$, tests.id('contract:1'), tests.id('cl:cctv')));

create function tests.dash(p_user text, p_path text) returns text language sql as $$
  select coalesce(tests.scalar(p_user, format($q$ select dashboard_summary() #>> %L $q$, p_path::text[])), 'null')
$$;
select tests.check('1. spend is derived by state: 500 awaiting approval, 300 approved and unpaid, 200 paid in the last 30 days',
  tests.dash('fin', '{spend,awaiting_approval,0,value}') || '/' || tests.dash('fin', '{spend,awaiting_approval,0,count}') || '|' || tests.dash('fin', '{spend,approved_unpaid,0,value}') || '|' || tests.dash('fin', '{spend,paid_30d,0,value}'),
  '500.00/1|300.00|200.00');
select tests.check('2. unapplied customer credit is the issued 200 (the invoice was already paid) and one credit note awaits approval',
  tests.dash('fin', '{receivables,credit_unapplied,0,value}') || '|' || tests.dash('fin', '{receivables,credit_notes_awaiting_approval}'), '200.00|1');
select tests.check('3. billing: the schedule is due, none are paused', tests.dash('fin', '{billing,schedules_due}') || '|' || tests.dash('fin', '{billing,schedules_paused}'), '1|0');
select tests.check('4. someone without expense, credit note or schedule access sees empty spend and zero billing (no figures leak), and an outsider gets nothing',
  tests.dash('tech_lead', '{spend,awaiting_approval}') || tests.dash('tech_lead', '{spend,approved_unpaid}') || tests.dash('tech_lead', '{billing,schedules_due}') || tests.dash('tech_lead', '{receivables,credit_notes_awaiting_approval}') || '|' || tests.dash('outsider', '{spend}'),
  '[][]00|null');
select tests.finish();
rollback;
