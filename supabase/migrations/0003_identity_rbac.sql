-- 0003_identity_rbac: staff, roles, permissions, scoped role assignments,
-- authorization helpers, anti-escalation guards, and the first RLS policies.
--
-- Model:  auth.users -> staff -> staff_roles(role, division scope) -> role_permissions -> permissions
--   * staff_roles.division_id IS NULL  => the role applies organization-wide.
--   * staff_roles.division_id = X      => the role applies only inside division X.
--   * has_permission(key)              => organization-wide holders only.
--   * has_permission(key, division)    => org-wide holders OR holders scoped to that division.

create type employment_status as enum ('active', 'on_leave', 'contractor', 'suspended', 'terminated');
create type account_status    as enum ('invited', 'active', 'suspended', 'disabled');

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
create table staff (
  id                  uuid primary key default gen_random_uuid(),
  ada_id              text not null unique,
  user_id             uuid unique references auth.users (id) on delete restrict,
  full_name           text not null check (btrim(full_name) <> ''),
  email               text not null check (email like '%@%'),
  work_phone          text,
  position_id         uuid references positions (id),
  primary_division_id uuid references divisions (id),
  employment_status   employment_status not null default 'active',
  account_status      account_status    not null default 'invited',
  start_date          date,
  end_date            date,
  responsibilities    text,
  classification      data_classification not null default 'internal',
  deleted_at          timestamptz,
  deleted_by          uuid references staff (id),
  deletion_reason     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create unique index staff_email_unique on staff (lower(email)) where deleted_at is null;
comment on table staff is 'Purpose: staff directory and the link from a login (auth.users) to ADA. Directory columns only; sensitive HR data lives in staff_private. [class: internal]';
comment on column staff.account_status is 'Only an active account can use the system. Changing it requires staff.manage_accounts.';

create table staff_private (
  staff_id                 uuid primary key references staff (id) on delete restrict,
  personal_email           text,
  personal_phone           text,
  national_id              text,
  date_of_birth            date,
  home_address             text,
  emergency_contact_name   text,
  emergency_contact_phone  text,
  hr_notes                 text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
comment on table staff_private is 'Purpose: sensitive HR information, readable only by the staff member themself and hr.view holders. [class: confidential]';

-- ---------------------------------------------------------------------------
-- Roles & permissions
-- ---------------------------------------------------------------------------
create table permissions (
  id          uuid primary key default gen_random_uuid(),
  key         text not null unique check (key ~ '^[a-z_]+\.[a-z_]+$'),
  module      text not null,
  action      text not null,
  description text not null,
  sensitivity data_classification not null default 'internal',
  check (key = module || '.' || action)
);
comment on table permissions is 'Purpose: catalogue of granular permissions (module.action). Defined by migrations only; not writable through the API. [class: internal]';

create table roles (
  id          uuid primary key default gen_random_uuid(),
  key         text not null unique check (key ~ '^[a-z][a-z0-9_]*$'),
  name        text not null,
  description text,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table roles is 'Purpose: named bundles of permissions. Positions are descriptive; roles grant access. [class: restricted]';

create table role_permissions (
  id            uuid primary key default gen_random_uuid(),
  role_id       uuid not null references roles (id) on delete cascade,
  permission_id uuid not null references permissions (id) on delete restrict,
  unique (role_id, permission_id)
);
comment on table role_permissions is 'Purpose: which permissions each role carries (the configurable permission matrix). [class: restricted]';

create table staff_roles (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references staff (id) on delete restrict,
  role_id     uuid not null references roles (id) on delete restrict,
  division_id uuid references divisions (id) on delete restrict,
  granted_by  uuid references staff (id),
  granted_at  timestamptz not null default now(),
  reason      text
);
create unique index staff_roles_unique
  on staff_roles (staff_id, role_id, coalesce(division_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index staff_roles_staff_idx on staff_roles (staff_id);
comment on table staff_roles is 'Purpose: assigns a role to a staff member, organization-wide (division_id null) or scoped to one division. [class: restricted]';

do $$ begin perform attach_ada_id('staff', 'staff'); end $$;

create trigger staff_updated         before update on staff         for each row execute function set_updated_at();
create trigger staff_private_updated before update on staff_private for each row execute function set_updated_at();
create trigger roles_updated         before update on roles         for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Authorization helpers (SECURITY DEFINER so RLS on the lookup tables cannot
-- recurse; each is read-only and pinned to a safe search_path).
-- ---------------------------------------------------------------------------
create function current_staff_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from staff
  where user_id = auth.uid() and account_status = 'active' and deleted_at is null
$$;

create function is_active_staff() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select current_staff_id() is not null
$$;

create function has_permission(p_key text, p_division uuid default null) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from staff s
    join staff_roles sr       on sr.staff_id = s.id
    join role_permissions rp  on rp.role_id = sr.role_id
    join permissions p        on p.id = rp.permission_id
    where s.user_id = auth.uid()
      and s.account_status = 'active' and s.deleted_at is null
      and p.key = p_key
      and (sr.division_id is null or sr.division_id = p_division)
  )
$$;

-- True if the user holds the permission in ANY scope (used for "is this module relevant to me").
create function has_permission_anywhere(p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from staff s
    join staff_roles sr       on sr.staff_id = s.id
    join role_permissions rp  on rp.role_id = sr.role_id
    join permissions p        on p.id = rp.permission_id
    where s.user_id = auth.uid()
      and s.account_status = 'active' and s.deleted_at is null
      and p.key = p_key
  )
$$;

-- API roles (anon/authenticated) are untrusted; everything else (migrations,
-- service_role, definer functions owned by the migration role) is trusted.
create function is_untrusted_caller() returns boolean
language sql stable as $$
  select current_user in ('anon', 'authenticated')
$$;

-- What the IRM needs to render itself: identity, roles, and effective permissions.
create function my_access() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'staff', jsonb_build_object(
      'id', s.id, 'ada_id', s.ada_id, 'full_name', s.full_name, 'email', s.email,
      'position', pos.title,
      'division_id', d.id, 'division_name', d.name),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', r.key, 'name', r.name, 'division_id', sr.division_id, 'division_name', dv.name))
      from staff_roles sr join roles r on r.id = sr.role_id
      left join divisions dv on dv.id = sr.division_id
      where sr.staff_id = s.id), '[]'::jsonb),
    'permissions', coalesce((
      select jsonb_agg(distinct jsonb_build_object('key', p.key, 'division_id', sr.division_id))
      from staff_roles sr
      join role_permissions rp on rp.role_id = sr.role_id
      join permissions p on p.id = rp.permission_id
      where sr.staff_id = s.id), '[]'::jsonb))
  from staff s
  left join positions pos on pos.id = s.position_id
  left join divisions d on d.id = s.primary_division_id
  where s.id = current_staff_id()
$$;

-- ---------------------------------------------------------------------------
-- Generic guards reused by later modules
-- ---------------------------------------------------------------------------
-- Soft delete: needs <module>.delete (organization-wide), a reason, and stamps who/when.
create function soft_delete_guard() returns trigger
language plpgsql as $$
begin
  if (old.deleted_at is null) <> (new.deleted_at is null) then
    if is_untrusted_caller() and not has_permission(tg_argv[0] || '.delete') then
      raise exception 'not permitted to delete or restore % records', tg_argv[0] using errcode = '42501';
    end if;
    if new.deleted_at is not null then
      if coalesce(btrim(new.deletion_reason), '') = '' then
        raise exception 'deletion_reason is required' using errcode = '23514';
      end if;
      new.deleted_at := now();
      new.deleted_by := current_staff_id();
    else
      new.deleted_by := null;
      new.deletion_reason := null;
    end if;
  elsif is_untrusted_caller()
        and (new.deleted_by is distinct from old.deleted_by
          or new.deletion_reason is distinct from old.deletion_reason) then
    raise exception 'deletion fields are managed by the system' using errcode = '42501';
  end if;
  return new;
end $$;

-- Classification: only records.classify holders may mark data restricted/confidential
-- (or change a classification).
create function classification_guard() returns trigger
language plpgsql as $$
begin
  if is_untrusted_caller()
     and (tg_op = 'INSERT' and new.classification in ('restricted', 'confidential')
          or tg_op = 'UPDATE' and new.classification is distinct from old.classification)
     and not has_permission('records.classify') then
    raise exception 'not permitted to set classification %', new.classification using errcode = '42501';
  end if;
  return new;
end $$;

create trigger staff_soft_delete   before update on staff for each row execute function soft_delete_guard('staff');
create trigger staff_classify      before insert or update on staff for each row execute function classification_guard();

-- ---------------------------------------------------------------------------
-- Staff guards
-- ---------------------------------------------------------------------------
create function staff_guard() returns trigger
language plpgsql as $$
begin
  if is_untrusted_caller() then
    if tg_op = 'INSERT' then
      if new.user_id is not null or new.account_status <> 'invited' then
        if not has_permission('staff.manage_accounts') then
          raise exception 'creating staff with a linked/active account requires staff.manage_accounts' using errcode = '42501';
        end if;
      end if;
    else
      if (new.user_id is distinct from old.user_id
          or new.account_status is distinct from old.account_status
          or new.employment_status is distinct from old.employment_status)
         and not has_permission('staff.manage_accounts') then
        raise exception 'changing account or employment status requires staff.manage_accounts' using errcode = '42501';
      end if;
      if old.id = current_staff_id() and new.account_status is distinct from old.account_status then
        raise exception 'you cannot change your own account status' using errcode = '42501';
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' and new.employment_status = 'terminated' and old.employment_status <> 'terminated' then
    new.account_status := 'disabled';
  end if;
  return new;
end $$;
create trigger staff_guard_trg before insert or update on staff for each row execute function staff_guard();

-- Invariant: ADA must always keep at least one active org-wide administrator.
create function assert_admin_remains() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from staff where deleted_at is null)
     and not exists (
       select 1
       from staff s
       join staff_roles sr      on sr.staff_id = s.id and sr.division_id is null
       join role_permissions rp on rp.role_id = sr.role_id
       join permissions p       on p.id = rp.permission_id and p.key = 'roles.administer'
       where s.account_status = 'active' and s.deleted_at is null and s.user_id is not null) then
    raise exception 'operation would leave ADA without an active administrator' using errcode = '23514';
  end if;
  return null;
end $$;
create trigger staff_admin_remains
  after update of account_status, deleted_at, user_id on staff
  for each statement execute function assert_admin_remains();
create trigger staff_roles_admin_remains
  after delete on staff_roles for each statement execute function assert_admin_remains();
create trigger role_permissions_admin_remains
  after delete on role_permissions for each statement execute function assert_admin_remains();

-- ---------------------------------------------------------------------------
-- Anti-escalation guards on role assignment / role definition
-- ---------------------------------------------------------------------------
create function staff_roles_guard() returns trigger
language plpgsql as $$
declare
  v_row staff_roles := case when tg_op = 'DELETE' then old else new end;
  v_missing text;
begin
  if tg_op = 'INSERT' then
    new.granted_by := current_staff_id();
  end if;
  if not is_untrusted_caller() then
    return v_row;
  end if;
  if not has_permission('roles.administer', v_row.division_id) then
    raise exception 'roles.administer is required' using errcode = '42501';
  end if;
  if v_row.staff_id = current_staff_id() then
    raise exception 'you cannot change your own role assignments' using errcode = '42501';
  end if;
  -- The actor must already hold every permission the role carries, in the same scope.
  select p.key into v_missing
  from role_permissions rp join permissions p on p.id = rp.permission_id
  where rp.role_id = v_row.role_id and not has_permission(p.key, v_row.division_id)
  limit 1;
  if v_missing is not null then
    raise exception 'cannot assign or revoke a role carrying % which you do not hold', v_missing using errcode = '42501';
  end if;
  return v_row;
end $$;
create trigger staff_roles_guard_trg before insert or delete on staff_roles
  for each row execute function staff_roles_guard();

create function role_permissions_guard() returns trigger
language plpgsql as $$
declare
  v_row role_permissions := case when tg_op = 'DELETE' then old else new end;
  v_key text;
begin
  if not is_untrusted_caller() then
    return v_row;
  end if;
  if not has_permission('roles.administer') then
    raise exception 'roles.administer is required' using errcode = '42501';
  end if;
  select key into v_key from permissions where id = v_row.permission_id;
  if not has_permission(v_key) then
    raise exception 'cannot change role grants for % which you do not hold', v_key using errcode = '42501';
  end if;
  return v_row;
end $$;
create trigger role_permissions_guard_trg before insert or delete on role_permissions
  for each row execute function role_permissions_guard();

create function roles_guard() returns trigger
language plpgsql as $$
begin
  if is_untrusted_caller() then
    if not has_permission('roles.administer') then
      raise exception 'roles.administer is required' using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and (new.key is distinct from old.key or new.is_system is distinct from old.is_system) then
      raise exception 'role key and system flag are immutable' using errcode = '42501';
    end if;
    if tg_op = 'INSERT' and new.is_system then
      raise exception 'system roles are created by migrations only' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger roles_guard_trg before insert or update on roles for each row execute function roles_guard();

-- ---------------------------------------------------------------------------
-- Account lifecycle functions
-- ---------------------------------------------------------------------------
-- Links an existing login (created in Supabase Auth by invitation) to a staff record.
create function link_staff_account(p_staff_id uuid, p_login_email text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid;
begin
  if not has_permission('staff.manage_accounts') then
    raise exception 'staff.manage_accounts is required' using errcode = '42501';
  end if;
  select id into v_user from auth.users where lower(email) = lower(p_login_email);
  if v_user is null then
    raise exception 'no login exists for %; invite the user in Authentication first', p_login_email using errcode = 'P0002';
  end if;
  update staff set user_id = v_user, account_status = 'active' where id = p_staff_id;
  if not found then
    raise exception 'staff record not found' using errcode = 'P0002';
  end if;
end $$;

-- One-time bootstrap of the first administrator. Service role only; refuses to run twice.
create function bootstrap_first_admin(p_user_id uuid, p_full_name text, p_email text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_staff uuid;
begin
  lock table staff in exclusive mode;
  if exists (select 1 from staff) then
    raise exception 'ADA is already bootstrapped' using errcode = '55000';
  end if;
  insert into staff (user_id, full_name, email, employment_status, account_status, start_date)
  values (p_user_id, p_full_name, p_email, 'active', 'active', current_date)
  returning id into v_staff;
  insert into staff_roles (staff_id, role_id, division_id, reason)
  select v_staff, id, null, 'bootstrap' from roles where key = 'ceo';
  return v_staff;
end $$;

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table staff            enable row level security;
alter table staff_private    enable row level security;
alter table permissions      enable row level security;
alter table roles            enable row level security;
alter table role_permissions enable row level security;
alter table staff_roles      enable row level security;

revoke all on staff, staff_private, permissions, roles, role_permissions, staff_roles from anon, authenticated;
grant select, insert, update on staff, staff_private to authenticated;
grant select on permissions to authenticated;
grant select, insert, update on roles to authenticated;
grant select, insert, delete on role_permissions, staff_roles to authenticated;

-- Organization structure: readable by any active staff; changed by settings.update.
grant select, update on organization to authenticated;
grant select, insert, update on divisions, positions to authenticated;
create policy org_select on organization for select to authenticated using (is_active_staff());
create policy org_update on organization for update to authenticated
  using (has_permission('settings.update')) with check (has_permission('settings.update'));
create policy divisions_select on divisions for select to authenticated using (is_active_staff());
create policy divisions_insert on divisions for insert to authenticated with check (has_permission('settings.update'));
create policy divisions_update on divisions for update to authenticated
  using (has_permission('settings.update')) with check (has_permission('settings.update'));
create policy positions_select on positions for select to authenticated using (is_active_staff());
create policy positions_insert on positions for insert to authenticated with check (has_permission('settings.update'));
create policy positions_update on positions for update to authenticated
  using (has_permission('settings.update')) with check (has_permission('settings.update'));

-- Staff directory: any active staff may list colleagues (deleted rows need records.view_deleted).
create policy staff_select on staff for select to authenticated
  using (is_active_staff() and (deleted_at is null or has_permission('records.view_deleted')));
create policy staff_insert on staff for insert to authenticated with check (has_permission('staff.create'));
create policy staff_update on staff for update to authenticated
  using (has_permission('staff.update')) with check (has_permission('staff.update'));

-- Sensitive HR data.
create policy staff_private_select on staff_private for select to authenticated
  using (staff_id = current_staff_id() or has_permission('hr.view'));
create policy staff_private_insert on staff_private for insert to authenticated with check (has_permission('hr.update'));
create policy staff_private_update on staff_private for update to authenticated
  using (has_permission('hr.update')) with check (has_permission('hr.update'));

-- Access-control metadata.
create policy permissions_select on permissions for select to authenticated using (has_permission('roles.view'));
create policy roles_select on roles for select to authenticated using (has_permission('roles.view'));
create policy roles_insert on roles for insert to authenticated with check (has_permission('roles.administer'));
create policy roles_update on roles for update to authenticated
  using (has_permission('roles.administer')) with check (has_permission('roles.administer'));
create policy role_permissions_select on role_permissions for select to authenticated using (has_permission('roles.view'));
create policy role_permissions_insert on role_permissions for insert to authenticated with check (has_permission('roles.administer'));
create policy role_permissions_delete on role_permissions for delete to authenticated using (has_permission('roles.administer'));
create policy staff_roles_select on staff_roles for select to authenticated
  using (has_permission('roles.view') or staff_id = current_staff_id());
create policy staff_roles_insert on staff_roles for insert to authenticated with check (has_permission('roles.administer', division_id));
create policy staff_roles_delete on staff_roles for delete to authenticated using (has_permission('roles.administer', division_id));

-- Function privileges: helpers are for signed-in users only; lifecycle functions are restricted.
revoke execute on function current_staff_id(), is_active_staff(), has_permission(text, uuid),
  has_permission_anywhere(text), is_untrusted_caller(), my_access(), link_staff_account(uuid, text),
  bootstrap_first_admin(uuid, text, text) from public, anon, authenticated;
grant execute on function current_staff_id(), is_active_staff(), has_permission(text, uuid),
  has_permission_anywhere(text), is_untrusted_caller(), my_access(), link_staff_account(uuid, text) to authenticated;
grant execute on function bootstrap_first_admin(uuid, text, text) to service_role;
