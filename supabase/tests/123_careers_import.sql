-- PERMANENT: Careers import - the owner-only import functions create vacancies and applications as exported, keep every extra detail and the CV as a reference,
-- are safe to run twice, skip test/unusable/duplicate records, send no notifications, and nobody else can run them.
begin;
select tests.setup();
select tests.setup_hr();
create table tests.outs (k text primary key, v text);
create function tests.o(p_key text, p_val text) returns void language sql as $$ insert into tests.outs values (p_key, p_val) on conflict (k) do update set v = excluded.v $$;
create function tests.g(p_key text) returns text language sql stable as $$ select v from tests.outs where k = p_key $$;

select tests.check('1. nobody but the owner can run the imports (signed-in staff and the public API role are refused)',
  tests.scalar('ceo', $q$ select import_vacancy('{"legacy_id":"x","title":"x","division":"web"}'::jsonb)::text $q$) || tests.scalar('web_lead', $q$ select import_application('{"legacy_id":"x"}'::jsonb)::text $q$), 'ERR:42501ERR:42501');
select tests.o('v1', import_vacancy('{"legacy_id":"op-1","title":"Web Developer","division":"web","employment_type":"full_time","status":"published","openings":2,"closing_date":"2099-12-31","summary":"Build sites","description":"Work","requirements":"HTML","created_at":"2026-09-01T08:00:00Z"}'::jsonb)::text);
select tests.o('v1b', import_vacancy('{"legacy_id":"op-1","title":"Web Developer","division":"web"}'::jsonb)::text);
select tests.o('v2', import_vacancy('{"legacy_id":"op-t","title":"TEST","division":"web","is_test":true}'::jsonb)::text);
select tests.check('2. a vacancy is created as exported (status, openings, closing date, original creation date, a position made for it); running again returns the same one; test records are skipped',
  (tests.g('v1')::jsonb ->> 'result') || '/' || (tests.g('v1b')::jsonb ->> 'result') || '/' || (tests.g('v2')::jsonb ->> 'result') || '|' ||
  (select status::text || openings || closing_date::text || created_at::date::text || (ada_id = tests.g('v1')::jsonb ->> 'id')::text from vacancies where title = 'Web Developer') || '|' ||
  (select count(*)::text from positions where title = 'Web Developer') || (select count(*)::text from vacancies where title = 'TEST'), 'created/exists/skipped|published22099-12-312026-09-01true|10');
select tests.check('3. unknown divisions and employment types are refused, not guessed',
  tests.try_owner($q$ select import_vacancy('{"legacy_id":"q","title":"x","division":"nowhere"}'::jsonb) $q$) || tests.try_owner($q$ select import_vacancy('{"legacy_id":"q2","title":"x","division":"web","employment_type":"casual"}'::jsonb) $q$), 'ERR:22023ERR:22P02');
select tests.o('a1', import_application('{"legacy_id":"ap-1","vacancy_legacy_id":"op-1","full_name":"Fixture One","email":"Fixture.One@Example.test","phone":"+264 81 000 0001","status":"shortlisted","cv_ref":"legacy-storage:career-documents/applications/ap-1/cv.pdf","submitted_at":"2026-09-10T09:00:00Z","details":{"skills":"HTML","nationality":"Namibian","internal_notes":"Strong"}}'::jsonb)::text);
select tests.o('a1b', import_application('{"legacy_id":"ap-1","vacancy_legacy_id":"op-1","full_name":"Fixture One","email":"fixture.one@example.test"}'::jsonb)::text);
select tests.o('a2', import_application('{"legacy_id":"ap-2","vacancy_legacy_id":"op-1","full_name":"Same Person Again","email":"fixture.one@example.test"}'::jsonb)::text);
select tests.o('a3', import_application('{"legacy_id":"ap-3","vacancy_legacy_id":"op-1","full_name":"No Email","email":""}'::jsonb)::text);
select tests.o('a4', import_application('{"legacy_id":"ap-4","vacancy_legacy_id":null,"division":"marketing","full_name":"Talent Pool Person","email":"pool@example.test","status":"withdrawn","submitted_at":"2026-09-13T09:00:00Z"}'::jsonb)::text);
select tests.check('4. an application keeps its status, original date, CV reference and every extra detail; the person is matched by e-mail (case-insensitive); a repeat is recognised',
  (tests.g('a1')::jsonb ->> 'result') || '/' || (tests.g('a1b')::jsonb ->> 'result') || '|' ||
  (select a.status::text || '|' || a.cv_ref || '|' || a.submitted_at::date::text || '|' || (a.details ->> 'skills') || (a.details ->> 'internal_notes') || '|' || p.email from applications a join people p on p.id = a.person_id where a.ada_id = tests.g('a1')::jsonb ->> 'id'),
  'created/exists|shortlisted|legacy-storage:career-documents/applications/ap-1/cv.pdf|2026-09-10|HTMLStrong|fixture.one@example.test');
select tests.check('5. the same person twice for one vacancy and a record with no usable e-mail are skipped with a reason',
  (tests.g('a2')::jsonb ->> 'result') || ':' || (tests.g('a2')::jsonb ->> 'reason') || '|' || (tests.g('a3')::jsonb ->> 'result') || ':' || (tests.g('a3')::jsonb ->> 'reason'),
  'skipped:this person already has an application for that vacancy|skipped:no usable name or email');
select tests.check('6. an application that was not for a specific vacancy goes to one standing closed vacancy of its division (made once)',
  (select v.title || ':' || v.status::text || ':' || d.key from applications a join vacancies v on v.id = a.vacancy_id join divisions d on d.id = v.division_id where a.ada_id = tests.g('a4')::jsonb ->> 'id') || '|' ||
  (select count(*)::text from vacancies where title like 'General applications%'), 'General applications (imported from the previous website):closed:marketing|1');
select tests.check('7. history is recorded, no notification and no application event is raised by an import, and the legacy map has every imported vacancy and application',
  (select count(*)::text from application_status_history h join applications a on a.id = h.application_id where h.reason = 'imported from the previous website') || '|' ||
  (select count(*)::text from notifications where type = 'application.submitted') || (select count(*)::text from events where event_type = 'application.submitted') || '|' ||
  (select count(*)::text from legacy_imports), '2|00|3');
select tests.check('8. imported applications are visible to recruitment and to nobody else (division staff, suspended staff, outsiders see none)',
  tests.scalar('ceo', 'select count(*)::text from applications') || tests.scalar('web_staff', 'select count(*)::text from applications') || tests.scalar('suspended', 'select count(*)::text from applications') || tests.scalar('outsider', 'select count(*)::text from applications'), '2000');
select tests.finish();
rollback;
