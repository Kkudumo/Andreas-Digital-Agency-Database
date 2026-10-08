-- 0017_project_graph: the project as the central container of work delivered to ONE client.
--  * status is controlled (project_transition); no ad-hoc updates
--  * services bought are rows that reference the catalogue AND snapshot the price actually used
--  * contacts are the client's shared contact records, never copies
--  * milestones group tasks; a portfolio entry is a separate, consent-gated public projection of a finished project
--  * money is NOT stored on projects: revenue/cost will be derived from invoices, payments and expenses

-- ---------------------------------------------------------------------------
-- Controlled project status
-- ---------------------------------------------------------------------------
alter table projects add column completed_at timestamptz;

create or replace function projects_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if is_untrusted_caller() and new.status <> 'proposed' then
      raise exception 'projects start as proposed' using errcode = '42501';
    end if;
    return new;
  end if;
  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.completed_at is distinct from old.completed_at then
      raise exception 'project status is changed only through project_transition()' using errcode = '42501';
    end if;
    if (new.lead_division_id is distinct from old.lead_division_id or new.client_id is distinct from old.client_id)
       and not has_permission('projects.update') then
      raise exception 'only organization-wide projects.update may change the client or lead division' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create function project_transition(p_id uuid, p_to project_status, p_reason text default null) returns project_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p projects%rowtype;
begin
  select * into p from projects where id = p_id and deleted_at is null for update;
  if not found or not can_view_project(p_id) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if not has_project_permission('projects.update', p_id) then
    raise exception 'projects.update is required' using errcode = '42501';
  end if;
  if (p.status, p_to) not in (
       ('proposed', 'approved'), ('proposed', 'cancelled'),
       ('approved', 'active'), ('approved', 'on_hold'), ('approved', 'cancelled'),
       ('active', 'on_hold'), ('active', 'completed'), ('active', 'cancelled'),
       ('on_hold', 'active'), ('on_hold', 'cancelled'),
       ('completed', 'archived'), ('completed', 'active'), ('cancelled', 'archived')) then
    raise exception 'invalid project transition % -> %', p.status, p_to using errcode = '23514';
  end if;
  if p_to = 'archived' and not has_project_permission('projects.archive', p_id) then
    raise exception 'projects.archive is required to archive' using errcode = '42501';
  end if;
  if p_to in ('cancelled', 'on_hold') and coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = '23514';
  end if;
  update projects set status = p_to,
         completed_at = case when p_to = 'completed' then now() when p_to = 'active' then null else completed_at end
   where id = p_id;
  if p_to = 'completed' then
    perform emit_event('project.completed', 'projects', p.id, p.ada_id, jsonb_build_object('status', 'completed'));
  end if;
  return p_to;
end $$;

-- ---------------------------------------------------------------------------
-- No stored copy of the quoted amount: it is derived from the linked quote(s)
-- ---------------------------------------------------------------------------
alter table project_financials drop column quoted_amount;
comment on table project_financials is 'Purpose: internal budget/cost PLANNING numbers only. Quoted, invoiced and received amounts are derived from quotes, invoices and payments (finance module), never stored here. [class: confidential]';

-- ---------------------------------------------------------------------------
-- Services bought on a project (price snapshot)
-- ---------------------------------------------------------------------------
create table project_services (
  id                    uuid primary key default gen_random_uuid(),
  project_id            uuid not null references projects (id) on delete restrict,
  service_id            uuid not null references services (id) on delete restrict,
  quote_line_id         uuid,
  price_id              uuid references service_prices (id),
  description           text,
  quantity              numeric(12,2) not null default 1 check (quantity > 0),
  unit_price            numeric(14,2) not null check (unit_price >= 0),
  discount_amount       numeric(14,2) not null default 0 check (discount_amount >= 0),
  line_total            numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2)) stored,
  currency              char(3) not null default 'NAD',
  price_override_reason text,
  created_by            uuid references staff (id),
  created_at            timestamptz not null default now(),
  check (price_id is not null or coalesce(btrim(price_override_reason), '') <> ''),
  check (discount_amount <= quantity * unit_price)
);
create index project_services_project_idx on project_services (project_id);
create index project_services_service_idx on project_services (service_id);
comment on table project_services is 'Purpose: which catalogue services a project delivers, with the price ACTUALLY used (unit_price is a snapshot; price_id points at the catalogue version it came from). [class: restricted]';

create function project_add_service(p_project uuid, p_service uuid, p_quantity numeric default 1, p_unit_price numeric default null,
                                    p_override_reason text default null, p_description text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pr service_prices;
  v_id uuid;
begin
  if not (can_view_project(p_project) and has_project_permission('projects.update', p_project)) then
    raise exception 'projects.update is required for this project' using errcode = '42501';
  end if;
  if not can_view_service(p_service) then raise exception 'service not found' using errcode = 'P0002'; end if;
  pr := price_on(p_service, current_date);
  if p_unit_price is null then
    if pr.id is null then raise exception 'this service has no approved price in force; give a price and a reason' using errcode = '23514'; end if;
    insert into project_services (project_id, service_id, price_id, description, quantity, unit_price, currency, created_by)
    values (p_project, p_service, pr.id, p_description, p_quantity, pr.amount, pr.currency, current_staff_id()) returning id into v_id;
  else
    if coalesce(btrim(p_override_reason), '') = '' then raise exception 'a reason is required for a non-catalogue price' using errcode = '23514'; end if;
    insert into project_services (project_id, service_id, price_id, description, quantity, unit_price, currency, price_override_reason, created_by)
    values (p_project, p_service, pr.id, p_description, p_quantity, p_unit_price, coalesce(pr.currency, 'NAD'), p_override_reason, current_staff_id()) returning id into v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Project contacts: the client's shared contact records
-- ---------------------------------------------------------------------------
create table project_contacts (
  project_id uuid not null references projects (id) on delete restrict,
  contact_id uuid not null references client_contacts (id) on delete restrict,
  role       text,
  added_at   timestamptz not null default now(),
  primary key (project_id, contact_id)
);
comment on table project_contacts is 'Purpose: which of the client''s contacts a project involves. References the shared client_contacts row; never a copy. [class: internal]';

create function project_contacts_check() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from client_contacts cc join projects p on p.id = new.project_id
                  where cc.id = new.contact_id and cc.client_id = p.client_id and cc.is_active) then
    raise exception 'that person is not an active contact of the project''s client' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger project_contacts_check_trg before insert on project_contacts for each row execute function project_contacts_check();

-- ---------------------------------------------------------------------------
-- Milestones (tasks may belong to one)
-- ---------------------------------------------------------------------------
create table milestones (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid not null references projects (id) on delete restrict,
  title        text not null check (btrim(title) <> ''),
  due_date     date,
  status       text not null default 'pending' check (status in ('pending', 'done', 'cancelled')),
  completed_at timestamptz,
  sort_order   integer not null default 100,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index milestones_project_idx on milestones (project_id, sort_order);
comment on table milestones is 'Purpose: delivery checkpoints within a project. [class: internal]';
create trigger milestones_updated before update on milestones for each row execute function set_updated_at();
create function milestones_guard() returns trigger
language plpgsql as $$
begin
  if new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then new.completed_at := now();
  elsif new.status <> 'done' then new.completed_at := null; end if;
  if tg_op = 'UPDATE' and is_untrusted_caller() and new.project_id is distinct from old.project_id then
    raise exception 'milestones cannot move between projects' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger milestones_guard_trg before insert or update on milestones for each row execute function milestones_guard();

alter table tasks add column milestone_id uuid references milestones (id) on delete set null;
create function tasks_milestone_check() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.milestone_id is not null and not exists (select 1 from milestones m where m.id = new.milestone_id and m.project_id = new.project_id) then
    raise exception 'the milestone belongs to a different project' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger tasks_milestone_check_trg before insert or update of milestone_id on tasks for each row execute function tasks_milestone_check();

-- ---------------------------------------------------------------------------
-- Portfolio: a consent-gated public projection of a finished project
-- ---------------------------------------------------------------------------
create table portfolio_entries (
  id               uuid primary key default gen_random_uuid(),
  ada_id           text not null unique,
  project_id       uuid not null unique references projects (id) on delete restrict,
  title            text not null check (btrim(title) <> ''),
  summary          text check (length(summary) <= 500),
  description      text,
  technologies     text[] not null default '{}',
  image_refs       text[] not null default '{}',
  client_consent   boolean not null default false,
  show_client_name boolean not null default false,
  completed_on     date,
  status           publication_state not null default 'draft',
  approved_by      uuid references staff (id),
  approved_at      timestamptz,
  published_at     timestamptz,
  status_reason    text,
  created_by       uuid references staff (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (not show_client_name or client_consent)
);
comment on table portfolio_entries is 'Purpose: what the public may see about a finished project. Requires a completed project and the client''s consent; the client''s name is shown only if show_client_name is also true. Internal project data is never exposed. [class: internal; public when published]';
do $$ begin perform attach_ada_id('portfolio_entries', 'portfolio'); end $$;
create trigger portfolio_entries_updated before update on portfolio_entries for each row execute function set_updated_at();
create trigger approval_sync_trg after insert or update on portfolio_entries
  for each row execute function approval_sync('portfolio', 'portfolio.publish', 'title', '');
create trigger publication_events_trg after update on portfolio_entries for each row execute function publication_events('portfolio');

create function project_lead_division(p_project uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select lead_division_id from projects where id = p_project and can_view_project(id)
$$;

create function portfolio_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if is_untrusted_caller() then
      if new.status <> 'draft' then raise exception 'portfolio entries are created as drafts' using errcode = '42501'; end if;
      if not exists (select 1 from projects where id = new.project_id and status in ('completed', 'archived')) then
        raise exception 'a portfolio entry can only be created for a completed project' using errcode = '23514';
      end if;
    end if;
    select completed_at::date into new.completed_on from projects where id = new.project_id;
    return new;
  end if;
  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at
       or new.published_at is distinct from old.published_at or new.status_reason is distinct from old.status_reason
       or new.project_id is distinct from old.project_id then
      raise exception 'portfolio status is changed only through portfolio_transition()' using errcode = '42501';
    end if;
    if (new.title, new.summary, new.description, new.technologies, new.image_refs, new.client_consent, new.show_client_name)
       is distinct from (old.title, old.summary, old.description, old.technologies, old.image_refs, old.client_consent, old.show_client_name)
       and old.status in ('pending_approval', 'approved', 'published') then
      new.status := 'draft'; new.approved_by := null; new.approved_at := null; new.published_at := null;
      new.status_reason := 'edited after approval; needs re-approval';
    end if;
  end if;
  return new;
end $$;
create trigger portfolio_guard_trg before insert or update on portfolio_entries for each row execute function portfolio_guard();

create function portfolio_transition(p_id uuid, p_to publication_state, p_reason text default null) returns publication_state
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  e portfolio_entries%rowtype;
  v_div uuid;
  v_edit boolean;
  v_pub boolean;
begin
  select * into e from portfolio_entries where id = p_id for update;
  v_div := case when found then project_lead_division(e.project_id) end;
  if v_div is null then raise exception 'portfolio entry not found' using errcode = 'P0002'; end if;
  v_edit := has_permission('portfolio.edit', v_div);
  v_pub := has_permission('portfolio.publish');

  case
    when e.status in ('draft', 'unpublished') and p_to = 'pending_approval' then
      if not v_edit then raise exception 'portfolio.edit is required' using errcode = '42501'; end if;
      if coalesce(btrim(e.summary), '') = '' or coalesce(btrim(e.description), '') = '' then
        raise exception 'a summary and description are required' using errcode = '23514';
      end if;
      if not e.client_consent then raise exception 'the client''s consent is required before a project can be shown publicly' using errcode = '23514'; end if;
      update portfolio_entries set status = p_to, status_reason = null where id = p_id;
      perform notify_holders('portfolio.publish', null, 'approval.required', 'Portfolio entry awaiting approval: ' || e.title, null, 'portfolio_entries', e.id, e.ada_id);
    when e.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_pub) then raise exception 'not permitted' using errcode = '42501'; end if;
      update portfolio_entries set status = p_to, status_reason = p_reason where id = p_id;
    when e.status = 'pending_approval' and p_to = 'approved' then
      if not v_pub then raise exception 'portfolio.publish is required to approve' using errcode = '42501'; end if;
      update portfolio_entries set status = p_to, approved_by = current_staff_id(), approved_at = now(), status_reason = null where id = p_id;
    when e.status = 'approved' and p_to = 'published' then
      if not v_pub then raise exception 'portfolio.publish is required to publish' using errcode = '42501'; end if;
      if not e.client_consent or not exists (select 1 from projects where id = e.project_id and status in ('completed', 'archived')) then
        raise exception 'the project must be completed and the client must have consented' using errcode = '23514';
      end if;
      update portfolio_entries set status = p_to, published_at = now() where id = p_id;
    when e.status = 'published' and p_to = 'unpublished' then
      if not v_pub then raise exception 'portfolio.publish is required to unpublish' using errcode = '42501'; end if;
      update portfolio_entries set status = p_to, published_at = null, status_reason = p_reason where id = p_id;
    when e.status <> 'archived' and p_to = 'archived' then
      if not v_pub then raise exception 'portfolio.publish is required to archive' using errcode = '42501'; end if;
      update portfolio_entries set status = p_to, published_at = null, status_reason = p_reason where id = p_id;
    else
      raise exception 'invalid portfolio transition % -> %', e.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table project_services  enable row level security;
alter table project_contacts  enable row level security;
alter table milestones        enable row level security;
alter table portfolio_entries enable row level security;
revoke all on project_services, project_contacts, milestones, portfolio_entries from anon, authenticated;
grant select on project_services to authenticated;
grant select, insert, delete on project_contacts to authenticated;
grant select, insert, update on milestones to authenticated;
grant select, insert on portfolio_entries to authenticated;
grant update (title, summary, description, technologies, image_refs, client_consent, show_client_name) on portfolio_entries to authenticated;

-- Commercial line items follow quote visibility rules (restricted): project editors and quote viewers.
create policy project_services_select on project_services for select to authenticated
  using (can_view_project(project_id) and (has_project_permission('projects.update', project_id) or has_permission_anywhere('quotes.view') or has_permission('finance.view')));
create policy project_contacts_select on project_contacts for select to authenticated using (can_view_project(project_id));
create policy project_contacts_insert on project_contacts for insert to authenticated with check (can_edit_project(project_id));
create policy project_contacts_delete on project_contacts for delete to authenticated using (can_edit_project(project_id));
create policy milestones_select on milestones for select to authenticated using (can_view_project(project_id));
create policy milestones_insert on milestones for insert to authenticated with check (can_edit_project(project_id));
create policy milestones_update on milestones for update to authenticated using (can_edit_project(project_id)) with check (can_edit_project(project_id));
create policy portfolio_select on portfolio_entries for select to authenticated using (can_view_project(project_id));
create policy portfolio_insert on portfolio_entries for insert to authenticated
  with check (has_permission('portfolio.edit', project_lead_division(project_id)));
create policy portfolio_update on portfolio_entries for update to authenticated
  using (has_permission('portfolio.edit', project_lead_division(project_id)))
  with check (has_permission('portfolio.edit', project_lead_division(project_id)));

revoke execute on function project_transition(uuid, project_status, text), project_add_service(uuid, uuid, numeric, numeric, text, text),
  project_lead_division(uuid), portfolio_transition(uuid, publication_state, text) from public, anon;
grant execute on function project_transition(uuid, project_status, text), project_add_service(uuid, uuid, numeric, numeric, text, text),
  project_lead_division(uuid), portfolio_transition(uuid, publication_state, text) to authenticated;

do $$ begin perform attach_audit('project_services'); end $$;
do $$ begin perform attach_audit('project_contacts'); end $$;
do $$ begin perform attach_audit('milestones'); end $$;
do $$ begin perform attach_audit('portfolio_entries'); end $$;

-- ---------------------------------------------------------------------------
-- Public API: portfolio and derived statistics
-- ---------------------------------------------------------------------------
create function public_api.portfolio(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'portfolio.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', e.ada_id, 'title', e.title, 'summary', e.summary, 'description', e.description,
      'technologies', to_jsonb(e.technologies), 'images', to_jsonb(e.image_refs), 'completed_on', e.completed_on,
      'client', case when e.show_client_name and e.client_consent then c.name end,
      'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end,
      'services', (select jsonb_agg(distinct s.name order by s.name) from project_services ps join services s on s.id = ps.service_id
                    where ps.project_id = e.project_id and s.status = 'published'))) order by e.completed_on desc nulls last, e.title)
    from portfolio_entries e
    join projects p on p.id = e.project_id and p.deleted_at is null and p.status in ('completed', 'archived')
    join clients c on c.id = p.client_id
    join divisions d on d.id = p.lead_division_id
    where e.status = 'published' and e.client_consent and (p_division is null or d.key = p_division)), '[]'::jsonb);
end $$;
revoke all on function public_api.portfolio(text, text) from public, anon, authenticated;
grant execute on function public_api.portfolio(text, text) to ada_public_api;

create or replace function public_api.statistics(p_key_hash text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'statistics.read');
  return jsonb_build_object(
    'staff', (select count(*) from staff where deleted_at is null and employment_status in ('active', 'on_leave', 'contractor')),
    'team_members', (select count(*) from staff_profiles p join staff s on s.id = p.staff_id
                      where p.status = 'published' and s.deleted_at is null and s.employment_status in ('active', 'on_leave', 'contractor')),
    'open_vacancies', (select count(*) from vacancies where status = 'published' and deleted_at is null and (closing_date is null or closing_date >= current_date)),
    'divisions', (select count(*) from divisions where public_state = 'published' and is_active),
    'services', (select count(*) from services where status = 'published' and is_active and deleted_at is null),
    'portfolio_projects', (select count(*) from portfolio_entries e join projects p on p.id = e.project_id
                            where e.status = 'published' and e.client_consent and p.deleted_at is null and p.status in ('completed', 'archived')));
end $$;
