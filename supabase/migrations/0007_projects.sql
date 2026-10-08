-- 0007_projects: projects, participating divisions, members, tasks, and a separate
-- finance table so that seeing a project never implies seeing its money.

create type project_status   as enum ('proposed', 'approved', 'active', 'on_hold', 'completed', 'cancelled', 'archived');
create type priority_level   as enum ('low', 'normal', 'high', 'urgent');
create type task_status      as enum ('todo', 'in_progress', 'blocked', 'done', 'cancelled');

create table projects (
  id               uuid primary key default gen_random_uuid(),
  ada_id           text not null unique,
  client_id        uuid not null references clients (id) on delete restrict,
  lead_division_id uuid not null references divisions (id),
  name             text not null check (btrim(name) <> ''),
  description      text,
  project_type     text,
  status           project_status not null default 'proposed',
  priority         priority_level not null default 'normal',
  start_date       date,
  due_date         date,
  classification   data_classification not null default 'internal',
  created_by       uuid references staff (id),
  deleted_at       timestamptz,
  deleted_by       uuid references staff (id),
  deletion_reason  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (due_date is null or start_date is null or due_date >= start_date)
);
create index projects_client_idx on projects (client_id);
create index projects_lead_idx   on projects (lead_division_id);
create index projects_due_idx    on projects (due_date) where deleted_at is null;
comment on table projects is 'Purpose: central project record; belongs to one client, led by one division, optionally shared with others. Money lives in project_financials. [class: internal by default]';

create table project_divisions (
  project_id  uuid not null references projects (id) on delete restrict,
  division_id uuid not null references divisions (id) on delete restrict,
  primary key (project_id, division_id)
);
comment on table project_divisions is 'Purpose: every division participating in a project (the lead division is always included). [class: internal]';

create table project_members (
  project_id  uuid not null references projects (id) on delete restrict,
  staff_id    uuid not null references staff (id) on delete restrict,
  member_role text not null default 'member',
  added_at    timestamptz not null default now(),
  primary key (project_id, staff_id)
);
comment on table project_members is 'Purpose: staff assigned to a project (gives visibility to holders of projects.view in any scope). [class: internal]';

create table project_financials (
  project_id     uuid primary key references projects (id) on delete restrict,
  currency       char(3) not null default 'NAD',
  quoted_amount  numeric(14,2) check (quoted_amount >= 0),
  budget         numeric(14,2) check (budget >= 0),
  revenue_to_date numeric(14,2) not null default 0 check (revenue_to_date >= 0),
  cost_to_date   numeric(14,2) not null default 0 check (cost_to_date >= 0),
  notes          text,
  updated_at     timestamptz not null default now()
);
comment on table project_financials is 'Purpose: money attached to a project, isolated so project access never implies finance access. [class: confidential]';

create table tasks (
  id           uuid primary key default gen_random_uuid(),
  ada_id       text not null unique,
  project_id   uuid not null references projects (id) on delete restrict,
  title        text not null check (btrim(title) <> ''),
  description  text,
  status       task_status    not null default 'todo',
  priority     priority_level not null default 'normal',
  assignee_id  uuid references staff (id),
  due_date     date,
  completed_at timestamptz,
  created_by   uuid references staff (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index tasks_project_idx  on tasks (project_id);
create index tasks_assignee_idx on tasks (assignee_id) where status not in ('done', 'cancelled');
comment on table tasks is 'Purpose: work items within a project. [class: internal]';

do $$ begin perform attach_ada_id('projects', 'project'); end $$;
do $$ begin perform attach_ada_id('tasks', 'task'); end $$;
create trigger projects_updated          before update on projects          for each row execute function set_updated_at();
create trigger tasks_updated             before update on tasks             for each row execute function set_updated_at();
create trigger project_financials_updated before update on project_financials for each row execute function set_updated_at();
create trigger projects_soft_delete      before update on projects for each row execute function soft_delete_guard('projects');
create trigger projects_classify         before insert or update on projects for each row execute function classification_guard();

-- ---------------------------------------------------------------------------
-- Access helpers. Row-based variants evaluate the row's own columns so the SELECT policy
-- also holds for INSERT ... RETURNING; by-id wrappers serve the child tables.
-- ---------------------------------------------------------------------------
-- Permission held org-wide, in the lead division, in any participating division,
-- or (anywhere + personally a member).
create function has_project_permission_row(p_key text, p_id uuid, p_lead uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission(p_key)
      or has_permission(p_key, p_lead)
      or exists (select 1 from project_divisions pd where pd.project_id = p_id and has_permission(p_key, pd.division_id))
      or (has_permission_anywhere(p_key)
          and exists (select 1 from project_members pm where pm.project_id = p_id and pm.staff_id = current_staff_id()))
$$;

create function can_view_project_row(p_id uuid, p_lead uuid, p_class data_classification, p_deleted timestamptz)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select (p_deleted is null or has_permission('records.view_deleted'))
    and has_project_permission_row('projects.view', p_id, p_lead)
    and (
      p_class in ('public', 'internal')
      or (p_class = 'restricted'
          and (has_permission('records.view_restricted')
               or exists (select 1 from project_members pm where pm.project_id = p_id and pm.staff_id = current_staff_id())))
      or (p_class = 'confidential' and has_permission('records.view_confidential'))
    )
$$;

create function can_edit_project_row(p_id uuid, p_lead uuid, p_class data_classification, p_deleted timestamptz)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select can_view_project_row(p_id, p_lead, p_class, p_deleted)
     and has_project_permission_row('projects.update', p_id, p_lead)
$$;

create function has_project_permission(p_key text, p_project uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select has_project_permission_row(p_key, p.id, p.lead_division_id) from projects p where p.id = p_project), false)
$$;

create function can_view_project(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_project_row(p.id, p.lead_division_id, p.classification, p.deleted_at)
                   from projects p where p.id = p_id), false)
$$;

create function can_edit_project(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_edit_project_row(p.id, p.lead_division_id, p.classification, p.deleted_at)
                   from projects p where p.id = p_id), false)
$$;

create function projects_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
  elsif is_untrusted_caller() then
    new.created_by := old.created_by;
    if (new.lead_division_id is distinct from old.lead_division_id or new.client_id is distinct from old.client_id)
       and not has_permission('projects.update') then
      raise exception 'only organization-wide projects.update may change the client or lead division' using errcode = '42501';
    end if;
    if (new.status = 'archived') is distinct from (old.status = 'archived')
       and not has_project_permission('projects.archive', old.id) then
      raise exception 'projects.archive is required to archive or unarchive' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger projects_guard_trg before insert or update on projects for each row execute function projects_guard();

-- Lead division participates automatically and the client gains an active relationship
-- with every participating division.
create function projects_sync_lead_division() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into project_divisions (project_id, division_id) values (new.id, new.lead_division_id)
  on conflict do nothing;
  return null;
end $$;
create trigger projects_sync_lead after insert on projects
  for each row execute function projects_sync_lead_division();

create function project_divisions_sync_client() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into client_divisions (client_id, division_id)
  select p.client_id, new.division_id from projects p where p.id = new.project_id
  on conflict (client_id, division_id) do update set relationship_status = 'active';
  return null;
end $$;
create trigger project_divisions_sync after insert on project_divisions
  for each row execute function project_divisions_sync_client();

create function tasks_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
  end if;
  if new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then
    new.completed_at := now();
  elsif new.status <> 'done' then
    new.completed_at := null;
  end if;
  if is_untrusted_caller() and tg_op = 'UPDATE' and new.project_id is distinct from old.project_id then
    raise exception 'tasks cannot move between projects' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger tasks_guard_trg before insert or update on tasks for each row execute function tasks_guard();

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table projects          enable row level security;
alter table project_divisions enable row level security;
alter table project_members   enable row level security;
alter table project_financials enable row level security;
alter table tasks             enable row level security;
revoke all on projects, project_divisions, project_members, project_financials, tasks from anon, authenticated;
grant select, insert, update on projects, project_financials, tasks to authenticated;
grant select, insert, delete on project_divisions, project_members to authenticated;

create policy projects_select on projects for select to authenticated
  using (can_view_project_row(id, lead_division_id, classification, deleted_at));
create policy projects_insert on projects for insert to authenticated
  with check (has_permission('projects.create', lead_division_id) and can_view_client(client_id));
create policy projects_update on projects for update to authenticated
  using (can_edit_project_row(id, lead_division_id, classification, deleted_at))
  with check (can_edit_project_row(id, lead_division_id, classification, null));

-- Adding a participating division widens visibility, so it needs organization-wide projects.update.
create policy project_divisions_select on project_divisions for select to authenticated using (can_view_project(project_id));
create policy project_divisions_insert on project_divisions for insert to authenticated
  with check (can_edit_project(project_id) and has_permission('projects.update'));
create policy project_divisions_delete on project_divisions for delete to authenticated
  using (can_edit_project(project_id) and has_permission('projects.update'));

create policy project_members_select on project_members for select to authenticated using (can_view_project(project_id));
create policy project_members_insert on project_members for insert to authenticated with check (can_edit_project(project_id));
create policy project_members_delete on project_members for delete to authenticated using (can_edit_project(project_id));

-- Finance is organization-wide only: no division scope, no project-based shortcut.
create policy project_financials_select on project_financials for select to authenticated using (has_permission('finance.view'));
create policy project_financials_insert on project_financials for insert to authenticated with check (has_permission('finance.create'));
create policy project_financials_update on project_financials for update to authenticated
  using (has_permission('finance.create')) with check (has_permission('finance.create'));

create policy tasks_select on tasks for select to authenticated using (can_view_project(project_id));
create policy tasks_insert on tasks for insert to authenticated
  with check (can_view_project(project_id) and has_project_permission('tasks.create', project_id));
create policy tasks_update on tasks for update to authenticated
  using (can_view_project(project_id) and has_project_permission('tasks.update', project_id))
  with check (can_view_project(project_id) and has_project_permission('tasks.update', project_id));

revoke execute on function has_project_permission(text, uuid), can_view_project(uuid), can_edit_project(uuid),
  has_project_permission_row(text, uuid, uuid),
  can_view_project_row(uuid, uuid, data_classification, timestamptz),
  can_edit_project_row(uuid, uuid, data_classification, timestamptz) from public, anon;
grant execute on function has_project_permission(text, uuid), can_view_project(uuid), can_edit_project(uuid),
  has_project_permission_row(text, uuid, uuid),
  can_view_project_row(uuid, uuid, data_classification, timestamptz),
  can_edit_project_row(uuid, uuid, data_classification, timestamptz) to authenticated;

do $$ begin perform attach_audit('projects'); end $$;
do $$ begin perform attach_audit('project_divisions'); end $$;
do $$ begin perform attach_audit('project_members'); end $$;
do $$ begin perform attach_audit('project_financials'); end $$;
do $$ begin perform attach_audit('tasks'); end $$;
