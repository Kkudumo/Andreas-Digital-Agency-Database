-- PERMANENT: Unattended billing - the preview shows exactly what a run would bill and writes nothing; the scheduled run acts as the named runner (held to their
-- own permissions, audited as them, drafts only), cannot be called by application users, and hands the identity back afterwards.
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
select tests.remember('s:cctv', tests.scalar('fin', format($q$ select billing_schedule_create(%L, %L, 1, '2026-01-01', 1)::text $q$, tests.id('contract:1'), tests.id('cl:cctv'))));

select tests.check('1. the preview lists exactly the periods a run would bill (January to March, one unit each) and writes nothing',
  tests.scalar('fin', $q$ select string_agg(period_start || '=' || quantity, ',' order by period_start) from billing_schedule_preview('2026-03-31') $q$) || '|' ||
  (select count(*)::text from billable_items where contract_id = tests.id('contract:1')) || '/' || (select count(*)::text from billing_schedule_runs),
  '2026-01-01=1.00,2026-02-01=1.00,2026-03-01=1.00|0/0');
select tests.check('2. the preview stops at the line''s remaining quantity and at the 12-period cap (4 units: four periods even when 11 are due)',
  tests.scalar('fin', $q$ select count(*)::text from billing_schedule_preview('2026-12-31') $q$), '4');
select tests.check('3. nothing is previewed for people who cannot bill (division staff, another division, suspended, outsider)',
  tests.scalar('web_staff', $q$ select count(*)::text from billing_schedule_preview('2026-12-31') $q$) || tests.scalar('tech_lead', $q$ select count(*)::text from billing_schedule_preview('2026-12-31') $q$) ||
  tests.scalar('suspended', $q$ select count(*)::text from billing_schedule_preview('2026-12-31') $q$) || tests.scalar('outsider', $q$ select count(*)::text from billing_schedule_preview('2026-12-31') $q$), '0000');

select tests.check('4. the scheduled run is not callable by application users, and with no runner configured it refuses',
  tests.scalar('fin', $q$ select billing_schedule_run_scheduled('2026-03-31')::text $q$) || tests.scalar('ceo', $q$ select billing_schedule_run_scheduled('2026-03-31')::text $q$) || '|' ||
  tests.try_owner($q$ select billing_schedule_run_scheduled('2026-03-31') $q$), 'ERR:42501ERR:42501|ERR:23514');
select tests.check('5. only finance.configure can name the runner, and only an active staff member with a login',
  tests.scalar('web_lead', format($q$ select billing_runner_set(%L)::text $q$, tests.id('staff:fin'))) || tests.scalar('ceo', format($q$ select billing_runner_set(%L)::text $q$, tests.id('x:random'))),
  'ERR:42501ERR:23514');
select tests.scalar('ceo', format($q$ select billing_runner_set(%L)::text $q$, tests.id('staff:web_staff')));

select tests.try_owner($q$ select tests.o('r1', billing_schedule_run_scheduled('2026-03-31')::text) $q$);
select tests.check('6. a runner without invoices.create bills nothing (the job is held to the runner''s own permissions)',
  tests.g('r1') || '|' || (select count(*)::text from billable_items where contract_id = tests.id('contract:1')),
  '[]|0');
select tests.scalar('ceo', format($q$ select billing_runner_set(%L)::text $q$, tests.id('staff:fin')));
select set_config('request.jwt.claim.sub', '', true);
select tests.try_owner($q$ select tests.o('r2', billing_schedule_run_scheduled('2026-03-31')::text) $q$);
select tests.check('7. as finance the job bills the three due periods and prepares one DRAFT invoice (nothing issued); the runs and the audit trail are the runner''s',
  (tests.g('r2')::jsonb -> 0 ->> 'periods_billed') || '|' ||
  (select count(*)::text || '/' || min(i.status::text) from billing_schedule_runs r join invoices i on i.id = r.invoice_id) || '|' ||
  (select (count(*) = 3 and bool_and(run_by = tests.id('staff:fin')))::text from billing_schedule_runs) || '|' ||
  (select count(*)::text from audit_log where action = 'billing.scheduled_run' and actor_staff_id is null and record_id = tests.id('staff:fin')),
  '3|3/draft|true|1');
select tests.try_owner($q$ select tests.o('r3', billing_schedule_run_scheduled('2026-03-31')::text) $q$);
select tests.check('8. the identity is handed back after the job, and a second run for the same date bills nothing more',
  coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), 'none') || '|' ||
  tests.g('r3') || '|' || (select count(*)::text from billing_schedule_runs), 'none|[]|3');
select tests.finish();
rollback;
