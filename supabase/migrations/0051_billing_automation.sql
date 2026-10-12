-- 0051_billing_automation: unattended recurring billing, and a preview of what a run would do.
--  * billing_schedule_preview(as_of): read-only. Lists, for the schedules the caller may bill, the periods a run for that date would bill (the same arithmetic as
--    billing_schedule_run, limited by the same 12-period cap and the line's remaining quantity). It writes nothing.
--  * A scheduled job has no logged-in person, and billing is a permissioned act, so the job runs AS a named staff member: finance_settings.billing_runner_id.
--    billing_schedule_run_scheduled() (service role only, never callable by app users) takes that member's identity for the duration of the call, runs
--    billing_schedule_run(today, create draft invoices), and restores the previous identity. The runner is held to exactly what they could do by hand
--    (invoices.create in each contract's division); every row is audited as theirs. The job only ever creates billable items and DRAFT invoices: nothing is issued.
--  * Who the runner is, is a finance decision: billing_runner_set needs finance.configure and refuses anyone who is not active staff.

alter table finance_settings add column billing_runner_id uuid references staff (id);
comment on column finance_settings.billing_runner_id is 'The staff member the unattended billing job runs as (needs invoices.create in the divisions it bills). Null = unattended billing is off.';

create function billing_runner_set(p_staff uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_permission('finance.configure') then raise exception 'finance.configure is required' using errcode = '42501'; end if;
  if p_staff is not null and not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null and user_id is not null) then
    raise exception 'the billing runner must be an active staff member with a login' using errcode = '23514';
  end if;
  update finance_settings set billing_runner_id = p_staff, updated_by = current_staff_id();
end $$;

create function billing_schedule_preview(p_as_of date default current_date)
returns table (schedule_id uuid, contract_id uuid, period_start date, quantity numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s billing_schedules%rowtype; c contracts%rowtype; v_next date; v_k integer; v_n integer; v_left numeric; v_qty numeric;
begin
  if p_as_of is null then raise exception 'choose the date to preview' using errcode = '23514'; end if;
  for s in select * from billing_schedules where status = 'active' and next_bill_on <= p_as_of order by contract_id, id loop
    continue when not can_view_billing_schedule_contract(s.contract_id);
    select * into c from contracts where id = s.contract_id;
    continue when not has_permission('invoices.create', c.division_id) or c.status not in ('signed', 'active');
    v_next := s.next_bill_on; v_n := 0;
    v_k := (select count(*) from billing_schedule_runs r where r.schedule_id = s.id)::integer;
    v_left := billing_line_remaining(s.origin_line_id);
    while v_next <= p_as_of and v_n < 12 and v_left > 0 and (s.end_on is null or v_next <= s.end_on) loop
      v_qty := least(s.quantity_per_period, v_left);
      schedule_id := s.id; contract_id := s.contract_id; period_start := v_next; quantity := v_qty;
      return next;
      v_left := v_left - v_qty; v_n := v_n + 1; v_k := v_k + 1;
      v_next := (s.first_period_start + make_interval(months => s.interval_months * v_k))::date;
    end loop;
  end loop;
end $$;

create function billing_schedule_run_scheduled(p_as_of date default current_date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_runner uuid; v_user uuid; v_prev_sub text := current_setting('request.jwt.claim.sub', true); v_prev_claims text := current_setting('request.jwt.claims', true); v_out jsonb;
begin
  select s.id, s.user_id into v_runner, v_user from finance_settings f join staff s on s.id = f.billing_runner_id
   where s.account_status = 'active' and s.deleted_at is null;
  if v_runner is null then raise exception 'no billing runner is configured (finance_settings.billing_runner_id)' using errcode = '23514'; end if;
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user)::text, true);
  v_out := billing_schedule_run(p_as_of, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_prev_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(v_prev_claims, ''), true);
  perform record_audit_event('billing.scheduled_run', 'billing_schedules', v_runner, jsonb_build_object('as_of', p_as_of, 'outcomes', v_out));
  return v_out;
end $$;

revoke execute on function billing_runner_set(uuid), billing_schedule_preview(date), billing_schedule_run_scheduled(date) from public, anon, authenticated;
grant execute on function billing_runner_set(uuid), billing_schedule_preview(date) to authenticated;
grant execute on function billing_schedule_run_scheduled(date) to service_role;
