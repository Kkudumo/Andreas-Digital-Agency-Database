-- 0009_platform: publication states, public division fields, position headcount, website registry
-- (hashed API keys), event outbox + webhook subscriptions, in-app notifications, assignment history.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;   -- Supabase already keeps extensions in this schema

create type publication_state as enum ('draft', 'pending_approval', 'approved', 'published', 'unpublished', 'archived');

insert into entity_types (key, prefix, description) values
  ('person',      'PER', 'A person known to ADA (applicant, future or former staff)'),
  ('vacancy',     'VAC', 'An opening for a position'),
  ('application', 'APP', 'A person''s application to a vacancy'),
  ('website',     'WEB', 'A connected ADA website or application'),
  ('profile',     'PRF', 'Public staff profile');

-- ---------------------------------------------------------------------------
-- Divisions: explicit public state; only published divisions reach the public API.
-- ---------------------------------------------------------------------------
alter table divisions
  add column public_state publication_state not null default 'draft',
  add column public_description text;
update divisions set public_state = 'published', public_description = description where kind = 'service';
comment on column divisions.public_state is 'Only divisions with state published are exposed by the public API. Internal units (Management, Administration, Finance) stay draft.';

-- ---------------------------------------------------------------------------
-- Positions: headcount + dedicated permission
-- ---------------------------------------------------------------------------
alter table positions add column headcount integer not null default 1 check (headcount >= 1);
comment on column positions.headcount is 'How many people ADA wants in this position. Availability = headcount minus current holders (see position_availability).';
drop policy positions_insert on positions;
drop policy positions_update on positions;
create policy positions_insert on positions for insert to authenticated with check (has_permission('positions.manage'));
create policy positions_update on positions for update to authenticated
  using (has_permission('positions.manage')) with check (has_permission('positions.manage'));

-- ---------------------------------------------------------------------------
-- Website registry
-- ---------------------------------------------------------------------------
create type website_environment as enum ('development', 'staging', 'production');
create type website_status      as enum ('planned', 'active', 'suspended', 'retired');

create table websites (
  id             uuid primary key default gen_random_uuid(),
  ada_id         text not null unique,
  name           text not null check (btrim(name) <> ''),
  domain         text not null check (domain ~* '^[a-z0-9.-]+$'),
  division_id    uuid references divisions (id),
  environment    website_environment not null default 'production',
  status         website_status not null default 'planned',
  is_public      boolean not null default true,
  capabilities   text[] not null default '{}'
                 check (capabilities <@ array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read',
                                              'applications.submit', 'services.read', 'portfolio.read', 'contact.read', 'leads.submit']),
  api_key_prefix text,
  api_key_hash   text unique,
  key_issued_at  timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (domain, environment)
);
comment on table websites is 'Purpose: registry of connected websites/apps; the API identity and capabilities of each source of incoming data. Only a hash of the API key is stored. [class: restricted]';
comment on column websites.api_key_hash is 'SHA-256 of the API key. The key itself is shown once at issue time and never stored.';
do $$ begin perform attach_ada_id('websites', 'website'); end $$;
create trigger websites_updated before update on websites for each row execute function set_updated_at();

-- Issues (or rotates) a website's API key. Returns the plaintext key exactly once.
create function issue_website_key(p_website_id uuid) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_key text := 'ada_' || encode(gen_random_bytes(24), 'hex');
begin
  if not has_permission('websites.manage') then
    raise exception 'websites.manage is required' using errcode = '42501';
  end if;
  update websites
     set api_key_prefix = left(v_key, 8), api_key_hash = encode(digest(v_key, 'sha256'), 'hex'), key_issued_at = now()
   where id = p_website_id and status <> 'retired';
  if not found then
    raise exception 'website not found or retired' using errcode = 'P0002';
  end if;
  return v_key;
end $$;

-- Resolves a website API key HASH (sha256 hex, computed by the API server so the database never sees
-- the plaintext key) to an active website. Used only by the public API functions.
create function site_from_key_hash(p_key_hash text) returns websites
language sql stable security definer set search_path = public, pg_temp as $$
  select w.* from websites w where w.api_key_hash = p_key_hash and w.status = 'active'
$$;

alter table websites enable row level security;
revoke all on websites from anon, authenticated;
grant select (id, ada_id, name, domain, division_id, environment, status, is_public, capabilities, api_key_prefix, key_issued_at, created_at, updated_at)
  on websites to authenticated;
grant insert (name, domain, division_id, environment, status, is_public, capabilities) on websites to authenticated;
grant update (name, domain, division_id, environment, status, is_public, capabilities) on websites to authenticated;
create policy websites_select on websites for select to authenticated using (has_permission('websites.view'));
create policy websites_insert on websites for insert to authenticated with check (has_permission('websites.manage'));
create policy websites_update on websites for update to authenticated
  using (has_permission('websites.manage')) with check (has_permission('websites.manage'));

-- ---------------------------------------------------------------------------
-- Events outbox + webhook subscriptions (payloads carry identifiers and states only, never personal data)
-- ---------------------------------------------------------------------------
create table events (
  id             bigint generated always as identity primary key,
  occurred_at    timestamptz not null default now(),
  event_type     text not null check (event_type ~ '^[a-z_]+\.[a-z_]+$'),
  entity_table   text,
  entity_id      uuid,
  entity_ada_id  text,
  payload        jsonb not null default '{}',
  actor_staff_id uuid
);
create index events_type_idx on events (event_type, occurred_at desc);
comment on table events is 'Purpose: outbox of business events (vacancy.published, staff.deactivated, ...) for cache invalidation and webhooks. Payloads are identifiers and states only. [class: restricted]';

create table event_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  website_id  uuid not null references websites (id) on delete cascade,
  url         text not null check (url ~ '^https://'),
  secret_ref  text,
  event_types text[] not null default array['*'],
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table event_subscriptions is 'Purpose: where to notify a website when events occur. secret_ref names a secret in the secret manager; the secret is never stored here. [class: restricted]';
create trigger event_subscriptions_updated before update on event_subscriptions for each row execute function set_updated_at();

create table event_deliveries (
  id              bigint generated always as identity primary key,
  event_id        bigint not null references events (id) on delete cascade,
  subscription_id uuid not null references event_subscriptions (id) on delete cascade,
  status          text not null default 'pending' check (status in ('pending', 'delivered', 'failed')),
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error      text,
  delivered_at    timestamptz,
  unique (event_id, subscription_id)
);
create index event_deliveries_pending_idx on event_deliveries (next_attempt_at) where status = 'pending';

create function emit_event(p_type text, p_table text, p_id uuid, p_ada_id text, p_payload jsonb default '{}') returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_event bigint;
begin
  insert into events (event_type, entity_table, entity_id, entity_ada_id, payload, actor_staff_id)
  values (p_type, p_table, p_id, p_ada_id, coalesce(p_payload, '{}'), current_staff_id())
  returning id into v_event;
  insert into event_deliveries (event_id, subscription_id)
  select v_event, s.id from event_subscriptions s join websites w on w.id = s.website_id
  where s.is_active and w.status = 'active' and (s.event_types @> array['*'] or s.event_types @> array[p_type]);
  return v_event;
end $$;
revoke execute on function emit_event(text, text, uuid, text, jsonb) from public, anon, authenticated;

create function websites_registered() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform emit_event('website.registered', 'websites', new.id, new.ada_id, jsonb_build_object('environment', new.environment));
  return null;
end $$;
create trigger websites_registered_trg after insert on websites for each row execute function websites_registered();

alter table events              enable row level security;
alter table event_subscriptions enable row level security;
alter table event_deliveries    enable row level security;
revoke all on events, event_subscriptions, event_deliveries from anon, authenticated;
grant select on events, event_deliveries to authenticated;
grant select, insert, update on event_subscriptions to authenticated;
create policy events_select on events for select to authenticated using (has_permission('audit.view') or has_permission('websites.manage'));
create policy event_deliveries_select on event_deliveries for select to authenticated using (has_permission('audit.view') or has_permission('websites.manage'));
create policy event_subscriptions_select on event_subscriptions for select to authenticated using (has_permission('websites.view'));
create policy event_subscriptions_insert on event_subscriptions for insert to authenticated with check (has_permission('websites.manage'));
create policy event_subscriptions_update on event_subscriptions for update to authenticated
  using (has_permission('websites.manage')) with check (has_permission('websites.manage'));

-- ---------------------------------------------------------------------------
-- Notifications (in-app now; email/other channels consume the same rows later)
-- ---------------------------------------------------------------------------
create table notifications (
  id                 uuid primary key default gen_random_uuid(),
  recipient_staff_id uuid not null references staff (id) on delete cascade,
  type               text not null,
  title              text not null,
  body               text,
  entity_table       text,
  entity_id          uuid,
  entity_ada_id      text,
  created_at         timestamptz not null default now(),
  read_at            timestamptz
);
create index notifications_recipient_idx on notifications (recipient_staff_id, created_at desc);
comment on table notifications is 'Purpose: central in-app notification inbox. Each row is addressed to one staff member. [class: internal]';

-- Notifies every active staff member holding a permission (org-wide, or scoped to p_division).
create function notify_holders(p_permission text, p_division uuid, p_type text, p_title text, p_body text,
                               p_table text, p_id uuid, p_ada_id text) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  insert into notifications (recipient_staff_id, type, title, body, entity_table, entity_id, entity_ada_id)
  select distinct s.id, p_type, p_title, p_body, p_table, p_id, p_ada_id
  from staff s
  join staff_roles sr on sr.staff_id = s.id
  join role_permissions rp on rp.role_id = sr.role_id
  join permissions p on p.id = rp.permission_id
  where p.key = p_permission and (sr.division_id is null or sr.division_id = p_division)
    and s.account_status = 'active' and s.deleted_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function notify_holders(text, uuid, text, text, text, text, uuid, text) from public, anon, authenticated;

alter table notifications enable row level security;
revoke all on notifications from anon, authenticated;
grant select on notifications to authenticated;
grant update (read_at) on notifications to authenticated;
create policy notifications_select on notifications for select to authenticated using (recipient_staff_id = current_staff_id());
create policy notifications_update on notifications for update to authenticated
  using (recipient_staff_id = current_staff_id()) with check (recipient_staff_id = current_staff_id());

-- ---------------------------------------------------------------------------
-- Staff assignment history (position / division over time)
-- ---------------------------------------------------------------------------
create table staff_assignments (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references staff (id) on delete restrict,
  position_id uuid references positions (id),
  division_id uuid references divisions (id),
  started_on  date not null default current_date,
  ended_on    date,
  reason      text,
  created_at  timestamptz not null default now(),
  check (ended_on is null or ended_on >= started_on)
);
create unique index staff_assignments_one_current on staff_assignments (staff_id) where ended_on is null;
create index staff_assignments_staff_idx on staff_assignments (staff_id, started_on desc);
comment on table staff_assignments is 'Purpose: history of each staff member''s position and division; exactly one open row while employed. Maintained by trigger. [class: confidential]';

create function staff_assignment_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.position_id is not null or new.primary_division_id is not null then
      insert into staff_assignments (staff_id, position_id, division_id, started_on, reason)
      values (new.id, new.position_id, new.primary_division_id, coalesce(new.start_date, current_date), 'initial assignment');
    end if;
    return null;
  end if;

  if new.employment_status = 'terminated' and old.employment_status <> 'terminated' then
    update staff_assignments set ended_on = greatest(started_on, coalesce(new.end_date, current_date)), reason = coalesce(reason, 'employment ended')
     where staff_id = new.id and ended_on is null;
  elsif new.position_id is distinct from old.position_id or new.primary_division_id is distinct from old.primary_division_id
        or (old.employment_status = 'terminated' and new.employment_status <> 'terminated') then
    update staff_assignments set ended_on = greatest(started_on, current_date) where staff_id = new.id and ended_on is null;
    if new.position_id is not null or new.primary_division_id is not null then
      insert into staff_assignments (staff_id, position_id, division_id, started_on, reason)
      values (new.id, new.position_id, new.primary_division_id, current_date,
              case when old.employment_status = 'terminated' then 'rehired' else 'position or division changed' end);
    end if;
  end if;
  return null;
end $$;
create trigger staff_assignment_sync_trg after insert or update of position_id, primary_division_id, employment_status on staff
  for each row execute function staff_assignment_sync();

alter table staff_assignments enable row level security;
revoke all on staff_assignments from anon, authenticated;
grant select on staff_assignments to authenticated;
create policy staff_assignments_select on staff_assignments for select to authenticated
  using (has_permission('hr.view') or staff_id = current_staff_id());

do $$ begin perform attach_audit('websites', array['api_key_hash']); end $$;
do $$ begin perform attach_audit('event_subscriptions'); end $$;
do $$ begin perform attach_audit('staff_assignments'); end $$;

revoke execute on function issue_website_key(uuid) from public, anon;
grant execute on function issue_website_key(uuid) to authenticated;
revoke execute on function site_from_key_hash(text) from public, anon, authenticated;
