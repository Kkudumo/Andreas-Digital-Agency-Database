-- Acceptance scenario (master spec §54): the complete life of a hire, with websites updating
-- automatically from central data. No step edits website code; "the website" is the public API.
begin;
select tests.setup();
select tests.setup_hr();
-- the main website subscribes to cache-revalidation events
insert into event_subscriptions (website_id, url, secret_ref, event_types)
  values (tests.id('site:main'), 'https://main.ada.test/api/revalidate', 'vault:main-webhook', array['vacancy.published', 'vacancy.closed', 'vacancy.unpublished', 'profile.published', 'profile.unpublished']);

-- 1. Management creates a "Senior Web Developer" position.
select tests.check('1. management creates the position',
  tests.try('ceo', $q$ insert into positions (title, division_id, headcount) select 'Senior Web Developer', id, 1 from divisions where key = 'web' $q$), 'ok');
insert into tests.ids select 'position:senior', id from positions where title = 'Senior Web Developer';

-- 2. A vacancy is created. 3. It is approved.
select tests.remember('vac:s', tests.scalar('recruiter', $q$ insert into vacancies (position_id, title, summary, description, requirements, closing_date, salary_min, salary_max, salary_public)
  values ((select id from tests.ids where key = 'position:senior'), 'Senior Web Developer', 'Lead web projects', 'Own delivery of client websites', '5 years TypeScript', current_date + 21, 15000, 20000, true) returning id::text $q$));
select tests.check('2. recruiter submits the vacancy', tests.scalar('recruiter', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:s'), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('3. management approves', tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:s'), 'approved')::text $q$), 'approved');
select tests.check('3b. website cannot see it yet', tests.pub('main', 'vacancies'), '[]');

-- 4. It becomes available on the websites automatically.
select tests.check('4. management publishes', tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:s'), 'published')::text $q$), 'published');
select tests.check('4b. the website now lists the vacancy, salary included',
  (select (x ->> 'title' = 'Senior Web Developer' and (x -> 'salary' ->> 'min') = '15000.00' and x -> 'division' ->> 'code' = 'web')::text from jsonb_array_elements(tests.pub('main', 'vacancies')::jsonb) x), 'true');
select tests.check('4c. the website is told to revalidate',
  (select count(*)::text from event_deliveries d join events e on e.id = d.event_id where e.event_type = 'vacancy.published' and d.status = 'pending'), '1');
select tests.check('4d. statistics show the opening', (tests.pub('main', 'statistics')::jsonb ->> 'open_vacancies'), '1');

-- 5. An applicant applies on ADA Main Website. 6. It enters ADA Core. 7. Recruitment staff see it.
select tests.check('5-6. application arrives with its source',
  ((tests.pub('main', 'submit_application', format('%L, %L, %L, %L, %L, %L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:s')),
     'Naomi Shikongo', 'newhire@ada.test', '+264811234567', 'I would love to join ADA Web.', '/careers/senior-web-developer',
     'https://www.google.com/', '{"utm_source":"google","utm_medium":"cpc","utm_campaign":"google_ads_2026"}'))::jsonb ->> 'reference') ~ '^ADA-APP-')::text, 'true');
insert into tests.ids select 'app:n', id from applications order by created_at desc limit 1;
select tests.check('7. recruitment staff see it, with source website, page and campaign',
  tests.scalar('recruiter', $q$ select (a.source_website_id = (select id from tests.ids where key = 'site:main') and a.source_page = '/careers/senior-web-developer' and a.utm_campaign = 'google_ads_2026')::text
                               from applications a where a.id = (select id from tests.ids where key = 'app:n') $q$), 'true');
select tests.check('7b. the web division lead is notified of the application',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'web_lead@ada.test' and n.type = 'application.submitted'), '1');
select tests.check('7c. staff in other divisions cannot see the application', tests.scalar('tech_lead', 'select count(*)::text from applications'), '0');

-- 8. Shortlisted. 9. Interviewed. 10. Offer. 11. Accepts.
select tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:n'), 'screening')::text $q$);
select tests.check('8. shortlisted', tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:n'), 'shortlisted')::text $q$), 'shortlisted');
select tests.check('9. interview', tests.scalar('web_lead', $q$ select application_transition((select id from tests.ids where key = 'app:n'), 'interview')::text $q$), 'interview');
select tests.try('web_lead', $q$ insert into application_reviews (application_id, reviewer_id, stage, score, notes) values ((select id from tests.ids where key = 'app:n'), gen_random_uuid(), 'interview', 5, 'Excellent') $q$);
select tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:n'), 'final_review')::text $q$);
select tests.check('10. management makes the offer',
  tests.scalar('ceo', $q$ select make_offer((select id from tests.ids where key = 'app:n'), current_date, 18000, 'NAD', current_date + 7, 'Standard ADA terms')::text $q$), 'offer');

-- 12-16. Acceptance runs the controlled onboarding.
create temp table hire as select tests.scalar('ceo', $q$ select accept_application((select id from tests.ids where key = 'app:n'))::text $q$) as staff_id;
insert into tests.ids select 'staff:hire', staff_id::uuid from hire where staff_id !~ '^ERR';
select tests.check('11-12. staff record created through the workflow', (select (staff_id !~ '^ERR')::text from hire), 'true');
select tests.check('13. staff ID generated', (select (ada_id ~ '^ADA-STF-\d{4}-\d{4}$')::text from staff where id = (select staff_id::uuid from hire)), 'true');
select tests.check('14. assigned to ADA Web in the Senior Web Developer position',
  (select (primary_division_id = tests.id('div:web') and position_id = tests.id('position:senior') and employment_status = 'active' and start_date = current_date)::text
   from staff where id = (select staff_id::uuid from hire)), 'true');
select tests.check('14b. assignment history was opened',
  (select (count(*) = 1 and bool_and(ended_on is null))::text from staff_assignments where staff_id = (select staff_id::uuid from hire)), 'true');
select tests.check('15. the position is now filled', (select (filled = headcount)::text from position_availability where title = 'Senior Web Developer'), 'true');
select tests.check('16. the vacancy is filled', (select status::text from vacancies where id = tests.id('vac:s')), 'filled');
select tests.check('16b. the website drops the vacancy automatically', tests.pub('main', 'vacancies'), '[]');
select tests.check('16c. onboarding tasks exist and management was notified',
  (select count(*)::text from onboarding_tasks where staff_id = (select staff_id::uuid from hire) and kind = 'onboarding') || '/' ||
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'admin@ada.test' and n.type = 'onboarding.task'), '5/1');
select tests.check('16d. application is accepted and linked to the staff record',
  (select (status = 'accepted' and staff_id = (select staff_id::uuid from hire))::text from applications where id = tests.id('app:n')), 'true');

-- Access is created by an authorised person (login linking), never implicitly.
select tests.check('hire cannot sign in until a login is linked', tests.scalar('newhire', 'select count(*)::text from staff'), '0');
select tests.check('administrator links the login',
  tests.try('ceo', $q$ select link_staff_account((select id from tests.ids where key = 'staff:hire'), 'newhire@ada.test') $q$), 'ok');
select tests.check('the new hire now has access, scoped to nothing until roles are granted',
  tests.scalar('newhire', 'select count(*)::text from staff') || '/' || tests.scalar('newhire', 'select count(*)::text from clients') || '/' || tests.scalar('newhire', 'select count(*)::text from applications'), '11/0/0');
select tests.check('the new hire sees their own onboarding tasks', tests.scalar('newhire', 'select count(*)::text from onboarding_tasks'), '5');
select tests.check('the new hire cannot see HR data', tests.scalar('newhire', 'select count(*)::text from staff_private'), '0');

-- 17-20. Public profile: draft -> management approval -> published -> websites update.
select tests.check('17. a draft public profile was prepared', (select status::text from staff_profiles where staff_id = (select staff_id::uuid from hire)), 'draft');
select tests.check('17b. nothing public about the new hire yet', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb)), '0');
select tests.check('the new hire edits their own profile',
  tests.try('newhire', $q$ update staff_profiles set bio = 'Full-stack developer who loves clean, fast websites.', public_title = 'Senior Web Developer' $q$), 'ok');
select tests.check('...and submits it for approval', tests.scalar('newhire', $q$ select profile_transition((select id from staff_profiles), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('...but cannot approve or publish it themselves',
  tests.scalar('newhire', $q$ select profile_transition((select id from staff_profiles), 'approved')::text $q$), 'ERR:42501');
select tests.check('...nor change its status directly', tests.try('newhire', $q$ update staff_profiles set status = 'published' $q$), 'ERR:42501');
select tests.check('submission asks management to approve',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'ceo@ada.test' and n.title like 'Profile awaiting approval%'), '1');
select tests.check('18. management approves', tests.scalar('ceo', $q$ select profile_transition((select id from staff_profiles), 'approved')::text $q$), 'approved');
select tests.check('approved is still not public', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb)), '0');
select tests.check('19. management publishes', tests.scalar('ceo', $q$ select profile_transition((select id from staff_profiles), 'published')::text $q$), 'published');
select tests.check('20. the team page updates automatically, with approved fields only',
  (select (x ->> 'name' = 'Naomi Shikongo' and x ->> 'title' = 'Senior Web Developer' and x -> 'division' ->> 'name' = 'ADA Web'
           and not (x ? 'email') and (select count(*) from jsonb_object_keys(x)) = 5)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb) x), 'true');
select tests.check('20b. the website is told to revalidate the team',
  (select count(*)::text from event_deliveries d join events e on e.id = d.event_id where e.event_type = 'profile.published'), '1');
select tests.check('20c. no private data leaks into the team DTO', (tests.pub('main', 'team') !~ '(newhire@|ADA-STF|\+264|18000|Standard ADA terms|Excellent)')::text, 'true');
select tests.check('20d. statistics follow the data', (tests.pub('main', 'statistics')::jsonb ->> 'team_members'), '1');
select tests.check('editing a published profile is allowed...', tests.try('newhire', $q$ update staff_profiles set bio = 'Updated bio' $q$), 'ok');
select tests.check('...but sends it back to draft for re-approval', (select status::text from staff_profiles), 'draft');
select tests.check('...and it leaves the website until management re-approves', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb)), '0');
select tests.scalar('newhire', $q$ select profile_transition((select id from staff_profiles), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select profile_transition((select id from staff_profiles), 'approved')::text $q$);
select tests.scalar('ceo', $q$ select profile_transition((select id from staff_profiles), 'published')::text $q$);
select tests.check('...and returns once management re-approves', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb)), '1');

-- 21-24. Departure.
select tests.check('21. staff leaves: recorded with a reason', tests.try('ceo', $q$ select terminate_staff((select id from tests.ids where key = 'staff:hire'), current_date, 'Resigned') $q$), 'ok');
select tests.check('22. staff becomes inactive and access is revoked',
  (select (employment_status = 'terminated' and account_status = 'disabled')::text from staff where id = (select staff_id::uuid from hire)), 'true');
select tests.check('22b. they can no longer read anything',
  tests.scalar('newhire', 'select count(*)::text from staff') || tests.scalar('newhire', 'select count(*)::text from onboarding_tasks') || tests.scalar('newhire', 'select count(*)::text from notifications'), '000');
select tests.check('22c. they cannot call the workflow functions either', tests.scalar('newhire', $q$ select profile_transition((select id from staff_profiles), 'pending_approval')::text $q$), 'ERR:P0002');
select tests.check('23. public profile is no longer published',
  (select status::text from staff_profiles where staff_id = (select staff_id::uuid from hire)), 'unpublished');
select tests.check('23b. the team page drops them automatically', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'team')::jsonb)), '0');
select tests.check('23c. statistics follow', (tests.pub('main', 'statistics')::jsonb ->> 'team_members'), '0');
select tests.check('23d. offboarding checklist was created',
  (select count(*)::text from onboarding_tasks where staff_id = (select staff_id::uuid from hire) and kind = 'offboarding'), '4');
select tests.check('23e. assignment history is closed, not deleted',
  (select (count(*) = 1 and bool_and(ended_on is not null))::text from staff_assignments where staff_id = (select staff_id::uuid from hire)), 'true');
select tests.check('24. the position is available again', (select (filled = 0 and headcount = 1)::text from position_availability where title = 'Senior Web Developer'), 'true');
select tests.check('24b. no replacement vacancy was created automatically',
  (select count(*)::text from vacancies where position_id = tests.id('position:senior')), '1');
select tests.check('24c. management was told the position is vacant',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'ceo@ada.test' and n.type = 'position.vacant'), '1');

-- 25. A new vacancy can be created for the same position, if management wants.
select tests.remember('vac:s2', tests.scalar('recruiter', $q$ insert into vacancies (position_id, title, description, requirements, closing_date)
  values ((select id from tests.ids where key = 'position:senior'), 'Senior Web Developer (replacement)', 'Replace departing developer', '5 years', current_date + 30) returning id::text $q$));
select tests.scalar('recruiter', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:s2'), 'pending_approval')::text $q$);
select tests.check('25. the replacement vacancy is approved and published',
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:s2'), 'approved')::text $q$) ||
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:s2'), 'published')::text $q$), 'approvedpublished');
select tests.check('25b. the website lists it again', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'vacancies')::jsonb)), '1');

-- 26. Everything is visible in the audit history.
select tests.check('26. audit answers: who approved the vacancy?',
  (select count(*)::text from audit_log where table_name = 'vacancies' and record_id = tests.id('vac:s') and new_data ->> 'status' = 'approved'
     and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')), '1');
select tests.check('26b. who moved the application through each stage?',
  (select count(distinct actor_ada_id)::text from audit_log where table_name = 'applications' and record_id = tests.id('app:n') and action = 'UPDATE'), '3');
select tests.check('26c. who created the staff record?',
  (select count(*)::text from audit_log where table_name = 'staff' and action = 'INSERT' and new_data ->> 'person_id' is not null
     and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')), '1');
select tests.check('26d. who published the team profile?',
  (select count(*)::text from audit_log where table_name = 'staff_profiles' and new_data ->> 'status' = 'published'
     and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')), '2');
select tests.check('26e. who ended the employment?',
  (select count(*)::text from audit_log where table_name = 'staff' and new_data ->> 'employment_status' = 'terminated'
     and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')), '1');
select tests.check('26f. the whole story is in the event outbox, in order',
  (select string_agg(distinct event_type, ',' order by event_type) from events where event_type not like 'website.%'),
  'application.accepted,application.offer_made,application.status_changed,application.submitted,profile.published,profile.unpublished,staff.created,staff.deactivated,vacancy.closed,vacancy.published');
select tests.check('26g. no event ever carried personal data',
  (select count(*)::text from events where payload::text ~* '(@|naomi|shikongo|264)'), '0');

select tests.finish();
rollback;
