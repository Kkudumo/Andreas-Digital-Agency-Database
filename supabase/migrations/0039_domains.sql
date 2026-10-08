-- 0039_domains: the Domains module, on the institutional foundation (NOT a stand-alone mini-system).
--  * Identity: a domain is a registered entity (type `domain`) through the one registration path (attach_entity); nothing here generates an ID.
--    The NAME is the natural key (one record per name, case-insensitive); the institutional ID never changes and is never reused.
--    A name that is dropped and later taken again is the SAME record (retired -> requested), so history is one continuous story.
--  * Record vs identity vs relationships: `domains` is the authoritative record (name, purpose, owning division, lifecycle, classification, expiry).
--    Who it belongs to (registrant organization, client, project, website, registrar supplier) lives in `domain_relations` as REFERENCES to registered
--    entities, with valid_from / valid_to history; nothing about those entities is copied here.
--  * Lifecycle is explicit: requested -> active <-> suspended, active -> transfer_pending -> active | retired, active -> expired -> active | retired,
--    retired -> requested (re-registration). Registrations and renewals form an append-only, gap-free ledger (`domain_registrations`); expires_on is a
--    trigger-maintained mirror of it. Transfers (`domain_transfers`) are approved (approval engine), completed and append-only. Nothing is ever deleted.
--  * Classification is inherited from the entities a domain is currently related to (a restricted client makes its domains restricted); hidden domains
--    are exempt from name uniqueness and flagged silently, exactly like hidden clients.
--  * Search resolves domains through the registry (label = name). Nothing is public: `publishable` stays false until the publication layer exists.

insert into permissions (key, module, action, description, sensitivity) values
  ('domains.view', 'domains', 'view', 'View domains (own division)', 'internal'::data_classification),
  ('domains.create', 'domains', 'create', 'Create domain records and bring existing domains under management', 'internal'::data_classification),
  ('domains.update', 'domains', 'update', 'Edit domain details and relationships', 'internal'::data_classification),
  ('domains.renew', 'domains', 'renew', 'Record registrations and renewals', 'internal'::data_classification),
  ('domains.suspend', 'domains', 'suspend', 'Suspend and restore domains', 'restricted'::data_classification),
  ('domains.transfer', 'domains', 'transfer', 'Request complete and cancel transfers', 'restricted'::data_classification),
  ('domains.approve', 'domains', 'approve', 'Approve domain transfers', 'restricted'::data_classification),
  ('domains.retire', 'domains', 'retire', 'Retire domains and re-register retired ones', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'domains.view'),
  ('administration_officer', 'domains.view'),
  ('finance_officer', 'domains.view'),
  ('division_lead', 'domains.view'),
  ('division_staff', 'domains.view'),
  ('auditor', 'domains.view'),
  ('ceo', 'domains.create'),
  ('administration_officer', 'domains.create'),
  ('division_lead', 'domains.create'),
  ('ceo', 'domains.update'),
  ('administration_officer', 'domains.update'),
  ('division_lead', 'domains.update'),
  ('ceo', 'domains.renew'),
  ('administration_officer', 'domains.renew'),
  ('finance_officer', 'domains.renew'),
  ('division_lead', 'domains.renew'),
  ('ceo', 'domains.suspend'),
  ('administration_officer', 'domains.suspend'),
  ('division_lead', 'domains.suspend'),
  ('ceo', 'domains.transfer'),
  ('administration_officer', 'domains.transfer'),
  ('division_lead', 'domains.transfer'),
  ('ceo', 'domains.approve'),
  ('ceo', 'domains.retire'),
  ('administration_officer', 'domains.retire')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

update entity_types set is_built = true, domain_table = 'domains', division_col = 'division_id', status_col = 'status', class_col = 'effective_classification',
       label_col = 'name', view_fn = 'domain_360', description = 'Domain name under ADA management' where key = 'domain';

create type domain_status as enum ('requested', 'active', 'suspended', 'transfer_pending', 'expired', 'retired');

create function domain_name_valid(p_name text) returns boolean
language sql immutable as $$
  select p_name ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' and length(p_name) <= 253 and p_name !~ '(^|\.)-|-(\.|$)'
$$;

-- ---------------------------------------------------------------------------
-- The domain record
-- ---------------------------------------------------------------------------
create table domains (
  id                       uuid primary key default gen_random_uuid(),
  name                     text not null check (domain_name_valid(name)),
  purpose                  text not null default 'website' check (purpose in ('website', 'email', 'redirect', 'defensive', 'internal', 'other')),
  description              text,
  division_id              uuid not null references divisions (id),
  status                   domain_status not null default 'requested',
  expires_on               date,
  classification           data_classification not null default 'internal',
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  retired_at               timestamptz
);
create unique index domains_name_unique on domains (name) where effective_classification in ('public', 'internal');
create index domains_name_idx on domains (name);
create index domains_division_idx on domains (division_id);
create index domains_expiry_idx on domains (expires_on) where status in ('active', 'suspended', 'transfer_pending');
comment on table domains is 'Purpose: the authoritative record of a domain name under ADA management: name, purpose, owning division, lifecycle status, expiry, classification. Who owns / uses it is a reference in domain_relations; its registration and renewal history is domain_registrations. Registered through attach_entity (permanent institutional ID; origin division fixed). One record per name for ever: a dropped name that is taken again is the same record. [class: internal; inherits the strictest classification of its current relations]';
comment on column domains.division_id is 'CURRENT owning division. The ORIGIN division is fixed in the registry. Changes only through domain_set_division.';
comment on column domains.expires_on is 'Trigger-maintained mirror of the end of the latest registration period (domain_registrations). Never written directly.';
comment on column domains.effective_classification is 'Derived: the greater of the domain''s own classification and that of every entity it is currently related to. Authorization reads this column.';
do $$ begin perform attach_entity('domains', 'domain'); end $$;
create trigger domains_updated before update on domains for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Relationships: references only, with history
-- ---------------------------------------------------------------------------
create table domain_relations (
  id                      uuid primary key default gen_random_uuid(),
  domain_id               uuid not null references domains (id) on delete restrict,
  relation                text not null check (relation in ('registrant', 'client', 'project', 'website', 'registrar')),
  entity_institutional_id text not null references entity_registry (institutional_id),
  valid_from              timestamptz not null default now(),
  valid_to                timestamptz,
  set_by                  uuid references staff (id) default current_staff_id(),
  reason                  text,
  ended_by                uuid references staff (id),
  end_reason              text
);
create unique index domain_relations_one_current_single on domain_relations (domain_id, relation) where valid_to is null and relation in ('registrant', 'client', 'registrar');
create unique index domain_relations_one_current_multi on domain_relations (domain_id, relation, entity_institutional_id) where valid_to is null;
create index domain_relations_entity_idx on domain_relations (entity_institutional_id, valid_from);
create index domain_relations_domain_idx on domain_relations (domain_id, valid_from);
comment on table domain_relations is 'Purpose: which registered entities a domain relates to - registrant (organization), client, project, website, registrar (supplier) - as REFERENCES by institutional ID with valid_from / valid_to. Changing a single-valued relation ends the old row and opens a new one, so "who owned it then" stays answerable. Nothing about the entity is copied. [class: inherits the domain; a row is visible only if the domain AND the target entity are visible]';

create table domain_registrations (
  id                     uuid primary key default gen_random_uuid(),
  domain_id              uuid not null references domains (id) on delete restrict,
  kind                   text not null check (kind in ('registration', 'renewal')),
  period_start           date not null,
  period_end             date not null,
  registrar_institutional_id text references entity_registry (institutional_id),
  order_reference        text check (btrim(order_reference) <> ''),
  note                   text,
  recorded_by            uuid references staff (id) default current_staff_id(),
  recorded_at            timestamptz not null default now(),
  check (period_end > period_start)
);
create unique index domain_registrations_period_unique on domain_registrations (domain_id, period_start);
create unique index domain_registrations_reference_unique on domain_registrations (domain_id, lower(order_reference)) where order_reference is not null;
comment on table domain_registrations is 'Purpose: the append-only ledger of registration periods and renewals. Periods are contiguous (each starts where the previous ended), an order reference makes a repeated submission a no-op, and the latest end date is the domain''s expiry. Never edited or deleted. [class: inherits the domain]';
create trigger domain_registrations_immutable before update or delete on domain_registrations for each row execute function append_only();

create table domain_transfers (
  id                         uuid primary key default gen_random_uuid(),
  domain_id                  uuid not null references domains (id) on delete restrict,
  kind                       text not null check (kind in ('registrar', 'ownership', 'out')),
  to_entity_institutional_id text references entity_registry (institutional_id),
  to_client_institutional_id text references entity_registry (institutional_id),
  destination_note           text,
  reason                     text not null check (btrim(reason) <> ''),
  state                      text not null default 'requested' check (state in ('requested', 'approved', 'completed', 'rejected', 'cancelled')),
  status_before              domain_status,
  requested_by               uuid references staff (id) default current_staff_id(),
  requested_at               timestamptz not null default now(),
  decided_by                 uuid references staff (id),
  decided_at                 timestamptz,
  decision_note              text,
  closed_by                  uuid references staff (id),
  closed_at                  timestamptz,
  closing_note               text,
  check ((kind = 'out') = (to_entity_institutional_id is null)),
  check (kind <> 'registrar' or (to_entity_institutional_id is not null and to_client_institutional_id is null)),
  check (kind <> 'ownership' or to_entity_institutional_id is not null)
);
create unique index domain_transfers_one_open on domain_transfers (domain_id) where state in ('requested', 'approved');
comment on table domain_transfers is 'Purpose: controlled transfers of a domain - to another registrar, to another owner (organization, optionally client), or out of ADA''s management. Requested (target must be visible to the requester), approved by a different person (approval engine), completed or cancelled with a note. Forward-only and never deleted; the domain is transfer_pending while one is open. Transfer authorisation codes are never stored. [class: inherits the domain]';

create table domain_events (
  id             bigint generated always as identity primary key,
  domain_id      uuid not null references domains (id) on delete restrict,
  kind           text not null check (kind in ('created', 'metadata', 'classification', 'division', 'activated', 'renewed', 'status', 'expired', 'expiry_notice', 'relation_added', 'relation_ended',
                                               'transfer_requested', 'transfer_decided', 'transfer_completed', 'transfer_cancelled', 'reregistered', 'review')),
  actor_staff_id uuid references staff (id),
  occurred_at    timestamptz not null default now(),
  detail         jsonb not null default '{}'::jsonb
);
create index domain_events_domain_idx on domain_events (domain_id, id);
comment on table domain_events is 'Purpose: append-only history of everything that happens to a domain (creation, activation, every renewal and expiry, status changes, relationship changes, transfer steps, re-registration), with the acting staff identity (NULL only for the system sweep). Cannot be edited or deleted. [class: inherits the domain]';
create trigger domain_events_immutable before update or delete on domain_events for each row execute function append_only();

create table domain_reviews (
  id              uuid primary key default gen_random_uuid(),
  left_domain_id  uuid not null references domains (id),
  right_domain_id uuid not null references domains (id),
  reason          text not null,
  status          text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  created_at      timestamptz not null default now(),
  resolved_by     uuid references staff (id),
  resolved_at     timestamptz,
  resolution_note text,
  check (left_domain_id <> right_domain_id)
);
create unique index domain_reviews_open_pair on domain_reviews (least(left_domain_id, right_domain_id), greatest(left_domain_id, right_domain_id)) where status = 'open';
comment on table domain_reviews is 'Purpose: two records for the same domain name where one is hidden from whoever created the other (so the creator was told nothing). Only matching.review holders see it. [class: restricted]';

create function domain_log(p_domain uuid, p_kind text, p_detail jsonb default '{}') returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into domain_events (domain_id, kind, actor_staff_id, detail) values (p_domain, p_kind, current_staff_id(), coalesce(p_detail, '{}'))
$$;
revoke execute on function domain_log(uuid, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Authorization: one decision per action, evaluated before anything is shown
-- ---------------------------------------------------------------------------
create function domain_can_row(p_id uuid, p_division uuid, p_class data_classification, p_deleted boolean, p_status domain_status, p_action text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_perm text := case p_action when 'view' then 'domains.view' when 'update' then 'domains.update' when 'renew' then 'domains.renew' when 'suspend' then 'domains.suspend'
                                     when 'transfer' then 'domains.transfer' when 'approve' then 'domains.approve' when 'retire' then 'domains.retire' end;
begin
  if v_perm is null then return false; end if;
  if not coalesce(classification_visible(p_class) and (not p_deleted or has_permission('records.view_deleted')), false) then return false; end if;
  if not coalesce(has_permission('domains.view', p_division), false) then return false; end if;
  if p_action = 'view' then return true; end if;
  if p_status = 'retired' and p_action <> 'retire' then return false; end if;
  return coalesce(has_permission(v_perm, p_division), false);
end $$;
create function domain_can(p_id uuid, p_action text default 'view') returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select domain_can_row(d.id, d.division_id, d.effective_classification, d.client_deleted, d.status, p_action) from domains d where d.id = p_id), false)
$$;
-- Loads and locks a domain the caller may see: hidden and missing are the same error
create function domain_require(p_id uuid, p_action text default 'view') returns domains
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  select * into d from domains where id = p_id for update;
  if not found or not domain_can_row(d.id, d.division_id, d.effective_classification, d.client_deleted, d.status, 'view') then raise exception 'domain not found' using errcode = 'P0002'; end if;
  if p_action <> 'view' and not domain_can_row(d.id, d.division_id, d.effective_classification, d.client_deleted, d.status, p_action) then
    raise exception 'you are not permitted to % this domain', p_action using errcode = '42501';
  end if;
  return d;
end $$;
create function domain_inst_id(p_id uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$ select institutional_id from entity_registry where table_name = 'domains' and entity_id = p_id $$;
create function domain_note_denied(p_id uuid, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform security_note_lookup(coalesce(domain_inst_id(p_id), p_id::text), 'domain.' || left(coalesce(p_action, 'view'), 24)); end $$;
revoke execute on function domain_require(uuid, text), domain_inst_id(uuid) from public, anon, authenticated;
revoke execute on function domain_note_denied(uuid, text) from public, anon;
grant execute on function domain_note_denied(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Triggers: classification inheritance, the record's guard, hidden-duplicate flag
-- ---------------------------------------------------------------------------
create function domains_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cls data_classification; v_del boolean;
begin
  select coalesce(max(r.classification), 'public'),
         coalesce(bool_or(case r.table_name when 'clients'  then exists (select 1 from clients c  where c.id = r.entity_id and c.deleted_at is not null)
                                            when 'projects' then exists (select 1 from projects p where p.id = r.entity_id and p.deleted_at is not null) else false end), false)
    into v_cls, v_del
    from domain_relations dr join entity_registry r on r.institutional_id = dr.entity_institutional_id
   where dr.domain_id = new.id and dr.valid_to is null;
  new.effective_classification := greatest(new.classification, v_cls);
  new.client_deleted := v_del;
  return new;
end $$;
create trigger domains_inherit_trg before insert or update on domains for each row execute function domains_inherit();

create function domains_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'domains are never deleted: they are retired, and their identity is kept' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.name := lower(rtrim(btrim(new.name), '.'));
    new.status := 'requested'; new.expires_on := null; new.retired_at := null;
    new.created_by := coalesce(new.created_by, current_staff_id());
    return new;
  end if;
  if new.name is distinct from old.name or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then
    raise exception 'a domain''s name, creator and creation time are permanent' using errcode = '42501';
  end if;
  if old.status = 'retired' and new.status = 'retired' and (to_jsonb(new) - array['updated_at', 'effective_classification', 'client_deleted']) is distinct from (to_jsonb(old) - array['updated_at', 'effective_classification', 'client_deleted']) then
    raise exception 'a retired domain is a closed record until it is re-registered' using errcode = '42501';
  end if;
  if new.division_id is distinct from old.division_id and coalesce(current_setting('ada.domain_division', true), '') <> 'on' then
    raise exception 'a domain changes division only through domain_set_division' using errcode = '42501';
  end if;
  if new.expires_on is distinct from old.expires_on and coalesce(current_setting('ada.domain_ledger', true), '') <> 'on' then
    raise exception 'a domain''s expiry follows its registration ledger and is never written directly' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'requested' and new.status in ('active', 'expired', 'retired'))
         or (old.status = 'active' and new.status in ('suspended', 'transfer_pending', 'expired', 'retired'))
         or (old.status = 'suspended' and new.status in ('active', 'transfer_pending', 'expired', 'retired'))
         or (old.status = 'transfer_pending' and new.status in ('active', 'suspended', 'retired'))
         or (old.status = 'expired' and new.status in ('active', 'retired'))
         or (old.status = 'retired' and new.status = 'requested')) then
      raise exception 'invalid domain status change % -> %', old.status, new.status using errcode = '23514';
    end if;
    if (old.status = 'transfer_pending' or new.status = 'transfer_pending') and coalesce(current_setting('ada.domain_transfer', true), '') <> 'on' then
      raise exception 'a domain enters and leaves transfer_pending only through the transfer workflow' using errcode = '42501';
    end if;
    if new.status = 'active' and old.status in ('requested', 'expired') and coalesce(current_setting('ada.domain_ledger', true), '') <> 'on' then
      raise exception 'a domain becomes active only when a registration or renewal is recorded' using errcode = '42501';
    end if;
    if new.status = 'active' and (new.expires_on is null or new.expires_on < current_date) then raise exception 'an active domain must have an expiry date that is not in the past' using errcode = '23514'; end if;
    if new.status = 'expired' and (new.expires_on is null or new.expires_on >= current_date) then raise exception 'a domain is expired only after its expiry date' using errcode = '23514'; end if;
    new.retired_at := case when new.status = 'retired' then now() when old.status = 'retired' then null else old.retired_at end;
  end if;
  return new;
end $$;
create trigger domains_guard_trg before insert or update or delete on domains for each row execute function domains_guard();

-- Two records for one name where one is hidden from whoever made the other: the creator is told nothing, management gets a review item
create function domains_flag_duplicates() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  for r in select d.id, d.effective_classification from domains d where d.name = new.name and d.id <> new.id loop
    if new.effective_classification not in ('public', 'internal') or r.effective_classification not in ('public', 'internal') then
      insert into domain_reviews (left_domain_id, right_domain_id, reason) values (new.id, r.id, 'same name') on conflict do nothing;
    end if;
  end loop;
  return null;
end $$;
create trigger domains_flag_duplicates_trg after insert or update of classification on domains for each row execute function domains_flag_duplicates();

-- Dependents follow their entities (restriction / soft deletion), in both directions
create function domains_follow_entity() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update domains set classification = classification
   where id in (select dr.domain_id from domain_relations dr join entity_registry r on r.institutional_id = dr.entity_institutional_id
                  where r.table_name = tg_table_name and r.entity_id = new.id and dr.valid_to is null);
  return null;
end $$;
create trigger domains_follow_client_trg after update of deleted_at on clients for each row execute function domains_follow_entity();
create trigger domains_follow_project_trg after update of deleted_at on projects for each row execute function domains_follow_entity();

create or replace function registry_sync_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t entity_types; a record; r entity_registry%rowtype;
begin
  select * into r from entity_registry where table_name = tg_table_name and entity_id = coalesce(new.id, old.id);
  if not found then return null; end if;
  if tg_op = 'DELETE' then
    update entity_registry set status = 'removed', routing_version = routing_version + 1 where institutional_id = r.institutional_id;
    return null;
  end if;
  select * into t from entity_types where key = r.entity_type;
  select * into a from registry_attrs(t, to_jsonb(new));
  if (a.division_id, a.location, a.status, a.classification, a.scope) is distinct from (r.current_division_id, r.current_location, r.status, r.classification, r.authorization_scope) then
    update entity_registry set current_division_id = a.division_id, current_location = a.location, status = a.status, classification = a.classification,
           authorization_scope = a.scope, routing_version = routing_version + 1 where institutional_id = r.institutional_id;
    if a.division_id is distinct from r.current_division_id or a.location is distinct from r.current_location then
      insert into entity_location_history (institutional_id, from_division_id, to_division_id, from_location, to_location, reason, changed_by)
      values (r.institutional_id, r.current_division_id, a.division_id, r.current_location, a.location, 'moved', current_staff_id());
    end if;
    if a.classification is distinct from r.classification then
      update documents set classification = classification
       where id in (select dl.document_id from document_links dl where dl.entity_institutional_id = r.institutional_id and dl.removed_at is null);
      update domains set classification = classification
       where id in (select dr.domain_id from domain_relations dr where dr.entity_institutional_id = r.institutional_id and dr.valid_to is null);
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Relationships (references, with history)
-- ---------------------------------------------------------------------------
create function domain_relations_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare cur domain_relations%rowtype;
begin
  if tg_op = 'DELETE' then raise exception 'relationships are never deleted: they are ended with a reason, so history stays answerable' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if (new.domain_id, new.relation, new.entity_institutional_id, new.valid_from, new.set_by, new.reason) is distinct from (old.domain_id, old.relation, old.entity_institutional_id, old.valid_from, old.set_by, old.reason)
       or old.valid_to is not null or new.valid_to is null or coalesce(current_setting('ada.domain_relation', true), '') <> 'on' then
      raise exception 'a relationship is permanent; it can only be ended once, with a reason, by the system' using errcode = '42501';
    end if;
    return new;
  end if;
  new.set_by := coalesce(new.set_by, current_staff_id());
  new.valid_to := null; new.ended_by := null; new.end_reason := null; new.valid_from := now();
  -- NOTE: nothing here may raise an error that depends on records the caller may not see (this runs BEFORE row security is checked);
  -- the validations that can fail are in the AFTER trigger, which only runs for rows the caller was allowed to write.
  if new.relation in ('registrant', 'client', 'registrar') then
    select * into cur from domain_relations where domain_id = new.domain_id and relation = new.relation and valid_to is null and entity_institutional_id <> new.entity_institutional_id for update;
    if found then
      perform set_config('ada.domain_relation', 'on', true);
      update domain_relations set valid_to = now(), ended_by = current_staff_id(), end_reason = 'replaced: ' || coalesce(nullif(btrim(new.reason), ''), 'no reason given') where id = cur.id;
      perform set_config('ada.domain_relation', 'off', true);
    end if;
  end if;
  return new;
end $$;
create trigger domain_relations_before_trg before insert or update or delete on domain_relations for each row execute function domain_relations_before();
create function domain_relations_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text; d domains%rowtype;
begin
  if tg_op = 'INSERT' then
    select * into d from domains where id = new.domain_id;
    if d.status = 'retired' then raise exception 'a retired domain takes no new relationships' using errcode = '23514'; end if;
    select entity_type into v_type from entity_registry where institutional_id = new.entity_institutional_id;
    if not coalesce(case new.relation when 'registrant' then v_type in ('external_organization', 'organization') when 'client' then v_type = 'client' when 'project' then v_type = 'project'
                                      when 'website' then v_type = 'website' when 'registrar' then v_type = 'supplier' end, false) then
      raise exception 'a % relationship must point at a different kind of record', new.relation using errcode = '23514';
    end if;
  end if;
  update domains set classification = classification where id = new.domain_id;
  if tg_op = 'INSERT' then perform domain_log(new.domain_id, 'relation_added', jsonb_build_object('relation', new.relation, 'entity', new.entity_institutional_id, 'reason', new.reason));
  else perform domain_log(new.domain_id, 'relation_ended', jsonb_build_object('relation', new.relation, 'entity', new.entity_institutional_id, 'reason', new.end_reason)); end if;
  return null;
end $$;
create trigger domain_relations_after_trg after insert or update on domain_relations for each row execute function domain_relations_after();

create function domain_relation_end(p_relation uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r domain_relations%rowtype; d domains%rowtype;
begin
  select * into r from domain_relations where id = p_relation;
  if not found then raise exception 'domain not found' using errcode = 'P0002'; end if;
  d := domain_require(r.domain_id, 'update');
  if r.valid_to is not null then raise exception 'the relationship is already ended' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  perform set_config('ada.domain_relation', 'on', true);
  update domain_relations set valid_to = now(), ended_by = current_staff_id(), end_reason = p_reason where id = r.id;
  perform set_config('ada.domain_relation', 'off', true);
end $$;

-- Internal: set a relation as the system (used by workflows that already authorised and validated the target)
create function domain_relation_apply(p_domain uuid, p_relation text, p_entity text, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_entity is null then
    perform set_config('ada.domain_relation', 'on', true);
    update domain_relations set valid_to = now(), ended_by = current_staff_id(), end_reason = p_reason where domain_id = p_domain and relation = p_relation and valid_to is null;
    perform set_config('ada.domain_relation', 'off', true);
  else
    insert into domain_relations (domain_id, relation, entity_institutional_id, reason) values (p_domain, p_relation, p_entity, p_reason);
  end if;
end $$;
revoke execute on function domain_relation_apply(uuid, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The registration ledger drives the lifecycle: registration / renewal rows are validated, then expiry and status follow
-- ---------------------------------------------------------------------------
create function domain_registrations_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; v_prev date; v_registrar text;
begin
  select * into d from domains where id = new.domain_id for update;
  select max(period_end) into v_prev from domain_registrations where domain_id = new.domain_id;
  select entity_institutional_id into v_registrar from domain_relations where domain_id = new.domain_id and relation = 'registrar' and valid_to is null;
  if new.kind = 'registration' then
    if d.status <> 'requested' then raise exception 'a registration can only be recorded for a requested domain (this one is %)', d.status using errcode = '23514'; end if;
    if v_registrar is null then raise exception 'name the registrar (a supplier) before recording a registration' using errcode = '23514'; end if;
    if v_prev is not null and new.period_start < v_prev then raise exception 'the new registration period must start on or after the end of the previous one (%)', v_prev using errcode = '23514'; end if;
  else
    if d.status not in ('active', 'suspended', 'expired') then raise exception 'a renewal can only be recorded for an active, suspended or expired domain (this one is %)', d.status using errcode = '23514'; end if;
    if v_prev is null or new.period_start <> v_prev then raise exception 'a renewal must start where the previous period ended (%)', v_prev using errcode = '23514'; end if;
  end if;
  if new.period_end - new.period_start not between 28 and 3660 then raise exception 'a registration period is between one month and ten years' using errcode = '23514'; end if;
  if new.period_end > current_date + interval '10 years' then raise exception 'a domain cannot be registered beyond ten years from today' using errcode = '23514'; end if;
  new.registrar_institutional_id := coalesce(new.registrar_institutional_id, v_registrar);
  new.recorded_by := coalesce(new.recorded_by, current_staff_id());
  return new;
end $$;
create trigger domain_registrations_before_trg before insert on domain_registrations for each row execute function domain_registrations_before();

create function domain_registrations_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; v_to domain_status;
begin
  select * into d from domains where id = new.domain_id;
  perform set_config('ada.domain_ledger', 'on', true);
  v_to := case when d.status in ('requested', 'expired') then (case when new.period_end >= current_date then 'active' else 'expired' end)::domain_status else d.status end;
  update domains set expires_on = new.period_end, status = v_to where id = d.id;
  perform set_config('ada.domain_ledger', 'off', true);
  perform domain_log(d.id, case when new.kind = 'registration' then 'activated' else 'renewed' end,
                     jsonb_build_object('period_start', new.period_start, 'period_end', new.period_end, 'order_reference', new.order_reference, 'status', v_to, 'previous_status', d.status));
  return null;
end $$;
create trigger domain_registrations_after_trg after insert on domain_registrations for each row execute function domain_registrations_after();

-- ---------------------------------------------------------------------------
-- Transfers
-- ---------------------------------------------------------------------------
create function domain_transfers_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  if tg_op = 'DELETE' then raise exception 'transfers are never deleted' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if (new.domain_id, new.kind, new.to_entity_institutional_id, new.to_client_institutional_id, new.destination_note, new.reason, new.status_before, new.requested_by, new.requested_at)
       is distinct from (old.domain_id, old.kind, old.to_entity_institutional_id, old.to_client_institutional_id, old.destination_note, old.reason, old.status_before, old.requested_by, old.requested_at) then
      raise exception 'a transfer''s request is permanent' using errcode = '42501';
    end if;
    if new.state is distinct from old.state and not ((old.state = 'requested' and new.state in ('approved', 'rejected', 'cancelled')) or (old.state = 'approved' and new.state in ('completed', 'cancelled'))) then
      raise exception 'invalid transfer state change % -> %', old.state, new.state using errcode = '23514';
    end if;
    if old.state in ('completed', 'rejected', 'cancelled') then raise exception 'a closed transfer is final' using errcode = '42501'; end if;
    if new.state is distinct from old.state and coalesce(current_setting('ada.domain_transfer', true), '') <> 'on' then raise exception 'a transfer changes state only through the transfer workflow' using errcode = '42501'; end if;
    return new;
  end if;
  select * into d from domains where id = new.domain_id for update;
  -- (validation that could reveal hidden records is in the AFTER trigger, which only runs for rows row security let through)
  new.state := 'requested'; new.status_before := d.status; new.requested_by := coalesce(new.requested_by, current_staff_id());
  new.requested_at := now(); new.decided_by := null; new.decided_at := null; new.closed_by := null; new.closed_at := null;
  return new;
end $$;
create trigger domain_transfers_before_trg before insert or update or delete on domain_transfers for each row execute function domain_transfers_before();

create function domain_transfers_after_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; v_type text; v_cur text;
begin
  select * into d from domains where id = new.domain_id;
  if new.status_before not in ('active', 'suspended') then raise exception 'only an active or suspended domain can be transferred (this one is %)', new.status_before using errcode = '23514'; end if;
  if new.kind = 'registrar' then
    select entity_type into v_type from entity_registry where institutional_id = new.to_entity_institutional_id;
    if v_type is distinct from 'supplier' then raise exception 'the receiving registrar must be a supplier' using errcode = '23514'; end if;
    select entity_institutional_id into v_cur from domain_relations where domain_id = d.id and relation = 'registrar' and valid_to is null;
    if v_cur = new.to_entity_institutional_id then raise exception 'that registrar already holds the domain' using errcode = '23514'; end if;
  elsif new.kind = 'ownership' then
    select entity_type into v_type from entity_registry where institutional_id = new.to_entity_institutional_id;
    if v_type not in ('external_organization', 'organization') then raise exception 'the new owner must be an organization' using errcode = '23514'; end if;
    if new.to_client_institutional_id is not null and (select entity_type from entity_registry where institutional_id = new.to_client_institutional_id) is distinct from 'client' then
      raise exception 'the new client must be a client record' using errcode = '23514';
    end if;
    select entity_institutional_id into v_cur from domain_relations where domain_id = d.id and relation = 'registrant' and valid_to is null;
    if v_cur = new.to_entity_institutional_id then raise exception 'that organization already owns the domain' using errcode = '23514'; end if;
  end if;
  perform set_config('ada.domain_transfer', 'on', true);
  update domains set status = 'transfer_pending' where id = d.id;
  perform set_config('ada.domain_transfer', 'off', true);
  perform approval_open('domain_transfer', 'domain_transfers', new.id, null, d.division_id, coalesce((approval_policy('domain_transfer', d.division_id, null)).required_permission, 'domains.approve'),
                        'Domain transfer (' || new.kind || ')', d.effective_classification);
  if d.effective_classification = 'internal' then
    perform notify_holders('domains.approve', d.division_id, 'approval.required', 'Domain transfer awaiting approval', null, 'domains', d.id, null);
  end if;
  perform domain_log(d.id, 'transfer_requested', jsonb_build_object('transfer', new.id, 'kind', new.kind, 'to', new.to_entity_institutional_id, 'to_client', new.to_client_institutional_id, 'reason', new.reason));
  return null;
end $$;
create trigger domain_transfers_after_insert_trg after insert on domain_transfers for each row execute function domain_transfers_after_insert();

-- ---------------------------------------------------------------------------
-- Commands: record, registration, renewal, lifecycle
-- ---------------------------------------------------------------------------
create function domain_create(p_name text, p_division uuid, p_purpose text default 'website', p_description text default null, p_classification data_classification default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text := lower(rtrim(btrim(coalesce(p_name, '')), '.')); v_id uuid; v_existing text; v_class data_classification := coalesce(p_classification, 'internal');
begin
  if current_staff_id() is null then raise exception 'only active staff create domain records' using errcode = '42501'; end if;
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('domains.create', p_division) then raise exception 'domains.create is required in that division' using errcode = '42501'; end if;
  if not domain_name_valid(v_name) then raise exception 'a valid domain name is required (for example example.com)' using errcode = '22023'; end if;
  if v_class <> 'internal' and not has_permission('records.classify') then raise exception 'records.classify is required to set a classification' using errcode = '42501'; end if;
  if not classification_visible(v_class) then raise exception 'you cannot create a record above your own classification clearance' using errcode = '42501'; end if;
  -- a discoverable record for this name already exists: say so (one record per name for ever); hidden ones are never mentioned
  if v_class in ('public', 'internal') then
    select domain_inst_id(d.id) into v_existing from domains d where d.name = v_name and d.effective_classification in ('public', 'internal');
    if v_existing is not null then return jsonb_build_object('status', 'exists', 'domain', v_existing, 'next', 'ask the owning division, or have it shared with you'); end if;
  end if;
  insert into domains (name, purpose, description, division_id, classification) values (v_name, p_purpose, p_description, p_division, v_class) returning id into v_id;
  perform domain_log(v_id, 'created', jsonb_build_object('purpose', p_purpose, 'division', p_division));
  return jsonb_build_object('status', 'created', 'id', v_id, 'domain', domain_inst_id(v_id), 'name', v_name, 'lifecycle', 'requested', 'origin_division_id', p_division);
end $$;

-- Recording a registration (new or adopted) is what makes a domain active; the registrar is the domain's current 'registrar' relation
create function domain_activate(p_domain uuid, p_period_start date, p_period_end date, p_reference text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  d := domain_require(p_domain, 'renew');
  if p_period_start is null or p_period_end is null then raise exception 'the registration period is required' using errcode = '22023'; end if;
  insert into domain_registrations (domain_id, kind, period_start, period_end, order_reference, note) values (d.id, 'registration', p_period_start, p_period_end, nullif(btrim(p_reference), ''), p_note);
  select * into d from domains where id = d.id;
  return jsonb_build_object('status', d.status, 'expires_on', d.expires_on);
end $$;

-- Renewal. Repeating the same order reference is a no-op (a double click or a retried request never double-renews).
create function domain_renew(p_domain uuid, p_years integer, p_reference text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; v_prev date; r domain_registrations%rowtype; v_ref text := nullif(btrim(p_reference), '');
begin
  d := domain_require(p_domain, 'renew');
  if p_years is null or p_years not between 1 and 10 then raise exception 'renew for 1 to 10 years' using errcode = '22023'; end if;
  if v_ref is not null then
    select * into r from domain_registrations where domain_id = d.id and lower(order_reference) = lower(v_ref);
    if found then return jsonb_build_object('status', d.status, 'expires_on', d.expires_on, 'period_start', r.period_start, 'period_end', r.period_end, 'duplicate', true); end if;
  end if;
  select max(period_end) into v_prev from domain_registrations where domain_id = d.id;
  if v_prev is null then raise exception 'this domain has no registration to renew: record the registration first' using errcode = '23514'; end if;
  insert into domain_registrations (domain_id, kind, period_start, period_end, order_reference, note)
  values (d.id, 'renewal', v_prev, (v_prev + make_interval(years => p_years))::date, v_ref, p_note) returning * into r;
  select * into d from domains where id = d.id;
  return jsonb_build_object('status', d.status, 'expires_on', d.expires_on, 'period_start', r.period_start, 'period_end', r.period_end, 'duplicate', false);
end $$;

create function domain_transition(p_domain uuid, p_to domain_status, p_reason text) returns domain_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  d := domain_require(p_domain, 'view');
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if p_to = 'suspended' and d.status = 'active' then perform domain_require(p_domain, 'suspend');
  elsif p_to = 'active' and d.status = 'suspended' then perform domain_require(p_domain, 'suspend');
  elsif p_to = 'retired' and d.status in ('requested', 'active', 'suspended', 'expired') then perform domain_require(p_domain, 'retire');
  else raise exception 'a domain cannot move from % to % this way (registration and renewal make it active, transfers use the transfer workflow)', d.status, p_to using errcode = '23514';
  end if;
  update domains set status = p_to where id = d.id;
  perform domain_log(d.id, 'status', jsonb_build_object('from', d.status, 'to', p_to, 'reason', p_reason));
  return p_to;
end $$;

create function domain_mark_expired(p_domain uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  d := domain_require(p_domain, 'renew');
  if d.status not in ('active', 'suspended') or d.expires_on is null or d.expires_on >= current_date then raise exception 'the domain has not expired' using errcode = '23514'; end if;
  update domains set status = 'expired' where id = d.id;
  perform domain_log(d.id, 'expired', jsonb_build_object('expires_on', d.expires_on, 'previous_status', d.status));
end $$;

create function domain_reregister(p_domain uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  d := domain_require(p_domain, 'retire');
  if d.status <> 'retired' then raise exception 'only a retired domain is re-registered' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update domains set status = 'requested' where id = d.id;
  perform domain_log(d.id, 'reregistered', jsonb_build_object('reason', p_reason, 'previous_expiry', d.expires_on));
end $$;

create function domain_set_division(p_domain uuid, p_division uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  d := domain_require(p_domain, 'update');
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('domains.update', p_division) and not has_permission('domains.create', p_division) then raise exception 'you cannot hand a domain to a division where you have no domain rights' using errcode = '42501'; end if;
  if p_division = d.division_id then raise exception 'the domain is already with that division' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  perform set_config('ada.domain_division', 'on', true);
  update domains set division_id = p_division where id = d.id;
  perform set_config('ada.domain_division', 'off', true);
  perform domain_log(d.id, 'division', jsonb_build_object('from', d.division_id, 'to', p_division, 'reason', p_reason));
end $$;

create function domain_update(p_domain uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; k text;
begin
  d := domain_require(p_domain, 'update');
  if p_changes is null or p_changes = '{}'::jsonb then raise exception 'nothing to change' using errcode = '23514'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if k not in ('purpose', 'description') then raise exception 'cannot change % here', k using errcode = '23514'; end if;
  end loop;
  update domains set purpose = case when p_changes ? 'purpose' then p_changes ->> 'purpose' else purpose end,
                     description = case when p_changes ? 'description' then p_changes ->> 'description' else description end where id = d.id;
  perform domain_log(d.id, 'metadata', jsonb_build_object('fields', (select jsonb_agg(x) from jsonb_object_keys(p_changes) x)));
end $$;

create function domain_set_classification(p_domain uuid, p_class data_classification, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; e domains%rowtype;
begin
  d := domain_require(p_domain, 'update');
  if not has_permission('records.classify') then raise exception 'records.classify is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update domains set classification = p_class where id = d.id returning * into e;
  if not classification_visible(e.effective_classification) then raise exception 'you cannot classify a domain above your own clearance' using errcode = '42501'; end if;
  perform domain_log(d.id, 'classification', jsonb_build_object('from', d.classification, 'to', p_class, 'reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Transfers
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER: the insert runs under the caller's row security, so a target they cannot see is refused exactly like one that does not exist
create function domain_transfer_request(p_domain uuid, p_kind text, p_to text default null, p_to_client text default null, p_destination_note text default null, p_reason text default null) returns uuid
language plpgsql set search_path = public, pg_temp as $$
declare v_to text; v_client text; v_id uuid;
begin
  if not domain_can(p_domain, 'view') then raise exception 'domain not found' using errcode = 'P0002'; end if;
  if not domain_can(p_domain, 'transfer') then raise exception 'you are not permitted to transfer this domain' using errcode = '42501'; end if;
  if p_to is not null then
    select institutional_id into v_to from entity_registry where institutional_id = upper(btrim(p_to)) or ada_id = btrim(p_to);
    if v_to is null then raise exception 'entity not found' using errcode = 'P0002'; end if;
  end if;
  if p_to_client is not null then
    select institutional_id into v_client from entity_registry where institutional_id = upper(btrim(p_to_client)) or ada_id = btrim(p_to_client);
    if v_client is null then raise exception 'entity not found' using errcode = 'P0002'; end if;
  end if;
  insert into domain_transfers (domain_id, kind, to_entity_institutional_id, to_client_institutional_id, destination_note, reason)
  values (p_domain, p_kind, v_to, v_client, p_destination_note, coalesce(p_reason, '')) returning id into v_id;
  return v_id;
end $$;

create function domain_transfer_decide(p_transfer uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare x domain_transfers%rowtype; d domains%rowtype; v_gate text;
begin
  select * into x from domain_transfers where id = p_transfer;
  if not found then raise exception 'domain not found' using errcode = 'P0002'; end if;
  d := domain_require(x.domain_id, 'approve');
  if x.state <> 'requested' then raise exception 'this transfer is already %', x.state using errcode = '23514'; end if;
  perform set_config('ada.domain_transfer', 'on', true);
  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a transfer' using errcode = '23514'; end if;
    perform approval_gate('domain_transfer', 'domain_transfers', x.id, d.division_id, null, x.requested_by, 'domains.approve', false, p_note);
    update domain_transfers set state = 'rejected', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note, closed_by = current_staff_id(), closed_at = now(), closing_note = 'rejected' where id = x.id;
    update domains set status = x.status_before where id = d.id;
    perform approval_close('domain_transfers', x.id, 'rejected', p_note);
    perform set_config('ada.domain_transfer', 'off', true);
    perform domain_log(d.id, 'transfer_decided', jsonb_build_object('transfer', x.id, 'approved', false));
    return 'rejected';
  end if;
  v_gate := approval_gate('domain_transfer', 'domain_transfers', x.id, d.division_id, null, x.requested_by, 'domains.approve', true, p_note);
  if v_gate = 'pending' then perform set_config('ada.domain_transfer', 'off', true); return 'pending'; end if;
  update domain_transfers set state = 'approved', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = x.id;
  perform approval_close('domain_transfers', x.id, 'approved', p_note);
  perform set_config('ada.domain_transfer', 'off', true);
  perform domain_log(d.id, 'transfer_decided', jsonb_build_object('transfer', x.id, 'approved', true));
  return 'approved';
end $$;

create function domain_transfer_complete(p_transfer uuid, p_reference text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x domain_transfers%rowtype; d domains%rowtype; r text;
begin
  select * into x from domain_transfers where id = p_transfer;
  if not found then raise exception 'domain not found' using errcode = 'P0002'; end if;
  d := domain_require(x.domain_id, 'transfer');
  if x.state <> 'approved' then raise exception 'only an approved transfer can be completed (this one is %)', x.state using errcode = '23514'; end if;
  perform set_config('ada.domain_transfer', 'on', true);
  if x.kind = 'registrar' then
    perform domain_relation_apply(d.id, 'registrar', x.to_entity_institutional_id, 'transfer ' || x.id);
    update domains set status = x.status_before where id = d.id;
  elsif x.kind = 'ownership' then
    perform domain_relation_apply(d.id, 'registrant', x.to_entity_institutional_id, 'transfer ' || x.id);
    perform domain_relation_apply(d.id, 'client', x.to_client_institutional_id, 'ownership transferred (' || x.id || ')');
    update domains set status = x.status_before where id = d.id;
  else
    foreach r in array array['registrant', 'client', 'project', 'website', 'registrar'] loop
      perform domain_relation_apply(d.id, r, null, 'transferred out of ADA management (' || x.id || ')');
    end loop;
    update domains set status = 'retired' where id = d.id;
  end if;
  update domain_transfers set state = 'completed', closed_by = current_staff_id(), closed_at = now(), closing_note = p_reference where id = x.id;
  perform set_config('ada.domain_transfer', 'off', true);
  perform domain_log(d.id, 'transfer_completed', jsonb_build_object('transfer', x.id, 'kind', x.kind, 'reference', p_reference));
end $$;

create function domain_transfer_cancel(p_transfer uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x domain_transfers%rowtype; d domains%rowtype;
begin
  select * into x from domain_transfers where id = p_transfer;
  if not found then raise exception 'domain not found' using errcode = 'P0002'; end if;
  d := domain_require(x.domain_id, 'transfer');
  if x.state not in ('requested', 'approved') then raise exception 'this transfer is already %', x.state using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  perform set_config('ada.domain_transfer', 'on', true);
  update domain_transfers set state = 'cancelled', closed_by = current_staff_id(), closed_at = now(), closing_note = p_reason where id = x.id;
  update domains set status = x.status_before where id = d.id;
  if x.state = 'requested' then perform approval_close('domain_transfers', x.id, 'cancelled', p_reason); end if;
  perform set_config('ada.domain_transfer', 'off', true);
  perform domain_log(d.id, 'transfer_cancelled', jsonb_build_object('transfer', x.id, 'reason', p_reason));
end $$;

create function domain_review_resolve(p_review uuid, p_note text, p_retire uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m domain_reviews%rowtype;
begin
  if not has_permission('matching.review') then raise exception 'matching.review is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required' using errcode = '23514'; end if;
  select * into m from domain_reviews where id = p_review and status = 'open' for update;
  if not found then raise exception 'review not found or already resolved' using errcode = 'P0002'; end if;
  if p_retire is not null then
    if p_retire not in (m.left_domain_id, m.right_domain_id) then raise exception 'name one of the two records under review' using errcode = '23514'; end if;
    update domains set status = 'retired' where id = p_retire and status in ('requested', 'active', 'suspended', 'expired');
    perform domain_log(p_retire, 'status', jsonb_build_object('to', 'retired', 'reason', 'duplicate record: ' || p_note));
  end if;
  update domain_reviews set status = 'resolved', resolved_by = current_staff_id(), resolved_at = now(), resolution_note = p_note where id = m.id;
end $$;

-- ---------------------------------------------------------------------------
-- The sweep: explicit, recorded, never destructive (service role)
-- ---------------------------------------------------------------------------
create function domain_expiry_sweep(p_notice_days integer default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d domains%rowtype; n_expired integer := 0; n_notices integer := 0;
begin
  for d in select * from domains where status in ('active', 'suspended') and expires_on < current_date order by id for update skip locked loop
    update domains set status = 'expired' where id = d.id;
    insert into domain_events (domain_id, kind, actor_staff_id, detail) values (d.id, 'expired', null, jsonb_build_object('expires_on', d.expires_on, 'previous_status', d.status, 'by', 'sweep'));
    n_expired := n_expired + 1;
  end loop;
  for d in select * from domains where status = 'active' and expires_on between current_date and current_date + p_notice_days order by id for update skip locked loop
    if not exists (select 1 from domain_events e where e.domain_id = d.id and e.kind = 'expiry_notice' and e.detail ->> 'expires_on' = d.expires_on::text) then
      insert into domain_events (domain_id, kind, actor_staff_id, detail) values (d.id, 'expiry_notice', null, jsonb_build_object('expires_on', d.expires_on));
      if d.effective_classification = 'internal' then
        perform notify_holders('domains.renew', d.division_id, 'domain.expiring', 'A domain expires on ' || d.expires_on, null, 'domains', d.id, null);
      end if;
      n_notices := n_notices + 1;
    end if;
  end loop;
  return jsonb_build_object('expired', n_expired, 'notices', n_notices);
end $$;
revoke execute on function domain_expiry_sweep(integer) from public, anon, authenticated;
grant execute on function domain_expiry_sweep(integer) to service_role;

-- ---------------------------------------------------------------------------
-- Derived views, retrieval, 360
-- ---------------------------------------------------------------------------
create view domain_expiry_status with (security_invoker = true) as
  select d.id as domain_id, d.status, d.expires_on, (d.expires_on - current_date) as days_to_expiry,
         case when d.status in ('requested', 'retired') or d.expires_on is null then null
              when d.expires_on < current_date then 'lapsed' when d.expires_on <= current_date + 30 then 'due_soon' else 'ok' end as expiry_state
  from domains d;
comment on view domain_expiry_status is 'Purpose: derived expiry position of each domain (ok / due_soon / lapsed). Row access follows the domain. Nothing is stored.';

-- Hostnames of connected websites resolved to the registered domain they sit under (derived; websites.domain is unchanged and nothing is copied)
create view website_hostname_domains with (security_invoker = true) as
  select w.id as website_id, w.domain as hostname, d.id as domain_id
  from websites w
  join lateral (select x.id from domains x where lower(w.domain) = x.name or lower(w.domain) like '%.' || x.name order by length(x.name) desc limit 1) d on true;
comment on view website_hostname_domains is 'Purpose: which registered domain a connected website''s hostname belongs to (longest matching suffix). Derived on read; visible only where both the website and the domain are visible. Explicit website relations in domain_relations are the authoritative link.';

create function domains_of(p_ids text[], p_as_of timestamptz default null) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.name), '[]'::jsonb) from (
    select d.name,
           jsonb_build_object('domain', (select er.institutional_id from entity_registry er where er.table_name = 'domains' and er.entity_id = d.id), 'name', d.name, 'status', d.status, 'expires_on', d.expires_on,
             'relations', (select jsonb_agg(jsonb_build_object('relation', dr.relation, 'entity', dr.entity_institutional_id, 'since', dr.valid_from, 'until', dr.valid_to) order by dr.valid_from)
                             from domain_relations dr where dr.domain_id = d.id and dr.entity_institutional_id = any (p_ids)
                              and (case when p_as_of is null then dr.valid_to is null else dr.valid_from <= p_as_of and (dr.valid_to is null or dr.valid_to > p_as_of) end))) as j
      from domains d
     where exists (select 1 from domain_relations dr where dr.domain_id = d.id and dr.entity_institutional_id = any (p_ids)
                    and (case when p_as_of is null then dr.valid_to is null else dr.valid_from <= p_as_of and (dr.valid_to is null or dr.valid_to > p_as_of) end))) x
$$;

create function domains_for_entity(p_entity text, p_as_of timestamptz default null, p_include_children boolean default false) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare r entity_registry%rowtype;
begin
  select * into r from entity_registry where institutional_id = upper(btrim(coalesce(p_entity, ''))) or ada_id = btrim(coalesce(p_entity, ''));
  if not found then perform security_note_lookup(p_entity, 'domains_for_entity'); return null; end if;
  return domains_of(case when p_include_children then document_family_ids(r.institutional_id) else array[r.institutional_id] end, p_as_of);
end $$;

-- Resolve a name to its record, as the caller may know it. Hidden and missing are the same: nothing (and a lookup event).
create function domain_lookup(p_name text) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare v_name text := lower(rtrim(btrim(coalesce(p_name, '')), '.')); d domains%rowtype;
begin
  select * into d from domains where name = v_name order by (effective_classification in ('public', 'internal')) desc limit 1;
  if not found then perform security_note_lookup(v_name, 'domain.lookup'); return null; end if;
  return jsonb_build_object('institutional_id', (select institutional_id from entity_registry where table_name = 'domains' and entity_id = d.id), 'name', d.name, 'status', d.status, 'id', d.id);
end $$;

create function domain_360(p_domain uuid) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  select * into d from domains where id = p_domain;
  if not found then perform domain_note_denied(p_domain, 'view'); return null; end if;
  return jsonb_build_object(
    'identity', (select jsonb_build_object('institutional_id', er.institutional_id, 'entity_type', er.entity_type, 'origin_division_id', er.origin_division_id, 'origin_year', er.origin_year,
                          'current_division_id', er.current_division_id, 'status', er.status) from entity_registry er where er.table_name = 'domains' and er.entity_id = d.id),
    'record', jsonb_build_object('name', d.name, 'purpose', d.purpose, 'description', d.description, 'status', d.status, 'classification', d.effective_classification, 'created_at', d.created_at, 'retired_at', d.retired_at),
    'lifecycle', jsonb_build_object('expires_on', d.expires_on, 'expiry', (select to_jsonb(x) - 'domain_id' - 'status' - 'expires_on' from domain_expiry_status x where x.domain_id = d.id)),
    'registrations', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'period_start', r.period_start, 'period_end', r.period_end, 'order_reference', r.order_reference,
                          'registrar', r.registrar_institutional_id, 'recorded_at', r.recorded_at, 'note', r.note) order by r.period_start) from domain_registrations r where r.domain_id = d.id), '[]'),
    'relations', coalesce((select jsonb_agg(jsonb_build_object('relation', dr.relation, 'entity', dr.entity_institutional_id, 'entity_type', er.entity_type, 'since', dr.valid_from, 'until', dr.valid_to,
                          'reason', dr.reason, 'end_reason', dr.end_reason) order by dr.valid_from)
                          from domain_relations dr join entity_registry er on er.institutional_id = dr.entity_institutional_id where dr.domain_id = d.id), '[]'),
    'transfers', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'state', t.state, 'to', t.to_entity_institutional_id, 'requested_at', t.requested_at, 'closed_at', t.closed_at) order by t.requested_at)
                          from domain_transfers t where t.domain_id = d.id), '[]'),
    'websites', coalesce((select jsonb_agg(jsonb_build_object('website', h.website_id, 'hostname', h.hostname)) from website_hostname_domains h where h.domain_id = d.id), '[]'),
    'access', jsonb_build_object('can_update', domain_can(d.id, 'update'), 'can_renew', domain_can(d.id, 'renew'), 'can_suspend', domain_can(d.id, 'suspend'), 'can_transfer', domain_can(d.id, 'transfer'),
                          'can_approve', domain_can(d.id, 'approve'), 'can_retire', domain_can(d.id, 'retire')),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'kind', e.kind, 'by', (select ada_id from staff where id = e.actor_staff_id), 'detail', e.detail) order by e.id desc)
                          from (select * from domain_events where domain_id = d.id order by id desc limit 50) e), '[]'));
end $$;

-- ---------------------------------------------------------------------------
-- Domains in the 360 views of the entities they relate to
-- ---------------------------------------------------------------------------
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
    'domains', domains_of(document_family_ids((select institutional_id from entity_registry where table_name = 'clients' and entity_id = p_client))),
    'pending', jsonb_build_array('communications'));
end $$;

create or replace function project_360(p_project uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare p record;
begin
  select pr.*, cl.name as client_name, cl.ada_id as client_ada_id, d.name as division_name, d.key as division_key into p
    from projects pr join clients cl on cl.id = pr.client_id join divisions d on d.id = pr.lead_division_id where pr.id = p_project;
  if not found then return null; end if;
  return jsonb_build_object(
    'overview', jsonb_build_object('id', p.ada_id, 'name', p.name, 'description', p.description, 'status', p.status, 'priority', p.priority,
                 'type', p.project_type, 'start_date', p.start_date, 'due_date', p.due_date, 'completed_at', p.completed_at, 'division', p.division_key),
    'client', jsonb_build_object('id', p.client_ada_id, 'name', p.client_name),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('contact', cc.ada_id, 'name', pe.full_name, 'email', pe.email, 'role', pc.role))
               from project_contacts pc join client_contacts cc on cc.id = pc.contact_id join people pe on pe.id = cc.person_id where pc.project_id = p_project), '[]'),
    'divisions', coalesce((select jsonb_agg(d.key order by d.sort_order) from project_divisions pd join divisions d on d.id = pd.division_id where pd.project_id = p_project), '[]'),
    'services', coalesce((select jsonb_agg(jsonb_build_object('service', s.name, 'service_id', s.ada_id, 'quantity', ps.quantity, 'unit_price', ps.unit_price,
                 'discount', ps.discount_amount, 'total', ps.line_total, 'currency', ps.currency, 'catalogue_price_used', ps.price_id is not null,
                 'override_reason', ps.price_override_reason, 'quote', (select q.ada_id from quote_lines l join quotes q on q.id = l.quote_id where l.id = ps.quote_line_id)) order by s.name)
               from project_services ps join services s on s.id = ps.service_id where ps.project_id = p_project), '[]'),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total, 'lead', (select ada_id from leads where id = q.lead_id))) from quotes q where q.project_id = p_project), '[]'),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'role', pm.member_role)) from project_members pm join staff s on s.id = pm.staff_id where pm.project_id = p_project), '[]'),
    'milestones', coalesce((select jsonb_agg(jsonb_build_object('title', m.title, 'due_date', m.due_date, 'status', m.status) order by m.sort_order, m.due_date) from milestones m where m.project_id = p_project), '[]'),
    'tasks', jsonb_build_object(
      'open', (select count(*) from tasks where project_id = p_project and status in ('todo', 'in_progress', 'blocked')),
      'done', (select count(*) from tasks where project_id = p_project and status = 'done'),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', t.ada_id, 'title', t.title, 'status', t.status, 'due_date', t.due_date, 'assignee', (select full_name from staff where id = t.assignee_id)) order by t.created_at)
                 from tasks t where t.project_id = p_project), '[]')),
    'budget', (select to_jsonb(f) - 'project_id' from project_financials f where f.project_id = p_project),     -- empty unless finance.view
    'portfolio', (select jsonb_build_object('id', e.ada_id, 'status', e.status, 'consent', e.client_consent) from portfolio_entries e where e.project_id = p_project),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'projects' and record_id = p_project) order by id desc limit 25) a), '[]'),
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'title', c.title, 'status', c.status, 'total', t.total, 'currency', c.currency) order by c.created_at)
               from contract_projects cp join contracts c on c.id = cp.contract_id left join lateral contract_terms(c.id) t on true where cp.project_id = p_project), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.ada_id, 'status', i.status, 'total', i.total, 'currency', i.currency, 'due_date', i.due_date,
                 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id)) order by i.created_at)
               from invoices i where i.project_id = p_project
                  or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)), '[]'),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition) order by ast.created_at) from assets ast where ast.project_id = p_project), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.project_id = p_project), '[]'),
    'documents', documents_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'domains', domains_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'pending', jsonb_build_array('expenses', 'websites', 'deliverables'));
end $$;

create or replace function organization_360(p_org uuid) returns jsonb
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
    'domains', domains_of(document_family_ids(v_inst)),
    'open_reviews', case when has_permission('matching.review') then (select count(*) from organization_reviews r where r.status = 'open' and o.id in (r.left_org_id, r.right_org_id)) end);
end $$;


-- ---------------------------------------------------------------------------
-- Recovery manifest and ledger consistency
-- ---------------------------------------------------------------------------
create function domain_ledger_drift() returns table (domain_id uuid, expires_on date, ledger_end date)
language sql stable security definer set search_path = public, pg_temp as $$
  select d.id, d.expires_on, (select max(period_end) from domain_registrations r where r.domain_id = d.id)
    from domains d where d.expires_on is distinct from (select max(period_end) from domain_registrations r where r.domain_id = d.id)
$$;
revoke execute on function domain_ledger_drift() from public, anon, authenticated;
grant execute on function domain_ledger_drift() to service_role;

create function domain_backup_manifest() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'domains', (select count(*) from domains), 'relations', (select count(*) from domain_relations), 'registrations', (select count(*) from domain_registrations),
    'transfers', (select count(*) from domain_transfers), 'events', (select count(*) from domain_events), 'reviews', (select count(*) from domain_reviews), 'ledger_drift', (select count(*) from domain_ledger_drift()),
    'domains_md5', (select md5(coalesce(string_agg(concat_ws('|', r.institutional_id, d.name, d.status, d.expires_on, d.division_id, d.classification, d.effective_classification, d.purpose), ';' order by r.institutional_id), ''))
                      from domains d join entity_registry r on r.table_name = 'domains' and r.entity_id = d.id),
    'relations_md5', (select md5(coalesce(string_agg(concat_ws('|', domain_id, relation, entity_institutional_id, valid_from, valid_to), ';' order by domain_id, relation, valid_from, entity_institutional_id), '')) from domain_relations),
    'registrations_md5', (select md5(coalesce(string_agg(concat_ws('|', domain_id, kind, period_start, period_end, order_reference, registrar_institutional_id), ';' order by domain_id, period_start), '')) from domain_registrations),
    'transfers_md5', (select md5(coalesce(string_agg(concat_ws('|', domain_id, kind, state, to_entity_institutional_id), ';' order by domain_id, requested_at, id), '')) from domain_transfers),
    'events_md5', (select md5(coalesce(string_agg(concat_ws('|', domain_id, kind, actor_staff_id), ';' order by id), '')) from domain_events),
    'registry_md5', (select md5(coalesce(string_agg(concat_ws('|', institutional_id, entity_id, origin_division_id, origin_year, classification, status), ';' order by institutional_id), '')) from entity_registry where table_name = 'domains'))
$$;
revoke execute on function domain_backup_manifest() from public, anon, authenticated;
grant execute on function domain_backup_manifest() to service_role;

-- ---------------------------------------------------------------------------
-- Approval policy, grants, row-level security, audit
-- ---------------------------------------------------------------------------
insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note) values
  ('domain_transfer', 'domains.approve', false, true, 1, 'default');

alter table domains enable row level security;
alter table domain_relations enable row level security;
alter table domain_registrations enable row level security;
alter table domain_transfers enable row level security;
alter table domain_events enable row level security;
alter table domain_reviews enable row level security;
revoke all on domains, domain_relations, domain_registrations, domain_transfers, domain_events, domain_reviews, domain_expiry_status, website_hostname_domains from anon, authenticated;
grant select on domains, domain_relations, domain_registrations, domain_transfers, domain_events, domain_reviews, domain_expiry_status, website_hostname_domains to authenticated;
grant insert (domain_id, relation, entity_institutional_id, reason) on domain_relations to authenticated;
grant insert (domain_id, kind, to_entity_institutional_id, to_client_institutional_id, destination_note, reason) on domain_transfers to authenticated;

create policy domains_select on domains for select to authenticated using (domain_can_row(id, division_id, effective_classification, client_deleted, status, 'view'));
create policy domain_relations_select on domain_relations for select to authenticated
  using (domain_can(domain_id, 'view') and exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id));
create policy domain_relations_insert on domain_relations for insert to authenticated
  with check (domain_can(domain_id, 'update') and exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id));
create policy domain_registrations_select on domain_registrations for select to authenticated using (domain_can(domain_id, 'view'));
create policy domain_transfers_select on domain_transfers for select to authenticated
  using (domain_can(domain_id, 'view') and (has_permission_anywhere('domains.transfer') or has_permission_anywhere('domains.approve')));
create policy domain_transfers_insert on domain_transfers for insert to authenticated
  with check (domain_can(domain_id, 'transfer')
              and (to_entity_institutional_id is null or exists (select 1 from entity_registry r where r.institutional_id = to_entity_institutional_id))
              and (to_client_institutional_id is null or exists (select 1 from entity_registry r where r.institutional_id = to_client_institutional_id)));
create policy domain_events_select on domain_events for select to authenticated using (domain_can(domain_id, 'view'));
create policy domain_reviews_select on domain_reviews for select to authenticated using (has_permission('matching.review'));

revoke execute on function domain_can_row(uuid, uuid, data_classification, boolean, domain_status, text), domain_can(uuid, text), domain_create(text, uuid, text, text, data_classification),
  domain_activate(uuid, date, date, text, text), domain_renew(uuid, integer, text, text), domain_transition(uuid, domain_status, text), domain_mark_expired(uuid), domain_reregister(uuid, text),
  domain_set_division(uuid, uuid, text), domain_update(uuid, jsonb), domain_set_classification(uuid, data_classification, text), domain_relation_end(uuid, text),
  domain_transfer_request(uuid, text, text, text, text, text), domain_transfer_decide(uuid, boolean, text), domain_transfer_complete(uuid, text), domain_transfer_cancel(uuid, text),
  domain_review_resolve(uuid, text, uuid), domains_of(text[], timestamptz), domains_for_entity(text, timestamptz, boolean), domain_lookup(text), domain_360(uuid), domain_name_valid(text) from public, anon;
grant execute on function domain_can_row(uuid, uuid, data_classification, boolean, domain_status, text), domain_can(uuid, text), domain_create(text, uuid, text, text, data_classification),
  domain_activate(uuid, date, date, text, text), domain_renew(uuid, integer, text, text), domain_transition(uuid, domain_status, text), domain_mark_expired(uuid), domain_reregister(uuid, text),
  domain_set_division(uuid, uuid, text), domain_update(uuid, jsonb), domain_set_classification(uuid, data_classification, text), domain_relation_end(uuid, text),
  domain_transfer_request(uuid, text, text, text, text, text), domain_transfer_decide(uuid, boolean, text), domain_transfer_complete(uuid, text), domain_transfer_cancel(uuid, text),
  domain_review_resolve(uuid, text, uuid), domains_of(text[], timestamptz), domains_for_entity(text, timestamptz, boolean), domain_lookup(text), domain_360(uuid) to authenticated;

do $$ begin
  perform attach_audit('domains'); perform attach_audit('domain_relations'); perform attach_audit('domain_registrations'); perform attach_audit('domain_transfers'); perform attach_audit('domain_reviews');
end $$;

-- The audit log must not become a side channel for domains the reader cannot see
create function audit_domain_visible(p_table text, p_record uuid, p_new jsonb, p_old jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_table = 'domains' then domain_can(p_record, 'view')
    when p_table in ('domain_relations', 'domain_registrations', 'domain_transfers') then domain_can(nullif(coalesce(p_new, p_old) ->> 'domain_id', '')::uuid, 'view')
    when p_table = 'domain_reviews' then has_permission('matching.review')
    else true end
$$;
revoke execute on function audit_domain_visible(text, uuid, jsonb, jsonb) from public, anon;
grant execute on function audit_domain_visible(text, uuid, jsonb, jsonb) to authenticated;
drop policy audit_select on audit_log;
create policy audit_select on audit_log for select to authenticated
  using (has_permission('audit.view') and audit_document_visible(table_name, record_id, new_data, old_data) and audit_domain_visible(table_name, record_id, new_data, old_data));
