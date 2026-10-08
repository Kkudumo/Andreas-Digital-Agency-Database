-- 0032_tickets: the ticket FOUNDATION (ADA-TKT-YYYY-####), built now because assets and maintenance reference it.
--  * A ticket REFERENCES the asset, client, project and contact. When it is raised against an asset it takes client, project
--    and division from the asset - the technician never retypes "Lenovo ThinkPad, serial XYZ, assigned to John".
--  * It inherits the stricter classification of itself, its asset, its client and its project, and follows them when they change.
--  * Scope kept deliberately small: lifecycle, assignment, classification. SLAs, comments, categories, escalation, e-mail
--    intake and customer portal belong to the full Tickets module.

create type ticket_status as enum ('open', 'in_progress', 'waiting', 'resolved', 'closed', 'cancelled');
create type ticket_kind as enum ('incident', 'request', 'maintenance', 'question');

create table tickets (
  id                       uuid primary key default gen_random_uuid(),
  ada_id                   text not null unique,
  title                    text not null check (btrim(title) <> ''),
  description              text,
  kind                     ticket_kind not null default 'incident',
  priority                 priority_level not null default 'normal',
  status                   ticket_status not null default 'open',
  division_id              uuid not null references divisions (id),
  asset_id                 uuid references assets (id) on delete restrict,
  client_id                uuid references clients (id) on delete restrict,
  project_id               uuid references projects (id) on delete restrict,
  contact_id               uuid references client_contacts (id),
  reporter_staff_id        uuid references staff (id),
  assignee_staff_id        uuid references staff (id),
  classification           data_classification not null default 'internal',
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  resolution               text,
  resolved_at              timestamptz,
  closed_at                timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index tickets_asset_idx on tickets (asset_id) where asset_id is not null;
create index tickets_client_idx on tickets (client_id) where client_id is not null;
create index tickets_project_idx on tickets (project_id) where project_id is not null;
create index tickets_assignee_idx on tickets (assignee_staff_id) where assignee_staff_id is not null;
create index tickets_status_idx on tickets (status);
comment on table tickets is 'Purpose: a support/maintenance ticket. References asset, client, project, contact, reporter and assignee by id and inherits their classification; nothing about them is retyped. [class: internal; inherits]';
do $$ begin perform attach_ada_id('tickets', 'ticket'); end $$;
create trigger tickets_updated before update on tickets for each row execute function set_updated_at();

create function tickets_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare ast assets%rowtype; v_cc data_classification; v_cd boolean; v_pc data_classification; v_pclient uuid;
begin
  if new.asset_id is not null then
    select * into ast from assets where id = new.asset_id;
    if new.client_id is null then new.client_id := ast.client_id;
    elsif ast.client_id is not null and new.client_id is distinct from ast.client_id then raise exception 'the ticket''s client must be the asset''s client' using errcode = '23514'; end if;
    if new.project_id is null then new.project_id := ast.project_id;
    elsif ast.project_id is not null and new.project_id is distinct from ast.project_id then raise exception 'the ticket''s project must be the asset''s project' using errcode = '23514'; end if;
  end if;
  if new.project_id is not null then
    select client_id, effective_classification into v_pclient, v_pc from projects where id = new.project_id;
    if new.client_id is null then new.client_id := v_pclient;
    elsif new.client_id is distinct from v_pclient then raise exception 'the project must belong to the ticket''s client' using errcode = '23514'; end if;
  end if;
  if new.client_id is not null then select classification, deleted_at is not null into v_cc, v_cd from clients where id = new.client_id; end if;
  if new.contact_id is not null and not exists (select 1 from client_contacts cc where cc.id = new.contact_id and cc.client_id is not distinct from new.client_id) then
    raise exception 'the contact must belong to the ticket''s client' using errcode = '23514';
  end if;
  new.effective_classification := greatest(new.classification, coalesce(v_cc, 'internal'), coalesce(v_pc, 'internal'), coalesce(ast.effective_classification, 'internal'));
  new.client_deleted := coalesce(v_cd, false);
  return new;
end $$;
create trigger tickets_inherit_trg before insert or update of asset_id, client_id, project_id, contact_id, classification on tickets
  for each row execute function tickets_inherit();

create function tickets_guard() returns trigger
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
  if old.status in ('closed', 'cancelled') and (new.title, new.description, new.asset_id, new.client_id, new.project_id, new.contact_id, new.division_id, new.resolution)
     is distinct from (old.title, old.description, old.asset_id, old.client_id, old.project_id, old.contact_id, old.division_id, old.resolution) then
    raise exception 'a % ticket is final', old.status using errcode = '42501';
  end if;
  if new.asset_id is distinct from old.asset_id and old.asset_id is not null then raise exception 'a ticket cannot be moved to another asset' using errcode = '42501'; end if;
  return new;
end $$;
create trigger tickets_guard_trg before insert or update or delete on tickets for each row execute function tickets_guard();

-- Dependents follow their asset / client / project
create function tickets_follow_asset() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.effective_classification is distinct from old.effective_classification or new.client_deleted is distinct from old.client_deleted then
    update tickets set classification = classification where asset_id = new.id;
  end if;
  return null;
end $$;
create trigger tickets_follow_asset_trg after update of effective_classification, client_deleted on assets for each row execute function tickets_follow_asset();
create function tickets_follow_client() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update tickets set classification = classification where client_id = new.id;
  return null;
end $$;
create trigger tickets_follow_client_trg after update of classification, deleted_at on clients for each row execute function tickets_follow_client();
create function tickets_follow_project() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.effective_classification is distinct from old.effective_classification then update tickets set classification = classification where project_id = new.id; end if;
  return null;
end $$;
create trigger tickets_follow_project_trg after update of effective_classification on projects for each row execute function tickets_follow_project();

-- Visibility: the division's ticket viewers, plus the reporter and the assignee - always subject to classification
create function can_view_ticket_row(p_division uuid, p_class data_classification, p_client_deleted boolean, p_assignee uuid, p_reporter uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select (has_permission('tickets.view', p_division) or (current_staff_id() is not null and current_staff_id() in (p_assignee, p_reporter)))
     and classification_visible(p_class) and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_ticket(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_ticket_row(t.division_id, t.effective_classification, t.client_deleted, t.assignee_staff_id, t.reporter_staff_id) from tickets t where t.id = p_id), false)
$$;
create function ticket_load(p_id uuid) returns tickets
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype;
begin
  select * into t from tickets where id = p_id for update;
  if not found or not can_view_ticket_row(t.division_id, t.effective_classification, t.client_deleted, t.assignee_staff_id, t.reporter_staff_id) then
    raise exception 'ticket not found' using errcode = 'P0002';
  end if;
  return t;
end $$;

create function ticket_create(p_title text, p_description text default null, p_asset uuid default null, p_division uuid default null, p_client uuid default null,
                              p_project uuid default null, p_contact uuid default null, p_kind ticket_kind default 'incident', p_priority priority_level default 'normal',
                              p_classification data_classification default 'internal') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare ast assets%rowtype; v_div uuid := p_division; v_id uuid;
begin
  if p_asset is not null then
    select * into ast from assets where id = p_asset;
    if not found or not can_view_asset_row(ast.id, ast.division_id, ast.effective_classification, ast.client_deleted) then raise exception 'asset not found' using errcode = 'P0002'; end if;
    v_div := coalesce(v_div, ast.division_id);
  end if;
  if v_div is null then raise exception 'choose the division that will handle the ticket' using errcode = '23514'; end if;
  if not has_permission('tickets.create', v_div) then raise exception 'tickets.create is required in that division' using errcode = '42501'; end if;
  if p_client is not null and (not exists (select 1 from clients where id = p_client and deleted_at is null) or not can_view_client(p_client)) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if p_project is not null and not can_view_project(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if p_classification <> 'internal' and not has_permission('records.classify') then raise exception 'records.classify is required to set a classification' using errcode = '42501'; end if;
  insert into tickets (title, description, kind, priority, division_id, asset_id, client_id, project_id, contact_id, classification)
  values (p_title, p_description, p_kind, p_priority, v_div, p_asset, p_client, p_project, p_contact, p_classification) returning id into v_id;
  perform emit_event('ticket.opened', 'tickets', v_id, (select ada_id from tickets where id = v_id), jsonb_build_object('priority', p_priority));
  return v_id;
end $$;

create function ticket_assign(p_ticket uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t tickets%rowtype;
begin
  t := ticket_load(p_ticket);
  if not has_permission('tickets.assign', t.division_id) then raise exception 'tickets.assign is required' using errcode = '42501'; end if;
  if t.status in ('closed', 'cancelled') then raise exception 'a % ticket is final', t.status using errcode = '23514'; end if;
  if p_staff is not null and not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then raise exception 'the assignee must be an active staff member' using errcode = '23514'; end if;
  update tickets set assignee_staff_id = p_staff where id = t.id;
  if p_staff is not null then
    insert into notifications (recipient_staff_id, type, title, entity_table, entity_id, entity_ada_id)
    select p_staff, 'ticket.assigned', 'Ticket assigned: ' || t.ada_id, 'tickets', t.id, t.ada_id where t.effective_classification = 'internal';
  end if;
end $$;

create function ticket_transition(p_ticket uuid, p_to ticket_status, p_note text default null) returns ticket_status
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
  if p_to in ('resolved', 'closed') then perform emit_event('ticket.' || p_to, 'tickets', t.id, t.ada_id, '{}'); end if;
  return p_to;
end $$;

alter table tickets enable row level security;
revoke all on tickets from anon, authenticated;
grant select on tickets to authenticated;
create policy tickets_select on tickets for select to authenticated using (can_view_ticket_row(division_id, effective_classification, client_deleted, assignee_staff_id, reporter_staff_id));

revoke execute on function can_view_ticket_row(uuid, data_classification, boolean, uuid, uuid), can_view_ticket(uuid), ticket_load(uuid),
  ticket_create(text, text, uuid, uuid, uuid, uuid, uuid, ticket_kind, priority_level, data_classification), ticket_assign(uuid, uuid), ticket_transition(uuid, ticket_status, text) from public, anon, authenticated;
grant execute on function can_view_ticket_row(uuid, data_classification, boolean, uuid, uuid), can_view_ticket(uuid),
  ticket_create(text, text, uuid, uuid, uuid, uuid, uuid, ticket_kind, priority_level, data_classification), ticket_assign(uuid, uuid), ticket_transition(uuid, ticket_status, text) to authenticated;

do $$ begin perform attach_audit('tickets'); end $$;
