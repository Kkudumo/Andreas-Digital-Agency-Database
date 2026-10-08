-- 0006_clients: one client record shared by every division.
--
-- Visibility ("relevant clients"): a user sees a client when they hold clients.view
--   (a) organization-wide, or
--   (b) in the client's owner division or any division with an active relationship, or
--   (c) anywhere AND are personally assigned to the client;
-- and the record's classification and soft-delete state allow it.

create type client_type   as enum ('individual', 'company', 'government', 'ngo', 'educational');
create type client_status as enum ('prospect', 'active', 'inactive', 'archived');

create table clients (
  id                  uuid primary key default gen_random_uuid(),
  ada_id              text not null unique,
  name                text not null check (btrim(name) <> ''),
  client_type         client_type   not null default 'company',
  status              client_status not null default 'active',
  email               text,
  phone               text,
  address             text,
  city                text,
  country             text not null default 'Namibia',
  registration_number text,
  website             text,
  notes               text,
  owner_division_id   uuid references divisions (id),
  classification      data_classification not null default 'internal',
  created_by          uuid references staff (id),
  deleted_at          timestamptz,
  deleted_by          uuid references staff (id),
  deletion_reason     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index clients_owner_idx on clients (owner_division_id);
create index clients_name_idx  on clients (lower(name));
comment on table clients is 'Purpose: the single authoritative client record, shared across divisions. [class: internal by default; per-record classification]';

create table client_contacts (
  id         uuid primary key default gen_random_uuid(),
  ada_id     text not null unique,
  client_id  uuid not null references clients (id) on delete restrict,
  full_name  text not null check (btrim(full_name) <> ''),
  role_title text,
  email      text,
  phone      text,
  is_primary boolean not null default false,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index client_contacts_client_idx on client_contacts (client_id);
comment on table client_contacts is 'Purpose: people at a client. Visible to whoever can see the client. [class: internal]';

create table client_divisions (
  client_id           uuid not null references clients (id) on delete restrict,
  division_id         uuid not null references divisions (id) on delete restrict,
  relationship_status text not null default 'active' check (relationship_status in ('active', 'ended')),
  since               date not null default current_date,
  primary key (client_id, division_id)
);
comment on table client_divisions is 'Purpose: which divisions work with a client; drives division-scoped visibility. [class: internal]';

create table client_staff (
  client_id       uuid not null references clients (id) on delete restrict,
  staff_id        uuid not null references staff (id) on delete restrict,
  assignment_role text not null default 'account_manager',
  assigned_at     timestamptz not null default now(),
  primary key (client_id, staff_id)
);
comment on table client_staff is 'Purpose: staff personally responsible for a client (grants visibility to holders of clients.view in any scope). [class: internal]';

do $$ begin perform attach_ada_id('clients', 'client'); end $$;
do $$ begin perform attach_ada_id('client_contacts', 'contact'); end $$;
create trigger clients_updated         before update on clients         for each row execute function set_updated_at();
create trigger client_contacts_updated before update on client_contacts for each row execute function set_updated_at();
create trigger clients_soft_delete     before update on clients for each row execute function soft_delete_guard('clients');
create trigger clients_classify        before insert or update on clients for each row execute function classification_guard();

-- Row-based predicates: they evaluate the row's own columns (never re-read `clients`), so the
-- SELECT policy also holds for INSERT ... RETURNING, which PostgREST/supabase-js use.
create function can_view_client_row(p_id uuid, p_owner uuid, p_class data_classification, p_deleted timestamptz)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select (p_deleted is null or has_permission('records.view_deleted'))
    and (
      has_permission('clients.view')
      or has_permission('clients.view', p_owner)
      or exists (select 1 from client_divisions cd
                 where cd.client_id = p_id and cd.relationship_status = 'active'
                   and has_permission('clients.view', cd.division_id))
      or (has_permission_anywhere('clients.view')
          and exists (select 1 from client_staff cs where cs.client_id = p_id and cs.staff_id = current_staff_id()))
    )
    and (
      p_class in ('public', 'internal')
      or (p_class = 'restricted'
          and (has_permission('records.view_restricted')
               or exists (select 1 from client_staff cs where cs.client_id = p_id and cs.staff_id = current_staff_id())))
      or (p_class = 'confidential' and has_permission('records.view_confidential'))
    )
$$;

create function can_edit_client_row(p_id uuid, p_owner uuid, p_class data_classification, p_deleted timestamptz)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select can_view_client_row(p_id, p_owner, p_class, p_deleted)
    and (
      has_permission('clients.update')
      or has_permission('clients.update', p_owner)
      or exists (select 1 from client_divisions cd
                 where cd.client_id = p_id and cd.relationship_status = 'active'
                   and has_permission('clients.update', cd.division_id))
      or (has_permission_anywhere('clients.update')
          and exists (select 1 from client_staff cs where cs.client_id = p_id and cs.staff_id = current_staff_id()))
    )
$$;

-- By-id wrappers for child tables (contacts, divisions, projects, ...).
create function can_view_client(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_client_row(c.id, c.owner_division_id, c.classification, c.deleted_at)
                   from clients c where c.id = p_id), false)
$$;

create function can_edit_client(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_edit_client_row(c.id, c.owner_division_id, c.classification, c.deleted_at)
                   from clients c where c.id = p_id), false)
$$;

create function clients_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
  elsif is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.owner_division_id is distinct from old.owner_division_id and not has_permission('clients.update') then
      raise exception 'only organization-wide clients.update may reassign the owner division' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger clients_guard_trg before insert or update on clients for each row execute function clients_guard();

-- The owner division always has an active relationship with the client.
create function clients_sync_owner_division() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.owner_division_id is not null then
    insert into client_divisions (client_id, division_id) values (new.id, new.owner_division_id)
    on conflict do nothing;
  end if;
  return null;
end $$;
create trigger clients_sync_owner after insert or update of owner_division_id on clients
  for each row execute function clients_sync_owner_division();

alter table clients          enable row level security;
alter table client_contacts  enable row level security;
alter table client_divisions enable row level security;
alter table client_staff     enable row level security;
revoke all on clients, client_contacts, client_divisions, client_staff from anon, authenticated;
grant select, insert, update on clients, client_contacts, client_divisions to authenticated;
grant select, insert, delete on client_staff to authenticated;

create policy clients_select on clients for select to authenticated
  using (can_view_client_row(id, owner_division_id, classification, deleted_at));
create policy clients_insert on clients for insert to authenticated
  with check (has_permission('clients.create', owner_division_id));
create policy clients_update on clients for update to authenticated
  using (can_edit_client_row(id, owner_division_id, classification, deleted_at))
  with check (can_edit_client_row(id, owner_division_id, classification, null));  -- soft-deleting must stay possible

create policy contacts_select on client_contacts for select to authenticated using (can_view_client(client_id));
create policy contacts_insert on client_contacts for insert to authenticated with check (can_edit_client(client_id));
create policy contacts_update on client_contacts for update to authenticated
  using (can_edit_client(client_id)) with check (can_edit_client(client_id));

-- Linking a client to another division widens who can see it, so the actor must control that division.
create policy client_divisions_select on client_divisions for select to authenticated using (can_view_client(client_id));
create policy client_divisions_insert on client_divisions for insert to authenticated
  with check (can_edit_client(client_id)
              and (has_permission('clients.update') or has_permission('clients.update', division_id)));
create policy client_divisions_update on client_divisions for update to authenticated
  using (can_edit_client(client_id)
         and (has_permission('clients.update') or has_permission('clients.update', division_id)))
  with check (can_edit_client(client_id)
         and (has_permission('clients.update') or has_permission('clients.update', division_id)));

create policy client_staff_select on client_staff for select to authenticated using (can_view_client(client_id));
create policy client_staff_insert on client_staff for insert to authenticated with check (can_edit_client(client_id));
create policy client_staff_delete on client_staff for delete to authenticated using (can_edit_client(client_id));

revoke execute on function can_view_client(uuid), can_edit_client(uuid),
  can_view_client_row(uuid, uuid, data_classification, timestamptz),
  can_edit_client_row(uuid, uuid, data_classification, timestamptz) from public, anon;
grant execute on function can_view_client(uuid), can_edit_client(uuid),
  can_view_client_row(uuid, uuid, data_classification, timestamptz),
  can_edit_client_row(uuid, uuid, data_classification, timestamptz) to authenticated;

do $$ begin perform attach_audit('clients'); end $$;
do $$ begin perform attach_audit('client_contacts'); end $$;
do $$ begin perform attach_audit('client_divisions'); end $$;
do $$ begin perform attach_audit('client_staff'); end $$;
