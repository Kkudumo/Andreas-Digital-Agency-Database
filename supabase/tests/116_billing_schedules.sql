-- PERMANENT: Recurring invoicing - schedules over contract lines, periods billed once and only once, caps shared with ordinary billing, ending and pausing,
-- optional draft invoice, pause/resume, append-only run log, derived progress, visibility and non-disclosure, audit.
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
insert into tests.ids select 'cl:cctv', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.service_id = tests.id('svc:cctv');
insert into tests.ids select 'cl:web', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and cl.service_id = tests.id('svc:web');
create function tests.bs(p_user text, p_args text) returns text language sql as $$
  select tests.scalar(p_user, format('select billing_schedule_create(%L, %s)::text', tests.id('contract:1'), p_args))
$$;
create function tests.run(p_user text, p_as_of text, p_inv boolean default false) returns text language sql as $$
  select tests.scalar(p_user, format('select billing_schedule_run(%L::date, %L::boolean)::text', p_as_of, p_inv))
$$;
create function tests.prog(p_sched text) returns text language sql stable as $$
  select periods_billed || '/' || quantity_billed || '/' || line_remaining || '/' || next_bill_on || '/' || status from billing_schedule_progress where schedule_id = tests.id(p_sched)
$$;

-- 1. Creating ------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('s:cctv', coalesce(nullif(tests.bs('fin', format('%L, 1, %L, 1', tests.id('cl:cctv'), '2026-01-01')), ''), 'x'));
select tests.check('1. a schedule is created over a contract line by someone with invoices.create; nothing is billed yet',
  (select (status = 'active' and interval_months = 1 and quantity_per_period = 1 and next_bill_on = date '2026-01-01' and created_by is not null)::text || '/' ||
          (select count(*) from billing_schedule_runs)::text || '/' || (select count(*) from billable_items where contract_id = tests.id('contract:1'))::text
     from billing_schedules where id = tests.id('s:cctv')), 'true/0/0');
select tests.check('2. refused without invoices.create (division staff and suspended staff cannot even see the contract; an outsider) - and each is answered exactly as for an unknown contract',
  tests.bs('web_staff', format('%L, 1, %L', tests.id('cl:cctv'), '2026-01-01')) || '|' || tests.bs('suspended', format('%L, 1, %L', tests.id('cl:cctv'), '2026-01-01')) || '|' ||
  (select string_agg(tests.same_for(u, $q$ select billing_schedule_create(%L, null, 1, current_date)::text $q$, tests.id('contract:1'), tests.id('x:random')), ',') from unnest(array['outsider', 'suspended', 'tech_lead']) u),
  'ERR:P0002|ERR:P0002|same,same,same');
select tests.check('3. invalid terms are refused: interval, quantity, end before start, a line of another contract, a second live schedule on the same line',
  tests.bs('fin', format('%L, 2, %L', tests.id('cl:web'), '2026-01-01')) || tests.bs('fin', format('%L, 1, %L, 0', tests.id('cl:web'), '2026-01-01')) ||
  tests.bs('fin', format('%L, 1, %L, 1, %L', tests.id('cl:web'), '2026-01-01', '2025-12-01')) || tests.bs('fin', format('%L, 1, %L', tests.id('x:random'), '2026-01-01')) ||
  tests.bs('fin', format('%L, 3, %L', tests.id('cl:cctv'), '2026-02-01')),
  'ERR:23514ERR:23514ERR:23514ERR:P0002ERR:23505');

-- S2: the website line, quarterly (paused and resumed below)
select tests.remember('s:web', tests.bs('fin', format('%L, 3, %L', tests.id('cl:web'), '2026-01-01')));
select tests.scalar('fin', format($q$ select billing_schedule_set_status(%L, 'paused', null)::text $q$, tests.id('s:web')));
select tests.check('4. pausing needs a reason; a paused schedule is not billed',
  tests.scalar('fin', format($q$ select billing_schedule_set_status(%L, 'paused', null)::text $q$, tests.id('s:web'))), 'ERR:23514');
select tests.scalar('fin', format($q$ select billing_schedule_set_status(%L, 'paused', 'client asked to wait')::text $q$, tests.id('s:web')));

-- 2. Running -------------------------------------------------------------------------------------------------------------------------------------------
select tests.o('run1', tests.run('fin', '2026-01-15', true));
select tests.check('5. a run bills the period that came due once, as a normal contract billable item, and prepares one DRAFT invoice; the paused schedule is left alone',
  (select count(*)::text || '/' || max(quantity)::text || '/' || max(unit_price)::text || '/' || max(source::text) || '/' || max(status::text) from billable_items where contract_id = tests.id('contract:1')) || '|' ||
  (select count(*)::text || '/' || min(i.status::text) from billing_schedule_runs r join invoices i on i.id = r.invoice_id) || '|' ||
  (tests.g('run1')::jsonb -> 0 ->> 'outcome') || '/' || jsonb_array_length(tests.g('run1')::jsonb)::text || '|' || tests.prog('s:cctv') || '|' || tests.prog('s:web'),
  '1/1.00/1200.00/contract/invoiced|1/draft|billed/1|1/1.00/3.00/2026-02-01/active|0/0/1.00/2026-01-01/paused');
select tests.o('run2', tests.run('fin', '2026-01-15', true));
select tests.check('6. running again for the same date bills nothing more (no period is billed twice)',
  tests.g('run2') || '|' || (select count(*)::text from billable_items where contract_id = tests.id('contract:1')) || '|' || (select count(*)::text from billing_schedule_runs), '[]|1|1');
select tests.check('7. the run log refuses a second row for the same period (even from the owner), and is append-only',
  tests.try_owner(format('insert into billing_schedule_runs (schedule_id, period_start, billable_item_id, quantity) select schedule_id, period_start, billable_item_id, 1 from billing_schedule_runs where schedule_id = %L', tests.id('s:cctv'))) || '|' ||
  tests.try_owner('update billing_schedule_runs set quantity = 9') || '|' || tests.try_owner('delete from billing_schedule_runs'),
  'ERR:23505|ERR:42501|ERR:42501');
select tests.check('8. someone without invoices.create runs nothing, and the permission is checked per schedule',
  tests.run('web_staff', '2030-01-01') || tests.run('outsider', '2030-01-01') || tests.run('suspended', '2030-01-01') || tests.run('audit', '2030-01-01'), '[][][][]');

-- ordinary billing of the same line shares the cap: one unit is billed by hand, so the schedule can only bill what remains
select tests.scalar('fin', format('select billable_from_contract(%L, %L, 1)::text', tests.id('contract:1'), tests.id('cl:cctv')));
select tests.o('run3', tests.run('fin', '2026-03-31'));
select tests.check('9. a run catches up the periods missed (February and March) but never beyond what the contract line still allows (ordinary billing shares the cap)',
  (tests.g('run3')::jsonb -> 0 ->> 'periods_billed') || '|' || tests.prog('s:cctv') || '|' ||
  (select string_agg(period_start::text, ',' order by period_start) from billing_schedule_runs where schedule_id = tests.id('s:cctv')),
  '2|3/3.00/0.00/2026-04-01/active|2026-01-01,2026-02-01,2026-03-01');
select tests.o('run4', tests.run('fin', '2026-12-31'));
select tests.check('10. once the line is fully billed the next run ends the schedule (nothing is billed), and an ended schedule is final',
  (tests.g('run4')::jsonb -> 0 ->> 'outcome') || '/' || (tests.g('run4')::jsonb -> 0 ->> 'periods_billed') || '/' || (tests.g('run4')::jsonb -> 0 ->> 'message') || '|' || tests.prog('s:cctv') || '|' ||
  tests.scalar('fin', format($q$ select billing_schedule_set_status(%L, 'active', null)::text $q$, tests.id('s:cctv'))),
  'ended/0/the line is fully billed|3/3.00/0.00/2026-04-01/ended|ERR:42501');
select tests.check('11. a schedule cannot be created on a line that is already fully billed',
  tests.bs('fin', format('%L, 1, %L', tests.id('cl:cctv'), '2027-01-01')), 'ERR:23514');

-- 3. Pause, resume, skipping missed periods ------------------------------------------------------------------------------------------------------------
select tests.scalar('fin', format($q$ select billing_schedule_set_status(%L, 'active', null, true)::text $q$, tests.id('s:web')));
select tests.check('12. resuming with "skip missed" moves the schedule to the first period start after today on its own calendar; resuming clears the pause reason',
  (select (next_bill_on = (select min(d)::date from generate_series(date '2026-01-01', date '2100-01-01', interval '3 months') d where d > current_date) and status = 'active' and status_reason is null)::text
     from billing_schedules where id = tests.id('s:web')), 'true');
select tests.check('13. the terms of a schedule cannot be changed, and a schedule cannot be deleted',
  tests.try_owner(format('update billing_schedules set interval_months = 1 where id = %L', tests.id('s:web'))) || '|' || tests.try_owner(format('delete from billing_schedules where id = %L', tests.id('s:web'))),
  'ERR:42501|ERR:42501');
select tests.check('14. nobody can write the tables directly',
  tests.try('fin', 'update billing_schedules set status = ''ended''') || tests.try('ceo', 'insert into billing_schedule_runs (schedule_id, period_start, billable_item_id, quantity) select schedule_id, period_start, billable_item_id, 1 from billing_schedule_runs'),
  'ERR:42501ERR:42501');

-- 4. Contract no longer billable ------------------------------------------------------------------------------------------------------------------------
select tests.scalar('ceo', format($q$ select contract_transition(%L, 'terminated', 'client ended the agreement')::text $q$, tests.id('contract:1')));
select tests.o('run5', tests.run('fin', '2100-01-01', true));
select tests.check('15. when the contract no longer allows billing, a run parks the schedule (paused, with the reason) instead of billing or failing every time; it bills nothing',
  (tests.g('run5')::jsonb -> 0 ->> 'outcome') || '|' || (select status::text || '/' || (status_reason ~ '^paused by a run')::text from billing_schedules where id = tests.id('s:web')) || '|' ||
  (select count(*)::text from billing_schedule_runs where schedule_id = tests.id('s:web')) || '|' ||
  tests.scalar('fin', format($q$ select billing_schedule_set_status(%L, 'active', null)::text $q$, tests.id('s:web'))),
  'paused|paused/true|0|ERR:23514');
select tests.check('16. a schedule cannot be created on a terminated contract', tests.bs('fin', format('%L, 1, %L', tests.id('cl:web'), '2027-01-01')), 'ERR:23514');

-- 5. Visibility, non-disclosure, audit -----------------------------------------------------------------------------------------------------------------
select tests.check('17. schedules and their runs are visible with invoices.view in the division (management, finance, the division lead; the auditor has no invoices.view); division staff, another division, suspended and an outsider see none',
  (select string_agg(u || '=' || tests.scalar(u, 'select count(*)::text from billing_schedules') || '/' || tests.scalar(u, 'select count(*)::text from billing_schedule_runs'), ' ' order by u)
     from unnest(array['audit', 'ceo', 'fin', 'web_lead', 'web_staff', 'tech_lead', 'suspended', 'outsider']) u),
  'audit=0/0 ceo=2/3 fin=2/3 outsider=0/0 suspended=0/0 tech_lead=0/0 web_lead=2/3 web_staff=0/0');
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('18. a restricted client''s schedules and runs vanish for everyone without access (and the derived progress with them); management still sees them',
  (select string_agg(u || '=' || tests.scalar(u, 'select count(*)::text from billing_schedules') || '/' || tests.scalar(u, 'select count(*)::text from billing_schedule_runs') || '/' || tests.scalar(u, 'select count(*)::text from billing_schedule_progress'), ' ' order by u)
     from unnest(array['audit', 'ceo', 'fin', 'web_lead', 'tech_lead', 'suspended', 'outsider']) u),
  'audit=0/0/0 ceo=2/3/2 fin=0/0/0 outsider=0/0/0 suspended=0/0/0 tech_lead=0/0/0 web_lead=0/0/0');
select tests.check('19. pausing, resuming and running a restricted client''s schedule answer exactly as for one that does not exist',
  (select string_agg(tests.same_for(u, $q$ select billing_schedule_set_status(%L, 'ended', 'x')::text $q$, tests.id('s:web'), tests.id('x:random')), ',' order by u) from unnest(array['fin', 'web_lead', 'tech_lead', 'suspended', 'outsider']) u),
  'same,same,same,same,same');
select tests.check('20. creating, pausing, resuming and running are audited with who did it',
  (select (count(*) filter (where table_name = 'billing_schedules' and action = 'INSERT') >= 2 and count(*) filter (where table_name = 'billing_schedules' and action = 'UPDATE') >= 4
           and count(*) filter (where table_name = 'billing_schedule_runs' and action = 'INSERT') = 3 and bool_and(actor_staff_id is not null))::text
     from audit_log where table_name in ('billing_schedules', 'billing_schedule_runs')), 'true');

select tests.finish();
rollback;
