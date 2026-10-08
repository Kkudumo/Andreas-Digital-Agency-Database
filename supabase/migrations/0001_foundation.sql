-- 0001_foundation: shared types, ADA ID service, entity registry.
-- Portable PostgreSQL. The only Supabase-specific dependency in the whole
-- schema is auth.uid() / auth.users, introduced in 0003.

-- Least privilege by default: objects created from here on are NOT automatically open to the
-- API roles. Each migration grants exactly what it intends (Supabase otherwise grants ALL).
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

create type data_classification as enum ('public', 'internal', 'restricted', 'confidential');

create function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- ADA ID service: ADA-STF-2026-0001
-- ---------------------------------------------------------------------------
create table entity_types (
  key         text primary key,
  prefix      text not null unique check (prefix ~ '^[A-Z]{3}$'),
  description text not null
);
comment on table entity_types is 'Purpose: registry of ADA entity kinds and their 3-letter ID prefix. [class: internal]';

insert into entity_types (key, prefix, description) values
  ('organization', 'ORG', 'The ADA organization'),
  ('division',     'DIV', 'Division of ADA (Web, Tech, ...)'),
  ('position',     'POS', 'Job position / title'),
  ('staff',        'STF', 'Staff member'),
  ('client',       'CLI', 'Client'),
  ('contact',      'CON', 'Client contact person'),
  ('project',      'PRJ', 'Project'),
  ('task',         'TSK', 'Project task');

create table id_sequences (
  prefix     text    not null references entity_types (prefix),
  year       integer not null,
  last_value integer not null default 0,
  primary key (prefix, year)
);
comment on table id_sequences is 'Purpose: per-prefix, per-year counters behind ADA IDs. Never directly accessible to API roles. [class: internal]';

-- Allocates the next ADA ID. Not callable by API roles; only trigger code
-- (SECURITY DEFINER) reaches it.
create function next_ada_id(p_entity_type text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prefix text;
  v_year   integer := extract(year from (now() at time zone 'Africa/Windhoek'))::integer;
  v_n      integer;
begin
  select prefix into v_prefix from entity_types where key = p_entity_type;
  if v_prefix is null then
    raise exception 'unknown entity type %', p_entity_type;
  end if;
  insert into id_sequences (prefix, year, last_value) values (v_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_value = id_sequences.last_value + 1
  returning last_value into v_n;
  return format('ADA-%s-%s-%s', v_prefix, v_year, lpad(v_n::text, 4, '0'));
end $$;

-- ---------------------------------------------------------------------------
-- Entity registry: one row per ADA-identified record, across all tables.
-- ---------------------------------------------------------------------------
create table entity_registry (
  ada_id      text primary key,
  entity_type text not null references entity_types (key),
  entity_id   uuid not null,
  table_name  text not null,
  created_at  timestamptz not null default now(),
  unique (entity_type, entity_id)
);
comment on table entity_registry is 'Purpose: central lookup of every ADA ID to its record; basis for global search and cross-module references. [class: internal]';

-- Trigger function: assigns ada_id on insert (ignoring any supplied value),
-- makes it immutable, and registers the entity.
create function ada_id_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.ada_id := next_ada_id(tg_argv[0]);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.ada_id is distinct from old.ada_id then
      raise exception 'ada_id is immutable' using errcode = '42501';
    end if;
    return new;
  end if;
  return null;
end $$;

create function register_entity_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into entity_registry (ada_id, entity_type, entity_id, table_name)
  values (new.ada_id, tg_argv[0], new.id, tg_table_name);
  return null;
end $$;

-- Wires ADA ID assignment + registry onto a table that has (id uuid, ada_id text).
create function attach_ada_id(p_table regclass, p_entity_type text) returns void
language plpgsql as $$
begin
  execute format(
    'create trigger ada_id_assign before insert or update on %s
       for each row execute function ada_id_trigger(%L)', p_table, p_entity_type);
  execute format(
    'create trigger ada_id_register after insert on %s
       for each row execute function register_entity_trigger(%L)', p_table, p_entity_type);
end $$;

-- Lock the service tables away from API roles.
alter table id_sequences enable row level security;
alter table entity_registry enable row level security;
alter table entity_types enable row level security;
revoke all on id_sequences, entity_registry, entity_types from anon, authenticated;
revoke execute on function next_ada_id(text) from public, anon, authenticated;
revoke execute on function attach_ada_id(regclass, text) from public, anon, authenticated;
