-- 0036_tickets_module: the Tickets module, on the institutional foundation.
--  * Identity: tickets are registered entities (legacy ADA-TKT alias + permanent institutional ID) through the one registration path;
--    nothing here generates an identifier.
--  * No copies: a ticket REFERENCES requester (person), client, project, asset, service, website, contact, reporter and assignee.
--    Raised against an asset it takes client / project / division from it.
--  * Origin vs ownership: the handling division is the registry's CURRENT division; the ORIGIN division is fixed at creation.
--    Moving a ticket (ticket_transfer) never changes its ID or origin; history is kept in ticket_events and entity_location_history.
--  * Controlled lifecycle, SLA targets (agreed at creation, re-derived on priority change), internal vs requester-visible comments,
--    append-only event history, classification inherited from asset / client / project and followed when they change.
--  * Publication-ready: entity_types.publishable says which entity types may EVER have a public projection. Tickets never do.

-- permissions
insert into permissions (key, module, action, description, sensitivity) values
  ('tickets.configure', 'tickets', 'configure', 'Manage ticket categories and SLA policies', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'tickets.configure'),
  ('administration_officer', 'tickets.configure')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;


-- ---------------------------------------------------------------------------
-- Publication capability flag on the entity map (the future publication layer attaches here; nothing is published yet)
-- ---------------------------------------------------------------------------
alter table entity_types add column publishable boolean not null default false;
update entity_types set publishable = true where key in ('profile', 'service', 'portfolio', 'vacancy', 'division', 'programme', 'course', 'module', 'document', 'cohort');
comment on column entity_types.publishable is 'Whether instances of this type can EVER have a public projection (through an explicit publication state, approval and a public API function). false = the type never crosses the public boundary. Existence in ADA Hub never implies publication.';

-- ---------------------------------------------------------------------------
-- Categories and SLA policies (configuration, data not code)
-- ---------------------------------------------------------------------------
create table ticket_categories (
  id          uuid primary key default gen_random_uuid(),
  key         text not null unique check (key ~ '^[a-z0-9_]+$'),
  name        text not null,
  division_id uuid references divisions (id),
  is_active   boolean not null default true,
  sort_order  integer not null default 100
);
comment on table ticket_categories is 'Purpose: what a ticket is about (hardware, software, access, ...). Optionally owned by a division. Managed with tickets.configure. [class: internal]';
insert into ticket_categories (key, name, sort_order) values
  ('hardware', 'Hardware', 10), ('software', 'Software', 20), ('network', 'Network / connectivity', 30), ('access', 'Accounts and access', 40),
  ('website', 'Website / application', 50), ('request', 'Service request', 60), ('question', 'Question', 70), ('other', 'Other', 999);

create table ticket_sla_policies (
  id                     uuid primary key default gen_random_uuid(),
  priority               priority_level not null,
  division_id            uuid references divisions (id),
  first_response_minutes integer not null check (first_response_minutes > 0),
  resolution_minutes     integer not null check (resolution_minutes > 0),
  is_active              boolean not null default true,
  note                   text,
  check (resolution_minutes >= first_response_minutes)
);
create unique index ticket_sla_policies_unique on ticket_sla_policies (priority, coalesce(division_id, '00000000-0000-0000-0000-000000000000'::uuid)) where is_active;
insert into ticket_sla_policies (priority, first_response_minutes, resolution_minutes, note) values
  ('low', 1440, 10080, 'default'), ('normal', 480, 4320, 'default'), ('high', 120, 1440, 'default'), ('urgent', 30, 480, 'default');
comment on table ticket_sla_policies is 'Purpose: response and resolution targets by priority (and optionally division; the division row wins). Elapsed calendar minutes - business-hours calendars are not modelled. [class: internal]';

-- ---------------------------------------------------------------------------
-- Ticket columns: references only
-- ---------------------------------------------------------------------------
alter table tickets
  add column category_id            uuid references ticket_categories (id),
  add column requester_person_id    uuid references people (id),
  add column service_id             uuid references services (id),
  add column website_id             uuid references websites (id),
  add column origin_channel         text not null default 'internal' check (origin_channel in ('internal', 'email', 'web', 'phone', 'walk_in', 'system')),
  add column sla_policy_id          uuid references ticket_sla_policies (id),
  add column first_response_due_at  timestamptz,
  add column resolution_due_at      timestamptz,
  add column first_response_at      timestamptz;
create index tickets_requester_idx on tickets (requester_person_id) where requester_person_id is not null;
create index tickets_service_idx on tickets (service_id) where service_id is not null;
create index tickets_website_idx on tickets (website_id) where website_id is not null;
comment on column tickets.requester_person_id is 'The person who asked (a people row, never a name). Their details are visible only as far as people visibility allows.';
comment on column tickets.first_response_due_at is 'Target agreed at creation from the SLA policy then in force (re-derived only when the priority changes). Not an identity field.';

create function ticket_sla_for(p_priority priority_level, p_division uuid) returns ticket_sla_policies
language sql stable security definer set search_path = public, pg_temp as $$
  select * from ticket_sla_policies where is_active and priority = p_priority and (division_id is null or division_id = p_division)
  order by (division_id is not null) desc limit 1
$$;
revoke execute on function ticket_sla_for(priority_level, uuid) from public, anon, authenticated;

create function tickets_sla() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare p ticket_sla_policies; v_from timestamptz;
begin
  v_from := case when tg_op = 'INSERT' then now() else old.created_at end;
  if tg_op = 'INSERT' or new.priority is distinct from old.priority then
    p := ticket_sla_for(new.priority, new.division_id);
    new.sla_policy_id := p.id;
    new.first_response_due_at := case when p.id is not null then v_from + make_interval(mins => p.first_response_minutes) end;
    new.resolution_due_at := case when p.id is not null then v_from + make_interval(mins => p.resolution_minutes) end;
  end if;
  return new;
end $$;
create trigger tickets_sla_trg before insert or update of priority on tickets for each row execute function tickets_sla();

-- Ownership moves only through ticket_transfer (for every caller); everything else about the division is immutable
create or replace function tickets_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'tickets are never deleted; close or cancel them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then new.reporter_staff_id := coalesce(new.reporter_staff_id, current_staff_id()); return new; end if;
  if new.status is distinct from old.status and not (
        (old.status = 'open'        and new.status in ('in_progress', 'waiting', 'resolved', 'cancelled'))
     or (old.status = 'in_progress' and new.status in ('open', 'waiting', 'resolved', 'cancelled'))
     or (old.status = 'waiting'     and new.status in ('open', 'in_progress', 'resolved', 'cancelled'))
     or (old.status = 'resolved'    and new.status in ('open', 'in_progress', 'closed'))) then
    raise exception 'invalid ticket status change % -> %', old.status, new.status using errcode = '23514';
  end if;
  if old.status in ('closed', 'cancelled') and (new.title, new.description, new.asset_id, new.client_id, new.project_id, new.contact_id, new.division_id, new.resolution, new.requester_person_id, new.service_id, new.website_id, new.category_id)
     is distinct from (old.title, old.description, old.asset_id, old.client_id, old.project_id, old.contact_id, old.division_id, old.resolution, old.requester_person_id, old.service_id, old.website_id, old.category_id) then
    raise exception 'a % ticket is final', old.status using errcode = '42501';
  end if;
  if new.asset_id is distinct from old.asset_id and old.asset_id is not null then raise exception 'a ticket cannot be moved to another asset' using errcode = '42501'; end if;
  if new.division_id is distinct from old.division_id and coalesce(current_setting('ada.ticket_transfer', true), '') <> 'on' then
    raise exception 'a ticket changes division only through ticket_transfer' using errcode = '42501';
  end if;
  if (new.requester_person_id, new.created_at, new.reporter_staff_id) is distinct from (old.requester_person_id, old.created_at, old.reporter_staff_id) then
    raise exception 'a ticket''s requester, reporter and creation time are permanent' using errcode = '42501';
  end if;
  return new;
end $$;

-- The requester's person record is visible to those who can see the ticket (the relationship carries the privacy)
create or replace function can_view_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from staff s where s.person_id = p_id and has_permission('hr.view'))
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.view', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_view_client(cc.client_id))
      or exists (select 1 from leads l where l.person_id = p_id and has_permission('leads.view', l.division_id) and classification_visible(l.effective_classification))
      or exists (select 1 from students st where st.person_id = p_id and can_view_student_row(st.division_id, st.classification))
      or exists (select 1 from tickets t where t.requester_person_id = p_id and can_view_ticket_row(t.division_id, t.effective_classification, t.client_deleted, t.assignee_staff_id, t.reporter_staff_id))
$$;

-- People working a ticket (division ticket staff or the assignee) may see internal comments; a reporter alone may not
create function can_work_ticket_row(p_division uuid, p_class data_classification, p_client_deleted boolean, p_assignee uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select (has_permission('tickets.view', p_division) or (current_staff_id() is not null and current_staff_id() = p_assignee))
     and classification_visible(p_class) and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_work_ticket(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_work_ticket_row(t.division_id, t.effective_classification, t.client_deleted, t.assignee_staff_id) from tickets t where t.id = p_id), false)
$$;

-- ---------------------------------------------------------------------------
-- Comments and event history (append-only)
-- ---------------------------------------------------------------------------
create table ticket_comments (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid not null references tickets (id) on delete restrict,
  author_id   uuid references staff (id),
  body        text not null check (btrim(body) <> ''),
  is_internal boolean not null default true,
  created_at  timestamptz not null default now()
);
create index ticket_comments_ticket_idx on ticket_comments (ticket_id, created_at);
comment on table ticket_comments is 'Purpose: the conversation on a ticket. Internal notes are for people working the ticket; non-internal comments are also visible to the reporter. Append-only. [class: inherits the ticket]';
create trigger ticket_comments_immutable before update or delete on ticket_comments for each row execute function append_only();

create table ticket_events (
  id         bigint generated always as identity primary key,
  ticket_id  uuid not null references tickets (id) on delete restrict,
  kind       text not null check (kind in ('created', 'status', 'assignment', 'priority', 'escalation', 'transfer', 'comment', 'sla')),
  from_value text,
  to_value   text,
  actor_id   uuid references staff (id),
  note       text,
  created_at timestamptz not null default now()
);
create index ticket_events_ticket_idx on ticket_events (ticket_id, id);
comment on table ticket_events is 'Purpose: append-only history of a ticket (status, assignment, priority, escalation, transfers, comments). Never edited or deleted. [class: inherits the ticket]';
create trigger ticket_events_immutable before update or delete on ticket_events for each row execute function append_only();

create function ticket_log(p_ticket uuid, p_kind text, p_from text, p_to text, p_note text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into ticket_events (ticket_id, kind, from_value, to_value, actor_id, note) values (p_ticket, p_kind, p_from, p_to, current_staff_id(), p_note)
$$;
revoke execute on function ticket_log(uuid, text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
-- Replaces the 0032 version: same leading parameters, plus the new references (all optional)
drop function ticket_create(text, text, uuid, uuid, uuid, uuid, uuid, ticket_kind, priority_level, data_classification);
create function ticket_create(p_title text, p_description text default null, p_asset uuid default null, p_division uuid default null, p_client uuid default null,
                              p_project uuid default null, p_contact uuid default null, p_kind ticket_kind default 'incident', p_priority priority_level default 'normal',
                              p_classification data_classification default 'internal', p_category text default null, p_requester uuid default null,
                              p_service uuid default null, p_website uuid default null, p_channel text default 'internal') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare ast assets%rowtype; v_div uuid := p_division; v_id uuid; v_cat uuid;
begin
  if p_asset is not null then
    select * into ast from assets where id = p_asset;
    if not found or not can_view_asset_row(ast.id, ast.division_id, ast.effective_classification, ast.client_deleted) then raise exception 'asset not found' using errcode = 'P0002'; end if;
    v_div := coalesce(v_div, ast.division_id);
  end if;
  if v_div is null then raise exception 'choose the division that will handle the ticket' using errcode = '23514'; end if;
  if not has_permission('tickets.create', v_div) then raise exception 'tickets.create is required in that division' using errcode = '42501'; end if;
  if p_client is not null and (not exists (select 1 from clients where id = p_client and deleted_at is null) or not can_view_client(p_client)) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if p_project is not null and not asset_project_usable(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if p_requester is not null and (not exists (select 1 from people where id = p_requester) or not can_view_person(p_requester)) then raise exception 'person not found' using errcode = 'P0002'; end if;
  if p_service is not null and not can_view_service(p_service) then raise exception 'service not found' using errcode = 'P0002'; end if;
  if p_website is not null and not exists (select 1 from websites w where w.id = p_website and (has_permission('websites.view') or w.division_id = v_div)) then raise exception 'website not found' using errcode = 'P0002'; end if;
  if p_category is not null then
    select id into v_cat from ticket_categories where key = p_category and is_active and (division_id is null or division_id = v_div);
    if v_cat is null then raise exception 'unknown ticket category' using errcode = '23514'; end if;
  end if;
  if p_classification <> 'internal' and not has_permission('records.classify') then raise exception 'records.classify is required to set a classification' using errcode = '42501'; end if;
  insert into tickets (title, description, kind, priority, division_id, asset_id, client_id, project_id, contact_id, classification, category_id, requester_person_id, service_id, website_id, origin_channel)
  values (p_title, p_description, p_kind, p_priority, v_div, p_asset, p_client, p_project, p_contact, p_classification, v_cat, p_requester, p_service, p_website, p_channel) returning id into v_id;
  perform ticket_log(v_id, 'created', null, 'open', null);
  perform emit_event('ticket.opened', 'tickets', v_id, (select ada_id from tickets where id = v_id), jsonb_build_object('priority', p_priority));
  return v_id;
end $$;

create or replace function ticket_assign(p_ticket uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype;
begin
  t := ticket_load(p_ticket);
  if not has_permission('tickets.assign', t.division_id) then raise exception 'tickets.assign is required' using errcode = '42501'; end if;
  if t.status in ('closed', 'cancelled') then raise exception 'a % ticket is final', t.status using errcode = '23514'; end if;
  if p_staff is not null and not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then raise exception 'the assignee must be an active staff member' using errcode = '23514'; end if;
  update tickets set assignee_staff_id = p_staff where id = t.id;
  perform ticket_log(t.id, 'assignment', t.assignee_staff_id::text, p_staff::text, null);
  if p_staff is not null then
    insert into notifications (recipient_staff_id, type, title, entity_table, entity_id, entity_ada_id)
    select p_staff, 'ticket.assigned', 'Ticket assigned: ' || t.ada_id, 'tickets', t.id, t.ada_id where t.effective_classification = 'internal';
  end if;
end $$;

create or replace function ticket_transition(p_ticket uuid, p_to ticket_status, p_note text default null) returns ticket_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype;
begin
  t := ticket_load(p_ticket);
  if not (has_permission('tickets.update', t.division_id) or t.assignee_staff_id = current_staff_id()) then raise exception 'tickets.update is required' using errcode = '42501'; end if;
  if p_to in ('resolved', 'cancelled') and coalesce(btrim(p_note), '') = '' then raise exception 'a note is required' using errcode = '23514'; end if;
  update tickets set status = p_to,
         resolution = case when p_to = 'resolved' then p_note else resolution end,
         resolved_at = case when p_to = 'resolved' then now() when p_to in ('open', 'in_progress') then null else resolved_at end,
         closed_at = case when p_to = 'closed' then now() else closed_at end
   where id = t.id;
  perform ticket_log(t.id, 'status', t.status::text, p_to::text, p_note);
  if p_to in ('resolved', 'closed') then perform emit_event('ticket.' || p_to, 'tickets', t.id, t.ada_id, '{}'); end if;
  return p_to;
end $$;

create function ticket_comment_add(p_ticket uuid, p_body text, p_internal boolean default true) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype; v_id uuid; v_me uuid := current_staff_id(); v_works boolean;
begin
  t := ticket_load(p_ticket);
  v_works := can_work_ticket_row(t.division_id, t.effective_classification, t.client_deleted, t.assignee_staff_id);
  if t.status in ('closed', 'cancelled') then raise exception 'a % ticket is final', t.status using errcode = '23514'; end if;
  if not (v_works and (has_permission('tickets.update', t.division_id) or t.assignee_staff_id = v_me)) and not (v_me is not null and v_me = t.reporter_staff_id and not p_internal) then
    raise exception 'not permitted to comment on this ticket' using errcode = '42501';
  end if;
  insert into ticket_comments (ticket_id, author_id, body, is_internal) values (t.id, v_me, p_body, p_internal) returning id into v_id;
  perform ticket_log(t.id, 'comment', null, case when p_internal then 'internal' else 'public' end, null);
  if not p_internal and t.first_response_at is null and v_me is distinct from t.reporter_staff_id then
    update tickets set first_response_at = now() where id = t.id;
    perform ticket_log(t.id, 'sla', null, 'first_response', null);
  end if;
  return v_id;
end $$;

-- Priority change; raising it is an escalation (event, notification to assigners, SLA targets re-derived from the creation time)
create function ticket_set_priority(p_ticket uuid, p_priority priority_level, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype; v_up boolean;
begin
  t := ticket_load(p_ticket);
  if not has_permission('tickets.update', t.division_id) then raise exception 'tickets.update is required' using errcode = '42501'; end if;
  if t.status in ('closed', 'cancelled') then raise exception 'a % ticket is final', t.status using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if p_priority = t.priority then raise exception 'the priority is already %', t.priority using errcode = '23514'; end if;
  v_up := p_priority > t.priority;
  update tickets set priority = p_priority where id = t.id;
  perform ticket_log(t.id, case when v_up then 'escalation' else 'priority' end, t.priority::text, p_priority::text, p_reason);
  if v_up and t.effective_classification = 'internal' then
    perform notify_holders('tickets.assign', t.division_id, 'ticket.escalated', 'Ticket escalated to ' || p_priority || ': ' || t.ada_id, null, 'tickets', t.id, t.ada_id);
  end if;
end $$;

-- Ownership moves to another division. The permanent ID and the ORIGIN division never change; the registry's current division follows.
create function ticket_transfer(p_ticket uuid, p_division uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype;
begin
  t := ticket_load(p_ticket);
  if not has_permission('tickets.assign', t.division_id) then raise exception 'tickets.assign is required' using errcode = '42501'; end if;
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('tickets.assign', p_division) and not has_permission('tickets.create', p_division) then raise exception 'you cannot hand a ticket to a division where you have no ticket rights' using errcode = '42501'; end if;
  if t.status in ('closed', 'cancelled') then raise exception 'a % ticket is final', t.status using errcode = '23514'; end if;
  if p_division = t.division_id then raise exception 'the ticket is already with that division' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  perform set_config('ada.ticket_transfer', 'on', true);
  update tickets set division_id = p_division, assignee_staff_id = null where id = t.id;
  perform set_config('ada.ticket_transfer', 'off', true);
  perform ticket_log(t.id, 'transfer', t.division_id::text, p_division::text, p_reason);
  perform emit_event('ticket.transferred', 'tickets', t.id, t.ada_id, '{}');
end $$;

-- SLA state is derived, never stored
create view ticket_sla_status with (security_invoker = true) as
  select t.id as ticket_id, t.priority, t.first_response_due_at, t.resolution_due_at, t.first_response_at, t.resolved_at,
         (coalesce(t.first_response_at, case when t.status in ('cancelled') then null else now() end) > t.first_response_due_at) as first_response_breached,
         (coalesce(t.resolved_at, case when t.status = 'cancelled' then null else now() end) > t.resolution_due_at) as resolution_breached,
         case when t.status in ('resolved', 'closed', 'cancelled') then null else extract(epoch from (t.resolution_due_at - now())) / 60 end::integer as minutes_to_resolution_due
  from tickets t;
comment on view ticket_sla_status is 'Purpose: derived SLA state of each ticket (breach flags and time remaining). Row access follows the ticket. Nothing is stored.';

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table ticket_categories enable row level security;
alter table ticket_sla_policies enable row level security;
alter table ticket_comments enable row level security;
alter table ticket_events enable row level security;
revoke all on ticket_categories, ticket_sla_policies, ticket_comments, ticket_events, ticket_sla_status from anon, authenticated;
grant select on ticket_categories, ticket_sla_policies, ticket_comments, ticket_events, ticket_sla_status to authenticated;
grant insert, update on ticket_categories, ticket_sla_policies to authenticated;
create policy ticket_categories_select on ticket_categories for select to authenticated using (has_permission_anywhere('tickets.view') or has_permission_anywhere('tickets.create'));
create policy ticket_categories_insert on ticket_categories for insert to authenticated with check (has_permission('tickets.configure'));
create policy ticket_categories_update on ticket_categories for update to authenticated using (has_permission('tickets.configure')) with check (has_permission('tickets.configure'));
create policy ticket_sla_policies_select on ticket_sla_policies for select to authenticated using (has_permission_anywhere('tickets.view'));
create policy ticket_sla_policies_insert on ticket_sla_policies for insert to authenticated with check (has_permission('tickets.configure'));
create policy ticket_sla_policies_update on ticket_sla_policies for update to authenticated using (has_permission('tickets.configure')) with check (has_permission('tickets.configure'));
create policy ticket_comments_select on ticket_comments for select to authenticated using (can_view_ticket(ticket_id) and (not is_internal or can_work_ticket(ticket_id)));
create policy ticket_events_select on ticket_events for select to authenticated using (can_view_ticket(ticket_id) and (kind not in ('comment') or can_work_ticket(ticket_id)));

revoke execute on function can_work_ticket_row(uuid, data_classification, boolean, uuid), can_work_ticket(uuid), ticket_create(text, text, uuid, uuid, uuid, uuid, uuid, ticket_kind, priority_level, data_classification, text, uuid, uuid, uuid, text),
  ticket_comment_add(uuid, text, boolean), ticket_set_priority(uuid, priority_level, text), ticket_transfer(uuid, uuid, text) from public, anon, authenticated;
grant execute on function can_work_ticket_row(uuid, data_classification, boolean, uuid), can_work_ticket(uuid), ticket_create(text, text, uuid, uuid, uuid, uuid, uuid, ticket_kind, priority_level, data_classification, text, uuid, uuid, uuid, text),
  ticket_comment_add(uuid, text, boolean), ticket_set_priority(uuid, priority_level, text), ticket_transfer(uuid, uuid, text) to authenticated;

do $$ begin perform attach_audit('ticket_categories'); perform attach_audit('ticket_sla_policies'); perform attach_audit('ticket_comments'); end $$;
