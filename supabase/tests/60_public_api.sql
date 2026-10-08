-- What websites can and cannot get. Public data is a deliberate projection, never a table.
begin;
select tests.setup();
select tests.setup_hr();

-- Website registry & API keys ---------------------------------------------------------------
select tests.check('administration can see the website registry', tests.scalar('admin', 'select count(*)::text from websites'), '3');
select tests.check('division staff cannot see the website registry', tests.scalar('web_lead', 'select count(*)::text from websites'), '0');
select tests.check('administration cannot register websites',
  tests.try('admin', $q$ insert into websites (name, domain) values ('Rogue', 'rogue.test') $q$), 'ERR:42501');
select tests.check('management registers a website',
  tests.try('ceo', $q$ insert into websites (name, domain, capabilities, status) values ('ADA Web Website', 'web.ada.test', array['vacancies.read'], 'active') $q$), 'ok');
select tests.check('registering a website emits website.registered', (select count(*)::text from events where event_type = 'website.registered' and entity_id = (select id from websites where domain = 'web.ada.test')), '1');
select tests.check('unknown capability is rejected',
  tests.try('ceo', $q$ update websites set capabilities = array['everything.read'] where domain = 'web.ada.test' $q$), 'ERR:23514');
select tests.check('API key hash cannot be set by users',
  tests.try('ceo', $q$ update websites set api_key_hash = 'abc' where domain = 'web.ada.test' $q$), 'ERR:42501');
select tests.check('API key hash cannot be read by users', tests.try('ceo', 'select api_key_hash from websites'), 'ERR:42501');
select tests.check('other website columns are readable', tests.try('ceo', 'select id, name, domain, api_key_prefix from websites'), 'ok');
select tests.check('administration cannot issue keys', tests.scalar('admin', $q$ select issue_website_key((select id from tests.ids where key = 'site:main')) $q$), 'ERR:42501');
create temp table issued as select tests.scalar('ceo', $q$ select issue_website_key((select id from websites where domain = 'web.ada.test')) $q$) as k;
select tests.check('issued key looks right', (select (k ~ '^ada_[0-9a-f]{48}$')::text from issued), 'true');
select tests.check('only the hash of the key is stored', (select (api_key_hash = tests.keyhash((select k from issued)) and api_key_hash <> (select k from issued))::text from websites where domain = 'web.ada.test'), 'true');
select tests.check('key hash is redacted in the audit trail',
  (select count(*)::text from audit_log where table_name = 'websites' and (new_data::text like '%' || tests.keyhash((select k from issued)) || '%')), '0');
select tests.check('a rotated key invalidates the old one',
  (select (tests.scalar('ceo', $q$ select issue_website_key((select id from websites where domain = 'web.ada.test')) $q$) <> k)::text from issued), 'true');
select tests.check('event subscriptions must use https', tests.try('ceo', $q$ insert into event_subscriptions (website_id, url) values ((select id from tests.ids where key = 'site:main'), 'http://insecure.test/hook') $q$), 'ERR:23514');
select tests.check('subscription registered', tests.try('ceo', $q$ insert into event_subscriptions (website_id, url, secret_ref, event_types) values ((select id from tests.ids where key = 'site:main'), 'https://main.ada.test/api/revalidate', 'vault:main-webhook', array['vacancy.published', 'profile.published']) $q$), 'ok');

-- The website database role can touch no table ---------------------------------------------------
select tests.check('website role cannot read clients',   tests.scalar_pub('select count(*)::text from clients'), 'ERR:42501');
select tests.check('website role cannot read staff',     tests.scalar_pub('select count(*)::text from staff'), 'ERR:42501');
select tests.check('website role cannot read vacancies', tests.scalar_pub('select count(*)::text from vacancies'), 'ERR:42501');
select tests.check('website role cannot read applications', tests.scalar_pub('select count(*)::text from applications'), 'ERR:42501');
select tests.check('website role cannot read people',    tests.scalar_pub('select count(*)::text from people'), 'ERR:42501');
select tests.check('website role cannot read websites',  tests.scalar_pub('select count(*)::text from websites'), 'ERR:42501');
select tests.check('website role cannot read profiles',  tests.scalar_pub('select count(*)::text from staff_profiles'), 'ERR:42501');
select tests.check('website role cannot read audit',     tests.scalar_pub('select count(*)::text from audit_log'), 'ERR:42501');
select tests.check('website role cannot call internals',  tests.scalar_pub($q$ select has_permission('clients.view')::text $q$), 'ERR:42501');
select tests.check('website role cannot create applications directly', tests.scalar_pub($q$ select create_application_internal('x','x','x@x.xx','x','x',null,null,null,null,null,null,null,null,null) $q$), 'ERR:42501');

-- Authentication & capabilities ------------------------------------------------------------------
select tests.check('unknown key is refused', tests.scalar_pub($q$ select public_api.divisions('deadbeef')::text $q$), 'ERR:42501');
select tests.check('plaintext key is not accepted in place of its hash', tests.scalar_pub($q$ select public_api.divisions('testkey-main')::text $q$), 'ERR:42501');
select tests.check('a site without the capability is refused', tests.pub('limited', 'vacancies'), 'ERR:42501');
select tests.check('...but may use the capabilities it has', (tests.pub('limited', 'divisions') like '[%')::text, 'true');
select tests.check('a suspended website is refused entirely', tests.pub('susp', 'divisions'), 'ERR:42501');

-- Divisions: only the six service divisions ------------------------------------------------------------
select tests.check('public divisions are exactly the six service divisions',
  (select string_agg(x ->> 'code', ',') from jsonb_array_elements(tests.pub('main', 'divisions')::jsonb) x), 'web,tech,marketing,academy,software,consulting');
select tests.check('division DTO exposes only code, name, description',
  (select string_agg(k, ',' order by k) from (select distinct jsonb_object_keys(x) k from jsonb_array_elements(tests.pub('main', 'divisions')::jsonb) x) q), 'code,description,name');
update divisions set public_state = 'unpublished' where key = 'tech';
select tests.check('an unpublished division disappears immediately',
  (select count(*)::text from jsonb_array_elements(tests.pub('main', 'divisions')::jsonb)), '5');
update divisions set public_state = 'published' where key = 'tech';

-- Vacancies: only published, open, approved ---------------------------------------------------------------
select tests.check('nothing is public before anything is published', tests.pub('main', 'vacancies'), '[]');
select tests.remember('vac:v', tests.scalar('web_lead', $q$ insert into vacancies (position_id, title, summary, description, requirements, closing_date, salary_min, salary_max)
  select id, 'Web Developer', 'Join ADA Web', 'Build great sites', 'TypeScript', current_date + 30, 8000, 12000 from positions where title = 'Web Developer' returning id::text $q$));
select tests.check('a draft is not public', tests.pub('main', 'vacancies'), '[]');
select tests.scalar('web_lead', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:v'), 'pending_approval')::text $q$);
select tests.check('pending approval is not public', tests.pub('main', 'vacancies'), '[]');
select tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:v'), 'approved')::text $q$);
select tests.check('approved but unpublished is not public', tests.pub('main', 'vacancies'), '[]');
select tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:v'), 'published')::text $q$);
select tests.check('published vacancy appears with no website change', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'vacancies')::jsonb)), '1');
select tests.check('vacancy DTO exposes only intended fields (no salary unless marked public)',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(tests.pub('main', 'vacancies')::jsonb -> 0) k),
  'closing_date,description,division,employment_type,id,published_at,requirements,summary,title');
update vacancies set salary_public = true where id = tests.id('vac:v');
select tests.check('salary appears only when marked public', (tests.pub('main', 'vacancies')::jsonb -> 0 -> 'salary' ->> 'max'), '12000.00');
select tests.check('division filter works', tests.pub('main', 'vacancies', quote_literal('tech')), '[]');
select tests.check('single vacancy by ADA ID', (tests.pub('main', 'vacancy', quote_literal((select ada_id from vacancies where id = tests.id('vac:v'))))::jsonb ->> 'title'), 'Web Developer');
select tests.check('unknown vacancy is null', tests.pub('main', 'vacancy', quote_literal('ADA-VAC-1999-0001')), null);
select tests.check('publishing queued a cache-revalidation delivery for the subscribed site',
  (select count(*)::text from event_deliveries d join events e on e.id = d.event_id where e.event_type = 'vacancy.published' and d.status = 'pending'), '1');
update vacancies set closing_date = current_date - 1 where id = tests.id('vac:v');
select tests.check('a vacancy past its closing date disappears without any job running', tests.pub('main', 'vacancies'), '[]');
update vacancies set closing_date = current_date + 5 where id = tests.id('vac:v');

-- Applications from a website ----------------------------------------------------------------------------------
select tests.check('submit with invalid email is rejected',
  tests.pub('main', 'submit_application', format('%L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:v')), 'Zed', 'nope')), 'ERR:22023');
select tests.check('site without applications.submit is refused',
  tests.pub('limited', 'submit_application', format('%L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:v')), 'Zed', 'zed@example.com')), 'ERR:42501');
select tests.check('unknown vacancy is refused',
  tests.pub('main', 'submit_application', format('%L, %L, %L', 'ADA-VAC-1999-0001', 'Zed', 'zed@example.com')), 'ERR:P0002');
select tests.check('application arrives in ADA Core and returns only a reference',
  (select string_agg(k, ',') from jsonb_object_keys(tests.pub('main', 'submit_application',
     format('%L, %L, %L, %L, %L, %L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:v')), 'Zed Zebra', 'zed@example.com', '+264810000000',
            'Please consider me', '/careers/web-developer', 'https://www.google.com/', '{"utm_source":"google","utm_campaign":"google_ads_2026"}'))::jsonb) k), 'reference');
select tests.check('source website comes from the API identity',
  (select (source_website_id = tests.id('site:main'))::text from applications a join people p on p.id = a.person_id where p.email = 'zed@example.com'), 'true');
select tests.check('source page, referrer and campaign are stored',
  (select (source_page = '/careers/web-developer' and referrer = 'https://www.google.com/' and utm_source = 'google' and utm_campaign = 'google_ads_2026')::text
   from applications a join people p on p.id = a.person_id where p.email = 'zed@example.com'), 'true');
select tests.check('submitting twice is a conflict, not a second application',
  tests.pub('main', 'submit_application', format('%L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:v')), 'Zed Again', 'ZED@example.com')), 'ERR:23505');
select tests.check('over-long cover letter is refused',
  tests.pub('main', 'submit_application', format('%L, %L, %L, null, %L', (select ada_id from vacancies where id = tests.id('vac:v')), 'Long', 'long@example.com', repeat('x', 10001))), 'ERR:23514');
select tests.check('the recruiter sees the website application in IRM',
  tests.scalar('recruiter', $q$ select count(*)::text from applications a join people p on p.id = a.person_id where p.email = 'zed@example.com' $q$), '1');
select tests.check('recruiters were notified', (select (count(*) >= 1)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'recruiter@ada.test' and n.type = 'application.submitted'), 'true');
select tests.check('the application event exposes no applicant data',
  (select count(*)::text from events where event_type = 'application.submitted' and (payload::text ~ '@' or payload::text ilike '%zed%')), '0');
select tests.check('applicants are not visible to unrelated staff', tests.scalar('fin', 'select count(*)::text from people'), '0');

-- Team: published profiles of current staff only --------------------------------------------------------------
update staff set primary_division_id = tests.id('div:web') where email = 'web_staff@ada.test';
update staff set primary_division_id = tests.id('div:tech') where email = 'tech_staff@ada.test';
update staff set primary_division_id = (select id from divisions where key = 'management') where email = 'ceo@ada.test';
insert into staff_profiles (staff_id, public_name, public_title, bio, status, published_at)
  select id, full_name, 'Web Developer', 'Writes code', 'published', now() from staff where email = 'web_staff@ada.test';
insert into staff_profiles (staff_id, public_name, public_title, status)
  select id, full_name, 'Technician', 'draft' from staff where email = 'tech_staff@ada.test';
insert into staff_profiles (staff_id, public_name, public_title, status, published_at)
  select id, full_name, 'Chief Executive', 'published', now() from staff where email = 'ceo@ada.test';
insert into staff_profiles (staff_id, public_name, public_title, status)
  select id, 'Pending Person', 'Analyst', 'pending_approval' from staff where email = 'fin@ada.test';
select tests.check('only published profiles are on the team page',
  (select string_agg(x ->> 'name', ',' order by x ->> 'name') from jsonb_array_elements(tests.pub('main', 'team')::jsonb) x), 'Ceo,Web_Staff');
select tests.check('team DTO never includes internal fields',
  (select string_agg(k, ',' order by k) from (select distinct jsonb_object_keys(x) k from jsonb_array_elements(tests.pub('main', 'team')::jsonb) x) q), 'bio,division,id,name,title');
select tests.check('internal units are not shown as a public division',
  (select ((x -> 'division') is null)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb) x where x ->> 'name' = 'Ceo'), 'true');
select tests.check('no staff email, phone or ADA staff ID leaks', (tests.pub('main', 'team') !~ '(@ada\.test|ADA-STF)')::text, 'true');
update staff set employment_status = 'terminated' where email = 'web_staff@ada.test';
select tests.check('a published profile of departed staff is not shown (even if nobody unpublished it)',
  (select count(*)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb) x where x ->> 'name' = 'Web_Staff'), '0');
update staff set employment_status = 'active' where email = 'web_staff@ada.test';

-- Statistics are derived, not typed -------------------------------------------------------------------------------
select tests.check('statistics match live records',
  (tests.pub('main', 'statistics')::jsonb = jsonb_build_object(
     'staff', (select count(*) from staff where deleted_at is null and employment_status in ('active', 'on_leave', 'contractor')),
     'team_members', 2, 'open_vacancies', 1, 'divisions', 6, 'services', 0, 'portfolio_projects', 0))::text, 'true');
update vacancies set deleted_at = now(), deletion_reason = 'test' where id = tests.id('vac:v');
select tests.check('statistics follow the data (soft-deleted vacancy no longer counts)', (tests.pub('main', 'statistics')::jsonb ->> 'open_vacancies'), '0');

-- Anyone else --------------------------------------------------------------------------------------------------------------
select tests.check('signed-in staff cannot call the public API functions', tests.try('ceo', $q$ select public_api.divisions('x') $q$), 'ERR:42501');
select tests.check('anonymous Supabase role cannot call them either', tests.scalar_anon($q$ select public_api.divisions('x')::text $q$), 'ERR:42501');

select tests.finish();
rollback;
