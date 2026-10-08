-- 0016_services_pricing: ONE service catalogue and ONE pricing system, plus a shared approvals inbox.
--  * services belong to a division; every website, quote and report reads the same rows.
--  * prices are immutable VERSIONS with effective dates; a change is proposed, approved by someone else
--    (unless they hold pricing.approve_own), and never overwrites history.
--  * quotes/invoices (next migrations) snapshot the version they used, so history stays true.

insert into entity_types (key, prefix, description) values
  ('service',   'SVC', 'Service in the central catalogue'),
  ('quote',     'QUO', 'Quotation to a client'),
  ('portfolio', 'PFO', 'Portfolio entry derived from a completed project');

-- ---------------------------------------------------------------------------
-- Shared approvals inbox (the entity's own status stays authoritative; this is the uniform record + queue)
-- ---------------------------------------------------------------------------
create type approval_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create table approval_requests (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null,
  entity_table        text not null,
  entity_id           uuid not null,
  entity_ada_id       text,
  division_id         uuid references divisions (id),
  required_permission text not null,
  summary             text,
  requested_by        uuid references staff (id),
  requested_at        timestamptz not null default now(),
  status              approval_status not null default 'pending',
  decided_by          uuid references staff (id),
  decided_at          timestamptz,
  decision_note       text
);
create unique index approval_requests_one_pending on approval_requests (entity_table, entity_id) where status = 'pending';
create index approval_requests_queue_idx on approval_requests (required_permission, status);
comment on table approval_requests is 'Purpose: one uniform queue and history of everything awaiting or having received approval (vacancies, profiles, services, prices, quotes, ...). Written only by triggers. [class: restricted]';

create function approval_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  j jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
  v_status text := j ->> 'status';
  v_old text := o ->> 'status';
  v_req uuid;
begin
  if v_status = 'pending_approval' and (tg_op = 'INSERT' or v_old is distinct from 'pending_approval') then
    update approval_requests set status = 'cancelled', decided_at = now()
     where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
    insert into approval_requests (kind, entity_table, entity_id, entity_ada_id, division_id, required_permission, summary, requested_by)
    values (tg_argv[0], tg_table_name, new.id, j ->> 'ada_id', nullif(j ->> nullif(tg_argv[3], ''), '')::uuid, tg_argv[1],
            j ->> tg_argv[2], current_staff_id());
  elsif tg_op = 'UPDATE' and v_old = 'pending_approval' and v_status <> 'pending_approval' then
    select requested_by into v_req from approval_requests where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
    update approval_requests
       set status = case when v_status in ('approved', 'published') then 'approved'::approval_status
                         when v_status in ('rejected') or (v_status = 'draft' and v_req is distinct from current_staff_id()) then 'rejected'::approval_status
                         else 'cancelled'::approval_status end,
           decided_by = current_staff_id(), decided_at = now(), decision_note = coalesce(j ->> 'status_reason', j ->> 'decision_note')
     where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
  end if;
  return null;
end $$;

-- Four-eyes rule: you may not approve your own request unless you hold the "approve_own" permission.
create function assert_not_own_request(p_requested_by uuid, p_own_permission text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_requested_by is not null and p_requested_by = current_staff_id() and not has_permission(p_own_permission) then
    raise exception 'you cannot approve your own request' using errcode = '42501';
  end if;
end $$;
revoke execute on function assert_not_own_request(uuid, text) from public, anon, authenticated;

-- Generic published/unpublished event emitter for publishable entities.
create function publication_events() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'published' and old.status <> 'published' then
    perform emit_event(tg_argv[0] || '.published', tg_table_name, new.id, to_jsonb(new) ->> 'ada_id', jsonb_build_object('status', 'published'));
  elsif old.status = 'published' and new.status <> 'published' then
    perform emit_event(tg_argv[0] || '.unpublished', tg_table_name, new.id, to_jsonb(new) ->> 'ada_id', jsonb_build_object('status', new.status));
  end if;
  return null;
end $$;

-- NOTE: these triggers deliberately fire on ANY update. "UPDATE OF status" would be skipped when a BEFORE trigger
-- (not the statement) changes status - e.g. editing a published record demotes it to draft - and the event / queue
-- update would be silently lost.
drop trigger staff_profiles_events_trg on staff_profiles;
create trigger staff_profiles_events_trg after update on staff_profiles for each row execute function staff_profiles_events();

-- Retrofit the approvals queue onto vacancies and staff profiles (their functions are unchanged).
create trigger approval_sync_trg after insert or update on vacancies
  for each row execute function approval_sync('vacancy', 'vacancies.publish', 'title', 'division_id');
create trigger approval_sync_trg after insert or update on staff_profiles
  for each row execute function approval_sync('profile', 'profiles.publish', 'public_name', '');

alter table approval_requests enable row level security;
revoke all on approval_requests from anon, authenticated;
grant select on approval_requests to authenticated;
create policy approval_requests_select on approval_requests for select to authenticated
  using (requested_by = current_staff_id() or has_permission(required_permission, division_id));

-- ---------------------------------------------------------------------------
-- Services
-- ---------------------------------------------------------------------------
create type pricing_model as enum ('fixed', 'hourly', 'monthly', 'per_unit', 'quote_based');

create table services (
  id              uuid primary key default gen_random_uuid(),
  ada_id          text not null unique,
  division_id     uuid not null references divisions (id) on delete restrict,
  name            text not null check (btrim(name) <> ''),
  category        text,
  summary         text check (length(summary) <= 500),
  description     text,
  pricing_model   pricing_model not null default 'fixed',
  billing_unit    text not null default 'project',
  is_active       boolean not null default true,
  show_price      boolean not null default true,
  status          publication_state not null default 'draft',
  approved_by     uuid references staff (id),
  approved_at     timestamptz,
  published_at    timestamptz,
  status_reason   text,
  classification  data_classification not null default 'internal',
  created_by      uuid references staff (id),
  deleted_at      timestamptz,
  deleted_by      uuid references staff (id),
  deletion_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index services_name_unique on services (division_id, lower(btrim(name))) where deleted_at is null;
comment on table services is 'Purpose: the ONE service catalogue. Websites, quotes, projects and reports reference these rows; none keeps its own list. Public only when status = published. [class: internal]';
comment on column services.is_active is 'Operational availability (can it be quoted today?) - independent of publication.';
do $$ begin perform attach_ada_id('services', 'service'); end $$;
create trigger services_updated     before update on services for each row execute function set_updated_at();
create trigger services_soft_delete before update on services for each row execute function soft_delete_guard('services');
create trigger services_classify    before insert or update on services for each row execute function classification_guard();
create trigger approval_sync_trg    after insert or update on services
  for each row execute function approval_sync('service_publication', 'services.publish', 'name', 'division_id');
create trigger publication_events_trg after update on services for each row execute function publication_events('service');

create function services_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if is_untrusted_caller() and new.status <> 'draft' then
      raise exception 'services are created as drafts' using errcode = '42501';
    end if;
    return new;
  end if;
  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at
       or new.published_at is distinct from old.published_at or new.status_reason is distinct from old.status_reason then
      raise exception 'service status is changed only through service_transition()' using errcode = '42501';
    end if;
    if new.division_id is distinct from old.division_id then
      raise exception 'a service cannot move between divisions; create it in the right one' using errcode = '42501';
    end if;
    -- editing public content invalidates earlier approval
    if (new.name, new.category, new.summary, new.description, new.pricing_model, new.billing_unit, new.show_price)
       is distinct from (old.name, old.category, old.summary, old.description, old.pricing_model, old.billing_unit, old.show_price)
       and old.status in ('pending_approval', 'approved', 'published') then
      new.status := 'draft'; new.approved_by := null; new.approved_at := null; new.published_at := null;
      new.status_reason := 'edited after approval; needs re-approval';
    end if;
  end if;
  return new;
end $$;
create trigger services_guard_trg before insert or update on services for each row execute function services_guard();

-- ---------------------------------------------------------------------------
-- Price versions
-- ---------------------------------------------------------------------------
create type price_status as enum ('pending_approval', 'approved', 'rejected', 'withdrawn');

create table service_prices (
  id             uuid primary key default gen_random_uuid(),
  service_id     uuid not null references services (id) on delete restrict,
  version        integer not null,
  amount         numeric(14,2) check (amount >= 0),
  currency       char(3) not null default 'NAD',
  effective_from date not null,
  effective_to   date,
  status         price_status not null default 'pending_approval',
  reason         text not null check (btrim(reason) <> ''),
  proposed_by    uuid references staff (id),
  proposed_at    timestamptz not null default now(),
  approved_by    uuid references staff (id),
  approved_at    timestamptz,
  decision_note  text,
  created_at     timestamptz not null default now(),
  unique (service_id, version),
  check (effective_to is null or effective_to >= effective_from)
);
create unique index service_prices_one_pending on service_prices (service_id) where status = 'pending_approval';
create index service_prices_lookup_idx on service_prices (service_id, effective_from desc) where status = 'approved';
comment on table service_prices is 'Purpose: immutable price versions. An approved version never changes (only effective_to is set when a later version takes over). Quotes and invoices copy the version they used. [class: restricted until approved; internal after]';
create trigger approval_sync_trg after insert or update on service_prices
  for each row execute function approval_sync('price_change', 'pricing.approve', 'reason', '');

create function service_prices_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'approved' then raise exception 'approved prices cannot be deleted' using errcode = '42501'; end if;
    return old;
  end if;
  if old.status = 'approved' then
    if (new.amount, new.currency, new.effective_from, new.service_id, new.version, new.reason, new.proposed_by, new.approved_by, new.approved_at)
       is distinct from (old.amount, old.currency, old.effective_from, old.service_id, old.version, old.reason, old.proposed_by, old.approved_by, old.approved_at)
       or new.status is distinct from old.status then
      raise exception 'approved prices are immutable (only effective_to may be set when a newer version takes over)' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger service_prices_immutable_trg before update or delete on service_prices for each row execute function service_prices_immutable();

-- The price in force for a service on a date (null row when there is none).
create function price_on(p_service uuid, p_date date default current_date) returns service_prices
language sql stable as $$
  select * from service_prices
   where service_id = p_service and status = 'approved' and effective_from <= p_date and (effective_to is null or effective_to >= p_date)
   order by effective_from desc limit 1
$$;

create function service_division(p_service uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$ select division_id from services where id = p_service $$;

create function can_view_service_row(p_class data_classification, p_deleted timestamptz) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select is_active_staff() and (p_deleted is null or has_permission('records.view_deleted'))
     and (p_class in ('public', 'internal')
          or (p_class = 'restricted' and has_permission('records.view_restricted'))
          or (p_class = 'confidential' and has_permission('records.view_confidential')))
$$;

create function can_view_service(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_service_row(classification, deleted_at) from services where id = p_id), false)
$$;

-- Propose a new price version. It takes effect only after approval, never before its effective date.
create function price_propose(p_service uuid, p_amount numeric, p_currency text, p_effective_from date, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s services%rowtype;
  v_latest date;
  v_id uuid;
begin
  select * into s from services where id = p_service and deleted_at is null for update;
  if not found or not has_permission('pricing.propose', s.division_id) then
    raise exception 'pricing.propose is required for this service' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required for a price change' using errcode = '23514'; end if;
  if p_effective_from is null or p_effective_from < current_date then
    raise exception 'the effective date cannot be in the past' using errcode = '23514';
  end if;
  if s.pricing_model = 'quote_based' then
    if p_amount is not null then raise exception 'a quote-based service has no list price' using errcode = '23514'; end if;
  elsif p_amount is null or p_amount < 0 then
    raise exception 'a non-negative amount is required' using errcode = '23514';
  end if;
  select max(effective_from) into v_latest from service_prices where service_id = p_service and status = 'approved';
  if v_latest is not null and p_effective_from <= v_latest then
    raise exception 'the new price must take effect after the current version (%)', v_latest using errcode = '23514';
  end if;
  begin
    insert into service_prices (service_id, version, amount, currency, effective_from, reason, proposed_by)
    values (p_service, coalesce((select max(version) from service_prices where service_id = p_service), 0) + 1,
            p_amount, upper(coalesce(p_currency, 'NAD')), p_effective_from, p_reason, current_staff_id())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'a price change is already awaiting approval for this service' using errcode = '23505';
  end;
  perform notify_holders('pricing.approve', null, 'approval.required', 'Price change awaiting approval: ' || s.name,
                         p_reason, 'service_prices', v_id, s.ada_id);
  return v_id;
end $$;

create function price_decide(p_price uuid, p_approve boolean, p_note text default null) returns service_prices
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p service_prices%rowtype;
  s services%rowtype;
  v_latest date;
begin
  if not has_permission('pricing.approve') then
    raise exception 'pricing.approve is required' using errcode = '42501';
  end if;
  select * into p from service_prices where id = p_price for update;
  if not found then raise exception 'price not found' using errcode = 'P0002'; end if;
  select * into s from services where id = p.service_id;
  if p.status <> 'pending_approval' then raise exception 'this price is already %', p.status using errcode = '23514'; end if;
  perform assert_not_own_request(p.proposed_by, 'pricing.approve_own');

  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a price' using errcode = '23514'; end if;
    update service_prices set status = 'rejected', decision_note = p_note, approved_by = null where id = p_price returning * into p;
    return p;
  end if;

  select max(effective_from) into v_latest from service_prices where service_id = p.service_id and status = 'approved';
  if v_latest is not null and p.effective_from <= v_latest then
    raise exception 'a newer price (%) has been approved since this was proposed', v_latest using errcode = '23514';
  end if;
  if p.effective_from < current_date then
    -- approving late must not rewrite the past: the version starts today at the earliest
    update service_prices set effective_from = current_date where id = p_price;
    p.effective_from := current_date;
    if v_latest is not null and p.effective_from <= v_latest then
      raise exception 'a newer price (%) has been approved since this was proposed', v_latest using errcode = '23514';
    end if;
  end if;
  update service_prices set effective_to = p.effective_from - 1
   where service_id = p.service_id and status = 'approved' and effective_to is null;
  update service_prices set status = 'approved', approved_by = current_staff_id(), approved_at = now(), decision_note = p_note
   where id = p_price returning * into p;
  perform emit_event('price.changed', 'service_prices', p.id, s.ada_id,
                     jsonb_build_object('service', s.ada_id, 'effective_from', p.effective_from, 'status', 'approved'));
  if p.proposed_by is not null then
    insert into notifications (recipient_staff_id, type, title, entity_table, entity_id, entity_ada_id)
    values (p.proposed_by, 'price.approved', 'Price approved for ' || s.name, 'service_prices', p.id, s.ada_id);
  end if;
  return p;
end $$;

create function price_withdraw(p_price uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p service_prices%rowtype;
begin
  select * into p from service_prices where id = p_price for update;
  if not found then raise exception 'price not found' using errcode = 'P0002'; end if;
  if p.status <> 'pending_approval' then raise exception 'only a pending price can be withdrawn' using errcode = '23514'; end if;
  if p.proposed_by is distinct from current_staff_id() and not has_permission('pricing.approve') then
    raise exception 'only the proposer or an approver can withdraw this price' using errcode = '42501';
  end if;
  update service_prices set status = 'withdrawn' where id = p_price;
end $$;

-- ---------------------------------------------------------------------------
-- Service publication workflow
-- ---------------------------------------------------------------------------
create function service_transition(p_id uuid, p_to publication_state, p_reason text default null) returns publication_state
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s services%rowtype;
  v_edit boolean;
  v_pub boolean;
  v_has_price boolean;
begin
  select * into s from services where id = p_id and deleted_at is null for update;
  if not found or not can_view_service(p_id) then raise exception 'service not found' using errcode = 'P0002'; end if;
  v_edit := has_permission('services.update', s.division_id);
  v_pub := has_permission('services.publish');

  case
    when s.status in ('draft', 'unpublished') and p_to = 'pending_approval' then
      if not v_edit then raise exception 'services.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(s.summary), '') = '' or coalesce(btrim(s.description), '') = '' then
        raise exception 'a summary and description are required before approval' using errcode = '23514';
      end if;
      update services set status = p_to, status_reason = null where id = p_id;
      perform notify_holders('services.publish', null, 'approval.required', 'Service awaiting approval: ' || s.name, null, 'services', s.id, s.ada_id);
    when s.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_pub) then raise exception 'not permitted' using errcode = '42501'; end if;
      update services set status = p_to, status_reason = p_reason where id = p_id;
    when s.status = 'pending_approval' and p_to = 'approved' then
      if not v_pub then raise exception 'services.publish is required to approve' using errcode = '42501'; end if;
      update services set status = p_to, approved_by = current_staff_id(), approved_at = now(), status_reason = null where id = p_id;
    when s.status = 'approved' and p_to = 'published' then
      if not v_pub then raise exception 'services.publish is required to publish' using errcode = '42501'; end if;
      select (price_on(p_id)).id is not null into v_has_price;
      if s.show_price and s.pricing_model <> 'quote_based' and not v_has_price then
        raise exception 'publish needs an approved price in force, or turn off show_price' using errcode = '23514';
      end if;
      update services set status = p_to, published_at = now() where id = p_id;
    when s.status = 'published' and p_to = 'unpublished' then
      if not v_pub then raise exception 'services.publish is required to unpublish' using errcode = '42501'; end if;
      update services set status = p_to, published_at = null, status_reason = p_reason where id = p_id;
    when s.status <> 'archived' and p_to = 'archived' then
      if not v_pub then raise exception 'services.publish is required to archive' using errcode = '42501'; end if;
      update services set status = p_to, published_at = null, is_active = false, status_reason = p_reason where id = p_id;
    else
      raise exception 'invalid service transition % -> %', s.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table services       enable row level security;
alter table service_prices enable row level security;
revoke all on services, service_prices from anon, authenticated;
grant select, insert, update on services to authenticated;
grant select on service_prices to authenticated;

create policy services_select on services for select to authenticated using (can_view_service_row(classification, deleted_at));
create policy services_insert on services for insert to authenticated with check (has_permission('services.create', division_id));
create policy services_update on services for update to authenticated
  using (has_permission('services.update', division_id)) with check (has_permission('services.update', division_id));
-- Approved prices are readable by all staff who can see the service; proposals only by those involved.
create policy service_prices_select on service_prices for select to authenticated
  using (can_view_service(service_id)
         and (status = 'approved' or proposed_by = current_staff_id() or has_permission('pricing.approve')
              or has_permission('pricing.propose', service_division(service_id))));

revoke execute on function price_on(uuid, date), service_division(uuid), can_view_service_row(data_classification, timestamptz), can_view_service(uuid),
  price_propose(uuid, numeric, text, date, text), price_decide(uuid, boolean, text), price_withdraw(uuid),
  service_transition(uuid, publication_state, text) from public, anon;
grant execute on function price_on(uuid, date), service_division(uuid), can_view_service_row(data_classification, timestamptz), can_view_service(uuid),
  price_propose(uuid, numeric, text, date, text), price_decide(uuid, boolean, text), price_withdraw(uuid),
  service_transition(uuid, publication_state, text) to authenticated;

do $$ begin perform attach_audit('services'); end $$;
do $$ begin perform attach_audit('service_prices'); end $$;

-- ---------------------------------------------------------------------------
-- Public API: the approved catalogue with the price currently in force
-- ---------------------------------------------------------------------------
create function public_api.services(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'services.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', s.ada_id, 'name', s.name, 'category', s.category, 'summary', s.summary, 'description', s.description,
      'pricing_model', s.pricing_model, 'billing_unit', s.billing_unit,
      'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end,
      'price', case when s.show_price and s.pricing_model <> 'quote_based' and (price_on(s.id)).id is not null
                    then jsonb_build_object('amount', (price_on(s.id)).amount, 'currency', (price_on(s.id)).currency,
                                            'effective_from', (price_on(s.id)).effective_from) end)) order by d.sort_order, s.name)
    from services s join divisions d on d.id = s.division_id
    where s.status = 'published' and s.is_active and s.deleted_at is null and (p_division is null or d.key = p_division)), '[]'::jsonb);
end $$;
revoke all on function public_api.services(text, text) from public, anon, authenticated;
grant execute on function public_api.services(text, text) to ada_public_api;

-- ---------------------------------------------------------------------------
-- Hardening of earlier helpers: they must not confirm the existence or placement of records the caller
-- cannot see (they are executable by every signed-in user because RLS policies call them as the invoker).
-- ---------------------------------------------------------------------------
create or replace function application_division(p_application uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select v.division_id from applications a join vacancies v on v.id = a.vacancy_id
   where a.id = p_application and has_permission('applications.view', v.division_id)
$$;

create or replace function service_division(p_service uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select division_id from services where id = p_service and can_view_service(id)
$$;

create or replace function position_open_capacity(p_position uuid, p_exclude_vacancy uuid default null) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not (has_permission_anywhere('vacancies.view') or has_permission('positions.manage')) then null else
         p.headcount
       - (select count(*) from staff s where s.position_id = p.id and s.deleted_at is null
            and s.employment_status in ('active', 'on_leave', 'contractor', 'suspended'))::integer
       - coalesce((select sum(v.openings) from vacancies v
            where v.position_id = p.id and v.status in ('approved', 'published') and v.deleted_at is null
              and v.id is distinct from p_exclude_vacancy), 0)::integer end
  from positions p where p.id = p_position
$$;
