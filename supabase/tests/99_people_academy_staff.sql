-- PERMANENT: one person, many roles; automatic Student and Staff IDs that never change; academic history linked to a stable identity.
begin;
select tests.setup();
select tests.setup_hr();
create temp table fake as select 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ') as id;
select tests.add_staff('acad_lead', 'division_lead', 'academy');
select tests.add_staff('acad_staff', 'division_staff', 'academy');

-- Academy: programme, cohort, admission ----------------------------------------------------------------------------------------------------------------
select tests.check('Web''s lead cannot create Academy programmes', tests.scalar('web_lead', format($q$ select programme_create('Diploma in IT', %L)::text $q$, tests.id('div:academy'))), 'ERR:42501');
select tests.remember('prg:it', tests.scalar('acad_lead', format($q$ select programme_create('Diploma in IT', %L, 'computing', 'diploma')::text $q$, tests.id('div:academy'))));
select tests.remember('prg:bus', tests.scalar('acad_lead', format($q$ select programme_create('Certificate in Business', %L, 'business', 'certificate')::text $q$, tests.id('div:academy'))));
select tests.remember('coh:it26', tests.scalar('acad_lead', format($q$ select cohort_create(%L, 'January intake', 2026, current_date, current_date + 300)::text $q$, tests.id('prg:it'))));
select tests.remember('coh:it27', tests.scalar('acad_lead', format($q$ select cohort_create(%L, 'January intake', 2027)::text $q$, tests.id('prg:it'))));
select tests.remember('coh:bus26', tests.scalar('acad_lead', format($q$ select cohort_create(%L, 'July intake', 2026)::text $q$, tests.id('prg:bus'))));
select tests.check('programmes and cohorts are registered entities', (select string_agg(distinct entity_type, ',' order by entity_type) from entity_registry where entity_type in ('programme', 'cohort')), 'cohort,programme');

-- One person, many roles ---------------------------------------------------------------------------------------------------------------------------
select tests.mkclient_id('web_lead', 'Acme Training', 'web');
insert into tests.ids select 'client:acme', id from clients where name = 'Acme Training';
select tests.scalar('web_lead', format($q$ select add_client_contact(%L, 'Nelly Shikongo', 'nelly@example.test', null, 'Training manager', true)::text $q$, tests.id('client:acme')));
insert into tests.ids select 'person:nelly', id from people where email = 'nelly@example.test';
insert into vacancies (position_id, title, description, requirements, status, published_at) select id, 'Web Developer', 'd', 'r', 'published', now() from positions where title = 'Web Developer';
select tests.try('recruiter', $q$ select staff_record_application((select id from vacancies where title = 'Web Developer'), 'Nelly Shikongo', 'nelly@example.test') $q$);
select tests.check('so far: one person, who is a client contact and an applicant', (select count(*)::text from people where email = 'nelly@example.test') || (select count(*)::text from client_contacts where person_id = tests.id('person:nelly')) || (select count(*)::text from applications where person_id = tests.id('person:nelly')), '111');
select tests.check('a person who is not yet a student cannot be enrolled twice, and a missing person is refused',
  tests.scalar('acad_lead', format($q$ select student_admit(%L, %L)::text $q$, gen_random_uuid(), tests.id('prg:it'))), 'ERR:P0002');
select tests.check('the Academy lead can only admit a person they can see: Nelly is not visible to Academy yet (contact and applicant belong to other divisions)',
  tests.scalar('acad_lead', format($q$ select student_admit(%L, %L)::text $q$, tests.id('person:nelly'), tests.id('prg:it'))), 'ERR:P0002');
create temp table adm as select tests.scalar('ceo', format($q$ select student_admit(%L, %L, %L, 'Admitted from the January list')::text $q$, tests.id('person:nelly'), tests.id('prg:it'), tests.id('coh:it26')))::jsonb j;
select tests.check('the admission returned a generated 9-character Student ID, the origin division and the status', (select (j ->> 'institutional_id' ~ '^[0-9A-HJKMNP-TV-Z]{9}$' and j ->> 'origin_division' = 'academy' and j ->> 'status' = 'admitted')::text from adm), 'true');
insert into tests.ids select 'student:nelly', (j ->> 'student_id')::uuid from adm;
create temp table sid as select j ->> 'institutional_id' i from adm;
select tests.check('the Student ID is in the registry as a student, in the people/organization family, originating in Academy',
  (select concat_ws('|', entity_type, entity_family, (origin_division_id = tests.id('div:academy'))::text, table_name) from entity_registry where institutional_id = (select i from sid)), 'student|people_org|true|students');
select tests.check('the student record holds no name, email or phone (those stay on the person)', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name in ('students', 'student_enrolments', 'programmes', 'cohorts') and column_name ~ '(name|email|phone)' and column_name not in ('name')), 'none');
select tests.check('an existing student cannot be admitted again: one ID for life', tests.scalar('ceo', format($q$ select student_admit(%L, %L)::text $q$, tests.id('person:nelly'), tests.id('prg:bus'))), 'ERR:23505');
select tests.check('the person is still ONE record with a client-contact, applicant and student relationship',
  (select count(*)::text from people where email = 'nelly@example.test') || (select count(*)::text from students where person_id = tests.id('person:nelly')), '11');
-- a staff relationship for the same person
insert into staff (full_name, email, person_id, position_id, primary_division_id) select 'Nelly Shikongo', 'nelly.staff@ada.test', tests.id('person:nelly'), (select id from positions where title = 'Web Developer'), tests.id('div:web');
insert into tests.ids select 'staff:nelly', id from staff where email = 'nelly.staff@ada.test';
select tests.check('...and a staff relationship, still on the same person row (no duplicate person was created)', (select count(*)::text from people where email = 'nelly@example.test' or full_name = 'Nelly Shikongo'), '1');
select tests.check('management sees all four relationships, each with its own institutional ID',
  (select (jsonb_array_length(j -> 'staff') = 1 and jsonb_array_length(j -> 'student') = 1 and jsonb_array_length(j -> 'contacts') = 1 and jsonb_array_length(j -> 'applications') = 1 and (j -> 'person' ->> 'institutional_id') is not null)::text
   from (select tests.scalar('ceo', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q), 'true');
select tests.check('the role IDs are all different identities (person, staff, student, contact, application)',
  (select count(distinct id)::text from (select (j -> 'person' ->> 'institutional_id') id from (select tests.scalar('ceo', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q
     union all select x ->> 'institutional_id' from (select tests.scalar('ceo', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q, jsonb_array_elements(j -> 'staff') x
     union all select x ->> 'institutional_id' from (select tests.scalar('ceo', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q, jsonb_array_elements(j -> 'student') x
     union all select x ->> 'institutional_id' from (select tests.scalar('ceo', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q, jsonb_array_elements(j -> 'contacts') x
     union all select x ->> 'institutional_id' from (select tests.scalar('ceo', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q, jsonb_array_elements(j -> 'applications') x) z), '5');
select tests.check('relationships carry privacy: the Academy lead sees only the student slice of the same person, not the contact or the application',
  (select (jsonb_array_length(j -> 'student') = 1 and jsonb_array_length(j -> 'contacts') = 0 and jsonb_array_length(j -> 'applications') = 0)::text from (select tests.scalar('acad_lead', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q), 'true');
select tests.check('...and the Web lead sees the contact slice only', (select (jsonb_array_length(j -> 'student') = 0 and jsonb_array_length(j -> 'contacts') = 1)::text from (select tests.scalar('web_lead', format('select person_relationships(%L)::text', tests.id('person:nelly')))::jsonb j) q), 'true');

-- The Student ID never changes ------------------------------------------------------------------------------------------------------------------------
select tests.check('the Academy lead now sees the student and the enrolment', tests.scalar('acad_lead', format('select (select count(*) from students where id = %L)::text || (select count(*) from student_enrolments where student_id = %L)', tests.id('student:nelly'), tests.id('student:nelly'))), '11');
select tests.check('a change of COHORT (same programme) keeps the Student ID', tests.try('acad_lead', format($q$ select student_enrol(%L, %L, %L, 'Moved to the 2027 intake') $q$, tests.id('student:nelly'), tests.id('prg:it'), tests.id('coh:it27'))), 'ok');
select tests.check('...unchanged', (select (institutional_id = (select i from sid))::text from entity_registry where entity_type = 'student' and entity_id = tests.id('student:nelly')), 'true');
select tests.check('a change of PROGRAMME keeps the Student ID', tests.try('acad_lead', format($q$ select student_enrol(%L, %L, %L, 'Switched to business') $q$, tests.id('student:nelly'), tests.id('prg:bus'), tests.id('coh:bus26'))), 'ok');
select tests.check('...unchanged', (select (institutional_id = (select i from sid))::text from entity_registry where entity_type = 'student' and entity_id = tests.id('student:nelly')), 'true');
select tests.check('a cohort of another programme is refused', tests.scalar('acad_lead', format($q$ select student_enrol(%L, %L, %L)::text $q$, tests.id('student:nelly'), tests.id('prg:bus'), tests.id('coh:it26'))), 'ERR:P0002');
select tests.check('academic records remain linked: three enrolments, all on the same student, two closed as transferred and one open',
  (select count(*)::text || '/' || count(*) filter (where status = 'transferred')::text || '/' || count(*) filter (where ends_on is null)::text from student_enrolments where student_id = tests.id('student:nelly')), '3/2/1');
select tests.check('enrolments are registered entities too, each with its own ID', (select count(*)::text from entity_registry r join student_enrolments e on e.id = r.entity_id where r.entity_type = 'enrollment' and e.student_id = tests.id('student:nelly')), '3');
select tests.check('academic history cannot be rewritten or deleted', tests.try_owner(format('update student_enrolments set programme_id = %L where student_id = %L', tests.id('prg:it'), tests.id('student:nelly'))) || tests.try_owner(format('delete from student_enrolments where student_id = %L', tests.id('student:nelly'))), 'ERR:42501ERR:42501');
select tests.check('one open enrolment at a time (database rule)', tests.try_owner(format('insert into student_enrolments (student_id, programme_id, division_id) values (%L, %L, %L)', tests.id('student:nelly'), tests.id('prg:it'), tests.id('div:academy'))), 'ERR:23505');
select tests.check('status changes (active, suspended) keep the ID and the registry mirrors the status',
  tests.try('acad_lead', format($q$ select student_set_status(%L, 'active') $q$, tests.id('student:nelly'))) || tests.try('acad_lead', format($q$ select student_set_status(%L, 'suspended', 'Fees') $q$, tests.id('student:nelly'))), 'okok');
select tests.check('...mirrored in the registry, same ID', (select (institutional_id = (select i from sid))::text || status from entity_registry where entity_type = 'student' and entity_id = tests.id('student:nelly')), 'truesuspended');
select tests.check('Academy staff cannot change student status (students.manage)', tests.scalar('acad_staff', format($q$ select student_set_status(%L, 'active')::text $q$, tests.id('student:nelly'))), 'ERR:42501');
select tests.check('graduating closes the open enrolment as completed; the ID is still the same; and the status is final',
  tests.try('acad_lead', format($q$ select student_set_status(%L, 'graduated') $q$, tests.id('student:nelly'))), 'ok');
select tests.check('...enrolment completed, ID unchanged', (select status from student_enrolments where student_id = tests.id('student:nelly') and ends_on = current_date and status = 'completed' limit 1) || (select (institutional_id = (select i from sid))::text from entity_registry where entity_type = 'student' and entity_id = tests.id('student:nelly')), 'completedtrue');
select tests.check('a graduated student cannot be re-enrolled or changed', tests.scalar('acad_lead', format($q$ select student_enrol(%L, %L)::text $q$, tests.id('student:nelly'), tests.id('prg:it'))) || tests.scalar('acad_lead', format($q$ select student_set_status(%L, 'active')::text $q$, tests.id('student:nelly'))), 'ERR:23514ERR:23514');
select tests.check('students are never deleted and their person is permanent', tests.try_owner('delete from students') || tests.try_owner(format('update students set person_id = (select id from people where email <> ''nelly@example.test'' limit 1) where id = %L', tests.id('student:nelly'))) , 'ERR:42501ERR:42501');
select tests.check('students are invisible outside Academy, indistinguishable from nonexistent',
  tests.scalar('web_lead', format('select count(*)::text from students where id = %L', tests.id('student:nelly'))) || tests.same_for('web_lead', $q$ select count(*)::text from students where id = %L $q$, tests.id('student:nelly'), gen_random_uuid()), '0same');
select tests.check('...and so is the Student ID in the registry', tests.outcome('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select i from sid))), tests.outcome('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select id from fake))));
select tests.check('Academy''s lead resolves the Student ID', tests.scalar('acad_lead', format($q$ select (entity_resolve(%L) ->> 'entity_type') $q$, (select i from sid))), 'student');

-- Staff IDs: automatic, one framework for every role, never change ------------------------------------------------------------------------------------
insert into staff (full_name, email, position_id, primary_division_id) select 'Lena Lecturer', 'lena@ada.test', (select id from positions where title = 'IT Technician'), tests.id('div:academy');
insert into staff (full_name, email, position_id, primary_division_id) select 'Adam Administrator', 'adam@ada.test', (select id from positions where title = 'Web Developer'), tests.id('div:management');
insert into staff (full_name, email, position_id, primary_division_id) select 'Tessa Technician', 'tessa@ada.test', (select id from positions where title = 'IT Technician'), tests.id('div:tech');
select tests.check('every staff record receives its own automatic Staff ID in the same framework, whatever the job',
  (select count(distinct institutional_id)::text || '/' || count(distinct entity_type)::text || '/' || bool_and(institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text from entity_registry r join staff s on s.id = r.entity_id and r.table_name = 'staff' where s.email in ('lena@ada.test', 'adam@ada.test', 'tessa@ada.test')), '3/1/true');
create temp table lena as select institutional_id i, origin_division_id o from entity_registry where entity_id = (select id from staff where email = 'lena@ada.test');
update staff set position_id = (select id from positions where title = 'Web Developer') where email = 'lena@ada.test';
select tests.check('a change of position keeps the Staff ID', (select (institutional_id = (select i from lena))::text from entity_registry where entity_id = (select id from staff where email = 'lena@ada.test')), 'true');
insert into staff_roles (staff_id, role_id, division_id) select (select id from staff where email = 'lena@ada.test'), id, tests.id('div:academy') from roles where key = 'division_lead';
select tests.check('a change of role keeps the Staff ID', (select (institutional_id = (select i from lena))::text from entity_registry where entity_id = (select id from staff where email = 'lena@ada.test')), 'true');
update staff set primary_division_id = tests.id('div:web') where email = 'lena@ada.test';
select tests.check('a change of division keeps the Staff ID and the origin; the current division follows',
  (select (institutional_id = (select i from lena) and origin_division_id = (select o from lena) and origin_division_id = tests.id('div:academy') and current_division_id = tests.id('div:web'))::text from entity_registry where entity_id = (select id from staff where email = 'lena@ada.test')), 'true');
update staff set employment_status = 'terminated' where email = 'lena@ada.test';
select tests.check('even leaving the organization keeps the Staff ID reserved (it is never reissued)', (select (institutional_id = (select i from lena))::text || status from entity_registry where entity_id = (select id from staff where email = 'lena@ada.test')), 'trueterminated');
select tests.check('Staff ID is the person''s staff identity, not the job: the registry has no position or role column', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'entity_registry' and column_name ~ '(position|role|title)'), 'none');

select tests.finish();
rollback;
