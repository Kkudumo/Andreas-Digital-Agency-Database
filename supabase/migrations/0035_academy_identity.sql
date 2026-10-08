-- 0035_academy_identity: the identity core of ADA Academy, built now to prove the institutional rules on a second domain:
--   Application -> admission -> Student entity -> AUTOMATIC permanent Student ID (registry) -> academic records.
--  * A student is a ROLE of a person: students.person_id -> people (one person record; a person is at most one student).
--  * The Student ID is minted by the central ID service when the student record is created and never changes. Programme,
--    cohort, academic year, semester and status are separate, historical facts (student_enrolments) - changing any of them
--    adds a row, it never touches the identity.
--  * Only the identity layer is here (programmes, cohorts, students, enrolments). Courses, modules, assessments, results,
--    attendance and certificates are reserved in the codebook and will attach to the same students.

create table programmes (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (btrim(name) <> ''),
  programme_family text,
  level            text,
  division_id      uuid not null references divisions (id),
  status           text not null default 'active' check (status in ('active', 'retired')),
  created_by       uuid references staff (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index programmes_name_unique on programmes (lower(btrim(name)), division_id);
comment on table programmes is 'Purpose: an Academy programme. Academic identity (programme/cohort/period) is separate from Student identity. [class: internal]';
create trigger programmes_updated before update on programmes for each row execute function set_updated_at();
select attach_entity('programmes', 'programme');

create table cohorts (
  id            uuid primary key default gen_random_uuid(),
  programme_id  uuid not null references programmes (id),
  name          text not null check (btrim(name) <> ''),
  academic_year integer not null check (academic_year between 2000 and 2100),
  starts_on     date,
  ends_on       date,
  division_id   uuid not null references divisions (id),
  status        text not null default 'planned' check (status in ('planned', 'active', 'completed', 'cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (programme_id, name, academic_year),
  check (ends_on is null or starts_on is null or ends_on >= starts_on)
);
comment on table cohorts is 'Purpose: an intake of a programme in an academic year. [class: internal]';
create trigger cohorts_updated before update on cohorts for each row execute function set_updated_at();
select attach_entity('cohorts', 'cohort');

create table students (
  id             uuid primary key default gen_random_uuid(),
  person_id      uuid not null unique references people (id) on delete restrict,
  division_id    uuid not null references divisions (id),
  status         text not null default 'admitted' check (status in ('admitted', 'active', 'suspended', 'withdrawn', 'graduated')),
  admitted_on    date not null default current_date,
  classification data_classification not null default 'internal',
  created_by     uuid references staff (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table students is 'Purpose: the student role of a person. Holds no name, email or phone (those are people). The permanent Student ID lives in the entity registry and is generated automatically at admission. [class: restricted by permission]';
create trigger students_updated before update on students for each row execute function set_updated_at();
select attach_entity('students', 'student', 'admitted');

create table student_enrolments (
  id           uuid primary key default gen_random_uuid(),
  student_id   uuid not null references students (id) on delete restrict,
  programme_id uuid not null references programmes (id),
  cohort_id    uuid references cohorts (id),
  division_id  uuid not null references divisions (id),
  starts_on    date not null default current_date,
  ends_on      date,
  status       text not null default 'active' check (status in ('active', 'completed', 'withdrawn', 'transferred')),
  note         text,
  created_by   uuid references staff (id),
  created_at   timestamptz not null default now(),
  check ((ends_on is null) = (status = 'active'))
);
create unique index student_enrolments_one_open on student_enrolments (student_id) where ends_on is null;
create index student_enrolments_student_idx on student_enrolments (student_id, starts_on);
comment on table student_enrolments is 'Purpose: academic history - which programme/cohort a student was on, when. A change of programme or cohort closes one row and opens another; the Student ID never changes. Rows are never deleted or rewritten. [class: restricted by permission]';
select attach_entity('student_enrolments', 'enrollment');

create function student_enrolments_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'academic history cannot be deleted' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and (old.ends_on is not null or (new.student_id, new.programme_id, new.cohort_id, new.division_id, new.starts_on, new.created_by) is distinct from (old.student_id, old.programme_id, old.cohort_id, old.division_id, old.starts_on, old.created_by)) then
    raise exception 'academic history cannot be rewritten: close the enrolment and open a new one' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger student_enrolments_guard_trg before update or delete on student_enrolments for each row execute function student_enrolments_guard();
create function students_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'students are never deleted; their status changes' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then new.created_by := current_staff_id(); return new; end if;
  if new.person_id is distinct from old.person_id then raise exception 'a student record belongs to one person for life' using errcode = '42501'; end if;
  return new;
end $$;
create trigger students_guard_trg before insert or update or delete on students for each row execute function students_guard();

create function can_view_student_row(p_division uuid, p_class data_classification) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('students.view', p_division) and classification_visible(p_class)
$$;
create function can_view_student(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_student_row(s.division_id, s.classification) from students s where s.id = p_id), false)
$$;

-- A student's person is visible to those who may see the student (the relationship carries the privacy, as for contacts and staff)
create or replace function can_view_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from staff s where s.person_id = p_id and has_permission('hr.view'))
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.view', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_view_client(cc.client_id))
      or exists (select 1 from leads l where l.person_id = p_id and has_permission('leads.view', l.division_id) and classification_visible(l.effective_classification))
      or exists (select 1 from students st where st.person_id = p_id and can_view_student_row(st.division_id, st.classification))
$$;

create function programme_create(p_name text, p_division uuid, p_family text default null, p_level text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not has_permission('programmes.manage', p_division) then raise exception 'programmes.manage is required in that division' using errcode = '42501'; end if;
  insert into programmes (name, programme_family, level, division_id, created_by) values (p_name, p_family, p_level, p_division, current_staff_id()) returning id into v_id;
  return v_id;
end $$;

create function cohort_create(p_programme uuid, p_name text, p_year integer, p_starts date default null, p_ends date default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare pr programmes%rowtype; v_id uuid;
begin
  select * into pr from programmes where id = p_programme and status = 'active';
  if not found then raise exception 'programme not found' using errcode = 'P0002'; end if;
  if not has_permission('programmes.manage', pr.division_id) then raise exception 'programmes.manage is required in that division' using errcode = '42501'; end if;
  insert into cohorts (programme_id, name, academic_year, starts_on, ends_on, division_id) values (p_programme, p_name, p_year, p_starts, p_ends, pr.division_id) returning id into v_id;
  return v_id;
end $$;

-- Admission: the ONE moment a Student entity is created. The Student ID is generated by ADA Core; nobody types it.
create function student_admit(p_person uuid, p_programme uuid, p_cohort uuid default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pr programmes%rowtype; c cohorts%rowtype; v_student uuid; v_inst text;
begin
  select * into pr from programmes where id = p_programme and status = 'active';
  if not found then raise exception 'programme not found' using errcode = 'P0002'; end if;
  if not has_permission('students.admit', pr.division_id) then raise exception 'students.admit is required in that division' using errcode = '42501'; end if;
  if not exists (select 1 from people where id = p_person) or not can_view_person(p_person) then raise exception 'person not found' using errcode = 'P0002'; end if;
  if p_cohort is not null then
    select * into c from cohorts where id = p_cohort and programme_id = p_programme;
    if not found then raise exception 'cohort not found for this programme' using errcode = 'P0002'; end if;
  end if;
  if exists (select 1 from students where person_id = p_person) then
    raise exception 'this person is already a student: enrol them instead (a student keeps one ID for life)' using errcode = '23505';
  end if;
  insert into students (person_id, division_id) values (p_person, pr.division_id) returning id into v_student;
  insert into student_enrolments (student_id, programme_id, cohort_id, division_id, note, created_by) values (v_student, p_programme, p_cohort, pr.division_id, p_note, current_staff_id());
  select institutional_id into v_inst from entity_registry where entity_type = 'student' and entity_id = v_student;
  perform emit_event('student.admitted', 'students', v_student, v_inst, '{}');
  return jsonb_build_object('student_id', v_student, 'institutional_id', v_inst, 'origin_division', (select key from divisions where id = pr.division_id), 'status', 'admitted');
end $$;

-- A change of programme or cohort: close the open enrolment, open a new one. The Student ID is untouched.
create function student_enrol(p_student uuid, p_programme uuid, p_cohort uuid default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s students%rowtype; pr programmes%rowtype; c cohorts%rowtype; v_id uuid;
begin
  select * into s from students where id = p_student for update;
  if not found or not can_view_student_row(s.division_id, s.classification) then raise exception 'student not found' using errcode = 'P0002'; end if;
  select * into pr from programmes where id = p_programme and status = 'active';
  if not found then raise exception 'programme not found' using errcode = 'P0002'; end if;
  if not has_permission('students.admit', pr.division_id) then raise exception 'students.admit is required in that division' using errcode = '42501'; end if;
  if p_cohort is not null then
    select * into c from cohorts where id = p_cohort and programme_id = p_programme;
    if not found then raise exception 'cohort not found for this programme' using errcode = 'P0002'; end if;
  end if;
  if s.status in ('withdrawn', 'graduated') then raise exception 'a % student cannot be enrolled', s.status using errcode = '23514'; end if;
  update student_enrolments set ends_on = current_date, status = 'transferred' where student_id = s.id and ends_on is null;
  insert into student_enrolments (student_id, programme_id, cohort_id, division_id, note, created_by) values (s.id, p_programme, p_cohort, pr.division_id, p_reason, current_staff_id()) returning id into v_id;
  return v_id;
end $$;

create function student_set_status(p_student uuid, p_to text, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s students%rowtype;
begin
  select * into s from students where id = p_student for update;
  if not found or not can_view_student_row(s.division_id, s.classification) then raise exception 'student not found' using errcode = 'P0002'; end if;
  if not has_permission('students.manage', s.division_id) then raise exception 'students.manage is required' using errcode = '42501'; end if;
  if p_to not in ('active', 'suspended', 'withdrawn', 'graduated') then raise exception 'invalid student status' using errcode = '22023'; end if;
  if s.status in ('withdrawn', 'graduated') then raise exception 'a % student is final', s.status using errcode = '23514'; end if;
  update students set status = p_to where id = s.id;
  if p_to in ('withdrawn', 'graduated') then
    update student_enrolments set ends_on = current_date, status = case when p_to = 'graduated' then 'completed' else 'withdrawn' end where student_id = s.id and ends_on is null;
  end if;
end $$;

-- One person, many relationships: the same people row seen through every role the caller is allowed to see
create function person_relationships(p_person uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from people where id = p_person) then return null; end if;
  return jsonb_build_object(
    'person', (select jsonb_build_object('institutional_id', r.institutional_id) from entity_registry r where r.entity_type = 'person' and r.entity_id = p_person),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('institutional_id', r.institutional_id, 'status', st.employment_status)) from staff st join entity_registry r on r.entity_type = 'staff' and r.entity_id = st.id where st.person_id = p_person), '[]'),
    'student', coalesce((select jsonb_agg(jsonb_build_object('institutional_id', r.institutional_id, 'status', sd.status)) from students sd join entity_registry r on r.entity_type = 'student' and r.entity_id = sd.id where sd.person_id = p_person), '[]'),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('institutional_id', rc.institutional_id, 'client', rcl.institutional_id)) from client_contacts cc
                          join entity_registry rc on rc.entity_type = 'contact' and rc.entity_id = cc.id join entity_registry rcl on rcl.entity_type = 'client' and rcl.entity_id = cc.client_id where cc.person_id = p_person), '[]'),
    'applications', coalesce((select jsonb_agg(jsonb_build_object('institutional_id', ra.institutional_id)) from applications ap join entity_registry ra on ra.entity_type = 'application' and ra.entity_id = ap.id where ap.person_id = p_person), '[]'));
end $$;

-- Registering an asset the institutional way: the user supplies information, ADA Core supplies the identity and returns it
create function asset_register(p_name text, p_category text, p_division uuid, p_manufacturer text default null, p_model text default null,
                               p_serial text default null, p_tag text default null, p_condition asset_condition default 'good', p_status asset_status default 'proposed',
                               p_method asset_acquisition default null, p_acquired_on date default null, p_cost numeric default null, p_currency text default null,
                               p_supplier uuid default null, p_client uuid default null, p_project uuid default null, p_parent uuid default null,
                               p_location text default null, p_classification data_classification default 'internal') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; r entity_registry%rowtype;
begin
  v_id := asset_create(p_name, p_category, p_division, p_manufacturer, p_model, p_serial, p_tag, p_condition, p_status, p_method, p_acquired_on, p_cost, p_currency,
                       p_supplier, p_client, p_project, p_parent, p_location, p_classification);
  select * into r from entity_registry where entity_type = 'asset' and entity_id = v_id;
  return jsonb_build_object('asset_id', v_id, 'institutional_id', r.institutional_id, 'origin_division', (select key from divisions where id = r.origin_division_id),
                            'status', r.status, 'registered', true);
end $$;

alter table programmes enable row level security;
alter table cohorts enable row level security;
alter table students enable row level security;
alter table student_enrolments enable row level security;
revoke all on programmes, cohorts, students, student_enrolments from anon, authenticated;
grant select on programmes, cohorts, students, student_enrolments to authenticated;
create policy programmes_select on programmes for select to authenticated using (has_permission('students.view', division_id) or has_permission('programmes.manage', division_id));
create policy cohorts_select on cohorts for select to authenticated using (has_permission('students.view', division_id) or has_permission('programmes.manage', division_id));
create policy students_select on students for select to authenticated using (can_view_student_row(division_id, classification));
create policy student_enrolments_select on student_enrolments for select to authenticated using (can_view_student(student_id));

revoke execute on function can_view_student_row(uuid, data_classification), can_view_student(uuid), programme_create(text, uuid, text, text), cohort_create(uuid, text, integer, date, date),
  student_admit(uuid, uuid, uuid, text), student_enrol(uuid, uuid, uuid, text), student_set_status(uuid, text, text), person_relationships(uuid),
  asset_register(text, text, uuid, text, text, text, text, asset_condition, asset_status, asset_acquisition, date, numeric, text, uuid, uuid, uuid, uuid, text, data_classification) from public, anon, authenticated;
grant execute on function can_view_student_row(uuid, data_classification), can_view_student(uuid), programme_create(text, uuid, text, text), cohort_create(uuid, text, integer, date, date),
  student_admit(uuid, uuid, uuid, text), student_enrol(uuid, uuid, uuid, text), student_set_status(uuid, text, text), person_relationships(uuid),
  asset_register(text, text, uuid, text, text, text, text, asset_condition, asset_status, asset_acquisition, date, numeric, text, uuid, uuid, uuid, uuid, text, data_classification) to authenticated;

do $$ begin perform attach_audit('programmes'); perform attach_audit('cohorts'); perform attach_audit('students'); perform attach_audit('student_enrolments'); end $$;
