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
       array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read', 'applications.submit', 'services.read', 'portfolio.read', 'enquiries.submit', 'documents.read'], tests.keyhash('testkey-main'), 'testkey-'),
    ('Limited Site', 'limited.ada.test', 'production', 'active', array['divisions.read'], tests.keyhash('testkey-limited'), 'testkey-'),
    ('ADA Tech Website', 'tech.ada.test', 'production', 'active', array['divisions.read', 'services.read', 'enquiries.submit'], tests.keyhash('testkey-tech'), 'testkey-'),
    ('Suspended Site', 'suspended.ada.test', 'production', 'suspended', array['vacancies.read', 'divisions.read'], tests.keyhash('testkey-susp'), 'testkey-');
  insert into tests.ids select 'site:' || split_part(domain, '.', 1), id from websites;
  update websites set division_id = tests.id('div:tech') where domain = 'tech.ada.test';
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
  -- every table that carries a legacy ada_id, and every table the registry routes to, must have a registry row for each record
  for r in select distinct table_name from (
             select c.table_name from information_schema.columns c join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
              where c.table_schema = 'public' and c.column_name = 'ada_id' and c.table_name <> 'entity_registry'
             union select domain_table from entity_types where is_built and domain_table is not null) q order by 1 loop
    execute format('select count(*) from %I x where not exists (select 1 from entity_registry g where g.table_name = %L and g.entity_id = x.id)', r.table_name, r.table_name) into n;
    if n > 0 then bad := bad || r.table_name::text; end if;
  end loop;
  return case when cardinality(bad) = 0 then 'none' else array_to_string(bad, ',') end;
end $$;

-- Controlled client creation as a user. mkclient returns the jsonb result as text (or ERR:<state>);
-- mkclient_id returns just the new client's uuid (or the status / error, so remember() fails loudly).
create function tests.mkclient(p_user text, p_name text, p_division_key text default null, p_registration text default null, p_reason text default null) returns text
language sql as $$
  select tests.scalar(p_user, format('select client_create(%L, %s, ''company'', %L, null, null, %L)::text', p_name,
         case when p_division_key is null then 'null::uuid' else format('(select id from divisions where key = %L)', p_division_key) end, p_registration, p_reason))
$$;
create function tests.mkclient_id(p_user text, p_name text, p_division_key text default null, p_registration text default null, p_reason text default null) returns text
language plpgsql as $$
declare r text := tests.mkclient(p_user, p_name, p_division_key, p_registration, p_reason);
begin
  if r like 'ERR:%' then return r; end if;
  return coalesce(r::jsonb ->> 'id', 'status:' || (r::jsonb ->> 'status'));
end $$;

-- Submit an enquiry as a connected website. enq returns the JSON response (or ERR:<state>); enq_id returns the enquiry's uuid.
create function tests.enq(p_site text, p_name text, p_email text, p_phone text default null, p_org text default null, p_service text default null,
                          p_message text default null, p_page text default null, p_referrer text default null, p_utm text default '{}') returns text
language sql as $$
  select tests.pub(p_site, 'submit_enquiry', format('%L, %L, %L, %L, %L, %L, %L, %L, %L::jsonb', p_name, p_email, p_phone, p_org, p_service, p_message, p_page, p_referrer, p_utm))
$$;
create function tests.enq_id(p_site text, p_name text, p_email text, p_phone text default null, p_org text default null, p_service text default null,
                             p_message text default null, p_page text default null, p_referrer text default null, p_utm text default '{}') returns text
language plpgsql as $$
declare r text := tests.enq(p_site, p_name, p_email, p_phone, p_org, p_service, p_message, p_page, p_referrer, p_utm);
begin
  if r like 'ERR:%' then return r; end if;
  return (select id::text from enquiries where ada_id = r::jsonb ->> 'reference');
end $$;

-- Existence-leakage probing: run a statement as a user and report exactly what they could observe
-- (value or SQLSTATE + message). same_for() runs one template against two ids and says whether the
-- observable outcomes are identical.
create function tests.outcome(p_user text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', case when p_user is null then '' else tests.uid(p_user)::text end, true);
  set local role authenticated;
  begin
    execute p_sql into v;
    reset role;
    return 'ok:' || coalesce(v, '<null>');
  exception when others then
    reset role;
    return sqlstate || ': ' || sqlerrm;
  end;
end $$;

create function tests.same_for(p_user text, p_template text, p_a uuid, p_b uuid) returns text language plpgsql as $$
declare a text := tests.outcome(p_user, format(p_template, p_a));
        b text := tests.outcome(p_user, format(p_template, p_b));
begin
  return case when a = b then 'same' else 'DIFFERENT: [' || a || '] vs [' || b || ']' end;
end $$;

-- Finance fixture: ONE client (ABC Company, created by Tech, claimed by Web) with contact John, two priced services,
-- an accepted quote (web N$5,000 x1 + cctv N$1,200 x4 with N$500 discount = N$9,300) and the ACTIVE contract made from it.
-- Remembers: client:abc contact:john svc:web svc:cctv price:web price:cctv quote:1 contract:1 project:abc
create function tests.finance_world() returns void language plpgsql as $$
begin
  perform tests.remember('client:abc', tests.mkclient_id('tech_lead', 'ABC Company', 'tech'));
  perform tests.try('web_lead', format('select claim_client_for_division(%L, %L)', tests.id('client:abc'), tests.id('div:web')));
  perform tests.remember('contact:john', tests.scalar('web_lead', format('select add_client_contact(%L, ''John Director'', ''john@abc.example'', null, ''Director'', true)::text', tests.id('client:abc'))));
  perform tests.remember('svc:web', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Website Development', 's', 'd' from divisions where key = 'web' returning id::text $q$));
  perform tests.remember('svc:cctv', tests.scalar('tech_lead', $q$ insert into services (division_id, name, summary, description, billing_unit) select id, 'CCTV Installation', 's', 'd', 'camera' from divisions where key = 'tech' returning id::text $q$));
  perform tests.remember('price:web', tests.scalar('web_lead', format('select price_propose(%L, 5000, ''NAD'', current_date, ''launch'')::text', tests.id('svc:web'))));
  perform tests.scalar('ceo', format('select (price_decide(%L, true)).status::text', tests.id('price:web')));
  perform tests.remember('price:cctv', tests.scalar('tech_lead', format('select price_propose(%L, 1200, ''NAD'', current_date, ''launch'')::text', tests.id('svc:cctv'))));
  perform tests.scalar('ceo', format('select (price_decide(%L, true)).status::text', tests.id('price:cctv')));
  perform tests.remember('quote:1', tests.scalar('web_lead', format('select quote_create(%L, %L, ''Website and CCTV for ABC'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
  perform tests.scalar('web_lead', format('select quote_add_line(%L, %L)::text', tests.id('quote:1'), tests.id('svc:web')));
  perform tests.scalar('web_lead', format('select quote_add_line(%L, %L, 4, null, null, null, 500)::text', tests.id('quote:1'), tests.id('svc:cctv')));
  perform tests.scalar('web_lead', format('select quote_transition(%L, ''pending_approval'')::text', tests.id('quote:1')));
  perform tests.scalar('ceo', format('select quote_transition(%L, ''approved'')::text', tests.id('quote:1')));
  perform tests.scalar('web_lead', format('select quote_transition(%L, ''sent'')::text', tests.id('quote:1')));
  perform tests.scalar('web_lead', format('select quote_transition(%L, ''accepted'', ''Signed by John'')::text', tests.id('quote:1')));
  perform tests.remember('project:abc', tests.scalar('web_lead', format('select quote_convert_to_project(%L)::text', tests.id('quote:1'))));
  perform tests.remember('contract:1', tests.scalar('web_lead', format('select contract_create_from_quote(%L)::text', tests.id('quote:1'))));
  perform tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:1')));
  perform tests.scalar('ceo', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:1')));
  perform tests.scalar('web_lead', format('select contract_transition(%L, ''sent'')::text', tests.id('contract:1')));
  perform tests.scalar('web_lead', format('select contract_transition(%L, ''signed'')::text', tests.id('contract:1')));
  perform tests.scalar('web_lead', format('select contract_transition(%L, ''active'')::text', tests.id('contract:1')));
end $$;

-- For setup steps whose value is only needed as a stored id: remembers it and returns 'ok' (or the error).
create function tests.remember_ok(p_key text, p_value text) returns text language plpgsql as $$
begin
  if p_value is null or p_value like 'ERR:%' then return coalesce(p_value, 'null'); end if;
  perform tests.remember(p_key, p_value);
  return 'ok';
end $$;

-- A bank account for received payments (owner-level setup). Remembers 'acct:<key>'.
create function tests.bank_account(p_key text, p_currency text default 'NAD') returns void language plpgsql as $$
declare v_id uuid;
begin
  insert into bank_accounts (name, bank_name, account_hint, currency) values ('Account ' || p_key, 'FNB', '1234', p_currency) returning id into v_id;
  insert into tests.ids values ('acct:' || p_key, v_id);
end $$;

-- An ISSUED invoice of one manual charge (finance prepares, management approves, finance issues).
-- Adds a billing contact to the client if it has none. Remembers 'inv:<key>' and returns the invoice id as text.
create function tests.issued_invoice(p_key text, p_client_key text, p_amount numeric, p_division_key text default 'web') returns text language plpgsql as $$
declare v_client uuid := tests.id(p_client_key); v_div uuid := tests.id('div:' || p_division_key); v_person uuid; v_bi text; v_inv text;
begin
  if not exists (select 1 from client_contacts where client_id = v_client and is_active) then
    insert into people (full_name, email) values ('Billing ' || p_key, lower(p_key) || '.billing@example.test') returning id into v_person;
    insert into client_contacts (client_id, person_id, is_billing, is_primary) values (v_client, v_person, true, true);
  end if;
  v_bi := tests.scalar('fin', format('select billable_manual(%L, %L, %L, 1, %s, ''test charge'')::text', v_client, v_div, 'Services ' || p_key, p_amount));
  v_inv := tests.scalar('fin', format('select invoice_create(array[%L]::uuid[])::text', v_bi));
  perform tests.remember('inv:' || p_key, v_inv);
  perform tests.scalar('fin', format('select invoice_transition(%L, ''pending_approval'')::text', v_inv));
  perform tests.scalar('ceo', format('select invoice_transition(%L, ''approved'')::text', v_inv));
  perform tests.scalar('fin', format('select invoice_transition(%L, ''issued'')::text', v_inv));
  return v_inv;
end $$;

-- An extra staff member with a login and one role (optionally division-scoped). Remembers 'staff:<name>'.
create function tests.add_staff(p_name text, p_role text, p_division_key text default null) returns void language plpgsql as $$
declare v_staff uuid;
begin
  insert into auth.users (id, email) values (tests.uid(p_name), p_name || '@ada.test');
  insert into staff (user_id, full_name, email, account_status) values (tests.uid(p_name), initcap(p_name), p_name || '@ada.test', 'active') returning id into v_staff;
  insert into staff_roles (staff_id, role_id, division_id)
    select v_staff, r.id, case when p_division_key is not null then tests.id('div:' || p_division_key) end from roles r where r.key = p_role;
  insert into tests.ids values ('staff:' || p_name, v_staff) on conflict (key) do update set id = excluded.id;
end $$;

-- A draft invoice of one manual charge, prepared by the given user (default finance). Returns the invoice id as text.
create function tests.draft_invoice(p_key text, p_user text, p_client_key text, p_amount numeric, p_discount numeric default 0, p_division_key text default 'web') returns text language plpgsql as $$
declare v_client uuid := tests.id(p_client_key); v_div uuid := tests.id('div:' || p_division_key); v_person uuid; v_bi text; v_inv text;
begin
  if not exists (select 1 from client_contacts where client_id = v_client and is_active) then
    insert into people (full_name, email) values ('Billing ' || p_key, lower(p_key) || '.billing@example.test') returning id into v_person;
    insert into client_contacts (client_id, person_id, is_billing, is_primary) values (v_client, v_person, true, true);
  end if;
  v_bi := tests.scalar(p_user, format('select billable_manual(%L, %L, %L, 1, %s, ''test charge'', null, %s)::text', v_client, v_div, 'Services ' || p_key, p_amount, p_discount));
  v_inv := tests.scalar(p_user, format('select invoice_create(array[%L]::uuid[])::text', v_bi));
  perform tests.remember('inv:' || p_key, v_inv);
  return v_inv;
end $$;

-- Register an asset as a user. Returns the new id (and remembers it as 'asset:<key>') or the error. Optional references use test keys.
create function tests.mk_asset(p_user text, p_key text, p_name text, p_div text default 'web', p_manufacturer text default null, p_serial text default null,
                               p_tag text default null, p_status text default 'in_stock', p_client text default null, p_project text default null, p_parent text default null,
                               p_classification text default 'internal') returns text
language plpgsql as $$
declare r text;
begin
  r := tests.scalar(p_user, format('select asset_create(p_name => %L, p_category => ''laptop'', p_division => %L, p_manufacturer => %L, p_serial => %L, p_tag => %L, p_status => %L::asset_status, p_client => %L, p_project => %L, p_parent => %L, p_classification => %L::data_classification)::text',
         p_name, tests.id('div:' || p_div), p_manufacturer, p_serial, p_tag, p_status, tests.id(p_client), tests.id(p_project), tests.id(p_parent), p_classification));
  if r like 'ERR:%' or r is null then return coalesce(r, 'null'); end if;
  perform tests.remember('asset:' || p_key, r);
  return r;
end $$;

-- Documents -----------------------------------------------------------------------------------------------------------------------------------------
create function tests.h(p text) returns text language sql immutable as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;

-- Registers a document as p_user, remembers doc:<key>; returns the uuid text or ERR:<state>. Optional links are added by the same user afterwards.
create function tests.mk_doc(p_user text, p_key text, p_title text, p_type text default 'report', p_div text default 'web', p_link_key text default null,
                             p_class text default null, p_critical boolean default null) returns text language plpgsql as $$
declare v text; l text;
begin
  v := tests.scalar(p_user, format($q$ select (document_register(%L, %L, %L, p_classification => %s, p_critical => %s)) ->> 'id' $q$, p_title, p_type, tests.id('div:' || p_div),
                         case when p_class is null then 'null' else quote_literal(p_class) || '::data_classification' end, coalesce(p_critical::text, 'null')));
  if v like 'ERR:%' then return v; end if;
  insert into tests.ids values ('doc:' || p_key, v::uuid) on conflict (key) do update set id = excluded.id;
  if p_link_key is not null then
    l := tests.scalar(p_user, format($q$ select document_link_add(%L, (select institutional_id from entity_registry where entity_id = %L))::text $q$, v, tests.id(p_link_key)));
    if l like 'ERR:%' then return l; end if;
  end if;
  return v;
end $$;

-- Adds a version (content = the text, hashed) as p_user; remembers ver:<vkey>; returns the uuid text or ERR:<state>
create function tests.add_ver(p_user text, p_doc_key text, p_vkey text, p_content text, p_label text default null, p_mime text default 'application/pdf') returns text language plpgsql as $$
declare v text;
begin
  v := tests.scalar(p_user, format($q$ select (document_add_version(%L, 'memstore', %L, %L, %s, %L, %L, %L)) ->> 'version_id' $q$,
                         tests.id('doc:' || p_doc_key), 'obj/' || p_vkey, tests.h(p_content), length(p_content) + 1, p_mime, p_vkey || '.pdf', p_label));
  if v like 'ERR:%' then return v; end if;
  insert into tests.ids values ('ver:' || p_vkey, v::uuid) on conflict (key) do update set id = excluded.id;
  return v;
end $$;

-- Test-only: moves a document's whole history back in time (guards that forbid editing history are lifted inside this transaction only)
create function tests.backdate_doc(p_doc_key text, p_by interval) returns void language plpgsql as $$
declare v_doc uuid := tests.id(p_doc_key);
begin
  alter table document_events disable trigger document_events_immutable;
  alter table document_versions disable trigger document_versions_guard_trg;
  alter table document_links disable trigger document_links_guard_trg;
  alter table documents disable trigger documents_guard_trg;
  update document_events set occurred_at = occurred_at - p_by where document_id = v_doc;
  update document_versions set uploaded_at = uploaded_at - p_by where document_id = v_doc;
  update document_links set linked_at = linked_at - p_by where document_id = v_doc;
  update documents set created_at = created_at - p_by where id = v_doc;
  alter table document_events enable trigger document_events_immutable;
  alter table document_versions enable trigger document_versions_guard_trg;
  alter table document_links enable trigger document_links_guard_trg;
  alter table documents enable trigger documents_guard_trg;
end $$;

-- Domains -------------------------------------------------------------------------------------------------------------------------------------------
-- Creates a domain record as p_user; remembers dom:<key>; returns the uuid text or ERR:<state>
create function tests.mk_domain(p_user text, p_key text, p_name text, p_div text default 'web') returns text language plpgsql as $$
declare v text;
begin
  v := tests.scalar(p_user, format($q$ select (domain_create(%L, %L)) ->> 'id' $q$, p_name, tests.id('div:' || p_div)));
  if v is null or v like 'ERR:%' then return coalesce(v, 'NULL'); end if;
  insert into tests.ids values ('dom:' || p_key, v::uuid) on conflict (key) do update set id = excluded.id;
  return v;
end $$;
-- Relates a domain to a registered entity (by table + remembered key) as p_user; returns 'ok' or ERR:<state>
create function tests.rel(p_user text, p_dom_key text, p_relation text, p_table text, p_entity_key text, p_reason text default 'test') returns text language sql as $$
  select tests.try(p_user, format($q$ insert into domain_relations (domain_id, relation, entity_institutional_id, reason)
     values (%L, %L, (select institutional_id from entity_registry where table_name = %L and entity_id = %L), %L) $q$, tests.id('dom:' || p_dom_key), p_relation, p_table, tests.id(p_entity_key), p_reason))
$$;
-- Registers + activates a domain: record, registrar relation, a one-year registration ending p_days days from today
create function tests.live_domain(p_user text, p_key text, p_name text, p_days integer default 300, p_div text default 'web') returns text language plpgsql as $$
declare v text;
begin
  v := tests.mk_domain(p_user, p_key, p_name, p_div);
  if v like 'ERR:%' or v = 'NULL' then return v; end if;
  v := tests.rel(p_user, p_key, 'registrar', 'suppliers', 'sup:namreg');
  if v <> 'ok' then return 'rel ' || v; end if;
  return tests.try(p_user, format($q$ select domain_activate(%L, current_date + %s - 365, current_date + %s, %L) $q$, tests.id('dom:' || p_key), p_days, p_days, 'REG-' || p_key));
end $$;
