-- 0038_organization_unification: ONE organization record -> MANY organizational roles.
--
--   organizations  (sole source of truth for external-organization identity: name, legal / trading name, registration number, address, ...)
--        |-- clients    role / context table (client IDs, ADA-CLI aliases and every downstream foreign key are UNCHANGED)
--        |-- suppliers  role table
--        '-- partners   role table (new)
--
--  * An organization exists independently of any role. One company that is a client AND a supplier AND a partner is ONE organization row with
--    three role rows; the relationship never creates a second organization.
--  * clients.name / registration_number (and the other identity columns) and suppliers.name / registration_number / website are
--    trigger-maintained, readable MIRRORS. A direct write to a mirror is REDIRECTED into organizations (for every caller, the database
--    owner included); the organization stays authoritative and the roles are re-synchronised. Recursion is prevented with transaction-local
--    flags; a drift check proves no inconsistent state exists.
--  * Existing data is reconciled by organization_reconcile(): strong evidence (registration number, normalised name, website host) links
--    roles to ONE organization; anything ambiguous stays separate and goes to a human-review queue (organization_reviews). Nothing ambiguous
--    is ever merged automatically. A merge is a human decision (organization_merge) and leaves a tombstone, so every old ID stays valid.
--  * Hidden (restricted / confidential) organizations behave like hidden clients: never reused for a discoverable role, never named in
--    a message, exempt from the uniqueness rules, flagged silently for review.
--  * No hard cut, no compatibility view: the role tables, their IDs, aliases, triggers, policies and downstream references are untouched.

insert into permissions (key, module, action, description, sensitivity) values
  ('organizations.view', 'organizations', 'view', 'View organizations (the single identity record behind client, supplier and partner roles)', 'internal'::data_classification),
  ('organizations.create', 'organizations', 'create', 'Create organizations that have no client / supplier / partner role yet', 'internal'::data_classification),
  ('organizations.update', 'organizations', 'update', 'Edit organization identity (legal name, registration number, address)', 'internal'::data_classification),
  ('partners.view', 'partners', 'view', 'View partners', 'internal'::data_classification),
  ('partners.manage', 'partners', 'manage', 'Create and edit partners', 'internal'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'organizations.view'),
  ('administration_officer', 'organizations.view'),
  ('auditor', 'organizations.view'),
  ('ceo', 'organizations.create'),
  ('administration_officer', 'organizations.create'),
  ('ceo', 'organizations.update'),
  ('administration_officer', 'organizations.update'),
  ('ceo', 'partners.view'),
  ('administration_officer', 'partners.view'),
  ('finance_officer', 'partners.view'),
  ('division_lead', 'partners.view'),
  ('auditor', 'partners.view'),
  ('ceo', 'partners.manage'),
  ('administration_officer', 'partners.manage')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- Entity types: external organizations get their own permanent institutional ID; partners are now built
-- ---------------------------------------------------------------------------
insert into entity_types (key, prefix, family, is_built, domain_table, division_col, status_col, class_col, location_col, label_col, view_fn, description, id_code, publishable)
values ('external_organization', 'XOR', 'people_org', true, 'organizations', null, 'status', 'effective_classification', null, 'name', 'organization_360',
        'External organization (the one identity record behind client / supplier / partner roles)', 'XR', false);
insert into id_codebook (version, kind, code, meaning, family, note)
select 1, 'type', id_code, key, family, description from entity_types where key = 'external_organization';
update entity_types set is_built = true, domain_table = 'partners', status_col = 'status', label_col = 'name', description = 'Partner organization (a role of an organization)' where key = 'partner';

-- registration may carry how an entity came to be (migrated by reconciliation vs created)
create or replace function register_entity_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t entity_types; j jsonb := to_jsonb(new); a record; v_year integer := extract(year from (now() at time zone 'Africa/Windhoek'))::integer; v_inst text;
begin
  select * into t from entity_types where key = tg_argv[0];
  select * into a from registry_attrs(t, j);
  v_inst := ada_mint_id(t.key, v_year);
  insert into entity_registry (institutional_id, ada_id, entity_type, entity_id, table_name, entity_family, origin_division_id, origin_year, origin_cycle, origin_kind,
                               classification, authorization_scope, current_division_id, current_location, status, created_by)
  values (v_inst, j ->> 'ada_id', t.key, new.id, tg_table_name, t.family, a.division_id, v_year,
          (select code from id_codebook where version = (select codebook_version from id_settings) and kind = 'cycle' and meaning = v_year::text),
          coalesce(nullif(current_setting('ada.origin_kind', true), ''), nullif(tg_argv[1], ''), 'created'), a.classification, a.scope, a.division_id, a.location, a.status, current_staff_id());
  insert into entity_location_history (institutional_id, to_division_id, to_location, reason, changed_by) values (v_inst, a.division_id, a.location, 'registered', current_staff_id());
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- The organization record
-- ---------------------------------------------------------------------------
create table organizations (
  id                       uuid primary key default gen_random_uuid(),
  name                     text not null check (btrim(name) <> ''),
  legal_name               text,
  trading_name             text,
  registration_number      text,
  website                  text,
  email                    text,
  phone                    text,
  address                  text,
  city                     text,
  country                  text not null default 'Namibia',
  industry                 text,
  social_links             jsonb not null default '{}' check (jsonb_typeof(social_links) = 'object'),
  name_key                 text generated always as (client_name_key(name)) stored,
  classification           data_classification not null default 'internal',
  effective_classification data_classification not null default 'internal',
  status                   text not null default 'active' check (status in ('active', 'dormant', 'merged')),
  uniqueness_exempt        boolean not null default false,
  merged_into_id           uuid references organizations (id),
  merged_at                timestamptz,
  merged_by                uuid references staff (id),
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (name_key <> ''),
  check ((status = 'merged') = (merged_into_id is not null)),
  check (merged_into_id is distinct from id)
);
comment on table organizations is 'Purpose: the SOLE source of truth for the identity of an external organization (legal / trading / display name, registration number, address, contact points). Clients, suppliers and partners are ROLES of an organization and carry read-only mirrors of these columns. An organization exists independently of its roles. [class: internal; the effective classification is the strictest of its own floor and its live client roles]';
comment on column organizations.name is 'How ADA refers to the organization. Uniqueness is on a normalised key (case, punctuation and legal suffixes ignored) among active, discoverable organizations.';
comment on column organizations.effective_classification is 'Derived: the greater of the organization''s own classification and that of its live client roles. Visibility reads this column.';
comment on column organizations.uniqueness_exempt is 'True for an organization created while an ambiguous or hidden look-alike exists (or confirmed distinct by a human): it is excluded from the name / registration uniqueness indexes. Set by the system only.';
comment on column organizations.status is 'active = has a live role (or none yet); dormant = every role has ended; merged = absorbed by merged_into_id (a tombstone: the ID still resolves).';
create unique index organizations_name_key_unique on organizations (name_key)
  where status = 'active' and effective_classification in ('public', 'internal') and not uniqueness_exempt;
create unique index organizations_registration_unique on organizations (lower(btrim(registration_number)))
  where registration_number is not null and btrim(registration_number) <> '' and status = 'active' and effective_classification in ('public', 'internal') and not uniqueness_exempt;
create index organizations_name_key_idx on organizations (name_key);
create index organizations_name_key_trgm on organizations using gin (name_key extensions.gin_trgm_ops);
create index organizations_registration_idx on organizations (lower(btrim(registration_number))) where registration_number is not null;
create trigger organizations_updated before update on organizations for each row execute function set_updated_at();

-- Which role-table columns mirror which organization columns (one place; the guards and the drift check read it)
create table organization_mirror_columns (
  role_table  text not null,
  column_name text not null,
  primary key (role_table, column_name)
);
comment on table organization_mirror_columns is 'Purpose: the role-table columns that are read-only mirrors of organizations.<same name>. Configuration of the sync / guard triggers. No API access. [class: internal]';
insert into organization_mirror_columns (role_table, column_name)
select 'clients', c from unnest(array['name', 'legal_name', 'trading_name', 'registration_number', 'website', 'email', 'phone', 'address', 'city', 'country', 'industry', 'social_links']) c
union all select 'suppliers', c from unnest(array['name', 'registration_number', 'website']) c
union all select 'partners', 'name';

-- Partner: the third role
create table partners (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations (id) on delete restrict,
  name            text not null check (btrim(name) <> ''),
  kind            text not null default 'other' check (kind in ('technology', 'reseller', 'referral', 'sponsor', 'academic', 'other')),
  status          text not null default 'prospect' check (status in ('prospect', 'active', 'inactive', 'ended')),
  since           date,
  notes           text,
  created_by      uuid references staff (id) default current_staff_id(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index partners_one_per_organization on partners (organization_id);
comment on table partners is 'Purpose: the PARTNER role of an organization (technology partner, reseller, referrer, sponsor, academic partner). The organization''s identity lives in organizations; name here is a read-only mirror. A partner may also be a client and a supplier. Registered through attach_entity (permanent institutional ID). [class: internal]';
comment on column partners.name is 'Read-only mirror of organizations.name (writes are redirected to the organization).';
create trigger partners_updated before update on partners for each row execute function set_updated_at();

-- The role columns that link a role to its organization (NULL only while a legacy row awaits reconciliation)
alter table clients   add column organization_id uuid references organizations (id) on delete restrict;
alter table suppliers add column organization_id uuid references organizations (id) on delete restrict;
create index clients_organization_idx on clients (organization_id);
create index suppliers_organization_idx on suppliers (organization_id);
comment on column clients.organization_id is 'The organization this client record is a role of (its identity lives there; the identity columns on this table are read-only mirrors).';
comment on column suppliers.organization_id is 'The organization this supplier record is a role of (its identity lives there; name, registration_number and website here are read-only mirrors).';
do $$ begin perform attach_entity('organizations', 'external_organization'); perform attach_entity('partners', 'partner'); end $$;

-- ---------------------------------------------------------------------------
-- Human-review queue and confirmed-distinct pairs
-- ---------------------------------------------------------------------------
create table organization_reviews (
  id              uuid primary key default gen_random_uuid(),
  left_org_id     uuid not null references organizations (id),
  right_org_id    uuid not null references organizations (id),
  reason          text not null,
  score           real,
  origin          text not null default 'runtime' check (origin in ('migration', 'runtime')),
  status          text not null default 'open' check (status in ('open', 'resolved_same', 'resolved_distinct', 'dismissed')),
  created_at      timestamptz not null default now(),
  resolved_by     uuid references staff (id),
  resolved_at     timestamptz,
  resolution_note text,
  check (left_org_id <> right_org_id)
);
create unique index organization_reviews_open_pair on organization_reviews (least(left_org_id, right_org_id), greatest(left_org_id, right_org_id)) where status = 'open';
comment on table organization_reviews is 'Purpose: possible duplicate organizations that the system will NOT merge by itself (ambiguous evidence, or a hidden record involved). Only matching.review holders see it, so the existence of a hidden organization is never disclosed to whoever triggered the match. [class: restricted]';
create table organization_distinct_pairs (
  org_a      uuid not null references organizations (id),
  org_b      uuid not null references organizations (id),
  reason     text not null,
  decided_by uuid references staff (id),
  decided_at timestamptz not null default now(),
  primary key (org_a, org_b),
  check (org_a < org_b)
);
comment on table organization_distinct_pairs is 'Purpose: pairs of organizations a human confirmed are different legal entities, so they are not flagged again. [class: restricted]';

-- ---------------------------------------------------------------------------
-- Matching (internal; sees everything, the callers decide what to tell)
-- ---------------------------------------------------------------------------
create function org_host(p_url text) returns text language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(lower(btrim(coalesce(p_url, ''))), '^[a-z]+://', ''), '^www\.|[/?#:].*$', '', 'g'), '')
$$;

-- strength: 'strong' = the same organization on the evidence; 'ambiguous' = could be, a human must decide.
create function org_match(p_name text, p_reg text, p_website text, p_role text, p_exclude uuid default null, p_discoverable_only boolean default false)
returns table (org_id uuid, strength text, reason text, score real)
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare o record; k text := client_name_key(p_name); r text := nullif(lower(btrim(coalesce(p_reg, ''))), ''); h text := org_host(p_website);
        v_ro text; v_name_eq boolean; v_sim real; v_reg_eq boolean; v_reg_conf boolean; v_host_eq boolean; v_role_conf boolean; v_strong boolean; v_amb boolean; v_reason text;
begin
  for o in select * from organizations x where x.status <> 'merged' and x.id is distinct from p_exclude
                 and (not p_discoverable_only or (x.effective_classification in ('public', 'internal') and not x.uniqueness_exempt)) loop
    v_ro := nullif(lower(btrim(coalesce(o.registration_number, ''))), '');
    v_name_eq := k <> '' and o.name_key = k;
    v_sim := case when k <> '' then similarity(o.name_key, k) else 0 end;
    v_reg_eq := r is not null and v_ro is not null and r = v_ro;
    v_reg_conf := r is not null and v_ro is not null and r <> v_ro;
    v_host_eq := h is not null and org_host(o.website) = h;
    v_role_conf := case p_role when 'client' then exists (select 1 from clients c where c.organization_id = o.id and c.deleted_at is null)
                               when 'supplier' then exists (select 1 from suppliers s where s.organization_id = o.id)
                               when 'partner' then exists (select 1 from partners p where p.organization_id = o.id) else false end;
    v_strong := not v_reg_conf and ((v_reg_eq and (v_name_eq or v_sim >= 0.5)) or v_name_eq or (v_host_eq and v_sim >= 0.4));
    v_amb := v_reg_eq or v_host_eq or v_sim >= 0.55 or (v_name_eq and v_reg_conf);
    if v_strong and not v_role_conf then
      org_id := o.id; strength := 'strong'; score := case when v_reg_eq then 1.0 else greatest(v_sim, 0.9) end::real;
      reason := case when v_reg_eq then 'registration_number' when v_name_eq then 'exact_name' else 'website_and_similar_name' end; return next;
    elsif v_strong or v_amb then
      v_reason := case when v_strong and v_role_conf then 'same_organization_already_holds_this_role' when v_name_eq and v_reg_conf then 'same_name_different_registration'
                       when v_reg_eq then 'same_registration_dissimilar_name' when v_host_eq then 'same_website' else 'similar_name' end;
      org_id := o.id; strength := 'ambiguous'; reason := v_reason; score := greatest(v_sim, case when v_reg_eq then 0.9 else 0 end)::real; return next;
    end if;
  end loop;
end $$;
revoke execute on function org_match(text, text, text, text, uuid, boolean) from public, anon, authenticated;

create function org_identity_json(p_org organizations, p_cols text[]) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(c, to_jsonb(p_org) -> c), '{}'::jsonb) from unnest(p_cols) c
$$;
create function org_mirror_cols(p_table text) returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(column_name order by column_name), '{}') from organization_mirror_columns where role_table = p_table
$$;
revoke execute on function org_identity_json(organizations, text[]), org_mirror_cols(text), org_host(text) from public, anon, authenticated;

-- What an organization's effective classification and status are, from its own floor and its roles
create function org_roles_max_class(p_org uuid) returns data_classification
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(max(c.classification), 'public') from clients c where c.organization_id = p_org and c.deleted_at is null
$$;
create function org_derived_status(p_org uuid, p_current text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_current = 'merged' then 'merged'
              when exists (select 1 from clients c where c.organization_id = p_org and c.deleted_at is null)
                or exists (select 1 from suppliers s where s.organization_id = p_org and s.status = 'active')
                or exists (select 1 from partners p where p.organization_id = p_org and p.status in ('prospect', 'active')) then 'active'
              when exists (select 1 from clients c where c.organization_id = p_org) or exists (select 1 from suppliers s where s.organization_id = p_org)
                or exists (select 1 from partners p where p.organization_id = p_org) then 'dormant'
              else p_current end
$$;
revoke execute on function org_roles_max_class(uuid), org_derived_status(uuid, text) from public, anon, authenticated;

create function organizations_compute() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_hint text := nullif(current_setting('ada.org_class_hint', true), '');
begin
  if tg_op = 'DELETE' then raise exception 'organizations are never deleted: they go dormant or are merged, and their IDs stay valid' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, current_staff_id());
    new.effective_classification := greatest(new.classification, coalesce(v_hint::data_classification, 'public'));
    return new;
  end if;
  -- identity of the record is permanent
  if new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then raise exception 'an organization''s creation facts are permanent' using errcode = '42501'; end if;
  if old.status = 'merged' and (to_jsonb(new) - array['updated_at', 'effective_classification']) is distinct from (to_jsonb(old) - array['updated_at', 'effective_classification']) then
    raise exception 'a merged organization is a tombstone and cannot change' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and new.status = 'merged' and coalesce(current_setting('ada.org_merge', true), '') <> 'on' then
    raise exception 'an organization is merged only through organization_merge' using errcode = '42501';
  end if;
  if new.uniqueness_exempt is distinct from old.uniqueness_exempt and coalesce(current_setting('ada.org_exempt', true), '') <> 'on' then
    raise exception 'the uniqueness exemption is set by the system only' using errcode = '42501';
  end if;
  if new.status <> 'merged' then
    new.effective_classification := greatest(new.classification, org_roles_max_class(new.id));
    new.status := org_derived_status(new.id, new.status);
  end if;
  return new;
end $$;
create trigger organizations_compute_trg before insert or update or delete on organizations for each row execute function organizations_compute();

-- Org -> roles: one authoritative change, every role mirror follows (the role currently being redirected is skipped; its BEFORE trigger sets its own row)
create function organization_resync(p_org uuid, p_skip uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o organizations%rowtype;
begin
  select * into o from organizations where id = p_org;
  if not found then return; end if;
  perform set_config('ada.org_sync', 'on', true);
  update clients c set name = o.name, legal_name = o.legal_name, trading_name = o.trading_name, registration_number = o.registration_number, website = o.website,
         email = o.email, phone = o.phone, address = o.address, city = o.city, country = o.country, industry = o.industry, social_links = o.social_links
   where c.organization_id = o.id and c.id is distinct from p_skip
     and (c.name, c.legal_name, c.trading_name, c.registration_number, c.website, c.email, c.phone, c.address, c.city, c.country, c.industry, c.social_links)
         is distinct from (o.name, o.legal_name, o.trading_name, o.registration_number, o.website, o.email, o.phone, o.address, o.city, o.country, o.industry, o.social_links);
  update suppliers s set name = o.name, registration_number = o.registration_number, website = o.website
   where s.organization_id = o.id and s.id is distinct from p_skip and (s.name, s.registration_number, s.website) is distinct from (o.name, o.registration_number, o.website);
  update partners p set name = o.name where p.organization_id = o.id and p.id is distinct from p_skip and p.name is distinct from o.name;
  perform set_config('ada.org_sync', 'off', true);
end $$;
revoke execute on function organization_resync(uuid, uuid) from public, anon, authenticated;

create function organizations_sync_roles() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform organization_resync(new.id, nullif(current_setting('ada.org_skip', true), '')::uuid);
  return null;
end $$;
create trigger organizations_sync_roles_trg after update of name, legal_name, trading_name, registration_number, website, email, phone, address, city, country, industry, social_links
  on organizations for each row execute function organizations_sync_roles();

-- An organization's own classification is a floor for its client roles (it can raise them; it never lowers them)
create function organizations_push_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update clients set classification = new.classification where organization_id = new.id and deleted_at is null and classification < new.classification;
  return null;
end $$;
create trigger organizations_push_classification_trg after update of classification on organizations
  for each row when (new.classification > old.classification) execute function organizations_push_classification();

-- Flag every look-alike the evidence does not settle for a human (silently: the person who caused the collision is told nothing about hidden records).
-- A creator who declared the new organization distinct from the look-alikes it was shown has already made that decision.
create function organizations_flag_hidden_duplicates() returns trigger
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r record; v_new_hidden boolean := new.effective_classification not in ('public', 'internal');
begin
  if new.status = 'merged' then return null; end if;
  for r in select m.*, (select (x.effective_classification not in ('public', 'internal')) from organizations x where x.id = m.org_id) as cand_hidden
             from org_match(new.name, new.registration_number, new.website, null, new.id, false) m loop
    if (v_new_hidden or r.cand_hidden or coalesce(current_setting('ada.org_distinct_declared', true), '') <> 'on')
       and not exists (select 1 from organization_distinct_pairs where org_a = least(new.id, r.org_id) and org_b = greatest(new.id, r.org_id)) then
      insert into organization_reviews (left_org_id, right_org_id, reason, score, origin)
      values (new.id, r.org_id, r.reason, r.score, case when current_setting('ada.origin_kind', true) = 'migrated' then 'migration' else 'runtime' end) on conflict do nothing;
    end if;
  end loop;
  return null;
end $$;
create trigger organizations_flag_hidden_duplicates_trg after insert or update of name, registration_number, website, classification on organizations
  for each row execute function organizations_flag_hidden_duplicates();

-- Roles -> organization: status and classification follow the live roles
create function org_roles_changed() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.organization_id is not null then update organizations set classification = classification where id = old.organization_id; end if;
  if tg_op in ('INSERT', 'UPDATE') and new.organization_id is not null and (tg_op = 'INSERT' or new.organization_id is distinct from old.organization_id) then
    update organizations set classification = classification where id = new.organization_id;
  end if;
  return null;
end $$;
create trigger clients_org_roles_trg after insert or update of classification, deleted_at, organization_id on clients for each row execute function org_roles_changed();
create trigger suppliers_org_roles_trg after insert or update of status, organization_id on suppliers for each row execute function org_roles_changed();
create trigger partners_org_roles_trg after insert or update of status, organization_id on partners for each row execute function org_roles_changed();

-- ---------------------------------------------------------------------------
-- Attaching a role to an organization (find-or-create) and keeping its mirrors honest
-- ---------------------------------------------------------------------------
-- Reuse happens only when BOTH sides are discoverable and exactly one organization matches strongly; a hidden record is never reused and
-- never named. Advisory locks on the name and registration keys make two simultaneous creations meet the same organization.
create function org_attach(p_role text, p_row jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare k text := client_name_key(p_row ->> 'name'); reg text := nullif(lower(btrim(coalesce(p_row ->> 'registration_number', ''))), ''); v_class data_classification;
        v_n integer; v_id uuid;
begin
  if k = '' then raise exception 'the name needs a distinguishing word' using errcode = '23514'; end if;
  perform pg_advisory_xact_lock(hashtext('org:' || k));
  if reg is not null then perform pg_advisory_xact_lock(hashtext('orgreg:' || reg)); end if;
  v_class := coalesce(nullif(p_row ->> 'classification', '')::data_classification, 'internal');
  if v_class in ('public', 'internal') then
    select count(*), (array_agg(m.org_id))[1] into v_n, v_id
      from org_match(p_row ->> 'name', p_row ->> 'registration_number', p_row ->> 'website', p_role, null, true) m where m.strength = 'strong';
    if v_n = 1 then
      update organizations set legal_name = coalesce(legal_name, nullif(btrim(p_row ->> 'legal_name'), '')), trading_name = coalesce(trading_name, nullif(btrim(p_row ->> 'trading_name'), '')),
             registration_number = coalesce(registration_number, nullif(btrim(p_row ->> 'registration_number'), '')), website = coalesce(website, nullif(btrim(p_row ->> 'website'), '')),
             email = coalesce(email, nullif(btrim(p_row ->> 'email'), '')), phone = coalesce(phone, nullif(btrim(p_row ->> 'phone'), '')), address = coalesce(address, nullif(btrim(p_row ->> 'address'), '')),
             city = coalesce(city, nullif(btrim(p_row ->> 'city'), '')), industry = coalesce(industry, nullif(btrim(p_row ->> 'industry'), ''))
       where id = v_id;
      return v_id;
    end if;
  end if;
  perform set_config('ada.org_class_hint', v_class::text, true);
  insert into organizations (name, legal_name, trading_name, registration_number, website, email, phone, address, city, country, industry, social_links)
  values (btrim(p_row ->> 'name'), nullif(btrim(p_row ->> 'legal_name'), ''), nullif(btrim(p_row ->> 'trading_name'), ''), nullif(btrim(p_row ->> 'registration_number'), ''), nullif(btrim(p_row ->> 'website'), ''),
          nullif(btrim(p_row ->> 'email'), ''), nullif(btrim(p_row ->> 'phone'), ''), nullif(btrim(p_row ->> 'address'), ''), nullif(btrim(p_row ->> 'city'), ''),
          coalesce(nullif(btrim(p_row ->> 'country'), ''), 'Namibia'), nullif(btrim(p_row ->> 'industry'), ''), coalesce(p_row -> 'social_links', '{}'::jsonb))
  returning id into v_id;
  perform set_config('ada.org_class_hint', '', true);
  return v_id;
end $$;
revoke execute on function org_attach(text, jsonb) from public, anon, authenticated;

create function org_role_before_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare o organizations%rowtype;
begin
  if new.organization_id is null then new.organization_id := org_attach(tg_argv[0], to_jsonb(new)); end if;
  select * into o from organizations where id = new.organization_id;
  if not found then raise exception 'organization not found' using errcode = 'P0002'; end if;
  if o.status = 'merged' then raise exception 'that organization was merged into another; use the surviving organization' using errcode = '23514'; end if;
  new := jsonb_populate_record(new, org_identity_json(o, org_mirror_cols(tg_table_name)));
  return new;
end $$;

-- The single door through which identity changes reach the organization
create function organization_apply(p_org uuid, p_patch jsonb, p_skip_role uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('ada.org_skip', coalesce(p_skip_role::text, ''), true);
  update organizations o set
    name                = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else o.name end,
    legal_name          = case when p_patch ? 'legal_name' then nullif(btrim(p_patch ->> 'legal_name'), '') else o.legal_name end,
    trading_name        = case when p_patch ? 'trading_name' then nullif(btrim(p_patch ->> 'trading_name'), '') else o.trading_name end,
    registration_number = case when p_patch ? 'registration_number' then nullif(btrim(p_patch ->> 'registration_number'), '') else o.registration_number end,
    website             = case when p_patch ? 'website' then nullif(btrim(p_patch ->> 'website'), '') else o.website end,
    email               = case when p_patch ? 'email' then nullif(btrim(p_patch ->> 'email'), '') else o.email end,
    phone               = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else o.phone end,
    address             = case when p_patch ? 'address' then nullif(btrim(p_patch ->> 'address'), '') else o.address end,
    city                = case when p_patch ? 'city' then nullif(btrim(p_patch ->> 'city'), '') else o.city end,
    country             = case when p_patch ? 'country' then btrim(p_patch ->> 'country') else o.country end,
    industry            = case when p_patch ? 'industry' then nullif(btrim(p_patch ->> 'industry'), '') else o.industry end,
    social_links        = case when p_patch ? 'social_links' then p_patch -> 'social_links' else o.social_links end
   where o.id = p_org;
  perform set_config('ada.org_skip', '', true);
  if not found then raise exception 'organization not found' using errcode = 'P0002'; end if;
end $$;
revoke execute on function organization_apply(uuid, jsonb, uuid) from public, anon, authenticated;

-- A direct write to a mirror column is not a write to the role: it is redirected to the organization, and the row then carries the organization's values
create function org_role_before_update() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare cols text[] := org_mirror_cols(tg_table_name); j_new jsonb := to_jsonb(new); j_old jsonb := to_jsonb(old); patch jsonb := '{}'; c text; o organizations%rowtype;
begin
  if coalesce(current_setting('ada.org_sync', true), '') = 'on' then return new; end if;        -- the organization is writing its own mirror
  if new.organization_id is distinct from old.organization_id then
    if coalesce(current_setting('ada.org_relink', true), '') <> 'on' then
      raise exception 'a role''s organization changes only through organization_merge' using errcode = '42501';
    end if;
    return new;
  end if;
  foreach c in array cols loop
    if j_new -> c is distinct from j_old -> c then patch := patch || jsonb_build_object(c, j_new -> c); end if;
  end loop;
  if patch <> '{}'::jsonb then perform organization_apply(new.organization_id, patch, new.id); end if;
  select * into o from organizations where id = new.organization_id;
  new := jsonb_populate_record(new, org_identity_json(o, cols));
  return new;
end $$;

create trigger clients_org_attach_trg before insert on clients for each row execute function org_role_before_insert('client');
create trigger clients_org_mirror_guard_trg before update on clients for each row execute function org_role_before_update();
create trigger suppliers_0_org_attach_trg before insert on suppliers for each row execute function org_role_before_insert('supplier');
create trigger suppliers_0_org_mirror_guard_trg before update on suppliers for each row execute function org_role_before_update();
create trigger partners_org_attach_trg before insert on partners for each row execute function org_role_before_insert('partner');
create trigger partners_org_mirror_guard_trg before update on partners for each row execute function org_role_before_update();

-- ---------------------------------------------------------------------------
-- Reconciliation of existing data (idempotent; also the tool tests and operations use)
-- ---------------------------------------------------------------------------
-- Strong evidence links a role to ONE organization. Anything ambiguous becomes a SEPARATE organization plus a review item. Never merges.
create function organization_reconcile() returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r record; m record; v_org uuid; v_strong uuid[]; n_linked integer := 0; n_created integer := 0; v_reviews_before integer := (select count(*) from organization_reviews);
begin
  perform set_config('ada.org_relink', 'on', true);
  perform set_config('ada.origin_kind', 'migrated', true);
  perform set_config('ada.org_exempt', 'on', true);
  for r in (select 'client' as role, c.id, to_jsonb(c) as j, c.created_at, c.created_by from clients c where c.organization_id is null
            union all
            select 'supplier', s.id, to_jsonb(s), s.created_at, s.created_by from suppliers s where s.organization_id is null) order by 1, 4, 2 loop
    v_strong := '{}';
    for m in select * from org_match(r.j ->> 'name', r.j ->> 'registration_number', r.j ->> 'website', case when r.role = 'client' and r.j ->> 'deleted_at' is not null then null else r.role end, null, false) loop
      if m.strength = 'strong' then v_strong := v_strong || m.org_id; end if;
    end loop;
    if cardinality(v_strong) = 1 then
      v_org := v_strong[1];
      update organizations set legal_name = coalesce(legal_name, nullif(btrim(r.j ->> 'legal_name'), '')), trading_name = coalesce(trading_name, nullif(btrim(r.j ->> 'trading_name'), '')),
             registration_number = coalesce(registration_number, nullif(btrim(r.j ->> 'registration_number'), '')), website = coalesce(website, nullif(btrim(r.j ->> 'website'), '')),
             email = coalesce(email, nullif(btrim(r.j ->> 'email'), '')), phone = coalesce(phone, nullif(btrim(r.j ->> 'phone'), '')), address = coalesce(address, nullif(btrim(r.j ->> 'address'), '')),
             city = coalesce(city, nullif(btrim(r.j ->> 'city'), '')), industry = coalesce(industry, nullif(btrim(r.j ->> 'industry'), ''))
       where id = v_org;
      n_linked := n_linked + 1;
    else
      perform set_config('ada.org_class_hint', coalesce(r.j ->> 'classification', 'internal'), true);
      begin
        insert into organizations (name, legal_name, trading_name, registration_number, website, email, phone, address, city, country, industry, social_links, created_at, created_by)
        values (btrim(r.j ->> 'name'), nullif(btrim(r.j ->> 'legal_name'), ''), nullif(btrim(r.j ->> 'trading_name'), ''), nullif(btrim(r.j ->> 'registration_number'), ''), nullif(btrim(r.j ->> 'website'), ''),
                nullif(btrim(r.j ->> 'email'), ''), nullif(btrim(r.j ->> 'phone'), ''), nullif(btrim(r.j ->> 'address'), ''), nullif(btrim(r.j ->> 'city'), ''),
                coalesce(nullif(btrim(r.j ->> 'country'), ''), 'Namibia'), nullif(btrim(r.j ->> 'industry'), ''), coalesce(r.j -> 'social_links', '{}'::jsonb), r.created_at, r.created_by)
        returning id into v_org;
      exception when unique_violation then
        insert into organizations (name, legal_name, trading_name, registration_number, website, email, phone, address, city, country, industry, social_links, created_at, created_by, uniqueness_exempt)
        values (btrim(r.j ->> 'name'), nullif(btrim(r.j ->> 'legal_name'), ''), nullif(btrim(r.j ->> 'trading_name'), ''), nullif(btrim(r.j ->> 'registration_number'), ''), nullif(btrim(r.j ->> 'website'), ''),
                nullif(btrim(r.j ->> 'email'), ''), nullif(btrim(r.j ->> 'phone'), ''), nullif(btrim(r.j ->> 'address'), ''), nullif(btrim(r.j ->> 'city'), ''),
                coalesce(nullif(btrim(r.j ->> 'country'), ''), 'Namibia'), nullif(btrim(r.j ->> 'industry'), ''), coalesce(r.j -> 'social_links', '{}'::jsonb), r.created_at, r.created_by, true)
        returning id into v_org;
      end;
      perform set_config('ada.org_class_hint', '', true);
      n_created := n_created + 1;
    end if;
    -- Ambiguous candidates (and any additional strong one) are queued for a human by organizations_flag_hidden_duplicates_trg, which fires
    -- whenever an organization is created or its identity changes (including the fill-in above).
    if r.role = 'client' then update clients set organization_id = v_org where id = r.id; else update suppliers set organization_id = v_org where id = r.id; end if;
    perform organization_resync(v_org);
  end loop;
  perform set_config('ada.org_relink', 'off', true);
  perform set_config('ada.origin_kind', '', true);
  perform set_config('ada.org_exempt', 'off', true);
  return jsonb_build_object('linked_to_existing', n_linked, 'organizations_created', n_created, 'review_items_opened', (select count(*) from organization_reviews) - v_reviews_before);
end $$;
revoke execute on function organization_reconcile() from public, anon, authenticated;
grant execute on function organization_reconcile() to service_role;

-- Run it on the data that exists now. The updated_at bump of the re-linked rows is not a business change, so it is suppressed.
alter table clients disable trigger clients_updated;
alter table suppliers disable trigger suppliers_updated;
select organization_reconcile();
alter table clients enable trigger clients_updated;
alter table suppliers enable trigger suppliers_updated;

alter table clients alter column organization_id set not null;
alter table suppliers alter column organization_id set not null;
create unique index clients_one_live_per_organization on clients (organization_id) where deleted_at is null;
create unique index suppliers_one_per_organization on suppliers (organization_id);

-- ---------------------------------------------------------------------------
-- Visibility. A role's own rules still decide who sees the role; the organization is visible to those who may see one of its roles
-- (a restricted client's organization stays hidden from everyone but its authorised people and the cleared organization-wide viewers).
-- ---------------------------------------------------------------------------
create function can_view_organization_row(p_id uuid, p_class data_classification) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
       (has_permission('organizations.view') and classification_visible(p_class))
    or exists (select 1 from clients c where c.organization_id = p_id and can_view_client_row(c.id, c.owner_division_id, c.classification, c.deleted_at))
    or (classification_visible(p_class)
        and (((has_permission_anywhere('suppliers.view') or has_permission_anywhere('assets.view')) and exists (select 1 from suppliers s where s.organization_id = p_id))
          or (has_permission_anywhere('partners.view') and exists (select 1 from partners p where p.organization_id = p_id)))), false)
$$;
create function can_view_organization(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_organization_row(o.id, o.effective_classification) from organizations o where o.id = p_id), false)
$$;
create function partner_visible(p_org uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(has_permission_anywhere('partners.view') and exists (select 1 from organizations o where o.id = p_org and classification_visible(o.effective_classification)), false)
$$;
create function organization_require(p_org uuid) returns organizations
language plpgsql security definer set search_path = public, pg_temp as $$
declare o organizations%rowtype;
begin
  select * into o from organizations where id = p_org for update;
  if not found or not can_view_organization_row(o.id, o.effective_classification) then raise exception 'organization not found' using errcode = 'P0002'; end if;
  return o;
end $$;
create function organization_note_denied(p_org uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform security_note_lookup(coalesce((select institutional_id from entity_registry where table_name = 'organizations' and entity_id = p_org), p_org::text), 'organization.view');
end $$;
revoke execute on function organization_require(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
create function organization_create(p_name text, p_legal_name text default null, p_registration text default null, p_website text default null,
                                    p_email text default null, p_phone text default null, p_distinct_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_reg text := nullif(btrim(coalesce(p_registration, '')), ''); m record; v_exact record; v_similar jsonb; v_id uuid; v_inst text;
begin
  if not has_permission('organizations.create') then raise exception 'organizations.create is required' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then raise exception 'a valid name is required' using errcode = '22023'; end if;
  if client_name_key(p_name) = '' then raise exception 'the name needs a distinguishing word' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('org:' || client_name_key(p_name)));
  select m2.* into v_exact from org_match(p_name, v_reg, p_website, null, null, true) m2 where m2.strength = 'strong' order by m2.score desc limit 1;
  if found then
    return jsonb_build_object('status', 'exists', 'organization', (select institutional_id from entity_registry where table_name = 'organizations' and entity_id = v_exact.org_id),
                              'name', (select name from organizations where id = v_exact.org_id), 'next', 'organization_add_role');
  end if;
  if exists (select 1 from org_match(p_name, v_reg, p_website, null, null, true) m2 where m2.reason = 'same_name_different_registration') then
    return jsonb_build_object('status', 'name_conflict', 'next', 'a different legal entity already uses this name; choose a distinguishing name (for example add the town or trading name)');
  end if;
  select jsonb_agg(jsonb_build_object('organization', (select institutional_id from entity_registry where table_name = 'organizations' and entity_id = m2.org_id),
                                      'name', (select name from organizations where id = m2.org_id), 'reason', m2.reason, 'similarity', round(m2.score::numeric, 2)) order by m2.score desc)
    into v_similar from org_match(p_name, v_reg, p_website, null, null, true) m2 where m2.strength = 'ambiguous';
  if v_similar is not null and coalesce(btrim(p_distinct_reason), '') = '' then
    return jsonb_build_object('status', 'similar', 'candidates', v_similar, 'next', 'use an existing organization, or repeat with p_distinct_reason explaining why this is a different legal entity');
  end if;
  if v_similar is not null then perform set_config('ada.org_distinct_declared', 'on', true); end if;
  insert into organizations (name, legal_name, registration_number, website, email, phone)
  values (btrim(p_name), nullif(btrim(coalesce(p_legal_name, '')), ''), v_reg, nullif(btrim(coalesce(p_website, '')), ''), nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''))
  returning id into v_id;
  if v_similar is not null then
    insert into organization_distinct_pairs (org_a, org_b, reason, decided_by)
    select least(v_id, r.entity_id), greatest(v_id, r.entity_id), p_distinct_reason, current_staff_id()
      from entity_registry r where r.table_name = 'organizations' and r.institutional_id in (select e ->> 'organization' from jsonb_array_elements(v_similar) e) on conflict do nothing;
  end if;
  perform set_config('ada.org_distinct_declared', 'off', true);
  select institutional_id into v_inst from entity_registry where table_name = 'organizations' and entity_id = v_id;
  return jsonb_build_object('status', 'created', 'organization', v_inst, 'id', v_id);
end $$;

create function organization_update(p_org uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o organizations%rowtype; k text; v_allowed constant text[] := array['name', 'legal_name', 'trading_name', 'registration_number', 'website', 'email', 'phone', 'address', 'city', 'country', 'industry', 'social_links'];
begin
  o := organization_require(p_org);
  if not has_permission('organizations.update') then raise exception 'organizations.update is required' using errcode = '42501'; end if;
  if o.status = 'merged' then raise exception 'this organization was merged into another; edit the surviving organization' using errcode = '23514'; end if;
  if p_changes is null or p_changes = '{}'::jsonb then raise exception 'nothing to change' using errcode = '23514'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not (k = any (v_allowed)) then raise exception 'cannot change % here', k using errcode = '23514'; end if;
  end loop;
  perform organization_apply(o.id, p_changes, null);
end $$;

-- Another role for an organization that already exists: no second organization is ever created because the relationship differs
create function organization_add_role(p_org uuid, p_role text, p_division uuid default null, p_kind text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o organizations%rowtype; v_id uuid; v_ada text; v_inst text;
begin
  o := organization_require(p_org);
  if o.status = 'merged' then raise exception 'this organization was merged into another; use the surviving organization' using errcode = '23514'; end if;
  if p_role = 'client' then
    if p_division is null or not has_permission('clients.create', p_division) then raise exception 'clients.create is required in that division' using errcode = '42501'; end if;
    if exists (select 1 from clients where organization_id = o.id and deleted_at is null) then raise exception 'this organization already is a client' using errcode = '23514'; end if;
    insert into clients (name, organization_id, owner_division_id) values (o.name, o.id, p_division) returning id, ada_id into v_id, v_ada;
  elsif p_role = 'supplier' then
    if not has_permission('suppliers.manage') then raise exception 'suppliers.manage is required' using errcode = '42501'; end if;
    if exists (select 1 from suppliers where organization_id = o.id) then raise exception 'this organization already is a supplier' using errcode = '23514'; end if;
    insert into suppliers (name, organization_id) values (o.name, o.id) returning id, ada_id into v_id, v_ada;
  elsif p_role = 'partner' then
    if not has_permission('partners.manage') then raise exception 'partners.manage is required' using errcode = '42501'; end if;
    if exists (select 1 from partners where organization_id = o.id) then raise exception 'this organization already is a partner' using errcode = '23514'; end if;
    insert into partners (name, organization_id, kind, status, since) values (o.name, o.id, coalesce(p_kind, 'other'), 'active', current_date) returning id into v_id;
  else
    raise exception 'role must be client, supplier or partner' using errcode = '22023';
  end if;
  select institutional_id into v_inst from entity_registry where entity_id = v_id and table_name = case p_role when 'client' then 'clients' when 'supplier' then 'suppliers' else 'partners' end;
  return jsonb_build_object('role', p_role, 'id', v_id, 'legacy_identifier', v_ada, 'institutional_id', v_inst, 'organization', (select institutional_id from entity_registry where table_name = 'organizations' and entity_id = o.id));
end $$;

create function organization_set_classification(p_org uuid, p_class data_classification, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o organizations%rowtype; e organizations%rowtype;
begin
  o := organization_require(p_org);
  if not (has_permission('organizations.update') and has_permission('records.classify')) then raise exception 'organizations.update and records.classify are required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update organizations set classification = p_class where id = o.id returning * into e;
  if not can_view_organization_row(e.id, e.effective_classification) then raise exception 'you cannot classify an organization above your own clearance' using errcode = '42501'; end if;
end $$;

-- A human decision, never an automatic one. Both organizations keep their IDs; the absorbed one becomes a tombstone that resolves to the survivor.
create function organization_merge_apply(p_survivor uuid, p_absorbed uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s organizations%rowtype; a organizations%rowtype; r record;
begin
  if p_survivor = p_absorbed then raise exception 'an organization cannot be merged into itself' using errcode = '23514'; end if;
  select * into s from organizations where id = p_survivor for update;
  select * into a from organizations where id = p_absorbed for update;
  if s.id is null or a.id is null then raise exception 'organization not found' using errcode = 'P0002'; end if;
  if s.status = 'merged' or a.status = 'merged' then raise exception 'a merged organization cannot take part in another merge' using errcode = '23514'; end if;
  if exists (select 1 from clients x where x.organization_id = s.id and x.deleted_at is null) and exists (select 1 from clients y where y.organization_id = a.id and y.deleted_at is null) then
    raise exception 'both organizations have a live client record: resolve the duplicate client first (archive one with a reason), then merge' using errcode = '23514';
  end if;
  if exists (select 1 from suppliers where organization_id = s.id) and exists (select 1 from suppliers where organization_id = a.id) then
    raise exception 'both organizations are suppliers: the duplicate supplier record must be resolved first' using errcode = '23514';
  end if;
  if exists (select 1 from partners where organization_id = s.id) and exists (select 1 from partners where organization_id = a.id) then
    raise exception 'both organizations are partners: the duplicate partner record must be resolved first' using errcode = '23514';
  end if;
  perform set_config('ada.org_relink', 'on', true);
  perform set_config('ada.org_merge', 'on', true);
  -- the survivor keeps its own facts and only gains what it lacked
  update organizations set legal_name = coalesce(legal_name, a.legal_name), trading_name = coalesce(trading_name, a.trading_name), registration_number = coalesce(registration_number, a.registration_number),
         website = coalesce(website, a.website), email = coalesce(email, a.email), phone = coalesce(phone, a.phone), address = coalesce(address, a.address), city = coalesce(city, a.city),
         industry = coalesce(industry, a.industry) where id = s.id;
  update clients set organization_id = s.id where organization_id = a.id;
  update suppliers set organization_id = s.id where organization_id = a.id;
  update partners set organization_id = s.id where organization_id = a.id;
  perform set_config('ada.org_exempt', 'on', true);
  update organizations set status = 'merged', merged_into_id = s.id, merged_at = now(), merged_by = current_staff_id(), uniqueness_exempt = true where id = a.id;
  perform set_config('ada.org_exempt', 'off', true);
  perform organization_resync(s.id);
  -- open questions about the absorbed organization now concern the survivor
  for r in select * from organization_reviews where status = 'open' and (left_org_id = a.id or right_org_id = a.id) loop
    update organization_reviews set status = case when s.id in (r.left_org_id, r.right_org_id) then 'resolved_same' else 'dismissed' end, resolved_by = current_staff_id(), resolved_at = now(),
           resolution_note = case when s.id in (r.left_org_id, r.right_org_id) then p_note else 'organization merged into another: ' || p_note end where id = r.id;
    if s.id not in (r.left_org_id, r.right_org_id) then
      insert into organization_reviews (left_org_id, right_org_id, reason, score, origin)
      values (s.id, case when r.left_org_id = a.id then r.right_org_id else r.left_org_id end, r.reason, r.score, r.origin) on conflict do nothing;
    end if;
  end loop;
  perform set_config('ada.org_relink', 'off', true);
  perform set_config('ada.org_merge', 'off', true);
end $$;
revoke execute on function organization_merge_apply(uuid, uuid, text) from public, anon, authenticated;

create function organization_merge(p_survivor uuid, p_absorbed uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_permission('matching.review') then raise exception 'matching.review is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required' using errcode = '23514'; end if;
  perform organization_require(p_survivor);
  perform organization_require(p_absorbed);
  perform organization_merge_apply(p_survivor, p_absorbed, p_note);
end $$;

create function organization_review_resolve(p_review uuid, p_outcome text, p_note text, p_survivor uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m organization_reviews%rowtype;
begin
  if not has_permission('matching.review') then raise exception 'matching.review is required' using errcode = '42501'; end if;
  if p_outcome not in ('same', 'distinct', 'dismissed') then raise exception 'outcome must be same, distinct or dismissed' using errcode = '22023'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required' using errcode = '23514'; end if;
  select * into m from organization_reviews where id = p_review and status = 'open' for update;
  if not found then raise exception 'review not found or already resolved' using errcode = 'P0002'; end if;
  if p_outcome = 'same' then
    if p_survivor is null or p_survivor not in (m.left_org_id, m.right_org_id) then raise exception 'name the surviving organization (one of the two under review)' using errcode = '23514'; end if;
    perform organization_merge_apply(p_survivor, case when p_survivor = m.left_org_id then m.right_org_id else m.left_org_id end, p_note);
    update organization_reviews set status = 'resolved_same', resolved_by = current_staff_id(), resolved_at = now(), resolution_note = p_note where id = m.id and status = 'open';
  else
    update organization_reviews set status = case p_outcome when 'distinct' then 'resolved_distinct' else 'dismissed' end, resolved_by = current_staff_id(), resolved_at = now(), resolution_note = p_note where id = m.id;
    if p_outcome = 'distinct' then
      insert into organization_distinct_pairs (org_a, org_b, reason, decided_by) values (least(m.left_org_id, m.right_org_id), greatest(m.left_org_id, m.right_org_id), p_note, current_staff_id()) on conflict do nothing;
    end if;
  end if;
end $$;

-- The 360 of an organization: identity once, then every role (each shown only to those who may see it) and its documents
create function organization_360(p_org uuid) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare o organizations%rowtype; v_inst text;
begin
  select * into o from organizations where id = p_org;
  if not found then perform organization_note_denied(p_org); return null; end if;
  select institutional_id into v_inst from entity_registry where table_name = 'organizations' and entity_id = o.id;
  return jsonb_build_object(
    'identity', jsonb_build_object('institutional_id', v_inst, 'entity_type', 'external_organization', 'status', o.status,
                                   'merged_into', (select r.institutional_id from entity_registry r where r.table_name = 'organizations' and r.entity_id = o.merged_into_id)),
    'organization', jsonb_build_object('name', o.name, 'legal_name', o.legal_name, 'trading_name', o.trading_name, 'registration_number', o.registration_number, 'website', o.website,
                                       'email', o.email, 'phone', o.phone, 'address', o.address, 'city', o.city, 'country', o.country, 'industry', o.industry, 'social_links', o.social_links,
                                       'classification', o.effective_classification),
    'roles', jsonb_build_object(
      'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'institutional_id', (select institutional_id from entity_registry where table_name = 'clients' and entity_id = c.id),
                                'status', c.status, 'live', c.deleted_at is null, 'division', (select key from divisions where id = c.owner_division_id)) order by c.created_at) from clients c where c.organization_id = o.id), '[]'),
      'supplier', (select jsonb_build_object('id', s.ada_id, 'institutional_id', (select institutional_id from entity_registry where table_name = 'suppliers' and entity_id = s.id), 'status', s.status) from suppliers s where s.organization_id = o.id),
      'partner', (select jsonb_build_object('institutional_id', (select institutional_id from entity_registry where table_name = 'partners' and entity_id = p.id), 'kind', p.kind, 'status', p.status, 'since', p.since) from partners p where p.organization_id = o.id)),
    'documents', documents_of(document_family_ids(v_inst)),
    'open_reviews', case when has_permission('matching.review') then (select count(*) from organization_reviews r where r.status = 'open' and o.id in (r.left_org_id, r.right_org_id)) end);
end $$;

-- ---------------------------------------------------------------------------
-- Controlled client creation learns about organizations: an organization that already exists (for example as a supplier) is reused,
-- and a different legal entity with the same name is reported before anything is written.
-- ---------------------------------------------------------------------------
create or replace function client_create(p_name text, p_division uuid, p_type client_type default 'company', p_registration text default null,
                              p_email text default null, p_phone text default null, p_distinct_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_key text;
  v_exact record;
  v_similar jsonb;
  v_id uuid;
  v_ada text;
  v_reg text := nullif(btrim(coalesce(p_registration, '')), '');
begin
  if not has_permission('clients.create', p_division) then
    raise exception 'clients.create is required%', case when p_division is null then ' (organization-wide)' else ' in that division' end using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then raise exception 'a valid name is required' using errcode = '22023'; end if;
  v_key := client_name_key(p_name);
  if v_key = '' then raise exception 'the name needs a distinguishing word' using errcode = '22023'; end if;

  select c.ada_id, c.name, c.status::text as status, nullif(btrim(c.registration_number), '') as registration into v_exact
    from clients c
   where c.deleted_at is null and c.classification in ('public', 'internal')
     and (c.name_key = v_key or (v_reg is not null and lower(btrim(c.registration_number)) = lower(v_reg)))
   order by (lower(btrim(c.registration_number)) is not distinct from lower(v_reg)) desc, c.created_at limit 1;
  if found then
    -- Same normalised name but both sides state DIFFERENT registration numbers: provably different legal entities.
    -- They are never merged, but the system cannot hold two clients with the same normalised name either, so the
    -- creator is asked for a distinguishing name (for example the town or trading name).
    if v_reg is not null and v_exact.registration is not null and lower(v_exact.registration) <> lower(v_reg) then
      return jsonb_build_object('status', 'name_conflict',
                                'next', 'a different legal entity already uses this name; choose a distinguishing name (for example add the town or trading name)');
    end if;
    return jsonb_build_object('status', 'exists', 'client', v_exact.ada_id, 'name', v_exact.name, 'next', 'claim_client_for_division');
  end if;

  -- organization level: a discoverable organization with this name but ANOTHER registration number is a different legal entity
  if v_reg is not null and exists (select 1 from organizations o where o.status = 'active' and o.effective_classification in ('public', 'internal') and not o.uniqueness_exempt
                                      and o.name_key = v_key and nullif(btrim(o.registration_number), '') is not null and lower(btrim(o.registration_number)) <> lower(v_reg)) then
    return jsonb_build_object('status', 'name_conflict',
                              'next', 'a different legal entity already uses this name; choose a distinguishing name (for example add the town or trading name)');
  end if;

  select jsonb_agg(jsonb_build_object('client', x.ada_id, 'name', x.name, 'status', x.status, 'similarity', round(x.score::numeric, 2)) order by x.score desc)
    into v_similar
    from (select c.ada_id, c.name, c.status::text as status, max(cc.score) as score, c.id
            from client_candidates(p_name, v_reg, null, null) cc join clients c on c.id = cc.client_id
           where cc.discoverable and cc.reason = 'similar_name' group by c.id, c.ada_id, c.name, c.status) x;
  if v_similar is not null and coalesce(btrim(p_distinct_reason), '') = '' then
    return jsonb_build_object('status', 'similar', 'candidates', v_similar,
                              'next', 'use an existing client, or repeat with p_distinct_reason explaining why this is a different legal entity');
  end if;

  if v_similar is not null then perform set_config('ada.org_distinct_declared', 'on', true); end if;
  insert into clients (name, client_type, registration_number, email, phone, owner_division_id)
  values (btrim(p_name), p_type, v_reg, nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''), p_division)
  returning id, ada_id into v_id, v_ada;

  perform set_config('ada.org_distinct_declared', 'off', true);
  if v_similar is not null then
    insert into client_distinct_pairs (client_a, client_b, reason, decided_by)
    select least(v_id, c.id), greatest(v_id, c.id), p_distinct_reason, current_staff_id()
      from clients c where c.ada_id in (select e ->> 'client' from jsonb_array_elements(v_similar) e) on conflict do nothing;
    insert into organization_distinct_pairs (org_a, org_b, reason, decided_by)
    select least(n.organization_id, c.organization_id), greatest(n.organization_id, c.organization_id), p_distinct_reason, current_staff_id()
      from clients n, clients c where n.id = v_id and c.ada_id in (select e ->> 'client' from jsonb_array_elements(v_similar) e) and c.organization_id <> n.organization_id on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'created', 'client', v_ada, 'id', v_id,
                            'organization', (select r.institutional_id from entity_registry r join clients c on c.organization_id = r.entity_id where r.table_name = 'organizations' and c.id = v_id));
end $$;

create or replace function client_360(p_client uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  c record;
begin
  select cl.*, d.name as owner_division_name, o.name as org_name, o.legal_name as org_legal_name, o.trading_name as org_trading_name, o.registration_number as org_registration_number, o.website as org_website, o.email as org_email, o.phone as org_phone, o.address as org_address, o.city as org_city, o.country as org_country, o.industry as org_industry, o.social_links as org_social_links, o.id as org_row_id, o.status as org_status into c
    from clients cl left join divisions d on d.id = cl.owner_division_id left join organizations o on o.id = cl.organization_id where cl.id = p_client;
  if not found then return null; end if;                         -- RLS: also null when the caller may not see it

  return jsonb_build_object(
    'organization', (select jsonb_build_object('institutional_id', (select r.institutional_id from entity_registry r where r.table_name = 'organizations' and r.entity_id = c.organization_id), 'status', c.org_status,
                 'roles', jsonb_build_object('client', true, 'supplier', exists (select 1 from suppliers sp where sp.organization_id = c.organization_id), 'partner', exists (select 1 from partners pa where pa.organization_id = c.organization_id)))),
    'overview', jsonb_build_object(
      'id', c.ada_id, 'name', coalesce(c.org_name, c.name), 'legal_name', coalesce(c.org_legal_name, c.legal_name), 'trading_name', coalesce(c.org_trading_name, c.trading_name), 'type', c.client_type, 'status', c.status,
      'industry', coalesce(c.org_industry, c.industry), 'registration_number', coalesce(c.org_registration_number, c.registration_number), 'email', coalesce(c.org_email, c.email), 'phone', coalesce(c.org_phone, c.phone), 'website', coalesce(c.org_website, c.website),
      'address', coalesce(c.org_address, c.address), 'city', coalesce(c.org_city, c.city), 'country', coalesce(c.org_country, c.country), 'billing_address', c.billing_address, 'social_links', coalesce(c.org_social_links, c.social_links),
      'classification', c.classification, 'created_at', c.created_at,
      'owner', (select jsonb_build_object('id', s.ada_id, 'name', s.full_name) from client_staff cs join staff s on s.id = cs.staff_id
                 where cs.client_id = p_client and cs.assignment_role = 'owner')),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('contact', cc.ada_id, 'person', pe.ada_id, 'name', pe.full_name, 'email', pe.email,
                 'phone', pe.phone, 'role', cc.role_title, 'primary', cc.is_primary, 'billing', cc.is_billing, 'active', cc.is_active) order by cc.is_primary desc, pe.full_name)
               from client_contacts cc join people pe on pe.id = cc.person_id where cc.client_id = p_client), '[]'),
    'relationship', jsonb_build_object(
      'divisions', coalesce((select jsonb_agg(jsonb_build_object('code', d.key, 'name', d.name, 'status', cd.relationship_status, 'since', cd.since) order by d.sort_order)
                  from client_divisions cd join divisions d on d.id = cd.division_id where cd.client_id = p_client), '[]'),
      'services_purchased', coalesce((select jsonb_agg(x order by x ->> 'service') from (
                  select jsonb_build_object('service', s.name, 'service_id', s.ada_id, 'division', dv.key, 'quantity', sum(ps.quantity), 'spent', sum(ps.line_total), 'currency', ps.currency) x
                  from project_services ps join projects p on p.id = ps.project_id join services s on s.id = ps.service_id join divisions dv on dv.id = s.division_id
                  where p.client_id = p_client and p.status <> 'cancelled' group by s.id, s.name, s.ada_id, dv.key, ps.currency) q), '[]')),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.ada_id, 'name', p.name, 'status', p.status, 'priority', p.priority, 'division', d.key,
                 'start_date', p.start_date, 'due_date', p.due_date, 'completed_at', p.completed_at) order by p.created_at)
               from projects p join divisions d on d.id = p.lead_division_id where p.client_id = p_client and p.deleted_at is null), '[]'),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total, 'currency', q.currency,
                 'valid_until', q.valid_until, 'project', (select ada_id from projects where id = q.project_id)) order by q.created_at)
               from quotes q where q.client_id = p_client), '[]'),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('id', l.ada_id, 'title', l.title, 'status', l.status, 'division', d.key,
                 'service', (select name from services where id = l.requested_service_id), 'enquiries', (select count(*) from enquiries e where e.lead_id = l.id),
                 'created_at', l.created_at) order by l.created_at)
               from leads l join divisions d on d.id = l.division_id where l.client_id = p_client), '[]'),
    'quote_summary', (select jsonb_build_object('pending', count(*) filter (where status in ('draft', 'pending_approval', 'approved', 'sent')),
                 'accepted', count(*) filter (where status = 'accepted'), 'rejected', count(*) filter (where status = 'rejected'),
                 'accepted_value', coalesce(sum(total) filter (where status = 'accepted'), 0)) from quotes where client_id = p_client),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'record', a.record_ada_id, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'clients' and record_id = p_client)
                        or (table_name = 'client_contacts' and (new_data ->> 'client_id')::uuid = p_client)
                        or (table_name = 'client_divisions' and (new_data ->> 'client_id')::uuid = p_client)
                     order by id desc limit 25) a), '[]'),
    -- finance: authorisation slices of the SAME records (empty unless the viewer holds contracts.view / invoices.view / payments.view)
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', ct.ada_id, 'title', ct.title, 'status', ct.status, 'version', ct.current_version_no, 'currency', ct.currency,
                 'total', ctt.total, 'start_date', ctt.start_date, 'end_date', ctt.end_date, 'auto_renew', ctt.auto_renew, 'quote', (select ada_id from quotes where id = ct.quote_id)) order by ct.created_at)
               from contracts ct left join lateral contract_terms(ct.id) ctt on true where ct.client_id = p_client), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.ada_id, 'status', i.status, 'currency', i.currency, 'total', i.total, 'issue_date', i.issue_date,
                 'due_date', i.due_date, 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id), 'contract', (select ada_id from contracts where id = i.contract_id)) order by i.created_at)
               from invoices i where i.client_id = p_client), '[]'),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', py.ada_id, 'status', py.status, 'currency', py.currency, 'amount', py.amount, 'received_on', py.received_on,
                 'method', py.method, 'reconciliation', py.reconciliation, 'credit', b.credit) order by py.received_on, py.created_at)
               from payments py join payment_balances b on b.payment_id = py.id where py.client_id = p_client), '[]'),
    'finance_summary', (select jsonb_build_object(
                 'invoiced', coalesce(sum(i.total) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'paid', coalesce(sum(invoice_paid(i.id)) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'outstanding', coalesce(sum(invoice_balance(i.id)) filter (where i.status in ('issued', 'partially_paid')), 0),
                 'overdue', coalesce(sum(invoice_balance(i.id)) filter (where i.status in ('issued', 'partially_paid') and i.due_date < current_date), 0),
                 'unallocated_credit', (select coalesce(sum(credit), 0) from payment_balances where client_id = p_client and status = 'received'))
               from invoices i where i.client_id = p_client),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition, 'category', (select name from asset_categories where id = ast.category_id),
                 'project', (select ada_id from projects where id = ast.project_id)) order by ast.created_at) from assets ast where ast.client_id = p_client), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority, 'asset', (select ada_id from assets where id = tk.asset_id)) order by tk.created_at)
               from tickets tk where tk.client_id = p_client), '[]'),
    'documents', documents_of(document_family_ids((select institutional_id from entity_registry where table_name = 'clients' and entity_id = p_client))),
    'pending', jsonb_build_array('domains', 'communications'));
end $$;

create or replace function document_family_ids(p_registry_id text) returns text[]
language plpgsql stable set search_path = public, pg_temp as $$
declare r entity_registry%rowtype; v_ids text[] := '{}';
begin
  select * into r from entity_registry where institutional_id = p_registry_id;
  if not found then return '{}'; end if;
  v_ids := array[r.institutional_id];
  if r.table_name = 'clients' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'projects'  and er.entity_id in (select id from projects  where client_id = r.entity_id))
      or (er.table_name = 'contracts' and er.entity_id in (select id from contracts where client_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes    where client_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices  where client_id = r.entity_id))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets   where client_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets    where client_id = r.entity_id));
  elsif r.table_name = 'projects' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'contracts' and er.entity_id in (select contract_id from contract_projects where project_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes   where project_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices where project_id = r.entity_id))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets  where project_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets   where project_id = r.entity_id));
  elsif r.table_name = 'organizations' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'clients'   and er.entity_id in (select id from clients   where organization_id = r.entity_id))
      or (er.table_name = 'suppliers' and er.entity_id in (select id from suppliers where organization_id = r.entity_id))
      or (er.table_name = 'partners'  and er.entity_id in (select id from partners  where organization_id = r.entity_id));
    select v_ids || coalesce(array_agg(x), '{}') into v_ids
      from (select unnest(document_family_ids(er.institutional_id)) x from entity_registry er
             where er.table_name = 'clients' and er.entity_id in (select id from clients where organization_id = r.entity_id)) q;
    select coalesce(array_agg(distinct x), '{}') into v_ids from unnest(v_ids) x;
  end if;
  return v_ids;
end $$;


-- ---------------------------------------------------------------------------
-- Consistency proof and recovery manifest
-- ---------------------------------------------------------------------------
create function organization_mirror_drift() returns table (role_table text, role_id uuid, column_name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select 'clients', c.id, k from clients c join organizations o on o.id = c.organization_id, unnest(org_mirror_cols('clients')) k where to_jsonb(c) -> k is distinct from to_jsonb(o) -> k
  union all
  select 'suppliers', s.id, k from suppliers s join organizations o on o.id = s.organization_id, unnest(org_mirror_cols('suppliers')) k where to_jsonb(s) -> k is distinct from to_jsonb(o) -> k
  union all
  select 'partners', p.id, k from partners p join organizations o on o.id = p.organization_id, unnest(org_mirror_cols('partners')) k where to_jsonb(p) -> k is distinct from to_jsonb(o) -> k
$$;
revoke execute on function organization_mirror_drift() from public, anon, authenticated;
grant execute on function organization_mirror_drift() to service_role;

create function organization_backup_manifest() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'organizations', (select count(*) from organizations), 'clients', (select count(*) from clients), 'suppliers', (select count(*) from suppliers), 'partners', (select count(*) from partners),
    'reviews', (select count(*) from organization_reviews), 'mirror_drift', (select count(*) from organization_mirror_drift()),
    'organizations_md5', (select md5(coalesce(string_agg(concat_ws('|', r.institutional_id, o.name, o.legal_name, o.registration_number, o.status, o.effective_classification, o.uniqueness_exempt, o.merged_into_id), ';' order by r.institutional_id), ''))
                            from organizations o join entity_registry r on r.table_name = 'organizations' and r.entity_id = o.id),
    'roles_md5', (select md5(coalesce(string_agg(concat_ws('|', t, id, organization_id), ';' order by t, id), '')) from (
                    select 'c' t, id, organization_id from clients union all select 's', id, organization_id from suppliers union all select 'p', id, organization_id from partners) x),
    'reviews_md5', (select md5(coalesce(string_agg(concat_ws('|', left_org_id, right_org_id, reason, status), ';' order by left_org_id, right_org_id, created_at), '')) from organization_reviews))
$$;
revoke execute on function organization_backup_manifest() from public, anon, authenticated;
grant execute on function organization_backup_manifest() to service_role;

-- ---------------------------------------------------------------------------
-- Grants, row-level security, audit
-- ---------------------------------------------------------------------------
alter table organizations enable row level security;
alter table partners enable row level security;
alter table organization_reviews enable row level security;
alter table organization_distinct_pairs enable row level security;
alter table organization_mirror_columns enable row level security;
revoke all on organizations, partners, organization_reviews, organization_distinct_pairs, organization_mirror_columns from anon, authenticated;
grant select on organizations, partners, organization_reviews, organization_distinct_pairs to authenticated;
grant insert, update on partners to authenticated;
create policy organizations_select on organizations for select to authenticated using (can_view_organization_row(id, effective_classification));
create policy partners_select on partners for select to authenticated using (partner_visible(organization_id));
create policy partners_insert on partners for insert to authenticated with check (has_permission('partners.manage'));
create policy partners_update on partners for update to authenticated using (has_permission('partners.manage') and partner_visible(organization_id)) with check (has_permission('partners.manage'));
create policy organization_reviews_select on organization_reviews for select to authenticated using (has_permission('matching.review'));
create policy organization_distinct_pairs_select on organization_distinct_pairs for select to authenticated using (has_permission('matching.review'));

revoke execute on function can_view_organization_row(uuid, data_classification), can_view_organization(uuid), partner_visible(uuid), organization_note_denied(uuid),
  organization_create(text, text, text, text, text, text, text), organization_update(uuid, jsonb), organization_add_role(uuid, text, uuid, text),
  organization_set_classification(uuid, data_classification, text), organization_merge(uuid, uuid, text), organization_review_resolve(uuid, text, text, uuid), organization_360(uuid) from public, anon;
grant execute on function can_view_organization_row(uuid, data_classification), can_view_organization(uuid), partner_visible(uuid), organization_note_denied(uuid),
  organization_create(text, text, text, text, text, text, text), organization_update(uuid, jsonb), organization_add_role(uuid, text, uuid, text),
  organization_set_classification(uuid, data_classification, text), organization_merge(uuid, uuid, text), organization_review_resolve(uuid, text, text, uuid), organization_360(uuid) to authenticated;

do $$ begin
  perform attach_audit('organizations'); perform attach_audit('partners'); perform attach_audit('organization_reviews'); perform attach_audit('organization_distinct_pairs');
end $$;
