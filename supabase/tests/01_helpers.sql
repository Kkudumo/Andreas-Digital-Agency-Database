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
  insert into project_financials (project_id, quoted_amount, budget) values (p_web, 5000, 3000), (p_tech, 9000, 6000);
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
