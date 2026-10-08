-- 0002_organization: ADA as a single organization with divisions and positions.
-- Policies for these tables are defined in 0003 once the permission helpers exist.

create table organization (
  id                  uuid primary key default gen_random_uuid(),
  ada_id              text not null unique,
  legal_name          text not null,
  trading_name        text,
  description         text,
  email               text,
  phone               text,
  address             text,
  website             text,
  registration_number text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table organization is 'Purpose: the single ADA organization record (public-facing profile fields feed the website later). [class: internal]';
create unique index organization_singleton on organization ((true));

create table divisions (
  id          uuid primary key default gen_random_uuid(),
  ada_id      text not null unique,
  key         text not null unique check (key ~ '^[a-z][a-z0-9_]*$'),
  name        text not null,
  kind        text not null check (kind in ('corporate', 'service')),
  description text,
  parent_id   uuid references divisions (id),
  is_active   boolean not null default true,
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (parent_id is distinct from id)
);
comment on table divisions is 'Purpose: ADA divisions and departments; the unit of permission scope. New divisions are rows, not schema changes. [class: internal]';

create table positions (
  id          uuid primary key default gen_random_uuid(),
  ada_id      text not null unique,
  title       text not null,
  division_id uuid references divisions (id),
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (title, division_id)
);
comment on table positions is 'Purpose: job positions, optionally tied to a division. A position is descriptive; access comes from roles, not positions. [class: internal]';

do $$ begin perform attach_ada_id('organization', 'organization'); end $$;
do $$ begin perform attach_ada_id('divisions', 'division'); end $$;
do $$ begin perform attach_ada_id('positions', 'position'); end $$;

create trigger organization_updated before update on organization for each row execute function set_updated_at();
create trigger divisions_updated    before update on divisions    for each row execute function set_updated_at();
create trigger positions_updated    before update on positions    for each row execute function set_updated_at();

alter table organization enable row level security;
alter table divisions    enable row level security;
alter table positions    enable row level security;
revoke all on organization, divisions, positions from anon, authenticated;
