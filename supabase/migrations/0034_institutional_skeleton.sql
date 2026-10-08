-- 0034_institutional_skeleton: ADA Core's institutional identity and routing layer.
--
--   ONE ORGANIZATION -> ONE CORE -> ONE INSTITUTIONAL SKELETON -> ONE SOURCE OF TRUTH -> MANY CONTROLLED INTERFACES
--
--  * CODEBOOK (versioned, centrally controlled): the meaning of every code that appears in an institutional ID.
--  * ID SERVICE: one generator, ada_mint_id(). A permanent ID is 9 characters from a 32-symbol alphabet (digits and letters
--    except I, L, O, U): 2 chars entity type + 1 char issue cycle + 5 chars scrambled serial + 1 check char. It encodes ONLY
--    immutable facts (what kind of thing, which issue year). Origin division, current division, location and status are registry
--    attributes, never part of the ID. The serial is a keyed Feistel permutation of a gap-free counter, so IDs are unique by
--    construction, opaque, and not guessable from their neighbours.
--  * ENTITY REGISTRY: the map, not the territory. For every authoritative record: its institutional ID, family, type, origin,
--    current division/location, status, classification, authorization scope, and WHERE the authoritative record lives
--    (table_name + entity_id). It holds no business data. The legacy ADA-XXX-YYYY-#### identifier stays as an alias
--    (ada_id / legacy_identifier) because immutable audit history refers to it - nothing historical is rewritten.
--  * ROUTING: entity_resolve / entity_get / search_route answer "what is this and where does it live" through the registry
--    first; row security of the authoritative table decides visibility, so a hidden entity is indistinguishable from a missing one.
--  * SECURITY: unresolved/denied lookups are recorded and escalate (flag -> case -> critical) without revealing anything.

-- permissions
insert into permissions (key, module, action, description, sensitivity) values
  ('security.view', 'security', 'view', 'View security events and investigation cases', 'restricted'::data_classification),
  ('security.manage', 'security', 'manage', 'Manage security policies and investigation cases', 'restricted'::data_classification),
  ('students.view', 'students', 'view', 'View students and their enrolments (own division)', 'restricted'::data_classification),
  ('students.admit', 'students', 'admit', 'Admit students and record enrolments', 'restricted'::data_classification),
  ('students.manage', 'students', 'manage', 'Change student status and academic structure', 'restricted'::data_classification),
  ('programmes.manage', 'programmes', 'manage', 'Manage programmes and cohorts', 'internal'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'security.view'),
  ('auditor', 'security.view'),
  ('ceo', 'security.manage'),
  ('ceo', 'students.view'),
  ('administration_officer', 'students.view'),
  ('division_lead', 'students.view'),
  ('division_staff', 'students.view'),
  ('auditor', 'students.view'),
  ('ceo', 'students.admit'),
  ('administration_officer', 'students.admit'),
  ('division_lead', 'students.admit'),
  ('ceo', 'students.manage'),
  ('administration_officer', 'students.manage'),
  ('division_lead', 'students.manage'),
  ('ceo', 'programmes.manage'),
  ('administration_officer', 'programmes.manage'),
  ('division_lead', 'programmes.manage')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;


-- ---------------------------------------------------------------------------
-- 1. Codebook
-- ---------------------------------------------------------------------------
create table id_codebook_versions (
  version    integer primary key,
  status     text not null check (status in ('draft', 'active', 'retired')),
  valid_from timestamptz not null default now(),
  note       text
);
insert into id_codebook_versions (version, status, note) values (1, 'active', 'Initial institutional coding standard');

create table id_settings (
  singleton        boolean primary key default true check (singleton),
  codebook_version integer not null references id_codebook_versions (version),
  scramble_key     text not null
);
insert into id_settings (codebook_version, scramble_key) values (1, encode(extensions.gen_random_bytes(16), 'hex'));
comment on table id_settings is 'Purpose: the active codebook version and the secret that scrambles serials. The key must NEVER change once IDs have been issued (it would break uniqueness); it is stored with the data so backups and restores keep it. No API access. [class: restricted]';
create function id_settings_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' or new.scramble_key is distinct from old.scramble_key then raise exception 'the ID scramble key is permanent' using errcode = '42501'; end if;
  return new;
end $$;
create trigger id_settings_guard_trg before update or delete on id_settings for each row execute function id_settings_guard();

create table id_codebook (
  version     integer not null references id_codebook_versions (version),
  kind        text not null check (kind in ('type', 'cycle', 'division', 'family')),
  code        text not null check (code ~ '^[0-9A-HJKMNP-TV-Z]{1,2}$'),
  meaning     text not null,
  family      text,
  note        text,
  valid_from  date,
  valid_until date,
  status      text not null default 'active' check (status in ('active', 'retired')),
  primary key (version, kind, code),
  unique (version, kind, meaning)
);
comment on table id_codebook is 'Purpose: the formal ADA coding dictionary. kind=type: 2-char entity type code; cycle: 1-char issue-year code; division: 2-char division code (for internal templates - NOT embedded in IDs); family: entity family. Versioned; codes are retired, never reused or changed. No API access. [class: restricted]';
create function id_codebook_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'codebook entries are retired, never deleted' using errcode = '42501'; end if;
  if (new.version, new.kind, new.code, new.meaning) is distinct from (old.version, old.kind, old.code, old.meaning) then
    raise exception 'a codebook entry''s code and meaning never change' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger id_codebook_guard_trg before update or delete on id_codebook for each row execute function id_codebook_guard();

create table id_counters (
  type_code  text not null,
  cycle_code text not null,
  last_value bigint not null default 0,
  primary key (type_code, cycle_code)
);
comment on table id_counters is 'Purpose: gap-free serial per (entity type, issue cycle). Incremented inside the registering transaction, so a rolled-back registration leaves no gap and no ID is ever reused. No API access. [class: restricted]';

-- Entity types: family, ID code and the routing map to the authoritative domain
alter table entity_types
  add column family       text,
  add column id_code      text unique,
  add column is_built     boolean not null default false,
  add column domain_table text,
  add column division_col text,
  add column status_col   text,
  add column class_col    text,
  add column location_col text,
  add column label_col    text,
  add column view_fn      text;
comment on column entity_types.domain_table is 'The authoritative table for this entity type. The registry points here; it never copies the record.';
comment on column entity_types.view_fn is 'Optional 360 function used by entity_get (SECURITY INVOKER: row security still decides what is returned).';

insert into entity_types (key, prefix, family, is_built, domain_table, division_col, status_col, class_col, location_col, label_col, view_fn, description, id_code) values
  ('organization', 'ORG', 'people_org', true, 'organization', null, null, null, null, 'legal_name', null, 'The ADA organization', 'W0'),
  ('division', 'DIV', 'people_org', true, 'divisions', null, null, null, null, 'name', null, 'Division of ADA', 'BR'),
  ('position', 'POS', 'people_org', true, 'positions', 'division_id', null, null, null, 'title', null, 'Job position', 'RB'),
  ('staff', 'STF', 'people_org', true, 'staff', 'primary_division_id', 'employment_status', 'classification', null, 'full_name', 'staff_360', 'Staff member', 'HZ'),
  ('person', 'PER', 'people_org', true, 'people', null, null, null, null, 'full_name', null, 'A person (one record per human)', '9B'),
  ('vacancy', 'VAC', 'people_org', true, 'vacancies', 'division_id', 'status', null, null, 'title', null, 'Vacancy', 'E6'),
  ('client', 'CLI', 'people_org', true, 'clients', 'owner_division_id', 'status', 'classification', null, 'name', 'client_360', 'Client', 'J8'),
  ('contact', 'CTC', 'people_org', true, 'client_contacts', null, null, null, null, null, null, 'Client contact (a persons relationship to a client)', '9S'),
  ('supplier', 'SUP', 'people_org', true, 'suppliers', null, 'status', null, null, 'name', null, 'Supplier / vendor', 'C2'),
  ('partner', 'PTN', 'people_org', false, null, null, null, null, null, null, null, 'Partner organization (reserved)', '86'),
  ('student', 'STU', 'people_org', true, 'students', 'division_id', 'status', 'classification', null, null, null, 'Student', '06'),
  ('profile', 'PRF', 'people_org', true, 'staff_profiles', null, 'status', null, null, 'public_name', null, 'Public staff profile', 'G5'),
  ('lead', 'LED', 'commercial', true, 'leads', 'division_id', 'status', 'effective_classification', null, 'title', null, 'Sales lead', 'K7'),
  ('enquiry', 'ENQ', 'commercial', true, 'enquiries', 'division_id', 'status', 'effective_classification', null, null, null, 'Inbound enquiry', '3B'),
  ('quote', 'QUO', 'commercial', true, 'quotes', 'division_id', 'status', null, null, 'title', null, 'Quote', 'ZX'),
  ('contract', 'CON', 'commercial', true, 'contracts', 'division_id', 'status', 'effective_classification', null, 'title', null, 'Contract', '00'),
  ('invoice', 'INV', 'commercial', true, 'invoices', 'division_id', 'status', 'effective_classification', null, null, null, 'Invoice', 'G9'),
  ('payment', 'PAY', 'commercial', true, 'payments', null, 'status', 'effective_classification', null, null, null, 'Payment received', 'QD'),
  ('credit_note', 'CRN', 'commercial', false, null, null, null, null, null, null, null, 'Credit note (reserved)', 'D6'),
  ('expense', 'EXP', 'commercial', false, null, null, null, null, null, null, null, 'Expense (reserved)', 'WE'),
  ('service', 'SVC', 'commercial', true, 'services', 'division_id', 'status', 'classification', null, 'name', null, 'Service in the catalogue', '17'),
  ('project', 'PRJ', 'operations', true, 'projects', 'lead_division_id', 'status', 'effective_classification', null, 'name', 'project_360', 'Project', 'R8'),
  ('task', 'TSK', 'operations', true, 'tasks', null, 'status', null, null, 'title', null, 'Project task', 'A6'),
  ('milestone', 'MST', 'operations', false, null, null, null, null, null, null, null, 'Milestone (reserved)', 'P2'),
  ('asset', 'AST', 'operations', true, 'assets', 'division_id', 'status', 'effective_classification', 'current_location', 'name', 'asset_360', 'Physical or technical asset', 'NZ'),
  ('ticket', 'TKT', 'operations', true, 'tickets', 'division_id', 'status', 'effective_classification', null, 'title', null, 'Support / maintenance ticket', 'HF'),
  ('document', 'DOC', 'operations', false, null, null, null, null, null, null, null, 'Document (reserved)', 'HW'),
  ('domain', 'DOM', 'operations', false, null, null, null, null, null, null, null, 'Domain (reserved)', 'KF'),
  ('website', 'WEB', 'operations', true, 'websites', 'division_id', 'status', null, null, 'name', null, 'Connected website', 'RQ'),
  ('application', 'APP', 'operations', true, 'applications', null, 'status', null, null, null, null, 'Application', 'B7'),
  ('portfolio', 'PFO', 'operations', true, 'portfolio_entries', null, 'status', null, null, null, null, 'Portfolio item', 'GF'),
  ('communication', 'COM', 'operations', false, null, null, null, null, null, null, null, 'Communication (reserved)', 'C9'),
  ('programme', 'PRG', 'academy', true, 'programmes', 'division_id', 'status', null, null, 'name', null, 'Academy programme', 'V0'),
  ('course', 'CRS', 'academy', false, null, null, null, null, null, null, null, 'Course (reserved)', '4J'),
  ('module', 'MOD', 'academy', false, null, null, null, null, null, null, null, 'Module (reserved)', '5X'),
  ('cohort', 'COH', 'academy', true, 'cohorts', 'division_id', 'status', null, null, 'name', null, 'Cohort', 'KK'),
  ('enrollment', 'ENR', 'academy', true, 'student_enrolments', 'division_id', 'status', null, null, null, null, 'Enrolment of a student in a programme / cohort', 'ZB'),
  ('assessment', 'ASE', 'academy', false, null, null, null, null, null, null, null, 'Assessment (reserved)', 'P9'),
  ('result', 'RES', 'academy', false, null, null, null, null, null, null, null, 'Result (reserved)', 'S3'),
  ('attendance', 'ATT', 'academy', false, null, null, null, null, null, null, null, 'Attendance (reserved)', 'R4'),
  ('certificate', 'CER', 'academy', false, null, null, null, null, null, null, null, 'Certificate (reserved)', 'R3'),
  ('academic_record', 'ACR', 'academy', false, null, null, null, null, null, null, null, 'Academic record (reserved)', 'B5'),
  ('approval', 'APR', 'governance', false, null, null, null, null, null, null, null, 'Approval (reserved)', 'AJ'),
  ('investigation_case', 'CAS', 'governance', true, 'security_cases', null, 'status', null, null, null, null, 'Security investigation case', '3W'),
  ('audit_event', 'AUD', 'governance', false, null, null, null, null, null, null, null, 'Audit event (reserved)', 'NK'),
  ('notification', 'NTF', 'governance', false, null, null, null, null, null, null, null, 'Notification (reserved)', 'CS'),
  ('policy', 'POL', 'governance', false, null, null, null, null, null, null, null, 'Policy (reserved)', '2G'),
  ('authorization_record', 'AUT', 'governance', false, null, null, null, null, null, null, null, 'Authorization record (reserved)', 'S0')
on conflict (key) do update set family = excluded.family, is_built = excluded.is_built, domain_table = excluded.domain_table, division_col = excluded.division_col,
  status_col = excluded.status_col, class_col = excluded.class_col, location_col = excluded.location_col, label_col = excluded.label_col,
  view_fn = excluded.view_fn, id_code = excluded.id_code;
alter table entity_types alter column family set not null, alter column id_code set not null;
alter table entity_types add constraint entity_types_id_code_chk check (id_code ~ '^[0-9A-HJKMNP-TV-Z]{2}$');
create function entity_types_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and (new.key, new.id_code, new.prefix) is distinct from (old.key, old.id_code, old.prefix) then raise exception 'an entity type''s key, prefix and ID code are permanent' using errcode = '42501'; end if;
  return coalesce(new, old);
end $$;
create trigger entity_types_guard_trg before update on entity_types for each row execute function entity_types_guard();

insert into id_codebook (version, kind, code, meaning, family, note)
select 1, 'type', id_code, key, family, description from entity_types;
insert into id_codebook (version, kind, code, meaning, note) select 1, v.kind, v.code, v.meaning, v.note from (values
  ('cycle', '1', '2024', '2024'),
  ('cycle', '0', '2025', '2025'),
  ('cycle', 'H', '2026', '2026'),
  ('cycle', 'V', '2027', '2027'),
  ('cycle', 'B', '2028', '2028'),
  ('cycle', 'Z', '2029', '2029'),
  ('cycle', 'Q', '2030', '2030'),
  ('cycle', 'T', '2031', '2031'),
  ('cycle', 'M', '2032', '2032'),
  ('cycle', 'D', '2033', '2033'),
  ('cycle', 'R', '2034', '2034'),
  ('cycle', '2', '2035', '2035'),
  ('cycle', 'W', '2036', '2036'),
  ('cycle', 'J', '2037', '2037'),
  ('cycle', '4', '2038', '2038'),
  ('cycle', '7', '2039', '2039'),
  ('cycle', 'E', '2040', '2040'),
  ('cycle', '5', '2041', '2041'),
  ('cycle', '3', '2042', '2042'),
  ('cycle', 'P', '2043', '2043'),
  ('cycle', 'F', '2044', '2044'),
  ('cycle', 'C', '2045', '2045'),
  ('cycle', '6', '2046', '2046'),
  ('cycle', 'A', '2047', '2047'),
  ('cycle', 'S', '2048', '2048'),
  ('cycle', '8', '2049', '2049'),
  ('cycle', 'G', '2050', '2050'),
  ('cycle', 'N', '2051', '2051'),
  ('cycle', 'X', '2052', '2052'),
  ('cycle', '9', '2053', '2053'),
  ('cycle', 'K', '2054', '2054'),
  ('cycle', 'Y', '2055', '2055'),
  ('division', '7T', 'management', null),
  ('division', 'T2', 'administration', null),
  ('division', 'RM', 'finance', null),
  ('division', 'S8', 'web', null),
  ('division', 'GR', 'tech', null),
  ('division', 'RX', 'marketing', null),
  ('division', 'MR', 'academy', null),
  ('division', 'CY', 'software', null),
  ('division', 'E3', 'consulting', null)
) v(kind, code, meaning, note);
insert into id_codebook (version, kind, code, meaning, note) values
  (1, 'family', 'PE', 'people_org', 'Organization and people'), (1, 'family', 'CM', 'commercial', 'Commercial'),
  (1, 'family', 'XP', 'operations', 'Operations'), (1, 'family', 'AC', 'academy', 'Academy'), (1, 'family', 'GV', 'governance', 'Security and governance');

-- ---------------------------------------------------------------------------
-- 2. The ID service
-- ---------------------------------------------------------------------------
create function id_b32(p_n bigint, p_len integer) returns text
language plpgsql immutable as $$
declare a constant text := 'ABCDEFGHJKMNPQRSTVWXYZ0123456789'; s text := ''; n bigint := p_n; i integer;
begin
  for i in 1..p_len loop s := substr(a, (n % 32)::integer + 1, 1) || s; n := n / 32; end loop;
  return s;
end $$;

-- Check character: odd weights are invertible mod 32, so any single wrong character is detected.
create function id_check_char(p_body text) returns text
language plpgsql immutable as $$
declare a constant text := 'ABCDEFGHJKMNPQRSTVWXYZ0123456789'; w constant integer[] := array[1, 3, 5, 7, 9, 11, 13, 15]; s integer := 0; i integer;
begin
  for i in 1..8 loop s := s + w[i] * (strpos(a, substr(p_body, i, 1)) - 1); end loop;
  return substr(a, (s % 32) + 1, 1);
end $$;

-- Keyed permutation of [0, 2^25): 4-round Feistel over 26 bits with cycle-walking. A bijection, so serial -> scrambled is collision-free.
create function id_scramble(p_n bigint, p_key text) returns bigint
language plpgsql immutable as $$
declare x bigint := p_n; l bigint; r bigint; f bigint; t bigint; i integer;
begin
  loop
    l := x >> 13; r := x & 8191;
    for i in 1..4 loop
      f := ((('x' || substr(md5(p_key || ':' || i::text || ':' || r::text), 1, 4))::bit(16)::integer) & 8191);
      t := l # f; l := r; r := t;
    end loop;
    x := (l << 13) | r;
    exit when x < 33554432;
  end loop;
  return x;
end $$;

-- Is this a well-formed institutional ID (9 chars, allowed alphabet, correct check char)? Reveals nothing about existence.
create function ada_id_valid(p_id text) returns boolean
language sql immutable security definer set search_path = public, pg_temp as $$
  select p_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$' and substr(p_id, 9, 1) = id_check_char(substr(p_id, 1, 8))
$$;

-- THE ONE ID GENERATOR. Called only from the registration trigger (and service code); never by users.
create function ada_mint_id(p_entity_type text, p_year integer default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_ver integer; v_key text; v_tcode text; v_year integer := coalesce(p_year, extract(year from (now() at time zone 'Africa/Windhoek'))::integer);
  v_ccode text; v_n bigint; v_body text;
begin
  select codebook_version, scramble_key into v_ver, v_key from id_settings;
  select code into v_tcode from id_codebook where version = v_ver and kind = 'type' and meaning = p_entity_type and status = 'active';
  if v_tcode is null then raise exception 'no active codebook entry for entity type %', p_entity_type using errcode = '22023'; end if;
  select code into v_ccode from id_codebook where version = v_ver and kind = 'cycle' and meaning = v_year::text and status = 'active';
  if v_ccode is null then raise exception 'the codebook has no issue cycle for year %: extend the codebook before issuing IDs', v_year using errcode = '22023'; end if;
  insert into id_counters (type_code, cycle_code, last_value) values (v_tcode, v_ccode, 1)
  on conflict (type_code, cycle_code) do update set last_value = id_counters.last_value + 1
  returning last_value into v_n;
  if v_n >= 33554432 then raise exception 'ID space exhausted for % in %', p_entity_type, v_year using errcode = '54000'; end if;
  v_body := v_tcode || v_ccode || id_b32(id_scramble(v_n - 1, v_key), 5);
  return v_body || id_check_char(v_body);
end $$;

-- Service-side decoding of the codebook meaning (never exposed to users)
create function ada_id_decode(p_id text) returns table (entity_type text, issue_year integer, valid boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select t.meaning, c.meaning::integer, ada_id_valid(p_id)
  from id_settings s
  left join id_codebook t on t.version = s.codebook_version and t.kind = 'type' and t.code = substr(p_id, 1, 2)
  left join id_codebook c on c.version = s.codebook_version and c.kind = 'cycle' and c.code = substr(p_id, 3, 1)
$$;

-- ---------------------------------------------------------------------------
-- 3. The Entity Registry
-- ---------------------------------------------------------------------------
alter table entity_registry drop constraint entity_registry_pkey;
alter table entity_registry
  add column institutional_id    text,
  add column entity_family       text,
  add column origin_division_id  uuid references divisions (id),
  add column origin_year         integer,
  add column origin_cycle        text,
  add column origin_kind         text not null default 'created',
  add column classification      data_classification,
  add column authorization_scope text,
  add column current_division_id uuid references divisions (id),
  add column current_location    text,
  add column status              text,
  add column routing_version     integer not null default 1,
  add column created_by          uuid references staff (id);

-- One routine reads the authoritative row and derives the routing attributes (the registry mirrors, never owns, them)
create function registry_attrs(p_type entity_types, p_row jsonb, out division_id uuid, out location text, out status text, out classification data_classification, out scope text)
language plpgsql immutable as $$
begin
  division_id := case when p_type.division_col is not null then nullif(p_row ->> p_type.division_col, '')::uuid end;
  location := case when p_type.location_col is not null then nullif(p_row ->> p_type.location_col, '') end;
  status := case when p_type.status_col is not null then nullif(p_row ->> p_type.status_col, '') end;
  classification := case when p_type.class_col is not null then coalesce(nullif(p_row ->> p_type.class_col, '')::data_classification, 'internal') else 'internal' end;
  scope := case when p_type.division_col is not null then 'division' else 'organization' end;
end $$;

-- Backfill: every existing entity receives its permanent institutional ID. Legacy ADA-XXX identifiers stay as aliases.
do $$
declare r record; t entity_types; j jsonb; a record; v_year integer; v_inst text;
begin
  for r in select * from entity_registry order by created_at, ada_id loop
    select * into t from entity_types where key = r.entity_type;
    v_year := extract(year from (r.created_at at time zone 'Africa/Windhoek'))::integer;
    v_inst := ada_mint_id(r.entity_type, v_year);
    execute format('select to_jsonb(x) from public.%I x where x.id = $1', r.table_name) into j using r.entity_id;
    if j is null then j := '{}'::jsonb; end if;
    select * into a from registry_attrs(t, j);
    update entity_registry set institutional_id = v_inst, entity_family = t.family, origin_division_id = a.division_id, origin_year = v_year,
           origin_cycle = (select code from id_codebook where version = 1 and kind = 'cycle' and meaning = v_year::text),
           origin_kind = 'migrated', classification = a.classification, authorization_scope = a.scope, current_division_id = a.division_id,
           current_location = a.location, status = a.status
     where ada_id = r.ada_id;
  end loop;
end $$;
alter table entity_registry alter column institutional_id set not null, alter column entity_family set not null, alter column origin_year set not null,
  alter column origin_cycle set not null, alter column classification set not null, alter column authorization_scope set not null;
alter table entity_registry add primary key (institutional_id);
alter table entity_registry add constraint entity_registry_id_format check (institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$');
alter table entity_registry add constraint entity_registry_id_check_char check (substr(institutional_id, 9, 1) = id_check_char(substr(institutional_id, 1, 8)));
alter table entity_registry alter column ada_id drop not null;
alter table entity_registry add constraint entity_registry_ada_id_key unique (ada_id);
create index entity_registry_domain_idx on entity_registry (table_name, entity_id);
comment on table entity_registry is 'Purpose: the institutional map. One row per authoritative record: permanent 9-char institutional_id, family/type, origin (division, year, cycle - immutable), current division/location/status/classification (mirrored from the authoritative record by trigger), and where the record lives (table_name + entity_id). Holds NO business data. ada_id is the legacy identifier alias. Never deleted. [class: internal]';
comment on column entity_registry.ada_id is 'legacy_identifier: the original ADA-XXX-YYYY-#### form, kept as an alias because immutable audit history refers to it.';

create table entity_location_history (
  id                 bigint generated always as identity primary key,
  institutional_id   text not null references entity_registry (institutional_id),
  from_division_id   uuid references divisions (id),
  to_division_id     uuid references divisions (id),
  from_location      text,
  to_location        text,
  reason             text not null default 'moved',
  changed_by         uuid references staff (id),
  changed_at         timestamptz not null default now()
);
create index entity_location_history_idx on entity_location_history (institutional_id, id);
comment on table entity_location_history is 'Purpose: where each entity has belonged over time (division and physical location). The permanent ID never changes when an entity moves; this is the movement history. Append-only. [class: internal]';
create trigger entity_location_history_immutable before update or delete on entity_location_history for each row execute function append_only();

-- Identity columns are immutable; only routing metadata may change, and never by a user
create function entity_registry_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'registry entries are never deleted: an ID is never reused' using errcode = '42501'; end if;
  if (new.institutional_id, new.entity_type, new.entity_id, new.table_name, new.entity_family, new.origin_division_id, new.origin_year, new.origin_cycle, new.origin_kind, new.created_at, new.created_by)
     is distinct from (old.institutional_id, old.entity_type, old.entity_id, old.table_name, old.entity_family, old.origin_division_id, old.origin_year, old.origin_cycle, old.origin_kind, old.created_at, old.created_by)
     or (old.ada_id is not null and new.ada_id is distinct from old.ada_id) then
    raise exception 'an entity''s identity and origin are permanent' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger entity_registry_guard_trg before update or delete on entity_registry for each row execute function entity_registry_guard();

-- THE registration path (replaces the old register trigger): validate -> mint -> register, in the caller's transaction
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
          coalesce(nullif(tg_argv[1], ''), 'created'), a.classification, a.scope, a.division_id, a.location, a.status, current_staff_id());
  insert into entity_location_history (institutional_id, to_division_id, to_location, reason, changed_by) values (v_inst, a.division_id, a.location, 'registered', current_staff_id());
  return null;
end $$;

-- Keeps the mirrored routing attributes current; records movement; marks removal (the ID stays reserved forever)
create function registry_sync_trigger() returns trigger
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
  end if;
  return null;
end $$;

-- attach_ada_id keeps its signature and now also wires the sync; attach_entity is for tables that carry no legacy identifier
create or replace function attach_ada_id(p_table regclass, p_entity_type text) returns void
language plpgsql as $$
begin
  execute format('create trigger ada_id_assign before insert or update on %s for each row execute function ada_id_trigger(%L)', p_table, p_entity_type);
  execute format('create trigger ada_id_register after insert on %s for each row execute function register_entity_trigger(%L)', p_table, p_entity_type);
  execute format('create trigger registry_sync_trg after update or delete on %s for each row execute function registry_sync_trigger()', p_table);
end $$;
create function attach_entity(p_table regclass, p_entity_type text, p_origin_kind text default 'created') returns void
language plpgsql as $$
begin
  execute format('create trigger ada_id_register after insert on %s for each row execute function register_entity_trigger(%L, %L)', p_table, p_entity_type, p_origin_kind);
  execute format('create trigger registry_sync_trg after update or delete on %s for each row execute function registry_sync_trigger()', p_table);
end $$;
revoke execute on function attach_entity(regclass, text, text) from public, anon, authenticated;

-- Wire the sync onto every table registered before this migration
do $$
declare r record;
begin
  -- driven by the entity-type map, not by existing rows: a fresh database has no rows yet but must be wired identically
  for r in select distinct domain_table as table_name from entity_types where domain_table is not null and to_regclass('public.' || domain_table) is not null loop
    if exists (select 1 from pg_trigger where tgrelid = to_regclass('public.' || r.table_name) and tgname = 'registry_sync_trg') then continue; end if;
    execute format('create trigger registry_sync_trg after update or delete on public.%I for each row execute function registry_sync_trigger()', r.table_name);
  end loop;
  insert into entity_location_history (institutional_id, to_division_id, to_location, reason)
  select institutional_id, current_division_id, current_location, 'registered' from entity_registry;
end $$;

-- Audit identity: new audit rows carry the institutional ID of the record they are about (old rows keep their legacy ID; join via the registry)
alter table audit_log add column record_institutional_id text;
comment on column audit_log.record_institutional_id is 'Institutional ID of the audited record (null on rows written before the identity layer; those join through entity_registry on record_id).';
create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old   jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new   jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_col   text;
  v_diff  text[];
  v_row   jsonb := coalesce(v_new, v_old);
  v_staff uuid  := current_staff_id();
begin
  if tg_nargs > 0 then
    foreach v_col in array tg_argv loop
      if v_old ? v_col then v_old := jsonb_set(v_old, array[v_col], '"[redacted]"'); end if;
      if v_new ? v_col then v_new := jsonb_set(v_new, array[v_col], '"[redacted]"'); end if;
    end loop;
  end if;
  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into v_diff
    from jsonb_object_keys(v_new) k
    where k <> 'updated_at' and v_new -> k is distinct from v_old -> k;
    if v_diff is null then return null; end if;
  end if;
  insert into audit_log (actor_user_id, actor_staff_id, actor_ada_id, action, table_name, record_id, record_ada_id, record_institutional_id, old_data, new_data, changed_fields, reason)
  values (auth.uid(), v_staff, (select ada_id from staff where id = v_staff), tg_op, tg_table_name,
          nullif(v_row ->> 'id', '')::uuid, v_row ->> 'ada_id',
          (select institutional_id from entity_registry where table_name = tg_table_name and entity_id = nullif(v_row ->> 'id', '')::uuid),
          v_old, v_new, v_diff, nullif(current_setting('ada.reason', true), ''));
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Authorization hook: the registry is readable only for entities the caller may read in their authoritative domain
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER on purpose: the dynamic query below runs with the CALLER's rights, so the authoritative table's own row-level
-- security decides. A restricted entity and a non-existent one both give false.
create function entity_visible(p_table text, p_id uuid) returns boolean
language plpgsql stable set search_path = public, pg_temp as $$
declare v boolean;
begin
  execute format('select exists (select 1 from public.%I where id = $1)', p_table) into v using p_id;
  return coalesce(v, false);
exception when others then
  return false;
end $$;
revoke execute on function entity_visible(text, uuid) from public, anon;
grant execute on function entity_visible(text, uuid) to authenticated;

alter table entity_registry enable row level security;
revoke all on entity_registry from anon, authenticated;
grant select on entity_registry to authenticated;
create policy entity_registry_select on entity_registry for select to authenticated using (entity_visible(table_name, entity_id));
alter table entity_location_history enable row level security;
revoke all on entity_location_history from anon, authenticated;
grant select on entity_location_history to authenticated;
create policy entity_location_history_select on entity_location_history for select to authenticated
  using (exists (select 1 from entity_registry r where r.institutional_id = entity_location_history.institutional_id));

create view entity_directory with (security_invoker = true) as
  select institutional_id, entity_family, entity_type, origin_division_id, origin_year, origin_cycle, origin_kind, table_name as authoritative_domain,
         entity_id as authoritative_record_key, classification, authorization_scope, current_location as current_logical_location, current_division_id,
         status, created_at, created_by, routing_version, ada_id as legacy_identifier
  from entity_registry;
comment on view entity_directory is 'Purpose: the registry under the institutional field names. Same row security as entity_registry.';
revoke all on entity_directory from anon, authenticated;
grant select on entity_directory to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Security events and investigation cases
-- ---------------------------------------------------------------------------
create table security_policies (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('lookup', 'bypass')),
  window_minutes integer not null check (window_minutes > 0),
  threshold      integer not null check (threshold > 0),
  case_status    text not null check (case_status in ('flagged', 'open')),
  severity       text not null check (severity in ('low', 'medium', 'high', 'critical')),
  is_active      boolean not null default true,
  note           text
);
insert into security_policies (kind, window_minutes, threshold, case_status, severity, note) values
  ('lookup', 10, 5, 'flagged', 'low', 'repeated denied or unresolved lookups: raise a security flag'),
  ('lookup', 60, 15, 'open', 'medium', 'sustained pattern: open an investigation case'),
  ('bypass', 1, 1, 'open', 'critical', 'an attempt to bypass the controls: immediate case');
comment on table security_policies is 'Purpose: escalation thresholds for denied/unresolved access attempts. One denial is only an audit event; repeated ones flag; a pattern opens an investigation; a bypass attempt opens a critical case at once. [class: restricted]';

create table security_events (
  id               bigint generated always as identity primary key,
  occurred_at      timestamptz not null default now(),
  actor_user_id    uuid,
  actor_staff_id   uuid references staff (id),
  kind             text not null check (kind in ('lookup', 'bypass')),
  requested_action text not null,
  requested_input  text,
  entity_exists    boolean,
  entity_class     data_classification,
  decision         text not null default 'denied_or_unresolved',
  reason           text,
  session_ref      text,
  source_addr      inet
);
create index security_events_actor_idx on security_events (actor_staff_id, occurred_at);
create index security_events_user_idx on security_events (actor_user_id, occurred_at);
comment on table security_events is 'Purpose: append-only record of denied/unresolved access attempts. entity_exists is internal only: the actor can never tell a hidden entity from a missing one, but investigators can. [class: restricted]';
create trigger security_events_immutable before update or delete on security_events for each row execute function append_only();

create table security_cases (
  id            uuid primary key default gen_random_uuid(),
  status        text not null default 'flagged' check (status in ('flagged', 'open', 'under_review', 'closed')),
  severity      text not null check (severity in ('low', 'medium', 'high', 'critical')),
  actor_staff_id uuid references staff (id),
  actor_user_id uuid,
  opened_at     timestamptz not null default now(),
  last_event_at timestamptz not null default now(),
  event_count   integer not null default 0,
  reason        text not null,
  closed_by     uuid references staff (id),
  closed_at     timestamptz,
  resolution    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index security_cases_one_live_per_actor on security_cases (coalesce(actor_staff_id, actor_user_id)) where status <> 'closed';
create trigger security_cases_updated before update on security_cases for each row execute function set_updated_at();
select attach_entity('security_cases', 'investigation_case', 'detected');
comment on table security_cases is 'Purpose: security flags and investigation cases raised by escalation policy (an investigation case is an entity with its own institutional ID). Refers to the actor and to events; carries no details of the entities probed. [class: restricted]';

create table security_case_events (
  case_id  uuid not null references security_cases (id),
  event_id bigint not null references security_events (id),
  primary key (case_id, event_id)
);

create function security_evaluate(p_event bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e security_events%rowtype; p security_policies%rowtype; v_count integer; c security_cases%rowtype; v_new boolean := false;
        v_rank constant text[] := array['low', 'medium', 'high', 'critical'];
begin
  select * into e from security_events where id = p_event;
  select * into p from security_policies pl where pl.is_active and pl.kind = e.kind
   and (select count(*) from security_events x where x.kind = e.kind and coalesce(x.actor_staff_id, x.actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id)
          and x.occurred_at > e.occurred_at - make_interval(mins => pl.window_minutes)) >= pl.threshold
   order by array_position(v_rank, pl.severity) desc limit 1;
  if not found then return; end if;
  select count(*) into v_count from security_events x where x.kind = e.kind and coalesce(x.actor_staff_id, x.actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id)
     and x.occurred_at > e.occurred_at - make_interval(mins => p.window_minutes);
  select * into c from security_cases where coalesce(actor_staff_id, actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id) and status <> 'closed' for update;
  if not found then
    insert into security_cases (status, severity, actor_staff_id, actor_user_id, reason, event_count)
    values (p.case_status, p.severity, e.actor_staff_id, e.actor_user_id, case when e.kind = 'bypass' then 'attempt to bypass access controls' else v_count || ' denied or unresolved lookups within ' || p.window_minutes || ' minutes' end, 0)
    returning * into c;
    v_new := true;
  elsif array_position(v_rank, p.severity) > array_position(v_rank, c.severity) or (c.status = 'flagged' and p.case_status = 'open') then
    update security_cases set severity = case when array_position(v_rank, p.severity) > array_position(v_rank, severity) then p.severity else severity end,
           status = case when c.status = 'flagged' and p.case_status = 'open' then 'open' else status end where id = c.id returning * into c;
    v_new := true;
  end if;
  -- the case references the whole pattern, including the earlier related attempts in the window
  insert into security_case_events (case_id, event_id)
  select c.id, x.id from security_events x where x.kind = e.kind and coalesce(x.actor_staff_id, x.actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id)
     and x.occurred_at > e.occurred_at - make_interval(mins => p.window_minutes) on conflict do nothing;
  update security_cases set event_count = (select count(*) from security_case_events where case_id = c.id), last_event_at = now() where id = c.id;
  if v_new then
    perform notify_holders('security.view', null, 'security.case', 'Security ' || case when c.status = 'flagged' then 'flag' else 'case' end || ' raised (' || c.severity || ')', null, 'security_cases', c.id, null);
  end if;
end $$;

create function security_events_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform security_evaluate(new.id); return null; end $$;
create trigger security_events_after_trg after insert on security_events for each row execute function security_events_after();

-- Records an unresolved/denied lookup by the CURRENT caller. Granted to API users: it can only describe their own attempt,
-- and it writes what investigators need while telling the caller nothing.
create function security_note_lookup(p_input text, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_in text := left(coalesce(p_input, ''), 64); r entity_registry%rowtype;
begin
  select * into r from entity_registry where institutional_id = upper(btrim(v_in)) or ada_id = btrim(v_in);
  insert into security_events (actor_user_id, actor_staff_id, kind, requested_action, requested_input, entity_exists, entity_class, session_ref, source_addr, reason)
  values (auth.uid(), current_staff_id(), 'lookup', left(coalesce(p_action, 'resolve'), 40), v_in, found, case when found then r.classification end,
          nullif(current_setting('request.jwt.claim.session_id', true), ''), inet_client_addr(),
          case when found then 'not authorized for this entity' else 'no such entity' end);
end $$;
revoke execute on function security_note_lookup(text, text) from public, anon;
grant execute on function security_note_lookup(text, text) to authenticated;

-- For gateways that observe a denial the database could not log (a raised error rolls back its own transaction)
create function security_report_denial(p_action text, p_hint text default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  select security_note_lookup(p_hint, 'client-reported:' || coalesce(p_action, 'unknown'))
$$;
revoke execute on function security_report_denial(text, text) from public, anon;
grant execute on function security_report_denial(text, text) to authenticated;

-- A detected attempt to bypass controls (service code / gateway): critical, immediately
create function security_report_bypass(p_actor_staff uuid, p_action text, p_detail text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id bigint; v_case uuid;
begin
  insert into security_events (actor_user_id, actor_staff_id, kind, requested_action, requested_input, decision, reason, session_ref, source_addr)
  values (auth.uid(), coalesce(p_actor_staff, current_staff_id()), 'bypass', left(p_action, 40), left(p_detail, 64), 'blocked', 'bypass attempt', nullif(current_setting('request.jwt.claim.session_id', true), ''), inet_client_addr())
  returning id into v_id;
  select case_id into v_case from security_case_events where event_id = v_id;
  return v_case;
end $$;
revoke execute on function security_report_bypass(uuid, text, text) from public, anon, authenticated;

create function security_case_update(p_case uuid, p_status text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_permission('security.manage') then raise exception 'security.manage is required' using errcode = '42501'; end if;
  if p_status not in ('open', 'under_review', 'closed') then raise exception 'invalid case status' using errcode = '22023'; end if;
  if p_status = 'closed' and coalesce(btrim(p_note), '') = '' then raise exception 'a resolution is required to close a case' using errcode = '23514'; end if;
  update security_cases set status = p_status, resolution = case when p_status = 'closed' then p_note else resolution end,
         closed_by = case when p_status = 'closed' then current_staff_id() end, closed_at = case when p_status = 'closed' then now() end where id = p_case;
  if not found then raise exception 'case not found' using errcode = 'P0002'; end if;
end $$;
revoke execute on function security_case_update(uuid, text, text) from public, anon;
grant execute on function security_case_update(uuid, text, text) to authenticated;

alter table security_policies enable row level security;
alter table security_events enable row level security;
alter table security_cases enable row level security;
alter table security_case_events enable row level security;
revoke all on security_policies, security_events, security_cases, security_case_events from anon, authenticated;
grant select on security_policies, security_events, security_cases, security_case_events to authenticated;
grant insert, update on security_policies to authenticated;
create policy security_policies_select on security_policies for select to authenticated using (has_permission('security.view'));
create policy security_policies_insert on security_policies for insert to authenticated with check (has_permission('security.manage'));
create policy security_policies_update on security_policies for update to authenticated using (has_permission('security.manage')) with check (has_permission('security.manage'));
create policy security_events_select on security_events for select to authenticated using (has_permission('security.view'));
create policy security_cases_select on security_cases for select to authenticated using (has_permission('security.view'));
create policy security_case_events_select on security_case_events for select to authenticated using (has_permission('security.view'));
do $$ begin perform attach_audit('security_policies'); perform attach_audit('security_cases'); end $$;

-- ---------------------------------------------------------------------------
-- 6. Routing and retrieval: registry first
-- ---------------------------------------------------------------------------
-- What is this thing and where does it live? SECURITY INVOKER: the registry's row security (-> the authoritative table's) decides.
create function entity_resolve(p_id text) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare v text := upper(btrim(coalesce(p_id, ''))); r entity_registry%rowtype;
begin
  if v ~ '^ADA-[A-Z]{3}-[0-9]{4}-[0-9]{4}$' then
    select * into r from entity_registry where ada_id = v;
  elsif ada_id_valid(v) then
    select * into r from entity_registry where institutional_id = v;
  end if;
  if r.institutional_id is null then
    perform security_note_lookup(p_id, 'resolve');
    return null;
  end if;
  return jsonb_build_object('institutional_id', r.institutional_id, 'legacy_identifier', r.ada_id, 'entity_family', r.entity_family, 'entity_type', r.entity_type,
    'authoritative_domain', r.table_name, 'authoritative_record_key', r.entity_id, 'origin', jsonb_build_object('division_id', r.origin_division_id, 'year', r.origin_year, 'kind', r.origin_kind),
    'current', jsonb_build_object('division_id', r.current_division_id, 'location', r.current_location), 'status', r.status, 'classification', r.classification,
    'authorization_scope', r.authorization_scope, 'routing_version', r.routing_version);
end $$;

-- Resolve, then fetch the authoritative record through the type's 360 function (invoker rights: row security applies again)
create function entity_view_fn(p_type text) returns text
language sql stable security definer set search_path = public, pg_temp as $$ select view_fn from entity_types where key = p_type $$;
create function entity_get(p_id text) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare m jsonb := entity_resolve(p_id); fn text; rec jsonb;
begin
  if m is null then return null; end if;
  fn := entity_view_fn(m ->> 'entity_type');
  if fn is not null then execute format('select public.%I($1)', fn) into rec using (m ->> 'authoritative_record_key')::uuid; end if;
  return m || jsonb_build_object('record', rec);
end $$;
revoke execute on function entity_resolve(text), entity_get(text), entity_view_fn(text) from public, anon;
grant execute on function entity_resolve(text), entity_get(text), entity_view_fn(text) to authenticated;

-- Derived, rebuildable search index: NOT a source of truth. Rows are visible exactly as the authoritative record is.
create table search_index (
  institutional_id text primary key references entity_registry (institutional_id),
  entity_type      text not null,
  table_name       text not null,
  entity_id        uuid not null,
  label            text not null,
  refreshed_at     timestamptz not null default now()
);
create index search_index_label_trgm on search_index using gin (label extensions.gin_trgm_ops);
comment on table search_index is 'Purpose: DERIVED lookup labels for fast retrieval, rebuildable at any time from the authoritative records by search_rebuild(). Not authoritative, not the registry. Visible only for entities the caller may read. [class: internal]';
create function search_rebuild() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare t record; n integer := 0; k integer;
begin
  delete from search_index;
  for t in select key, domain_table, label_col from entity_types where is_built and label_col is not null and domain_table is not null loop
    execute format('insert into search_index (institutional_id, entity_type, table_name, entity_id, label)
                    select r.institutional_id, r.entity_type, r.table_name, r.entity_id, x.%I::text from entity_registry r join public.%I x on x.id = r.entity_id
                    where r.entity_type = %L and x.%I is not null', t.label_col, t.domain_table, t.key, t.label_col);
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;
revoke execute on function search_rebuild() from public, anon, authenticated;
grant execute on function search_rebuild() to service_role;
alter table search_index enable row level security;
revoke all on search_index from anon, authenticated;
grant select on search_index to authenticated;
create policy search_index_select on search_index for select to authenticated using (entity_visible(table_name, entity_id));

-- The router: an ID goes straight through the registry (no table scan); free text uses the derived index
create function search_route(p_query text) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare v text := btrim(coalesce(p_query, '')); res jsonb;
begin
  if v = '' then return jsonb_build_object('route', 'none', 'results', '[]'::jsonb); end if;
  if upper(v) ~ '^ADA-[A-Z]{3}-[0-9]{4}-[0-9]{4}$' or upper(v) ~ '^[0-9A-HJKMNP-TV-Z]{9}$' then
    res := entity_resolve(v);
    return jsonb_build_object('route', 'registry', 'results', case when res is null then '[]'::jsonb else jsonb_build_array(res) end);
  end if;
  return jsonb_build_object('route', 'index', 'results', coalesce((
    select jsonb_agg(jsonb_build_object('institutional_id', s.institutional_id, 'entity_type', s.entity_type, 'label', s.label) order by s.label)
    from (select * from search_index where label ilike '%' || v || '%' limit 20) s), '[]'::jsonb));
end $$;
revoke execute on function search_route(text) from public, anon;
grant execute on function search_route(text) to authenticated;

revoke all on id_codebook_versions, id_codebook, id_settings, id_counters from anon, authenticated;
alter table id_codebook_versions enable row level security;
alter table id_codebook enable row level security;
alter table id_settings enable row level security;
alter table id_counters enable row level security;
revoke execute on function id_b32(bigint, integer), id_check_char(text), id_scramble(bigint, text), ada_mint_id(text, integer), ada_id_decode(text),
  registry_attrs(entity_types, jsonb), security_evaluate(bigint), security_report_bypass(uuid, text, text) from public, anon, authenticated;
revoke execute on function ada_id_valid(text) from public, anon;
grant execute on function ada_id_valid(text) to authenticated;
grant execute on function ada_id_decode(text) to service_role;

do $$ begin perform attach_audit('id_codebook_versions'); end $$;
