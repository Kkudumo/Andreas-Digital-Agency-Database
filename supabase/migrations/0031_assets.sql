-- 0031_assets: the central asset register (ADA-AST-YYYY-####).
--  * An asset is ONE record: what the thing is (category, manufacturer, model, serial, tag), its lifecycle and condition,
--    where it is, who is responsible. WHO HOLDS IT is not a mutable field on the asset: it is a history of assignments
--    (asset_assignments), at most one open at a time, never overwritten, never deleted.
--  * Lifecycle (controlled for every caller): proposed -> acquired -> in_stock -> assigned -> in_maintenance -> returned ->
--    retired -> disposed (plus cancelled for a proposal that never happened). Retired is not deleted: the record, its
--    assignments and its history stay traceable; a retired asset can only be disposed, never silently reactivated.
--  * Finance stays authoritative. The asset REFERENCES a supplier, a client/project and (via asset_finance_links) the
--    sales invoices / payments that concern it; it does not copy invoice or payment identity. acquisition_cost is a
--    documented SNAPSHOT until the expenses module supplies the authoritative record.
--  * Restricted clients/projects: an asset inherits the stricter classification of itself, its client, its project and its
--    parent asset, so it is invisible exactly like a non-existent record.
--  * Serial numbers and tags do NOT merge or block records. Suspicious matches are recorded as duplicate flags for review
--    (visible only to someone who can see both assets) - a unique index would be an existence oracle.

insert into entity_types (key, prefix, description) values
  ('supplier', 'SUP', 'Supplier / vendor'),
  ('ticket',   'TKT', 'Support / maintenance ticket');
update entity_types set description = 'Physical or technical asset' where key = 'asset';

-- permissions
insert into permissions (key, module, action, description, sensitivity) values
  ('assets.view', 'assets', 'view', 'View the asset register (own division; assignees see their own assets)', 'internal'::data_classification),
  ('assets.create', 'assets', 'create', 'Register assets and report duplicates', 'internal'::data_classification),
  ('assets.update', 'assets', 'update', 'Edit asset details and record locations / condition / documents / warranties', 'internal'::data_classification),
  ('assets.assign', 'assets', 'assign', 'Assign and return assets', 'internal'::data_classification),
  ('assets.maintain', 'assets', 'maintain', 'Schedule and record maintenance', 'internal'::data_classification),
  ('assets.retire', 'assets', 'retire', 'Retire assets', 'restricted'::data_classification),
  ('assets.dispose', 'assets', 'dispose', 'Dispose of retired assets', 'restricted'::data_classification),
  ('assets.configure', 'assets', 'configure', 'Manage asset categories', 'restricted'::data_classification),
  ('suppliers.view', 'suppliers', 'view', 'View suppliers and vendors', 'internal'::data_classification),
  ('suppliers.manage', 'suppliers', 'manage', 'Create and edit suppliers and vendors', 'internal'::data_classification),
  ('tickets.view', 'tickets', 'view', 'View tickets (own division; reporters and assignees see their own)', 'internal'::data_classification),
  ('tickets.create', 'tickets', 'create', 'Open tickets', 'internal'::data_classification),
  ('tickets.update', 'tickets', 'update', 'Work and resolve tickets', 'internal'::data_classification),
  ('tickets.assign', 'tickets', 'assign', 'Assign tickets to staff', 'internal'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'assets.view'),
  ('administration_officer', 'assets.view'),
  ('finance_officer', 'assets.view'),
  ('division_lead', 'assets.view'),
  ('division_staff', 'assets.view'),
  ('auditor', 'assets.view'),
  ('ceo', 'assets.create'),
  ('administration_officer', 'assets.create'),
  ('division_lead', 'assets.create'),
  ('ceo', 'assets.update'),
  ('administration_officer', 'assets.update'),
  ('division_lead', 'assets.update'),
  ('ceo', 'assets.assign'),
  ('administration_officer', 'assets.assign'),
  ('division_lead', 'assets.assign'),
  ('ceo', 'assets.maintain'),
  ('administration_officer', 'assets.maintain'),
  ('division_lead', 'assets.maintain'),
  ('division_staff', 'assets.maintain'),
  ('ceo', 'assets.retire'),
  ('administration_officer', 'assets.retire'),
  ('division_lead', 'assets.retire'),
  ('ceo', 'assets.dispose'),
  ('ceo', 'assets.configure'),
  ('administration_officer', 'assets.configure'),
  ('ceo', 'suppliers.view'),
  ('administration_officer', 'suppliers.view'),
  ('finance_officer', 'suppliers.view'),
  ('division_lead', 'suppliers.view'),
  ('ceo', 'suppliers.manage'),
  ('administration_officer', 'suppliers.manage'),
  ('finance_officer', 'suppliers.manage'),
  ('ceo', 'tickets.view'),
  ('administration_officer', 'tickets.view'),
  ('finance_officer', 'tickets.view'),
  ('division_lead', 'tickets.view'),
  ('division_staff', 'tickets.view'),
  ('auditor', 'tickets.view'),
  ('ceo', 'tickets.create'),
  ('administration_officer', 'tickets.create'),
  ('division_lead', 'tickets.create'),
  ('division_staff', 'tickets.create'),
  ('ceo', 'tickets.update'),
  ('administration_officer', 'tickets.update'),
  ('division_lead', 'tickets.update'),
  ('division_staff', 'tickets.update'),
  ('ceo', 'tickets.assign'),
  ('administration_officer', 'tickets.assign'),
  ('division_lead', 'tickets.assign')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

create type asset_status as enum ('proposed', 'acquired', 'in_stock', 'assigned', 'in_maintenance', 'returned', 'retired', 'disposed', 'cancelled');
create type asset_condition as enum ('new', 'good', 'fair', 'poor', 'broken');
create type asset_acquisition as enum ('purchased', 'leased', 'donated', 'built', 'client_supplied', 'transferred', 'other');
create type asset_disposal_method as enum ('sold', 'scrapped', 'donated', 'recycled', 'returned_to_vendor', 'lost', 'stolen');

-- ---------------------------------------------------------------------------
-- Suppliers / vendors (one record per vendor; assets and, later, expenses reference it)
-- ---------------------------------------------------------------------------
create table suppliers (
  id                  uuid primary key default gen_random_uuid(),
  ada_id              text not null unique,
  name                text not null check (btrim(name) <> ''),
  name_key            text not null,
  registration_number text,
  website             text,
  status              text not null default 'active' check (status in ('active', 'inactive')),
  notes               text,
  created_by          uuid references staff (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index suppliers_name_key_unique on suppliers (name_key);
comment on table suppliers is 'Purpose: the one record per supplier/vendor. Referenced by assets (supplier, warranty provider, maintenance vendor) and later by expenses. Contacts, when needed, are people. [class: internal]';
do $$ begin perform attach_ada_id('suppliers', 'supplier'); end $$;
create trigger suppliers_updated before update on suppliers for each row execute function set_updated_at();
create function suppliers_key() returns trigger language plpgsql as $$
begin
  new.name_key := client_name_key(new.name);
  if new.name_key = '' then raise exception 'the supplier name is not usable' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then new.created_by := current_staff_id(); end if;
  return new;
end $$;
create trigger suppliers_key_trg before insert or update of name on suppliers for each row execute function suppliers_key();

create table asset_categories (
  id         uuid primary key default gen_random_uuid(),
  key        text not null unique check (key ~ '^[a-z0-9_]+$'),
  name       text not null,
  is_active  boolean not null default true,
  sort_order integer not null default 100
);
comment on table asset_categories is 'Purpose: asset types (laptop, server, CCTV camera, ...). A lookup managed by assets.configure. [class: internal]';
insert into asset_categories (key, name, sort_order) values
  ('laptop', 'Laptop', 10), ('desktop', 'Desktop computer', 20), ('server', 'Server', 30), ('network', 'Network equipment', 40),
  ('mobile', 'Phone / tablet', 50), ('peripheral', 'Peripheral / accessory', 60), ('camera', 'CCTV / camera', 70), ('storage', 'Storage device', 80),
  ('vehicle', 'Vehicle', 90), ('furniture', 'Furniture / fixture', 100), ('software_license', 'Software licence', 110), ('other', 'Other', 999);

-- ---------------------------------------------------------------------------
-- The asset
-- ---------------------------------------------------------------------------
create table assets (
  id                       uuid primary key default gen_random_uuid(),
  ada_id                   text not null unique,
  name                     text not null check (btrim(name) <> ''),
  category_id              uuid not null references asset_categories (id),
  manufacturer             text,
  model                    text,
  serial_number            text,
  asset_tag                text,
  manufacturer_key         text generated always as (lower(regexp_replace(coalesce(manufacturer, ''), '[^A-Za-z0-9]', '', 'g'))) stored,
  serial_key               text generated always as (upper(regexp_replace(coalesce(serial_number, ''), '[^A-Za-z0-9]', '', 'g'))) stored,
  condition                asset_condition not null default 'good',
  status                   asset_status not null default 'proposed',
  acquisition_method       asset_acquisition,
  acquisition_date         date,
  acquisition_cost         numeric(14,2) check (acquisition_cost >= 0),
  acquisition_currency     char(3),
  supplier_id              uuid references suppliers (id),
  current_location         text,
  division_id              uuid not null references divisions (id),
  client_id                uuid references clients (id) on delete restrict,
  project_id               uuid references projects (id) on delete restrict,
  parent_asset_id          uuid references assets (id),
  classification           data_classification not null default 'internal',
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  notes                    text,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (parent_asset_id is distinct from id),
  check ((acquisition_cost is null) = (acquisition_currency is null))
);
create index assets_division_idx on assets (division_id);
create index assets_client_idx on assets (client_id) where client_id is not null;
create index assets_project_idx on assets (project_id) where project_id is not null;
create index assets_parent_idx on assets (parent_asset_id) where parent_asset_id is not null;
create index assets_serial_idx on assets (manufacturer_key, serial_key) where serial_key <> '';
create index assets_tag_idx on assets (lower(btrim(asset_tag))) where asset_tag is not null;
comment on table assets is 'Purpose: the one authoritative record of a physical/technical asset. Holder, location history and maintenance live in their own append-only tables; client/project are references; no invoice or payment identity is stored. No unique index on serial or tag (it would reveal hidden assets): duplicates are flagged for review. [class: internal; per-record classification]';
comment on column assets.acquisition_cost is 'SNAPSHOT: indicative cost recorded at acquisition until the expenses module links the authoritative financial record. Finance remains the source of truth.';
comment on column assets.effective_classification is 'Stricter of the asset, its client, its project and its parent asset. Maintained by trigger; drives visibility.';
comment on column assets.current_location is 'Where the asset physically is now; every change is appended to asset_history.';
do $$ begin perform attach_ada_id('assets', 'asset'); end $$;
create trigger assets_updated before update on assets for each row execute function set_updated_at();

-- Inheritance of classification, client consistency, no parent cycles
create function assets_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cc data_classification; v_cd boolean; v_pc data_classification; v_pclient uuid; v_par data_classification; v_walk uuid; v_depth integer := 0;
begin
  if new.project_id is not null then
    select client_id, effective_classification into v_pclient, v_pc from projects where id = new.project_id;
    if new.client_id is null then new.client_id := v_pclient;
    elsif new.client_id is distinct from v_pclient then raise exception 'the project must belong to the asset''s client' using errcode = '23514'; end if;
  end if;
  if new.client_id is not null then select classification, deleted_at is not null into v_cc, v_cd from clients where id = new.client_id; end if;
  if new.parent_asset_id is not null then
    v_walk := new.parent_asset_id;
    while v_walk is not null loop
      if v_walk = new.id then raise exception 'an asset cannot be its own ancestor' using errcode = '23514'; end if;
      v_depth := v_depth + 1;
      if v_depth > 20 then raise exception 'asset hierarchy too deep' using errcode = '23514'; end if;
      select parent_asset_id into v_walk from assets where id = v_walk;
    end loop;
    select effective_classification into v_par from assets where id = new.parent_asset_id;
  end if;
  new.effective_classification := greatest(new.classification, coalesce(v_cc, 'internal'), coalesce(v_pc, 'internal'), coalesce(v_par, 'internal'));
  new.client_deleted := coalesce(v_cd, false);
  return new;
end $$;
create trigger assets_inherit_trg before insert or update of client_id, project_id, parent_asset_id, classification on assets
  for each row execute function assets_inherit();

-- A reclassified parent / client / project pulls its dependents along (children, then tickets in a later migration)
create function assets_cascade() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.effective_classification is distinct from old.effective_classification then
    update assets set classification = classification where parent_asset_id = new.id;
  end if;
  return null;
end $$;
create trigger assets_cascade_trg after update of effective_classification on assets for each row execute function assets_cascade();

create function assets_follow_client() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update assets set classification = classification, client_id = client_id where client_id = new.id;
  return null;
end $$;
create trigger assets_follow_client_trg after update of classification, deleted_at on clients for each row execute function assets_follow_client();

create function assets_follow_project() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.effective_classification is distinct from old.effective_classification then
    update assets set classification = classification where project_id = new.id;
  end if;
  return null;
end $$;
create trigger assets_follow_project_trg after update of effective_classification on projects for each row execute function assets_follow_project();

-- The guard applies to EVERY caller (users have no write grants at all; this protects against the owner and future code too)
create function assets_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'assets are never deleted; retire and dispose them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if new.status not in ('proposed', 'acquired', 'in_stock') then raise exception 'an asset is registered as proposed, acquired or in stock' using errcode = '23514'; end if;
    return new;
  end if;
  if new.status is distinct from old.status and not (
        (old.status = 'proposed'       and new.status in ('acquired', 'cancelled'))
     or (old.status = 'acquired'       and new.status in ('in_stock', 'assigned'))
     or (old.status = 'in_stock'       and new.status in ('assigned', 'in_maintenance', 'retired'))
     or (old.status = 'assigned'       and new.status in ('returned', 'in_maintenance'))
     or (old.status = 'returned'       and new.status in ('in_stock', 'assigned', 'in_maintenance', 'retired'))
     or (old.status = 'in_maintenance' and new.status in ('in_stock', 'assigned', 'returned', 'retired'))
     or (old.status = 'retired'        and new.status = 'disposed')) then
    raise exception 'invalid asset status change % -> % (a retired asset can only be disposed)', old.status, new.status using errcode = '23514';
  end if;
  if old.status in ('retired', 'disposed', 'cancelled') and (
       (new.name, new.category_id, new.manufacturer, new.model, new.serial_number, new.asset_tag, new.condition, new.acquisition_method, new.acquisition_date,
        new.acquisition_cost, new.acquisition_currency, new.supplier_id, new.current_location, new.division_id, new.client_id, new.project_id, new.parent_asset_id, new.classification)
       is distinct from
       (old.name, old.category_id, old.manufacturer, old.model, old.serial_number, old.asset_tag, old.condition, old.acquisition_method, old.acquisition_date,
        old.acquisition_cost, old.acquisition_currency, old.supplier_id, old.current_location, old.division_id, old.client_id, old.project_id, old.parent_asset_id, old.classification)) then
    raise exception 'a % asset''s record is frozen', old.status using errcode = '42501';
  end if;
  return new;
end $$;
create trigger assets_guard_trg before insert or update or delete on assets for each row execute function assets_guard();

-- ---------------------------------------------------------------------------
-- Assignment history: who held the asset, for which division, from when to when
-- ---------------------------------------------------------------------------
create table asset_assignments (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references assets (id) on delete restrict,
  staff_id    uuid references staff (id),
  division_id uuid not null references divisions (id),
  project_id  uuid references projects (id),
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  assigned_by uuid references staff (id),
  ended_by    uuid references staff (id),
  end_reason  text,
  note        text,
  check (ended_at is null or ended_at >= started_at),
  check ((ended_at is null) = (end_reason is null))
);
create unique index asset_assignments_one_open on asset_assignments (asset_id) where ended_at is null;
create index asset_assignments_staff_idx on asset_assignments (staff_id) where ended_at is null;
create index asset_assignments_asset_idx on asset_assignments (asset_id, started_at);
comment on table asset_assignments is 'Purpose: historical accountability. One row per period an asset was held by a staff member / division. At most one is open per asset; ending one sets ended_at (once); rows are never edited or deleted. The "current holder" is derived from the open row. [class: internal]';

create function asset_assignments_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'assignment history cannot be deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    if exists (select 1 from asset_assignments o where o.asset_id = new.asset_id
               and tstzrange(o.started_at, coalesce(o.ended_at, 'infinity'), '[)') && tstzrange(new.started_at, coalesce(new.ended_at, 'infinity'), '[)')) then
      raise exception 'the asset already has an assignment covering that period' using errcode = '23505';
    end if;
    new.assigned_by := coalesce(new.assigned_by, current_staff_id());
    return new;
  end if;
  if old.ended_at is not null
     or (new.asset_id, new.staff_id, new.division_id, new.project_id, new.started_at, new.assigned_by, new.note)
        is distinct from (old.asset_id, old.staff_id, old.division_id, old.project_id, old.started_at, old.assigned_by, old.note) then
    raise exception 'assignment history cannot be rewritten; end the assignment and create a new one' using errcode = '42501';
  end if;
  new.ended_by := coalesce(new.ended_by, current_staff_id());
  return new;
end $$;
create trigger asset_assignments_guard_trg before insert or update or delete on asset_assignments for each row execute function asset_assignments_guard();

-- ---------------------------------------------------------------------------
-- Visibility (row-based; assignees see the asset they hold, still subject to classification)
-- ---------------------------------------------------------------------------
create function can_view_asset_row(p_id uuid, p_division uuid, p_class data_classification, p_client_deleted boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select (has_permission('assets.view', p_division)
          or exists (select 1 from asset_assignments a where a.asset_id = p_id and a.ended_at is null and a.staff_id is not null and a.staff_id = current_staff_id()))
     and classification_visible(p_class)
     and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_asset(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_asset_row(a.id, a.division_id, a.effective_classification, a.client_deleted) from assets a where a.id = p_id), false)
$$;
create function can_edit_asset(p_id uuid, p_permission text default 'assets.update') returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_asset_row(a.id, a.division_id, a.effective_classification, a.client_deleted) and has_permission(p_permission, a.division_id) from assets a where a.id = p_id), false)
$$;


-- Append-only history of everything that changes on an asset
create table asset_history (
  id             bigint generated always as identity primary key,
  asset_id       uuid not null references assets (id) on delete restrict,
  kind           text not null check (kind in ('created', 'status', 'field', 'assignment', 'maintenance', 'link', 'flag')),
  field          text,
  from_value     text,
  to_value       text,
  actor_staff_id uuid references staff (id),
  note           text,
  created_at     timestamptz not null default now()
);
create index asset_history_asset_idx on asset_history (asset_id, id);
comment on table asset_history is 'Purpose: append-only trail of status, condition, location, ownership and relationship changes of an asset (in addition to audit_log). Never edited or deleted. [class: internal]';
create trigger asset_history_immutable before update or delete on asset_history for each row execute function append_only();

create table asset_retirements (
  asset_id        uuid primary key references assets (id) on delete restrict,
  retired_on      date not null default current_date,
  reason          text not null check (btrim(reason) <> ''),
  retired_by      uuid references staff (id),
  disposal_method asset_disposal_method,
  disposed_on     date,
  disposal_note   text,
  disposed_by     uuid references staff (id),
  created_at      timestamptz not null default now(),
  check ((disposal_method is null) = (disposed_on is null))
);
comment on table asset_retirements is 'Purpose: why and when an asset was retired, and later how it was disposed of. The sale value of a disposed asset is NOT stored here: link the sales invoice instead (asset_finance_links). [class: internal]';
create function asset_retirements_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'retirement records cannot be deleted' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and (old.disposed_on is not null or (new.asset_id, new.retired_on, new.reason, new.retired_by) is distinct from (old.asset_id, old.retired_on, old.reason, old.retired_by)) then
    raise exception 'a retirement record cannot be rewritten' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger asset_retirements_guard_trg before update or delete on asset_retirements for each row execute function asset_retirements_guard();

create table asset_warranties (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references assets (id) on delete restrict,
  provider_id uuid references suppliers (id),
  reference   text,
  starts_on   date not null,
  ends_on     date not null,
  terms       text,
  voided_at   timestamptz,
  void_reason text,
  created_by  uuid references staff (id),
  created_at  timestamptz not null default now(),
  check (ends_on >= starts_on),
  check ((voided_at is null) = (void_reason is null))
);
create index asset_warranties_asset_idx on asset_warranties (asset_id, ends_on);
comment on table asset_warranties is 'Purpose: warranty coverage periods for an asset (manufacturer, extended, supplier). Append-only; a mistaken entry is voided with a reason, not edited. [class: internal]';

create table asset_documents (
  id           uuid primary key default gen_random_uuid(),
  asset_id     uuid not null references assets (id) on delete restrict,
  kind         text not null check (kind in ('warranty', 'invoice', 'manual', 'photo', 'handover', 'disposal', 'other')),
  title        text not null check (btrim(title) <> ''),
  document_ref text not null check (btrim(document_ref) <> ''),
  voided_at    timestamptz,
  void_reason  text,
  added_by     uuid references staff (id),
  added_at     timestamptz not null default now(),
  check ((voided_at is null) = (void_reason is null))
);
create index asset_documents_asset_idx on asset_documents (asset_id);
comment on table asset_documents is 'Purpose: INTERIM link between an asset and its documents (warranty, supplier invoice, manual, handover form, photo). Visible exactly as the asset is. The documents module will replace document_ref with real document links. [class: internal; inherits the asset''s classification]';

create table asset_finance_links (
  id         uuid primary key default gen_random_uuid(),
  asset_id   uuid not null references assets (id) on delete restrict,
  invoice_id uuid references invoices (id) on delete restrict,
  payment_id uuid references payments (id) on delete restrict,
  relation   text not null check (relation in ('billed_to_client', 'sold', 'hardware_charge', 'client_payment', 'other')),
  note       text,
  linked_by  uuid references staff (id),
  linked_at  timestamptz not null default now(),
  check ((invoice_id is not null) <> (payment_id is not null))
);
create unique index asset_finance_links_invoice on asset_finance_links (asset_id, invoice_id) where invoice_id is not null;
create unique index asset_finance_links_payment on asset_finance_links (asset_id, payment_id) where payment_id is not null;
comment on table asset_finance_links is 'Purpose: which invoices/payments concern an asset (e.g. hardware billed to a client). Only ids: the financial records stay authoritative in invoices/payments and are visible only to those who may see them. [class: confidential]';

create table asset_duplicate_flags (
  id             uuid primary key default gen_random_uuid(),
  asset_id       uuid not null references assets (id) on delete restrict,
  other_asset_id uuid not null references assets (id) on delete restrict,
  reason         text not null check (reason in ('same_serial', 'same_serial_unknown_maker', 'same_tag')),
  status         text not null default 'open' check (status in ('open', 'dismissed', 'confirmed_duplicate')),
  reviewed_by    uuid references staff (id),
  review_note    text,
  created_at     timestamptz not null default now(),
  check (asset_id < other_asset_id)
);
create unique index asset_duplicate_flags_pair on asset_duplicate_flags (asset_id, other_asset_id, reason);
comment on table asset_duplicate_flags is 'Purpose: suspected duplicate assets, raised automatically, reviewed by people. Nothing is merged. A flag is visible only to someone who can see BOTH assets, so flagging cannot reveal a hidden asset. [class: internal]';

create function asset_flags_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'duplicate flags cannot be deleted' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and ((new.asset_id, new.other_asset_id, new.reason, new.created_at) is distinct from (old.asset_id, old.other_asset_id, old.reason, old.created_at) or old.status <> 'open') then
    raise exception 'a reviewed flag is final' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger asset_flags_guard_trg before update or delete on asset_duplicate_flags for each row execute function asset_flags_guard();
create function asset_children_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception '% rows cannot be deleted', tg_table_name using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if tg_table_name = 'asset_warranties' then
      if old.voided_at is null and (new.asset_id, new.provider_id, new.reference, new.starts_on, new.ends_on, new.terms) is not distinct from (old.asset_id, old.provider_id, old.reference, old.starts_on, old.ends_on, old.terms) then return new; end if;
    elsif tg_table_name = 'asset_documents' then
      if old.voided_at is null and (new.asset_id, new.kind, new.title, new.document_ref) is not distinct from (old.asset_id, old.kind, old.title, old.document_ref) then return new; end if;
    end if;
    raise exception '% rows cannot be rewritten (void with a reason instead)', tg_table_name using errcode = '42501';
  end if;
  return new;
end $$;
create trigger asset_warranties_guard_trg before update or delete on asset_warranties for each row execute function asset_children_guard();
create trigger asset_documents_guard_trg before update or delete on asset_documents for each row execute function asset_children_guard();
create trigger asset_finance_links_guard_trg before update or delete on asset_finance_links for each row execute function asset_children_guard();

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
create function asset_log(p_asset uuid, p_kind text, p_field text, p_from text, p_to text, p_note text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into asset_history (asset_id, kind, field, from_value, to_value, actor_staff_id, note) values (p_asset, p_kind, p_field, p_from, p_to, current_staff_id(), p_note)
$$;

-- Loads (and locks) an asset the caller may see, or fails exactly as for one that does not exist.
create function asset_load(p_id uuid) returns assets
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype;
begin
  select * into a from assets where id = p_id for update;
  if not found or not can_view_asset_row(a.id, a.division_id, a.effective_classification, a.client_deleted) then
    raise exception 'asset not found' using errcode = 'P0002';
  end if;
  return a;
end $$;

-- Flags (never merges) assets that look like the same physical item. Runs over ALL assets; the flag is only readable by
-- someone who can see both, so it reveals nothing about a hidden asset.
create function asset_detect_duplicates(p_asset uuid) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; r record; n integer := 0;
begin
  select * into a from assets where id = p_asset;
  if not found then return 0; end if;
  for r in
    select b.id, case when a.manufacturer_key <> '' and b.manufacturer_key <> '' then 'same_serial' else 'same_serial_unknown_maker' end as reason
      from assets b
     where b.id <> a.id and a.serial_key <> '' and b.serial_key = a.serial_key
       and (a.manufacturer_key = b.manufacturer_key or a.manufacturer_key = '' or b.manufacturer_key = '')
    union
    select b.id, 'same_tag' from assets b
     where b.id <> a.id and a.asset_tag is not null and b.asset_tag is not null and lower(btrim(a.asset_tag)) = lower(btrim(b.asset_tag)) and btrim(a.asset_tag) <> ''
  loop
    insert into asset_duplicate_flags (asset_id, other_asset_id, reason) values (least(a.id, r.id), greatest(a.id, r.id), r.reason) on conflict do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

create function asset_create(p_name text, p_category text, p_division uuid, p_manufacturer text default null, p_model text default null,
                             p_serial text default null, p_tag text default null, p_condition asset_condition default 'good', p_status asset_status default 'proposed',
                             p_method asset_acquisition default null, p_acquired_on date default null, p_cost numeric default null, p_currency text default null,
                             p_supplier uuid default null, p_client uuid default null, p_project uuid default null, p_parent uuid default null,
                             p_location text default null, p_classification data_classification default 'internal') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cat uuid; v_id uuid; pa assets%rowtype;
begin
  if not has_permission('assets.create', p_division) then raise exception 'assets.create is required in that division' using errcode = '42501'; end if;
  select id into v_cat from asset_categories where key = p_category and is_active;
  if v_cat is null then raise exception 'unknown asset category' using errcode = '23514'; end if;
  if p_client is not null and (not exists (select 1 from clients where id = p_client and deleted_at is null) or not can_view_client(p_client)) then
    raise exception 'client not found' using errcode = 'P0002';
  end if;
  if p_project is not null and not can_view_project(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if p_parent is not null then pa := asset_load(p_parent); if pa.status in ('retired', 'disposed', 'cancelled') then raise exception 'the parent asset is %', pa.status using errcode = '23514'; end if; end if;
  if p_supplier is not null and not exists (select 1 from suppliers where id = p_supplier and status = 'active') then raise exception 'supplier not found' using errcode = 'P0002'; end if;
  if p_classification <> 'internal' and not has_permission('records.classify') then raise exception 'records.classify is required to set a classification' using errcode = '42501'; end if;
  if nullif(btrim(p_tag), '') is not null and exists (select 1 from assets a where lower(btrim(a.asset_tag)) = lower(btrim(p_tag))
        and can_view_asset_row(a.id, a.division_id, a.effective_classification, a.client_deleted)) then
    raise exception 'an asset with this tag already exists' using errcode = '23505';
  end if;
  insert into assets (name, category_id, manufacturer, model, serial_number, asset_tag, condition, status, acquisition_method, acquisition_date, acquisition_cost, acquisition_currency,
                      supplier_id, current_location, division_id, client_id, project_id, parent_asset_id, classification)
  values (p_name, v_cat, nullif(btrim(p_manufacturer), ''), nullif(btrim(p_model), ''), nullif(btrim(p_serial), ''), nullif(btrim(p_tag), ''), p_condition, p_status, p_method,
          case when p_status <> 'proposed' then coalesce(p_acquired_on, current_date) else p_acquired_on end, p_cost, case when p_cost is not null then coalesce(p_currency, (select base_currency from finance_settings)) end,
          p_supplier, p_location, p_division, p_client, p_project, p_parent, p_classification)
  returning id into v_id;
  perform asset_log(v_id, 'created', null, null, p_status::text, null);
  perform asset_detect_duplicates(v_id);
  perform emit_event('asset.created', 'assets', v_id, (select ada_id from assets where id = v_id), jsonb_build_object('status', p_status));
  return v_id;
end $$;

create function asset_update(p_asset uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a assets%rowtype; k text; o jsonb; n jsonb;
  allowed text[] := array['name', 'category_id', 'manufacturer', 'model', 'serial_number', 'asset_tag', 'condition', 'acquisition_method', 'acquisition_date',
                          'acquisition_cost', 'acquisition_currency', 'supplier_id', 'current_location', 'client_id', 'project_id', 'classification', 'notes'];
begin
  a := asset_load(p_asset);
  if not has_permission('assets.update', a.division_id) then raise exception 'assets.update is required' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any (allowed) then raise exception 'unknown or protected asset field: %', k using errcode = '22023'; end if;
  end loop;
  if a.status in ('retired', 'disposed', 'cancelled') and (p_changes - 'notes') <> '{}'::jsonb then
    raise exception 'a % asset''s record is frozen', a.status using errcode = '42501';
  end if;
  if p_changes ? 'classification' and not has_permission('records.classify') then raise exception 'records.classify is required' using errcode = '42501'; end if;
  if p_changes ? 'client_id' and (p_changes ->> 'client_id') is not null and (not exists (select 1 from clients where id = (p_changes ->> 'client_id')::uuid and deleted_at is null) or not can_view_client((p_changes ->> 'client_id')::uuid)) then
    raise exception 'client not found' using errcode = 'P0002';
  end if;
  if p_changes ? 'project_id' and (p_changes ->> 'project_id') is not null and not can_view_project((p_changes ->> 'project_id')::uuid) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if p_changes ? 'supplier_id' and (p_changes ->> 'supplier_id') is not null and not exists (select 1 from suppliers where id = (p_changes ->> 'supplier_id')::uuid and status = 'active') then raise exception 'supplier not found' using errcode = 'P0002'; end if;
  if p_changes ? 'asset_tag' and nullif(btrim(p_changes ->> 'asset_tag'), '') is not null and exists (select 1 from assets x where x.id <> a.id and lower(btrim(x.asset_tag)) = lower(btrim(p_changes ->> 'asset_tag'))
        and can_view_asset_row(x.id, x.division_id, x.effective_classification, x.client_deleted)) then
    raise exception 'an asset with this tag already exists' using errcode = '23505';
  end if;
  o := to_jsonb(a);
  update assets set
    name = case when p_changes ? 'name' then p_changes ->> 'name' else name end,
    category_id = case when p_changes ? 'category_id' then (p_changes ->> 'category_id')::uuid else category_id end,
    manufacturer = case when p_changes ? 'manufacturer' then nullif(btrim(p_changes ->> 'manufacturer'), '') else manufacturer end,
    model = case when p_changes ? 'model' then nullif(btrim(p_changes ->> 'model'), '') else model end,
    serial_number = case when p_changes ? 'serial_number' then nullif(btrim(p_changes ->> 'serial_number'), '') else serial_number end,
    asset_tag = case when p_changes ? 'asset_tag' then nullif(btrim(p_changes ->> 'asset_tag'), '') else asset_tag end,
    condition = case when p_changes ? 'condition' then (p_changes ->> 'condition')::asset_condition else condition end,
    acquisition_method = case when p_changes ? 'acquisition_method' then (p_changes ->> 'acquisition_method')::asset_acquisition else acquisition_method end,
    acquisition_date = case when p_changes ? 'acquisition_date' then (p_changes ->> 'acquisition_date')::date else acquisition_date end,
    acquisition_cost = case when p_changes ? 'acquisition_cost' then (p_changes ->> 'acquisition_cost')::numeric else acquisition_cost end,
    acquisition_currency = case when p_changes ? 'acquisition_currency' then p_changes ->> 'acquisition_currency' else acquisition_currency end,
    supplier_id = case when p_changes ? 'supplier_id' then (p_changes ->> 'supplier_id')::uuid else supplier_id end,
    current_location = case when p_changes ? 'current_location' then p_changes ->> 'current_location' else current_location end,
    client_id = case when p_changes ? 'client_id' then (p_changes ->> 'client_id')::uuid else client_id end,
    project_id = case when p_changes ? 'project_id' then (p_changes ->> 'project_id')::uuid else project_id end,
    classification = case when p_changes ? 'classification' then (p_changes ->> 'classification')::data_classification else classification end,
    notes = case when p_changes ? 'notes' then p_changes ->> 'notes' else notes end
  where id = a.id returning to_jsonb(assets.*) into n;
  for k in select jsonb_object_keys(p_changes) loop
    if (o ->> k) is distinct from (n ->> k) then perform asset_log(a.id, 'field', k, o ->> k, n ->> k, null); end if;
  end loop;
  if p_changes ?| array['serial_number', 'asset_tag', 'manufacturer'] then perform asset_detect_duplicates(a.id); end if;
end $$;

create function asset_set_parent(p_asset uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; pa assets%rowtype;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.update', a.division_id) then raise exception 'assets.update is required' using errcode = '42501'; end if;
  if a.status in ('retired', 'disposed', 'cancelled') then raise exception 'a % asset''s record is frozen', a.status using errcode = '42501'; end if;
  if p_parent is not null then
    pa := asset_load(p_parent);
    if pa.status in ('retired', 'disposed', 'cancelled') then raise exception 'the parent asset is %', pa.status using errcode = '23514'; end if;
  end if;
  update assets set parent_asset_id = p_parent where id = a.id;
  perform asset_log(a.id, 'field', 'parent_asset_id', a.parent_asset_id::text, p_parent::text, null);
end $$;

create function asset_flag_resolve(p_flag uuid, p_status text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare f asset_duplicate_flags%rowtype;
begin
  select * into f from asset_duplicate_flags where id = p_flag;
  if not found or not can_view_asset(f.asset_id) or not can_view_asset(f.other_asset_id) then raise exception 'flag not found' using errcode = 'P0002'; end if;
  if not (can_edit_asset(f.asset_id) and can_edit_asset(f.other_asset_id)) then raise exception 'assets.update is required on both assets' using errcode = '42501'; end if;
  if p_status not in ('dismissed', 'confirmed_duplicate') then raise exception 'status must be dismissed or confirmed_duplicate' using errcode = '22023'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required' using errcode = '23514'; end if;
  if f.status <> 'open' then raise exception 'this flag has already been reviewed' using errcode = '23514'; end if;
  update asset_duplicate_flags set status = p_status, reviewed_by = current_staff_id(), review_note = p_note where id = f.id;
  perform asset_log(f.asset_id, 'flag', f.reason, 'open', p_status, p_note);
  perform asset_log(f.other_asset_id, 'flag', f.reason, 'open', p_status, p_note);
end $$;

-- Lifecycle moves that are not assignment, maintenance, retirement or disposal
create function asset_transition(p_asset uuid, p_to asset_status, p_note text default null) returns asset_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype;
begin
  a := asset_load(p_asset);
  if p_to = 'assigned' then raise exception 'use asset_assign to assign an asset' using errcode = '23514'; end if;
  if p_to = 'retired' then raise exception 'use asset_retire to retire an asset' using errcode = '23514'; end if;
  if p_to = 'disposed' then raise exception 'use asset_dispose to dispose of a retired asset' using errcode = '23514'; end if;
  if p_to = 'in_maintenance' then raise exception 'start maintenance to move an asset into maintenance' using errcode = '23514'; end if;
  if p_to = 'returned' then perform asset_unassign(p_asset, coalesce(p_note, 'returned')); return 'returned'; end if;
  if not has_permission('assets.update', a.division_id) then raise exception 'assets.update is required' using errcode = '42501'; end if;
  if p_to = 'cancelled' and coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if p_to = 'acquired' and a.acquisition_date is null then update assets set acquisition_date = current_date where id = a.id; end if;
  update assets set status = p_to where id = a.id;
  perform asset_log(a.id, 'status', 'status', a.status::text, p_to::text, p_note);
  return p_to;
end $$;

create function asset_assign(p_asset uuid, p_staff uuid default null, p_division uuid default null, p_note text default null, p_project uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; v_div uuid; v_id uuid; o asset_assignments%rowtype;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.assign', a.division_id) then raise exception 'assets.assign is required' using errcode = '42501'; end if;
  if a.status not in ('acquired', 'in_stock', 'returned', 'assigned') then raise exception 'an asset that is % cannot be assigned', a.status using errcode = '23514'; end if;
  if p_staff is not null and not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then
    raise exception 'the holder must be an active staff member' using errcode = '23514';
  end if;
  if p_staff is null and p_division is null then raise exception 'assign to a staff member, a division, or both' using errcode = '23514'; end if;
  v_div := coalesce(p_division, (select primary_division_id from staff where id = p_staff), a.division_id);
  if v_div <> a.division_id and not has_permission('assets.assign', v_div) then raise exception 'assets.assign is required in the receiving division' using errcode = '42501'; end if;
  if p_project is not null and (not can_view_project(p_project) or not exists (select 1 from projects where id = p_project and (a.client_id is null or client_id = a.client_id))) then
    raise exception 'project not found' using errcode = 'P0002';
  end if;
  select * into o from asset_assignments where asset_id = a.id and ended_at is null for update;
  if found then
    update asset_assignments set ended_at = now(), end_reason = 'reassigned' where id = o.id;
    perform asset_log(a.id, 'assignment', 'ended', o.staff_id::text, null, 'reassigned');
  end if;
  insert into asset_assignments (asset_id, staff_id, division_id, project_id, note) values (a.id, p_staff, v_div, p_project, p_note) returning id into v_id;
  perform asset_log(a.id, 'assignment', 'started', null, coalesce(p_staff::text, 'division ' || v_div::text), p_note);
  if v_div <> a.division_id then
    update assets set division_id = v_div where id = a.id;
    perform asset_log(a.id, 'field', 'division_id', a.division_id::text, v_div::text, 'responsibility moved with the assignment');
  end if;
  if a.status <> 'assigned' then
    update assets set status = 'assigned' where id = a.id;
    perform asset_log(a.id, 'status', 'status', a.status::text, 'assigned', p_note);
  end if;
  perform emit_event('asset.assigned', 'assets', a.id, a.ada_id, '{}');
  return v_id;
end $$;

create function asset_unassign(p_asset uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; o asset_assignments%rowtype;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.assign', a.division_id) then raise exception 'assets.assign is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into o from asset_assignments where asset_id = a.id and ended_at is null for update;
  if not found then raise exception 'the asset has no open assignment' using errcode = '23514'; end if;
  update asset_assignments set ended_at = now(), end_reason = p_reason where id = o.id;
  perform asset_log(a.id, 'assignment', 'ended', o.staff_id::text, null, p_reason);
  if a.status = 'assigned' then
    update assets set status = 'returned' where id = a.id;
    perform asset_log(a.id, 'status', 'status', 'assigned', 'returned', p_reason);
  end if;
end $$;

create function asset_retire(p_asset uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.retire', a.division_id) then raise exception 'assets.retire is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if a.status not in ('in_stock', 'returned', 'in_maintenance') then raise exception 'an asset that is % cannot be retired (return it to stock first)', a.status using errcode = '23514'; end if;
  if exists (select 1 from asset_assignments where asset_id = a.id and ended_at is null) then raise exception 'end the open assignment first' using errcode = '23514'; end if;
  if exists (select 1 from assets c where c.parent_asset_id = a.id and c.status not in ('retired', 'disposed', 'cancelled')) then
    raise exception 'retire or detach the components of this asset first' using errcode = '23514';
  end if;
  update assets set status = 'retired' where id = a.id;
  insert into asset_retirements (asset_id, reason, retired_by) values (a.id, p_reason, current_staff_id());
  perform asset_log(a.id, 'status', 'status', a.status::text, 'retired', p_reason);
  perform emit_event('asset.retired', 'assets', a.id, a.ada_id, '{}');
end $$;

create function asset_dispose(p_asset uuid, p_method asset_disposal_method, p_on date default null, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.dispose', a.division_id) then raise exception 'assets.dispose is required' using errcode = '42501'; end if;
  if a.status <> 'retired' then raise exception 'only a retired asset can be disposed of (currently %)', a.status using errcode = '23514'; end if;
  if coalesce(p_on, current_date) > current_date then raise exception 'the disposal date cannot be in the future' using errcode = '23514'; end if;
  update asset_retirements set disposal_method = p_method, disposed_on = coalesce(p_on, current_date), disposal_note = p_note, disposed_by = current_staff_id() where asset_id = a.id;
  update assets set status = 'disposed' where id = a.id;
  perform asset_log(a.id, 'status', 'status', 'retired', 'disposed', coalesce(p_note, p_method::text));
  perform emit_event('asset.disposed', 'assets', a.id, a.ada_id, '{}');
end $$;

create function asset_add_warranty(p_asset uuid, p_starts date, p_ends date, p_provider uuid default null, p_reference text default null, p_terms text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; v_id uuid;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.update', a.division_id) then raise exception 'assets.update is required' using errcode = '42501'; end if;
  if p_provider is not null and not exists (select 1 from suppliers where id = p_provider) then raise exception 'supplier not found' using errcode = 'P0002'; end if;
  insert into asset_warranties (asset_id, provider_id, reference, starts_on, ends_on, terms, created_by) values (a.id, p_provider, p_reference, p_starts, p_ends, p_terms, current_staff_id()) returning id into v_id;
  perform asset_log(a.id, 'field', 'warranty', null, p_ends::text, p_reference);
  return v_id;
end $$;

create function asset_void_warranty(p_warranty uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare w asset_warranties%rowtype;
begin
  select * into w from asset_warranties where id = p_warranty;
  if not found or not can_edit_asset(w.asset_id) then raise exception 'warranty not found' using errcode = 'P0002'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if w.voided_at is not null then raise exception 'already voided' using errcode = '23514'; end if;
  update asset_warranties set voided_at = now(), void_reason = p_reason where id = w.id;
end $$;

create function asset_add_document(p_asset uuid, p_kind text, p_title text, p_ref text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; v_id uuid;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.update', a.division_id) then raise exception 'assets.update is required' using errcode = '42501'; end if;
  insert into asset_documents (asset_id, kind, title, document_ref, added_by) values (a.id, p_kind, p_title, p_ref, current_staff_id()) returning id into v_id;
  return v_id;
end $$;

create function asset_void_document(p_document uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d asset_documents%rowtype;
begin
  select * into d from asset_documents where id = p_document;
  if not found or not can_edit_asset(d.asset_id) then raise exception 'document not found' using errcode = 'P0002'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if d.voided_at is not null then raise exception 'already voided' using errcode = '23514'; end if;
  update asset_documents set voided_at = now(), void_reason = p_reason where id = d.id;
end $$;

-- Link an asset to a sales invoice / payment of ITS client. Only ids are stored; Finance stays authoritative.
create function asset_link_finance(p_asset uuid, p_invoice uuid default null, p_payment uuid default null, p_relation text default 'billed_to_client', p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; v_id uuid;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.update', a.division_id) then raise exception 'assets.update is required' using errcode = '42501'; end if;
  if (p_invoice is null) = (p_payment is null) then raise exception 'link exactly one invoice or one payment' using errcode = '22023'; end if;
  if a.client_id is null then raise exception 'only an asset that belongs to a client can be linked to client invoices and payments' using errcode = '23514'; end if;
  if p_invoice is not null and (not can_view_invoice(p_invoice) or not exists (select 1 from invoices where id = p_invoice and client_id = a.client_id)) then
    raise exception 'invoice not found for this asset''s client' using errcode = 'P0002';
  end if;
  if p_payment is not null and (not can_view_payment(p_payment) or not exists (select 1 from payments where id = p_payment and client_id = a.client_id)) then
    raise exception 'payment not found for this asset''s client' using errcode = 'P0002';
  end if;
  insert into asset_finance_links (asset_id, invoice_id, payment_id, relation, note, linked_by) values (a.id, p_invoice, p_payment, p_relation, p_note, current_staff_id()) returning id into v_id;
  perform asset_log(a.id, 'link', case when p_invoice is not null then 'invoice' else 'payment' end, null, coalesce(p_invoice, p_payment)::text, p_relation);
  return v_id;
end $$;

-- The holder today, derived from the open assignment (invoker rights: RLS applies)
create view asset_current_assignments with (security_invoker = true) as
  select a.asset_id, a.id as assignment_id, a.staff_id, a.division_id, a.project_id, a.started_at, a.note
  from asset_assignments a where a.ended_at is null;
comment on view asset_current_assignments is 'Purpose: who holds each asset now. Derived from the single open assignment; nothing is stored on the asset.';

create view asset_warranty_status with (security_invoker = true) as
  select a.id as asset_id, exists (select 1 from asset_warranties w where w.asset_id = a.id and w.voided_at is null and current_date between w.starts_on and w.ends_on) as in_warranty,
         (select max(w.ends_on) from asset_warranties w where w.asset_id = a.id and w.voided_at is null) as warranty_ends_on
  from assets a;
comment on view asset_warranty_status is 'Purpose: derived warranty state. Nothing is stored.';

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table suppliers              enable row level security;
alter table asset_categories       enable row level security;
alter table assets                 enable row level security;
alter table asset_assignments      enable row level security;
alter table asset_history          enable row level security;
alter table asset_retirements      enable row level security;
alter table asset_warranties       enable row level security;
alter table asset_documents        enable row level security;
alter table asset_finance_links    enable row level security;
alter table asset_duplicate_flags  enable row level security;
revoke all on suppliers, asset_categories, assets, asset_assignments, asset_history, asset_retirements, asset_warranties, asset_documents,
  asset_finance_links, asset_duplicate_flags, asset_current_assignments, asset_warranty_status from anon, authenticated;
grant select on assets, asset_assignments, asset_history, asset_retirements, asset_warranties, asset_documents, asset_finance_links, asset_duplicate_flags,
  asset_current_assignments, asset_warranty_status, suppliers, asset_categories to authenticated;
grant insert, update on suppliers, asset_categories to authenticated;      -- no delete: deactivate

create policy suppliers_select on suppliers for select to authenticated using (has_permission_anywhere('suppliers.view') or has_permission_anywhere('assets.view'));
create policy suppliers_insert on suppliers for insert to authenticated with check (has_permission('suppliers.manage'));
create policy suppliers_update on suppliers for update to authenticated using (has_permission('suppliers.manage')) with check (has_permission('suppliers.manage'));
create policy asset_categories_select on asset_categories for select to authenticated using (has_permission_anywhere('assets.view') or has_permission_anywhere('assets.create'));
create policy asset_categories_insert on asset_categories for insert to authenticated with check (has_permission('assets.configure'));
create policy asset_categories_update on asset_categories for update to authenticated using (has_permission('assets.configure')) with check (has_permission('assets.configure'));
create policy assets_select on assets for select to authenticated using (can_view_asset_row(id, division_id, effective_classification, client_deleted));
create policy asset_assignments_select on asset_assignments for select to authenticated using (can_view_asset(asset_id));
create policy asset_history_select on asset_history for select to authenticated using (can_view_asset(asset_id));
create policy asset_retirements_select on asset_retirements for select to authenticated using (can_view_asset(asset_id));
create policy asset_warranties_select on asset_warranties for select to authenticated using (can_view_asset(asset_id));
create policy asset_documents_select on asset_documents for select to authenticated using (can_view_asset(asset_id));
create policy asset_finance_links_select on asset_finance_links for select to authenticated
  using (can_view_asset(asset_id) and ((invoice_id is not null and can_view_invoice(invoice_id)) or (payment_id is not null and can_view_payment(payment_id))));
create policy asset_duplicate_flags_select on asset_duplicate_flags for select to authenticated using (can_view_asset(asset_id) and can_view_asset(other_asset_id));

revoke execute on function can_view_asset_row(uuid, uuid, data_classification, boolean), can_view_asset(uuid), can_edit_asset(uuid, text), asset_log(uuid, text, text, text, text, text),
  asset_load(uuid), asset_detect_duplicates(uuid), asset_create(text, text, uuid, text, text, text, text, asset_condition, asset_status, asset_acquisition, date, numeric, text, uuid, uuid, uuid, uuid, text, data_classification),
  asset_update(uuid, jsonb), asset_set_parent(uuid, uuid), asset_flag_resolve(uuid, text, text), asset_transition(uuid, asset_status, text),
  asset_assign(uuid, uuid, uuid, text, uuid), asset_unassign(uuid, text), asset_retire(uuid, text), asset_dispose(uuid, asset_disposal_method, date, text),
  asset_add_warranty(uuid, date, date, uuid, text, text), asset_void_warranty(uuid, text), asset_add_document(uuid, text, text, text), asset_void_document(uuid, text),
  asset_link_finance(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function can_view_asset_row(uuid, uuid, data_classification, boolean), can_view_asset(uuid), can_edit_asset(uuid, text),
  asset_create(text, text, uuid, text, text, text, text, asset_condition, asset_status, asset_acquisition, date, numeric, text, uuid, uuid, uuid, uuid, text, data_classification),
  asset_update(uuid, jsonb), asset_set_parent(uuid, uuid), asset_flag_resolve(uuid, text, text), asset_transition(uuid, asset_status, text),
  asset_assign(uuid, uuid, uuid, text, uuid), asset_unassign(uuid, text), asset_retire(uuid, text), asset_dispose(uuid, asset_disposal_method, date, text),
  asset_add_warranty(uuid, date, date, uuid, text, text), asset_void_warranty(uuid, text), asset_add_document(uuid, text, text, text), asset_void_document(uuid, text),
  asset_link_finance(uuid, uuid, uuid, text, text) to authenticated;

do $$ begin
  perform attach_audit('suppliers');
  perform attach_audit('asset_categories');
  perform attach_audit('assets');
  perform attach_audit('asset_assignments');
  perform attach_audit('asset_retirements');
  perform attach_audit('asset_warranties');
  perform attach_audit('asset_documents');
  perform attach_audit('asset_finance_links');
  perform attach_audit('asset_duplicate_flags');
end $$;
