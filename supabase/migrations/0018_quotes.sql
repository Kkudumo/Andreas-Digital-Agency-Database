-- 0018_quotes: a quote is a priced proposal TO an existing client, FROM a division, built from catalogue services.
--  * every service line records the price VERSION it used and copies the amount (snapshot), so later price
--    changes never alter a quote - and the same snapshot flows on to the project (and later the invoice);
--  * lines are editable only while the quote is a draft; the lifecycle is controlled and approved;
--  * accepting a quote converts it - once - into a project linked to the same client, contact and services.

create type quote_status as enum ('draft', 'pending_approval', 'approved', 'sent', 'accepted', 'rejected', 'expired', 'cancelled');

create table quotes (
  id                uuid primary key default gen_random_uuid(),
  ada_id            text not null unique,
  client_id         uuid not null references clients (id) on delete restrict,
  contact_id        uuid references client_contacts (id),
  division_id       uuid not null references divisions (id),
  project_id        uuid references projects (id),
  title             text not null check (btrim(title) <> ''),
  intro             text,
  terms             text,
  currency          char(3) not null default 'NAD',
  valid_until       date not null default (current_date + 30),
  assigned_staff_id uuid references staff (id),
  status            quote_status not null default 'draft',
  total             numeric(14,2) not null default 0,
  requested_by      uuid references staff (id),
  approved_by       uuid references staff (id),
  approved_at       timestamptz,
  sent_at           timestamptz,
  decided_at        timestamptz,
  decision_note     text,
  status_reason     text,
  converted_at      timestamptz,
  created_by        uuid references staff (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index quotes_client_idx on quotes (client_id);
create index quotes_status_idx on quotes (status);
comment on table quotes is 'Purpose: a priced proposal from a division to an existing client. Links to client, contact, division, project and (via lines) services and price versions. total is maintained from the lines. [class: restricted]';
do $$ begin perform attach_ada_id('quotes', 'quote'); end $$;
create trigger quotes_updated before update on quotes for each row execute function set_updated_at();
create trigger approval_sync_trg after insert or update on quotes
  for each row execute function approval_sync('quote', 'quotes.approve', 'title', 'division_id');

create table quote_lines (
  id                    uuid primary key default gen_random_uuid(),
  quote_id              uuid not null references quotes (id) on delete restrict,
  position              integer not null default 100,
  service_id            uuid references services (id),
  price_id              uuid references service_prices (id),
  description           text not null check (btrim(description) <> ''),
  quantity              numeric(12,2) not null default 1 check (quantity > 0),
  unit_price            numeric(14,2) not null check (unit_price >= 0),
  discount_amount       numeric(14,2) not null default 0 check (discount_amount >= 0),
  price_override_reason text,
  line_total            numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2)) stored,
  created_at            timestamptz not null default now(),
  check (price_id is null or service_id is not null),
  check (discount_amount <= quantity * unit_price)
);
create index quote_lines_quote_idx on quote_lines (quote_id, position);
comment on table quote_lines is 'Purpose: quote line items. unit_price is a SNAPSHOT of the catalogue price version in price_id (or a stated override). Locked once the quote leaves draft. [class: restricted]';
alter table project_services add constraint project_services_quote_line_fk foreign key (quote_line_id) references quote_lines (id);

-- lines belong to a draft quote only
create function quote_lines_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_status quote_status;
begin
  select status into v_status from quotes where id = coalesce(new.quote_id, old.quote_id);
  if v_status <> 'draft' then
    raise exception 'quote lines are locked once the quote leaves draft' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger quote_lines_guard_trg before insert or update or delete on quote_lines for each row execute function quote_lines_guard();

create function quote_lines_total() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_quote uuid := coalesce(new.quote_id, old.quote_id);
begin
  update quotes set total = coalesce((select sum(line_total) from quote_lines where quote_id = v_quote), 0) where id = v_quote;
  return null;
end $$;
create trigger quote_lines_total_trg after insert or update or delete on quote_lines for each row execute function quote_lines_total();

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create function quotes_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    return new;
  end if;
  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.total is distinct from old.total or new.requested_by is distinct from old.requested_by
       or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at or new.sent_at is distinct from old.sent_at
       or new.decided_at is distinct from old.decided_at or new.decision_note is distinct from old.decision_note
       or new.status_reason is distinct from old.status_reason or new.converted_at is distinct from old.converted_at
       or new.client_id is distinct from old.client_id or new.division_id is distinct from old.division_id or new.currency is distinct from old.currency then
      raise exception 'quote status, totals, client and division are managed through the quote functions' using errcode = '42501';
    end if;
    if old.status <> 'draft' and (new.title, new.intro, new.terms, new.valid_until, new.contact_id, new.project_id)
       is distinct from (old.title, old.intro, old.terms, old.valid_until, old.contact_id, old.project_id) then
      raise exception 'a quote can only be edited while it is a draft' using errcode = '42501';
    end if;
  end if;
  if new.contact_id is distinct from (case when tg_op = 'UPDATE' then old.contact_id end) and new.contact_id is not null
     and not exists (select 1 from client_contacts cc where cc.id = new.contact_id and cc.client_id = new.client_id and cc.is_active) then
    raise exception 'the contact must be an active contact of the quote''s client' using errcode = '23514';
  end if;
  if new.project_id is not null and not exists (select 1 from projects p where p.id = new.project_id and p.client_id = new.client_id) then
    raise exception 'the project must belong to the quote''s client' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger quotes_guard_trg before insert or update on quotes for each row execute function quotes_guard();

-- ---------------------------------------------------------------------------
-- Visibility: commercial permission in the division AND visibility of the client
-- ---------------------------------------------------------------------------
create function can_view_quote_row(p_client uuid, p_division uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('quotes.view', p_division) and can_view_client(p_client)
$$;
create function can_view_quote(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_quote_row(client_id, division_id) from quotes where id = p_id), false)
$$;

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
create function quote_create(p_client uuid, p_division uuid, p_title text, p_contact uuid default null, p_project uuid default null,
                             p_valid_until date default null, p_intro text default null, p_terms text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; c clients%rowtype;
begin
  if not has_permission('quotes.create', p_division) then
    raise exception 'quotes.create is required in that division' using errcode = '42501';
  end if;
  select * into c from clients where id = p_client and deleted_at is null;
  if not found or not can_view_client(p_client) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if c.status = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
  insert into quotes (client_id, contact_id, division_id, project_id, title, intro, terms, valid_until, assigned_staff_id)
  values (p_client, p_contact, p_division, p_project, p_title, p_intro, p_terms, coalesce(p_valid_until, current_date + 30), current_staff_id())
  returning id into v_id;
  return v_id;
end $$;

create function quote_add_line(p_quote uuid, p_service uuid default null, p_quantity numeric default 1, p_unit_price numeric default null,
                               p_override_reason text default null, p_description text default null, p_discount numeric default 0) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  q quotes%rowtype;
  s services%rowtype;
  pr service_prices;
  v_id uuid;
  v_desc text;
begin
  select * into q from quotes where id = p_quote for update;
  if not found or not can_view_quote(p_quote) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  if not has_permission('quotes.update', q.division_id) then raise exception 'quotes.update is required' using errcode = '42501'; end if;
  if q.status <> 'draft' then raise exception 'quote lines are locked once the quote leaves draft' using errcode = '42501'; end if;

  if p_service is not null then
    select * into s from services where id = p_service and deleted_at is null and can_view_service(id);
    if not found then raise exception 'service not found' using errcode = 'P0002'; end if;
    pr := price_on(p_service, current_date);
    v_desc := coalesce(nullif(btrim(p_description), ''), s.name);
    if p_unit_price is null then
      if pr.id is null then raise exception 'this service has no approved price in force; give a price and a reason' using errcode = '23514'; end if;
      if pr.currency <> q.currency then raise exception 'the service price is in %, the quote is in %', pr.currency, q.currency using errcode = '23514'; end if;
      insert into quote_lines (quote_id, service_id, price_id, description, quantity, unit_price, discount_amount)
      values (p_quote, p_service, pr.id, v_desc, p_quantity, pr.amount, p_discount) returning id into v_id;
    else
      if coalesce(btrim(p_override_reason), '') = '' then raise exception 'a reason is required when the price differs from the catalogue' using errcode = '23514'; end if;
      insert into quote_lines (quote_id, service_id, price_id, description, quantity, unit_price, discount_amount, price_override_reason)
      values (p_quote, p_service, pr.id, v_desc, p_quantity, p_unit_price, p_discount, p_override_reason) returning id into v_id;
    end if;
  else
    if p_unit_price is null or coalesce(btrim(p_description), '') = '' then
      raise exception 'a custom line needs a description and a price' using errcode = '23514';
    end if;
    insert into quote_lines (quote_id, description, quantity, unit_price, discount_amount, price_override_reason)
    values (p_quote, p_description, p_quantity, p_unit_price, p_discount, p_override_reason) returning id into v_id;
  end if;
  return v_id;
end $$;

create function quote_remove_line(p_line uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare q quotes%rowtype;
begin
  select qu.* into q from quotes qu join quote_lines l on l.quote_id = qu.id where l.id = p_line for update of qu;
  if not found or not can_view_quote(q.id) then raise exception 'quote line not found' using errcode = 'P0002'; end if;
  if not has_permission('quotes.update', q.division_id) then raise exception 'quotes.update is required' using errcode = '42501'; end if;
  delete from quote_lines where id = p_line;
end $$;

create function quote_transition(p_id uuid, p_to quote_status, p_note text default null) returns quote_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  q quotes%rowtype;
  v_edit boolean;
  v_appr boolean;
  v_lines integer;
begin
  select * into q from quotes where id = p_id for update;
  if not found or not can_view_quote(p_id) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  v_edit := has_permission('quotes.update', q.division_id);
  v_appr := has_permission('quotes.approve');

  case
    when q.status = 'draft' and p_to = 'pending_approval' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      select count(*) into v_lines from quote_lines where quote_id = p_id;
      if v_lines = 0 then raise exception 'add at least one line before submitting' using errcode = '23514'; end if;
      if q.valid_until < current_date then raise exception 'the validity date is in the past' using errcode = '23514'; end if;
      if (select status from clients where id = q.client_id) = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
      update quotes set status = p_to, requested_by = current_staff_id(), status_reason = null where id = p_id;
      perform notify_holders('quotes.approve', null, 'approval.required', 'Quote awaiting approval: ' || q.title, null, 'quotes', q.id, q.ada_id);
    when q.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_appr) then raise exception 'not permitted' using errcode = '42501'; end if;
      update quotes set status = p_to, status_reason = p_note where id = p_id;
    when q.status = 'pending_approval' and p_to = 'approved' then
      if not v_appr then raise exception 'quotes.approve is required' using errcode = '42501'; end if;
      perform assert_not_own_request(q.requested_by, 'quotes.approve_own');
      update quotes set status = p_to, approved_by = current_staff_id(), approved_at = now(), status_reason = null where id = p_id;
    when q.status = 'approved' and p_to = 'sent' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if q.valid_until < current_date then raise exception 'the quote has expired' using errcode = '23514'; end if;
      update quotes set status = p_to, sent_at = now() where id = p_id;
    when q.status = 'sent' and p_to = 'accepted' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if q.valid_until < current_date then raise exception 'the quote expired on %', q.valid_until using errcode = '23514'; end if;
      update quotes set status = p_to, decided_at = now(), decision_note = p_note where id = p_id;
      perform emit_event('quote.accepted', 'quotes', q.id, q.ada_id, jsonb_build_object('status', 'accepted'));
      perform notify_holders('projects.create', q.division_id, 'quote.accepted', 'Quote accepted: ' || q.title, 'Convert it into a project.', 'quotes', q.id, q.ada_id);
    when q.status = 'sent' and p_to = 'rejected' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'record why the client declined' using errcode = '23514'; end if;
      update quotes set status = p_to, decided_at = now(), decision_note = p_note where id = p_id;
    when q.status in ('draft', 'pending_approval', 'approved', 'sent') and p_to = 'cancelled' then
      if not (v_edit or v_appr) then raise exception 'not permitted' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
      update quotes set status = p_to, status_reason = p_note where id = p_id;
    else
      raise exception 'invalid quote transition % -> %', q.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;

-- Scheduled job (service role): quotes past their validity date can no longer be accepted.
create function expire_quotes() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  update quotes set status = 'expired', status_reason = 'validity date passed'
   where status in ('approved', 'sent') and valid_until < current_date;
  get diagnostics n = row_count;
  return n;
end $$;

-- Accepted quote -> project, once, carrying client, contact, services and price snapshots.
create function quote_convert_to_project(p_quote uuid, p_project_name text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  q quotes%rowtype;
  v_project uuid;
begin
  select * into q from quotes where id = p_quote for update;
  if not found or not can_view_quote(p_quote) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  if q.status <> 'accepted' then raise exception 'only an accepted quote can be converted (currently %)', q.status using errcode = '23514'; end if;
  if q.converted_at is not null then return q.project_id; end if;               -- idempotent

  if q.project_id is not null then
    v_project := q.project_id;
    if not has_project_permission('projects.update', v_project) then raise exception 'projects.update is required' using errcode = '42501'; end if;
  else
    if not has_permission('projects.create', q.division_id) then raise exception 'projects.create is required in that division' using errcode = '42501'; end if;
    insert into projects (client_id, lead_division_id, name, description, status)
    values (q.client_id, q.division_id, coalesce(nullif(btrim(p_project_name), ''), q.title), q.intro, 'approved')
    returning id into v_project;
  end if;

  insert into project_services (project_id, service_id, quote_line_id, price_id, description, quantity, unit_price, discount_amount, currency, price_override_reason, created_by)
  select v_project, l.service_id, l.id, l.price_id, l.description, l.quantity, l.unit_price, l.discount_amount, q.currency, l.price_override_reason, current_staff_id()
  from quote_lines l where l.quote_id = p_quote and l.service_id is not null;
  if q.contact_id is not null then
    insert into project_contacts (project_id, contact_id, role) values (v_project, q.contact_id, 'quote contact') on conflict do nothing;
  end if;
  if q.assigned_staff_id is not null then
    insert into project_members (project_id, staff_id, member_role) values (v_project, q.assigned_staff_id, 'account manager') on conflict do nothing;
  end if;
  update quotes set project_id = v_project, converted_at = now() where id = p_quote;
  return v_project;
end $$;

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table quotes      enable row level security;
alter table quote_lines enable row level security;
revoke all on quotes, quote_lines from anon, authenticated;
grant select on quotes, quote_lines to authenticated;
grant update (title, intro, terms, valid_until, contact_id, assigned_staff_id, project_id) on quotes to authenticated;

create policy quotes_select on quotes for select to authenticated using (can_view_quote_row(client_id, division_id));
create policy quotes_update on quotes for update to authenticated
  using (can_view_quote_row(client_id, division_id) and has_permission('quotes.update', division_id))
  with check (can_view_quote_row(client_id, division_id) and has_permission('quotes.update', division_id));
create policy quote_lines_select on quote_lines for select to authenticated using (can_view_quote(quote_id));

revoke execute on function can_view_quote_row(uuid, uuid), can_view_quote(uuid), quote_create(uuid, uuid, text, uuid, uuid, date, text, text),
  quote_add_line(uuid, uuid, numeric, numeric, text, text, numeric), quote_remove_line(uuid), quote_transition(uuid, quote_status, text),
  quote_convert_to_project(uuid, text), expire_quotes() from public, anon, authenticated;
grant execute on function can_view_quote_row(uuid, uuid), can_view_quote(uuid), quote_create(uuid, uuid, text, uuid, uuid, date, text, text),
  quote_add_line(uuid, uuid, numeric, numeric, text, text, numeric), quote_remove_line(uuid), quote_transition(uuid, quote_status, text),
  quote_convert_to_project(uuid, text) to authenticated;
grant execute on function expire_quotes() to service_role;

do $$ begin perform attach_audit('quotes'); end $$;
do $$ begin perform attach_audit('quote_lines'); end $$;
