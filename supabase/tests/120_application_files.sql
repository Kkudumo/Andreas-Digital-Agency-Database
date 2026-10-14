-- PERMANENT: application files - a CV or supporting document arrives only with a one-time upload pass that ADA Core gives the website that took the
-- application (within an hour of it); the pass is stored hashed, expires, and cannot send the same kind twice; files are readable exactly as the application is.
begin;
select tests.setup();
select tests.setup_hr();
update websites set capabilities = capabilities || array['applications.submit'] where id = tests.id('site:main') and not ('applications.submit' = any (capabilities));

select tests.remember('vac:f', tests.scalar('web_lead', $q$ insert into vacancies (position_id, title, summary, description, requirements, closing_date, slug)
  select id, 'Web Developer Files', 'Join ADA Web', 'Build sites', 'HTML', current_date + 30, 'web-developer-files' from positions where title = 'Web Developer' returning id::text $q$));
select tests.scalar('web_lead', format($q$ select vacancy_transition(%L, 'pending_approval')::text $q$, tests.id('vac:f')));
select tests.scalar('ceo', format($q$ select vacancy_transition(%L, 'approved')::text $q$, tests.id('vac:f')));
select tests.scalar('ceo', format($q$ select vacancy_transition(%L, 'published')::text $q$, tests.id('vac:f')));
create temp table ref as select (tests.pub('main', 'submit_application', format('%L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:f')), 'Ben Files', 'ben@example.com'))::jsonb ->> 'reference') as r;
create temp table pass as select (tests.pub('main', 'open_application_upload', format('%L', (select r from ref)))::jsonb ->> 'upload_pass') as p;
grant select on pass to service_role;
create temp table app as select id from applications where ada_id = (select r from ref);

select tests.check('the website that took the application gets a 64-character upload pass, valid for 30 minutes',
  (select length(p)::text from pass) || '|' || (select (expires_at between now() + interval '29 minutes' and now() + interval '31 minutes')::text from application_upload_passes where application_id = (select id from app)), '64|true');
select tests.check('only the hash of the pass is stored', (select count(*)::text from application_upload_passes where token_hash = (select p from pass)), '0');
select tests.check('another website, an unknown application and a bad key get no pass', concat_ws('|',
  tests.pub('tech', 'open_application_upload', format('%L', (select r from ref))), tests.pub('main', 'open_application_upload', format('%L', 'ADA-APP-1999-0001')),
  tests.scalar_pub(format($q$ select public_api.open_application_upload('bad-key', %L)::text $q$, (select r from ref)))), 'ERR:42501|ERR:P0002|ERR:42501');

-- The Edge Function's two steps (run as service_role)
set local role service_role;
create temp table path_cv as select (application_upload_begin((select p from pass), 'cv', 'Ben CV.pdf', 'application/pdf', 2000) ->> 'path') as v;
reset role;
select tests.check('the storage path starts with the application and names the kind', (select (v ~ ('^' || (select id::text from app) || '/cv-[0-9a-f-]{36}\.pdf$'))::text from path_cv), 'true');
set local role service_role;
select application_upload_done((select p from pass), 'cv', (select v from path_cv), 'Ben CV.pdf', 'application/pdf', 2000);
reset role;
select tests.check('the CV is recorded and becomes the application''s cv_ref', (select count(*)::text from application_files where application_id = (select id from app) and kind = 'cv') || '|' ||
  (select (cv_ref = 'storage:applications/' || (select v from path_cv))::text from applications where id = (select id from app)), '1|true');

create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  set local role service_role;
  begin execute p_sql into v; reset role; return coalesce(v, 'ok');
  exception when others then reset role; return 'ERR:' || sqlstate; end;
end $$;
select tests.check('the same kind cannot be sent twice; a wrong pass, a wrong type, a 20 MB file and an unknown kind are refused', concat_ws('|',
  pg_temp.svc(format($q$ select application_upload_begin(%L, 'cv', 'again.pdf', 'application/pdf', 100)::text $q$, (select p from pass))),
  pg_temp.svc($q$ select application_upload_begin('not-a-pass', 'supporting', 'x.pdf', 'application/pdf', 100)::text $q$),
  pg_temp.svc(format($q$ select application_upload_begin(%L, 'supporting', 'x.exe', 'application/x-msdownload', 100)::text $q$, (select p from pass))),
  pg_temp.svc(format($q$ select application_upload_begin(%L, 'supporting', 'big.pdf', 'application/pdf', 20971520)::text $q$, (select p from pass))),
  pg_temp.svc(format($q$ select application_upload_begin(%L, 'photo', 'x.pdf', 'application/pdf', 100)::text $q$, (select p from pass)))), 'ERR:23505|ERR:42501|ERR:22023|ERR:22023|ERR:22023');
select tests.check('a file cannot be recorded under another application''s path', pg_temp.svc(format($q$ select application_upload_done(%L, 'supporting', %L, 'x.pdf', 'application/pdf', 100)::text $q$,
  (select p from pass), gen_random_uuid()::text || '/supporting-' || gen_random_uuid()::text || '.pdf')), 'ERR:42501');
update application_upload_passes set expires_at = now() - interval '1 second' where application_id = (select id from app);
select tests.check('an expired pass is refused', pg_temp.svc(format($q$ select application_upload_begin(%L, 'supporting', 'x.pdf', 'application/pdf', 100)::text $q$, (select p from pass))), 'ERR:42501');

select tests.check('the website, signed-in staff and the public cannot call the Edge Function''s steps', concat_ws('|',
  tests.scalar_pub(format($q$ select application_upload_begin(%L, 'supporting', 'x.pdf', 'application/pdf', 100)::text $q$, (select p from pass))),
  tests.scalar('ceo', format($q$ select application_upload_begin(%L, 'supporting', 'x.pdf', 'application/pdf', 100)::text $q$, (select p from pass))),
  tests.scalar_anon($q$ select application_upload_begin('x', 'cv', 'x.pdf', 'application/pdf', 1)::text $q$)), 'ERR:42501|ERR:42501|ERR:42501');
select tests.check('those who may read the application see its files; others do not; passes are hidden from everyone signed in', concat_ws(',',
  tests.scalar('ceo', 'select count(*)::text from application_files'), tests.scalar('web_lead', 'select count(*)::text from application_files'),
  tests.scalar('tech_staff', 'select count(*)::text from application_files'), tests.scalar('outsider', 'select count(*)::text from application_files'),
  tests.scalar_anon('select count(*)::text from application_files'), tests.scalar('ceo', 'select count(*)::text from application_upload_passes')), '1,1,0,0,ERR:42501,ERR:42501');
select tests.check('the storage read rule follows the application', concat_ws(',',
  tests.scalar('web_lead', format($q$ select application_storage_can_read(%L)::text $q$, (select v from path_cv))),
  tests.scalar('tech_staff', format($q$ select application_storage_can_read(%L)::text $q$, (select v from path_cv))),
  tests.scalar('web_lead', $q$ select application_storage_can_read('../etc/passwd')::text $q$)), 'true,false,false');
select tests.finish();
