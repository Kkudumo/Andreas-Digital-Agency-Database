-- 0049_billing_schedules: recurring invoicing over contract lines.
--  * A billing schedule says "bill this contract line, N units every M months, from this date". It reuses the existing billing path: every period is a normal
--    billable item created by billable_from_contract (so the per-line remaining-quantity cap, the discount proration and the signed/active contract check all
--    apply unchanged). Nothing is billed outside a contract.
--  * Running is explicit and idempotent: billing_schedule_run(as_of) bills every period that has come due, once. A period can never be billed twice (unique
--    (schedule, period start) plus a row lock on the schedule). Concurrent runs skip schedules another run holds.
--  * A schedule ends itself when the line is fully billed or its end date passes; it pauses itself when the contract no longer allows billing.
--  * Optionally a run also prepares ONE DRAFT invoice per schedule from the periods it just billed. It never issues anything.
--  * Progress (periods billed, quantity billed, remaining) is DERIVED from the run log and the billable items, never stored.
--  * Permissions reuse invoices.create (to schedule and run) and invoices.view (to read); no new permission rows.

create type billing_schedule_status as enum ('active', 'paused', 'ended');

create table billing_schedules (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references contracts (id) on delete restrict,
  origin_line_id      uuid not null references contract_lines (id) on delete restrict,
  interval_months     integer not null check (interval_months in (1, 3, 6, 12)),
  quantity_per_period numeric(12,2) not null default 1 check (quantity_per_period > 0),
  first_period_start  date not null,
  next_bill_on        date not null,
  end_on              date,
  status              billing_schedule_status not null default 'active',
  status_reason       text,
  created_by          uuid references staff (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (next_bill_on >= first_period_start),
  check (end_on is null or end_on >= first_period_start),
  check (status = 'active' or status_reason is not null)
);
create unique index billing_schedules_one_live_per_line on billing_schedules (contract_id, origin_line_id) where status <> 'ended';
create index billing_schedules_due_idx on billing_schedules (next_bill_on) where status = 'active';
comment on table billing_schedules is 'Purpose: recurring billing of one contract line (quantity per period, every 1/3/6/12 months, billed in advance on the period start). Written only by the billing_schedule_* functions; every period goes through billable_from_contract so the contract caps apply. Progress is derived (billing_schedule_progress). [class: confidential]';

create table billing_schedule_runs (
  id               uuid primary key default gen_random_uuid(),
  schedule_id      uuid not null references billing_schedules (id) on delete restrict,
  period_start     date not null,
  billable_item_id uuid not null references billable_items (id) on delete restrict,
  invoice_id       uuid references invoices (id) on delete restrict,
  quantity         numeric(12,2) not null,
  run_by           uuid references staff (id),
  run_at           timestamptz not null default now(),
  unique (schedule_id, period_start)
);
create index billing_schedule_runs_item_idx on billing_schedule_runs (billable_item_id);
comment on table billing_schedule_runs is 'Purpose: the append-only log of billed periods; the unique (schedule, period start) is what makes a period impossible to bill twice. Never updated or deleted. [class: confidential]';

create function billing_schedule_runs_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op <> 'INSERT' then raise exception 'the billing run log is append-only' using errcode = '42501'; end if;
  return new;
end $$;
create trigger billing_schedule_runs_guard_trg before insert or update or delete on billing_schedule_runs for each row execute function billing_schedule_runs_guard();

-- The terms of a schedule are fixed; only its position (next_bill_on), status and end date move, and an ended schedule is final.
create function billing_schedules_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then raise exception 'a billing schedule is never deleted: end it' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if (new.contract_id, new.origin_line_id, new.interval_months, new.quantity_per_period, new.first_period_start, new.created_by)
       is distinct from (old.contract_id, old.origin_line_id, old.interval_months, old.quantity_per_period, old.first_period_start, old.created_by) then
      raise exception 'the terms of a billing schedule cannot be changed: end it and create a new one' using errcode = '42501';
    end if;
    if old.status = 'ended' then raise exception 'an ended billing schedule is final' using errcode = '42501'; end if;
  end if;
  return new;
end $$;
create trigger billing_schedules_updated before update on billing_schedules for each row execute function set_updated_at();
create trigger billing_schedules_guard_trg before update or delete on billing_schedules for each row execute function billing_schedules_guard();

-- ---------------------------------------------------------------------------
-- Visibility: a schedule is as visible as its contract (and needs invoices.view); a restricted contract's schedules look absent.
-- ---------------------------------------------------------------------------
create function can_view_billing_schedule_contract(p_contract uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_contract_row(c.division_id, c.effective_classification, c.client_deleted) and has_permission('invoices.view', c.division_id)
                     from contracts c where c.id = p_contract), false)
$$;
create function can_view_billing_schedule(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_billing_schedule_contract(s.contract_id) from billing_schedules s where s.id = p_id), false)
$$;

-- Quantity of the line (by origin) that the terms in force still allow to be billed: the same measure billable_from_contract enforces.
create function billing_line_remaining(p_origin uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select l.quantity from contract_lines l join contract_versions v on v.id = l.version_id
                    where v.status = 'signed' and l.origin_line_id = p_origin), 0)
       - coalesce((select sum(b.quantity) from billable_items b where b.contract_line_origin_id = p_origin and b.status <> 'void'), 0)
$$;
revoke execute on function billing_line_remaining(uuid) from public, anon, authenticated;

create view billing_schedule_progress with (security_invoker = true) as
select s.id as schedule_id, s.contract_id, s.origin_line_id, s.status, s.interval_months, s.quantity_per_period, s.first_period_start, s.next_bill_on, s.end_on,
       (select count(*) from billing_schedule_runs r where r.schedule_id = s.id)::integer as periods_billed,
       coalesce((select sum(r.quantity) from billing_schedule_runs r where r.schedule_id = s.id), 0) as quantity_billed,
       greatest(billing_line_remaining(s.origin_line_id), 0) as line_remaining
  from billing_schedules s;

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
create function billing_schedule_create(p_contract uuid, p_line uuid, p_interval_months integer, p_first_period_start date,
                                        p_quantity numeric default 1, p_end_on date default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype; v_origin uuid; v_id uuid;
begin
  c := contract_load(p_contract);
  if not has_permission('invoices.create', c.division_id) then raise exception 'invoices.create is required in that division' using errcode = '42501'; end if;
  if c.status not in ('signed', 'active') then raise exception 'only a signed or active contract can be scheduled (currently %)', c.status using errcode = '23514'; end if;
  if p_interval_months is null or p_interval_months not in (1, 3, 6, 12) then raise exception 'the interval must be 1, 3, 6 or 12 months' using errcode = '23514'; end if;
  if p_first_period_start is null then raise exception 'the first period start is required' using errcode = '23514'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'the quantity per period must be positive' using errcode = '23514'; end if;
  if p_end_on is not null and p_end_on < p_first_period_start then raise exception 'the end date is before the first period' using errcode = '23514'; end if;
  select l.origin_line_id into v_origin from contract_lines l join contract_versions v on v.id = l.version_id where l.id = p_line and v.contract_id = c.id;
  if v_origin is null then raise exception 'contract line not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from contract_lines l join contract_versions v on v.id = l.version_id where v.contract_id = c.id and v.status = 'signed' and l.origin_line_id = v_origin) then
    raise exception 'that line is not part of the terms currently in force' using errcode = '23514';
  end if;
  if billing_line_remaining(v_origin) <= 0 then raise exception 'that line is already fully billed' using errcode = '23514'; end if;
  if exists (select 1 from billing_schedules where contract_id = c.id and origin_line_id = v_origin and status <> 'ended') then
    raise exception 'this line already has a billing schedule: end it first' using errcode = '23505';
  end if;
  insert into billing_schedules (contract_id, origin_line_id, interval_months, quantity_per_period, first_period_start, next_bill_on, end_on, created_by)
  values (c.id, v_origin, p_interval_months, p_quantity, p_first_period_start, p_first_period_start, p_end_on, current_staff_id())
  returning id into v_id;
  return v_id;
end $$;

-- pause / resume / end. Resuming bills the periods missed while paused on the next run, unless p_skip_missed moves the schedule to the first period after today.
create function billing_schedule_set_status(p_schedule uuid, p_status billing_schedule_status, p_reason text default null, p_skip_missed boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s billing_schedules%rowtype; c contracts%rowtype; v_next date; v_k integer;
begin
  select * into s from billing_schedules where id = p_schedule;
  if not found or not can_view_billing_schedule_contract(s.contract_id) then raise exception 'billing schedule not found' using errcode = 'P0002'; end if;
  c := contract_load(s.contract_id);
  select * into s from billing_schedules where id = p_schedule for update;
  if not has_permission('invoices.create', c.division_id) then raise exception 'invoices.create is required in that division' using errcode = '42501'; end if;
  if s.status = 'ended' then raise exception 'an ended billing schedule is final' using errcode = '42501'; end if;
  if p_status = s.status then return; end if;
  if p_status in ('paused', 'ended') and coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if p_status = 'active' then
    if c.status not in ('signed', 'active') then raise exception 'the contract is % and cannot be billed', c.status using errcode = '23514'; end if;
    v_next := s.next_bill_on;
    if p_skip_missed then
      v_k := (select count(*) from billing_schedule_runs where schedule_id = s.id)::integer;
      while v_next <= current_date loop
        v_k := v_k + 1;
        v_next := (s.first_period_start + make_interval(months => s.interval_months * v_k))::date;
      end loop;
    end if;
    update billing_schedules set status = 'active', status_reason = null, next_bill_on = v_next where id = s.id;
  else
    update billing_schedules set status = p_status, status_reason = p_reason where id = s.id;
  end if;
end $$;

-- Bills every period that has come due (period start <= p_as_of), at most 12 periods per schedule per run. Returns one outcome per schedule it touched.
create function billing_schedule_run(p_as_of date default current_date, p_create_invoices boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s billing_schedules%rowtype; c contracts%rowtype; v_out jsonb := '[]'::jsonb; v_staff uuid := current_staff_id();
  v_items uuid[]; v_periods date[]; v_qtys numeric[]; v_item uuid; v_invoice uuid; v_next date; v_k integer; v_remaining numeric; v_qty numeric;
  v_state text; v_msg text; v_code text; i integer;
begin
  if p_as_of is null then raise exception 'choose the date to run for' using errcode = '23514'; end if;
  for s in select * from billing_schedules where status = 'active' and next_bill_on <= p_as_of order by contract_id, id for update skip locked loop
    -- other people's (or restricted) schedules are simply not part of this caller's run
    continue when not can_view_billing_schedule_contract(s.contract_id);
    select * into c from contracts where id = s.contract_id;
    continue when not has_permission('invoices.create', c.division_id);
    v_items := '{}'; v_periods := '{}'; v_qtys := '{}'; v_invoice := null; v_state := 'billed'; v_msg := null; v_code := null;
    v_k := (select count(*) from billing_schedule_runs where schedule_id = s.id)::integer;
    v_next := s.next_bill_on;
    begin
      while v_next <= p_as_of and cardinality(v_items) < 12 loop
        if s.end_on is not null and v_next > s.end_on then v_state := 'ended'; v_msg := 'the end date has passed'; exit; end if;
        v_remaining := billing_line_remaining(s.origin_line_id);
        if v_remaining <= 0 then v_state := 'ended'; v_msg := 'the line is fully billed'; exit; end if;
        v_qty := least(s.quantity_per_period, v_remaining);
        v_item := billable_from_contract(s.contract_id, s.origin_line_id, v_qty);
        v_items := v_items || v_item; v_periods := v_periods || v_next; v_qtys := v_qtys || v_qty;
        v_k := v_k + 1;
        v_next := (s.first_period_start + make_interval(months => s.interval_months * v_k))::date;
      end loop;
      if v_state = 'billed' and s.end_on is not null and v_next > s.end_on then v_state := 'ended'; v_msg := 'the end date has passed'; end if;
      if v_state = 'billed' and p_create_invoices and cardinality(v_items) > 0 then v_invoice := invoice_create(v_items); end if;
      for i in 1 .. coalesce(cardinality(v_items), 0) loop
        insert into billing_schedule_runs (schedule_id, period_start, billable_item_id, invoice_id, quantity, run_by)
        values (s.id, v_periods[i], v_items[i], v_invoice, v_qtys[i], v_staff);
      end loop;
      update billing_schedules set next_bill_on = v_next, status = case when v_state = 'ended' then 'ended' else status end,
             status_reason = case when v_state = 'ended' then v_msg else status_reason end where id = s.id;
    exception when others then
      -- everything this schedule did in this run is undone; the failure is reported, not hidden
      v_state := 'failed'; v_msg := sqlerrm; v_code := sqlstate; v_items := '{}'; v_invoice := null;
    end;
    if v_state = 'failed' and v_code in ('23514', 'P0002') then
      -- the contract or the line no longer allows billing: park the schedule rather than fail on every run
      update billing_schedules set status = 'paused', status_reason = 'paused by a run: ' || v_msg where id = s.id;
      v_state := 'paused';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('schedule_id', s.id, 'contract_id', s.contract_id, 'outcome', v_state,
               'periods_billed', coalesce(cardinality(v_items), 0), 'invoice_id', v_invoice, 'message', v_msg));
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table billing_schedules      enable row level security;
alter table billing_schedule_runs  enable row level security;
revoke all on billing_schedules, billing_schedule_runs, billing_schedule_progress from anon, authenticated;
grant select on billing_schedules, billing_schedule_runs, billing_schedule_progress to authenticated;
create policy billing_schedules_select on billing_schedules for select to authenticated using (can_view_billing_schedule_contract(contract_id));
create policy billing_schedule_runs_select on billing_schedule_runs for select to authenticated using (can_view_billing_schedule(schedule_id));

revoke execute on function can_view_billing_schedule_contract(uuid), can_view_billing_schedule(uuid),
  billing_schedule_create(uuid, uuid, integer, date, numeric, date), billing_schedule_set_status(uuid, billing_schedule_status, text, boolean),
  billing_schedule_run(date, boolean) from public, anon, authenticated;
grant execute on function can_view_billing_schedule_contract(uuid), can_view_billing_schedule(uuid),
  billing_schedule_create(uuid, uuid, integer, date, numeric, date), billing_schedule_set_status(uuid, billing_schedule_status, text, boolean),
  billing_schedule_run(date, boolean) to authenticated;

do $$ begin
  perform attach_audit('billing_schedules');
  perform attach_audit('billing_schedule_runs');
end $$;
