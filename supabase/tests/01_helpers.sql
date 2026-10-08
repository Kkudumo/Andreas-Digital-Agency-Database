-- Test helpers (scratch databases only).
create schema tests;
create table tests.results (id serial primary key, name text, ok boolean, detail text);

create function tests.uid(p_name text) returns uuid language sql immutable as $$ select md5('ada-test-' || p_name)::uuid $$;

-- Run a statement as an authenticated API user; returns 'ok', 'ok0' (zero rows) or 'ERR:<sqlstate>'.
create function tests.try(p_user text, p_sql text) returns text language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claim.sub', case when p_user is null then '' else tests.uid(p_user)::text end, true);
  set local role authenticated;
  begin
    execute p_sql;
    get diagnostics n = row_count;
    reset role;
    return case when n = 0 then 'ok0' else 'ok' end;   -- ok0 = ran, but affected nothing
  exception when others then
    reset role;
    return 'ERR:' || sqlstate;
  end;
end $$;

-- Run a single-value query as an authenticated user; returns the value as text or 'ERR:<sqlstate>'.
create function tests.scalar(p_user text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', case when p_user is null then '' else tests.uid(p_user)::text end, true);
  set local role authenticated;
  begin
    execute p_sql into v;
    reset role;
    return v;
  exception when others then
    reset role;
    return 'ERR:' || sqlstate;
  end;
end $$;

-- Same, but as the anonymous API role.
create function tests.scalar_anon(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  begin
    execute p_sql into v;
    reset role;
    return v;
  exception when others then
    reset role;
    return 'ERR:' || sqlstate;
  end;
end $$;

create function tests.check(p_name text, p_actual text, p_expected text) returns void language plpgsql as $$
begin
  insert into tests.results (name, ok, detail)
  values (p_name, p_actual is not distinct from p_expected,
          case when p_actual is not distinct from p_expected then null else format('expected %L, got %L', p_expected, p_actual) end);
end $$;

create function tests.finish() returns void language plpgsql as $$
declare r record; fails int := 0; total int := 0;
begin
  for r in select * from tests.results order by id loop
    total := total + 1;
    if r.ok then raise notice 'ok   - %', r.name;
    else fails := fails + 1; raise warning 'FAIL - % (%)', r.name, r.detail;
    end if;
  end loop;
  raise notice '% checks, % failed', total, fails;
  if fails > 0 then raise exception '% test(s) failed', fails; end if;
end $$;

-- Fixture world: one login + staff record per persona.
--   ceo (org-wide ceo) · admin (administration_officer) · fin (finance_officer) · audit (auditor)
--   web_lead / web_staff (division_lead / division_staff scoped to Web)
--   tech_staff (division_staff scoped to Tech) · suspended (ceo role but suspended account)
--   outsider (login with no staff record)
-- Data: client C_web (Web-owned), C_tech (Tech-owned), C_conf (confidential, org-owned),
--       project P_web (Web client), P_tech (Tech client) with finance rows on both.
create table tests.ids (key text primary key, id uuid not null);
grant usage on schema tests to authenticated;
grant select on tests.ids to authenticated;

create function tests.setup() returns void language plpgsql as $$
declare
  d record;
  p_name text;
  r_key text;
  v_staff uuid;
  v_div_web uuid; v_div_tech uuid;
  c_web uuid; c_tech uuid; c_conf uuid; p_web uuid; p_tech uuid;
begin
  select id into v_div_web  from divisions where key = 'web';
  select id into v_div_tech from divisions where key = 'tech';

  for p_name, r_key in select * from (values
      ('ceo','ceo'),('admin','administration_officer'),('fin','finance_officer'),('audit','auditor'),
      ('web_lead','division_lead'),('web_staff','division_staff'),('tech_staff','division_staff'),('suspended','ceo')
  ) v(n,r) loop
    insert into auth.users (id, email) values (tests.uid(p_name), p_name || '@ada.test');
    insert into staff (user_id, full_name, email, account_status)
      values (tests.uid(p_name), initcap(p_name), p_name || '@ada.test', case when p_name = 'suspended' then 'suspended' else 'active' end::account_status)
      returning id into v_staff;
    insert into staff_roles (staff_id, role_id, division_id)
      select v_staff, r.id,
             case when p_name in ('web_lead','web_staff') then v_div_web
                  when p_name = 'tech_staff' then v_div_tech end
      from roles r where r.key = r_key;
  end loop;
  insert into auth.users (id, email) values (tests.uid('outsider'), 'outsider@ada.test');

  insert into clients (name, owner_division_id) values ('C_web',  v_div_web)  returning id into c_web;
  insert into clients (name, owner_division_id) values ('C_tech', v_div_tech) returning id into c_tech;
  insert into clients (name, classification)    values ('C_conf', 'confidential') returning id into c_conf;
  insert into projects (client_id, lead_division_id, name) values (c_web,  v_div_web,  'P_web')  returning id into p_web;
  insert into projects (client_id, lead_division_id, name) values (c_tech, v_div_tech, 'P_tech') returning id into p_tech;
  insert into project_financials (project_id, budget) values (p_web, 3000), (p_tech, 6000);
  insert into tasks (project_id, title) values (p_web, 'T_web'), (p_tech, 'T_tech');
  insert into staff_private (staff_id, national_id, emergency_contact_name)
    select id, '123456789', 'Someone' from staff where email = 'web_staff@ada.test';

  -- Lookup table so tests can name rows the acting user is not allowed to read.
  insert into tests.ids select 'role:' || key, id from roles;
  insert into tests.ids select 'perm:' || key, id from permissions;
  insert into tests.ids select 'div:' || key, id from divisions;
  insert into tests.ids select 'staff:' || split_part(email, '@', 1), id from staff;
  insert into tests.ids select 'client:' || name, id from clients;
  insert into tests.ids select 'project:' || name, id from projects;
end $$;

-- Run a statement as the migration owner (no API role); returns 'ok' or 'ERR:<sqlstate>'.
create function tests.try_owner(p_sql text) returns text language plpgsql as $$
begin
  begin
    execute p_sql;
    return 'ok';
  exception when others then
    return 'ERR:' || sqlstate;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Recruitment / public API fixtures (call after tests.setup())
-- ---------------------------------------------------------------------------
create function tests.keyhash(p_key text) returns text language sql immutable as $$ select encode(extensions.digest(p_key, 'sha256'), 'hex') $$;

-- Remember a uuid returned by an earlier statement; fails loudly if that statement errored.
create function tests.remember(p_key text, p_value text) returns void language plpgsql as $$
begin
  if p_value is null or p_value like 'ERR:%' then raise exception 'cannot remember % (got %)', p_key, p_value; end if;
  insert into tests.ids (key, id) values (p_key, p_value::uuid) on conflict (key) do update set id = excluded.id;
end $$;

create function tests.id(p_key text) returns uuid language sql stable as $$ select id from tests.ids where key = p_key $$;

-- Run a single-value query as the website-facing database role.
create function tests.scalar_pub(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  set local role ada_public_api;
  begin
    execute p_sql into v;
    reset role;
    return v;
  exception when others then
    reset role;
    return 'ERR:' || sqlstate;
  end;
end $$;

create function tests.setup_hr() returns void language plpgsql as $$
declare
  v_staff uuid;
  v_web uuid := tests.id('div:web');
  v_tech uuid := tests.id('div:tech');
begin
  -- recruiter (org-wide recruiter role) and a Tech division lead
  insert into auth.users (id, email) values (tests.uid('recruiter'), 'recruiter@ada.test');
  insert into staff (user_id, full_name, email, account_status) values (tests.uid('recruiter'), 'Recruiter', 'recruiter@ada.test', 'active') returning id into v_staff;
  insert into staff_roles (staff_id, role_id) select v_staff, id from roles where key = 'recruiter';
  insert into tests.ids values ('staff:recruiter', v_staff);

  insert into auth.users (id, email) values (tests.uid('tech_lead'), 'tech_lead@ada.test');
  insert into staff (user_id, full_name, email, account_status) values (tests.uid('tech_lead'), 'Tech Lead', 'tech_lead@ada.test', 'active') returning id into v_staff;
  insert into staff_roles (staff_id, role_id, division_id) select v_staff, id, v_tech from roles where key = 'division_lead';
  insert into tests.ids values ('staff:tech_lead', v_staff);

  -- a login that will become a new hire's account
  insert into auth.users (id, email) values (tests.uid('newhire'), 'newhire@ada.test');

  insert into tests.ids select 'position:' || title, id from positions where title in ('Web Developer', 'IT Technician');

  -- registered websites with known API keys (plaintext only exists in tests)
  insert into websites (name, domain, environment, status, capabilities, api_key_hash, api_key_prefix) values
    ('ADA Main Website', 'main.ada.test', 'production', 'active',
       array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read', 'applications.submit', 'services.read', 'portfolio.read'], tests.keyhash('testkey-main'), 'testkey-'),
    ('Limited Site', 'limited.ada.test', 'production', 'active', array['divisions.read'], tests.keyhash('testkey-limited'), 'testkey-'),
    ('Suspended Site', 'suspended.ada.test', 'production', 'suspended', array['vacancies.read', 'divisions.read'], tests.keyhash('testkey-susp'), 'testkey-');
  insert into tests.ids select 'site:' || split_part(domain, '.', 1), id from websites;
end $$;

-- Call a public_api function as the website role: tests.pub('main', 'vacancy', quote_literal('ADA-VAC-...'))
create function tests.pub(p_site text, p_fn text, p_extra text default '') returns text language sql as $$
  select tests.scalar_pub(format('select public_api.%s(%L%s)::text', p_fn, tests.keyhash('testkey-' || p_site),
                                 case when p_extra = '' then '' else ', ' || p_extra end))
$$;

-- Like tests.try but returns 'ok' or '<sqlstate>: <message>' so a test can assert on the user-facing message.
create function tests.try_msg(p_user text, p_sql text) returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', case when p_user is null then '' else tests.uid(p_user)::text end, true);
  set local role authenticated;
  begin
    execute p_sql;
    reset role;
    return 'ok';
  exception when others then
    reset role;
    return sqlstate || ': ' || sqlerrm;
  end;
end $$;

-- Tables that have an ada_id column but contain rows missing from entity_registry ('none' when consistent).
create function tests.unregistered_tables() returns text language plpgsql as $$
declare r record; n bigint; bad text[] := '{}';
begin
  for r in select c.table_name from information_schema.columns c join information_schema.tables t
             on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
           where c.table_schema = 'public' and c.column_name = 'ada_id' and c.table_name <> 'entity_registry' order by 1 loop
    execute format('select count(*) from %I x where not exists (select 1 from entity_registry g where g.ada_id = x.ada_id)', r.table_name) into n;
    if n > 0 then bad := bad || r.table_name::text; end if;
  end loop;
  return case when cardinality(bad) = 0 then 'none' else array_to_string(bad, ',') end;
end $$;
