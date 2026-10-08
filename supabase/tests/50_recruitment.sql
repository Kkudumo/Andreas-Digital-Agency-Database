-- Recruitment: who may do what, and the guards that keep the pipeline honest.
begin;
select tests.setup();
select tests.setup_hr();

-- Positions ---------------------------------------------------------------------
select tests.check('web lead cannot create positions', tests.try('web_lead', $q$ insert into positions (title) values ('Rogue') $q$), 'ERR:42501');
select tests.check('administration can create positions',
  tests.try('admin', $q$ insert into positions (title, division_id, headcount) select 'Junior Web Developer', id, 2 from divisions where key = 'web' $q$), 'ok');
select tests.check('headcount must be positive', tests.try_owner($q$ insert into positions (title, headcount) values ('Zero', 0) $q$), 'ERR:23514');

-- Vacancy drafting & guards -------------------------------------------------------
select tests.remember('vac:w1', tests.scalar('web_lead', $q$
  insert into vacancies (position_id, division_id, title, description, requirements, openings, closing_date)
  select p.id, (select id from divisions where key = 'tech'), 'Web Developer', 'Build sites', 'HTML, CSS, TS', 1, current_date + 30
  from positions p where p.title = 'Web Developer' returning id::text $q$));
select tests.check('vacancy division is taken from the position, not the request',
  (select d.key from vacancies v join divisions d on d.id = v.division_id where v.id = tests.id('vac:w1')), 'web');
select tests.check('vacancy gets an ADA ID', (select (ada_id ~ '^ADA-VAC-\d{4}-\d{4}$')::text from vacancies where id = tests.id('vac:w1')), 'true');
select tests.check('vacancies cannot be created already published',
  tests.try('web_lead', $q$ insert into vacancies (position_id, title, status) select id, 'X', 'published' from positions where title = 'Web Developer' $q$), 'ERR:42501');
select tests.check('web staff cannot create vacancies',
  tests.try('web_staff', $q$ insert into vacancies (position_id, title) select id, 'X' from positions where title = 'Web Developer' $q$), 'ERR:42501');
select tests.check('web lead cannot create a vacancy for a Tech position',
  tests.try('web_lead', $q$ insert into vacancies (position_id, title) select id, 'X' from positions where title = 'IT Technician' $q$), 'ERR:42501');
select tests.check('status cannot be edited directly',
  tests.try('web_lead', $q$ update vacancies set status = 'published' where id = (select id from tests.ids where key = 'vac:w1') $q$), 'ERR:42501');
select tests.check('even the CEO cannot bypass the workflow with a direct update',
  tests.try('ceo', $q$ update vacancies set status = 'published' where id = (select id from tests.ids where key = 'vac:w1') $q$), 'ERR:42501');
select tests.check('position cannot be changed after creation',
  tests.try('web_lead', $q$ update vacancies set position_id = (select id from tests.ids where key = 'position:IT Technician') where id = (select id from tests.ids where key = 'vac:w1') $q$), 'ERR:42501');
select tests.check('web staff see no vacancies', tests.scalar('web_staff', 'select count(*)::text from vacancies'), '0');
select tests.check('tech lead sees no Web vacancies', tests.scalar('tech_lead', 'select count(*)::text from vacancies'), '0');
select tests.check('web lead sees own division''s vacancy', tests.scalar('web_lead', 'select count(*)::text from vacancies'), '1');
select tests.check('recruiter sees all vacancies', tests.scalar('recruiter', 'select count(*)::text from vacancies'), '1');
select tests.check('finance sees no vacancies', tests.scalar('fin', 'select count(*)::text from vacancies'), '0');

-- Approval workflow ---------------------------------------------------------------
select tests.check('incomplete vacancy cannot be submitted',
  tests.try('recruiter', $q$ insert into vacancies (position_id, title) select id, 'Empty' from positions where title = 'Web Developer' $q$) ||
  tests.scalar('recruiter', $q$ select vacancy_transition((select id from vacancies where title = 'Empty'), 'pending_approval')::text $q$), 'okERR:23514');
select tests.check('web lead submits for approval',
  tests.scalar('web_lead', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w1'), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('submission notifies approvers',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where n.type = 'approval.required' and s.email = 'ceo@ada.test'), '1');
select tests.check('content is locked once submitted',
  tests.try('web_lead', $q$ update vacancies set title = 'Changed' where id = (select id from tests.ids where key = 'vac:w1') $q$), 'ERR:42501');
select tests.check('recruiter cannot approve (no vacancies.publish)',
  tests.scalar('recruiter', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w1'), 'approved')::text $q$), 'ERR:42501');
select tests.check('web lead cannot approve their own vacancy',
  tests.scalar('web_lead', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w1'), 'approved')::text $q$), 'ERR:42501');
select tests.check('cannot skip approval to publish',
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w1'), 'published')::text $q$), 'ERR:23514');
select tests.check('management approves', tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w1'), 'approved')::text $q$), 'approved');
select tests.check('approval is recorded', (select (approved_by = (select id from staff where email = 'ceo@ada.test') and approved_at is not null)::text from vacancies where id = tests.id('vac:w1')), 'true');

-- Headcount protects against over-hiring
select tests.remember('vac:w2', tests.scalar('web_lead', $q$
  insert into vacancies (position_id, title, description, requirements)
  select id, 'Web Developer (second)', 'd', 'r' from positions where title = 'Web Developer' returning id::text $q$));
select tests.check('submits second vacancy', tests.scalar('web_lead', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w2'), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('cannot approve more openings than the position has room for',
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w2'), 'approved')::text $q$), 'ERR:23514');
select tests.check('CEO can return a vacancy to draft with a reason',
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w2'), 'draft', 'not needed yet')::text $q$), 'draft');
select tests.check('cancelling needs a reason',
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w2'), 'cancelled')::text $q$), 'ERR:23514');
select tests.check('cancelling with a reason works',
  tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w2'), 'cancelled', 'duplicate')::text $q$), 'cancelled');
select tests.check('cancelled is final', tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w2'), 'draft')::text $q$), 'ERR:23514');
select tests.check('management publishes', tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:w1'), 'published')::text $q$), 'published');
select tests.check('publishing emits vacancy.published',
  (select count(*)::text from events where event_type = 'vacancy.published' and entity_id = tests.id('vac:w1')), '1');

-- Applications: intake --------------------------------------------------------------
select tests.check('web staff cannot enter applications',
  tests.scalar('web_staff', $q$ select staff_record_application((select id from tests.ids where key = 'vac:w1'), 'Ann Applicant', 'ann@example.com') $q$), 'ERR:42501');
select tests.check('recruiter records an application',
  tests.scalar('recruiter', $q$ select (staff_record_application((select id from tests.ids where key = 'vac:w1'), 'Ann Applicant', 'Ann@Example.com', '+264811111111', 'Hello') ~ '^ADA-APP-\d{4}-\d{4}$')::text $q$), 'true');
insert into tests.ids select 'app:ann', id from applications order by created_at desc limit 1;
insert into tests.ids select 'person:ann', person_id from applications where id = tests.id('app:ann');
select tests.check('staff entry is recorded as such (no source website)', (select (source_website_id is null and status = 'submitted')::text from applications where id = tests.id('app:ann')), 'true');
select tests.check('same email again for the same vacancy is a duplicate',
  tests.scalar('recruiter', $q$ select staff_record_application((select id from tests.ids where key = 'vac:w1'), 'Ann Again', 'ANN@example.com') $q$), 'ERR:23505');
select tests.check('invalid email is rejected',
  tests.scalar('recruiter', $q$ select staff_record_application((select id from tests.ids where key = 'vac:w1'), 'Bad', 'not-an-email') $q$), 'ERR:22023');
select tests.check('cancelled vacancy accepts no applications',
  tests.scalar('recruiter', $q$ select staff_record_application((select id from tests.ids where key = 'vac:w2'), 'Late', 'late@example.com') $q$), 'ERR:P0002');
select tests.check('recruiter intake notified recruiters', (select (count(*) >= 1)::text from notifications where type = 'application.submitted'), 'true');

-- a second, published vacancy for another position; the same person applies again
insert into vacancies (position_id, title, description, requirements, status, published_at)
  select id, 'Junior Web Developer', 'd', 'r', 'published', now() from positions where title = 'Junior Web Developer';
insert into tests.ids select 'vac:jr', id from vacancies where title = 'Junior Web Developer';
select tests.check('the same person can apply to another vacancy',
  tests.scalar('recruiter', $q$ select (staff_record_application((select id from tests.ids where key = 'vac:jr'), 'Ann Applicant', 'ann@example.com') like 'ADA-APP-%')::text $q$), 'true');
select tests.check('...without duplicating the person record', (select count(*)::text from people where lower(email) = 'ann@example.com'), '1');
select tests.check('...and keeps both applications', (select count(*)::text from applications where person_id = tests.id('person:ann')), '2');

-- Visibility -------------------------------------------------------------------------
select tests.check('recruiter sees both applications', tests.scalar('recruiter', 'select count(*)::text from applications'), '2');
select tests.check('web lead sees applications for Web vacancies', tests.scalar('web_lead', 'select count(*)::text from applications'), '2');
select tests.check('tech lead sees none', tests.scalar('tech_lead', 'select count(*)::text from applications'), '0');
select tests.check('web staff see none', tests.scalar('web_staff', 'select count(*)::text from applications'), '0');
select tests.check('finance sees none', tests.scalar('fin', 'select count(*)::text from applications'), '0');
select tests.check('auditor sees none (applications are confidential)', tests.scalar('audit', 'select count(*)::text from applications'), '0');
select tests.check('applicant details visible to recruiter', tests.scalar('recruiter', 'select count(*)::text from people'), '1');
select tests.check('applicant details hidden from finance', tests.scalar('fin', 'select count(*)::text from people'), '0');
select tests.check('applicant details hidden from web staff', tests.scalar('web_staff', 'select count(*)::text from people'), '0');
select tests.check('applicant details hidden from tech lead', tests.scalar('tech_lead', 'select count(*)::text from people'), '0');
select tests.check('applications cannot be inserted directly',
  tests.try('ceo', $q$ insert into applications (vacancy_id, person_id) values ((select id from tests.ids where key = 'vac:w1'), gen_random_uuid()) $q$), 'ERR:42501');
select tests.check('applications cannot be updated directly, even by the CEO',
  tests.try('ceo', $q$ update applications set status = 'accepted' $q$), 'ERR:42501');

-- Reviews (interview notes) -------------------------------------------------------------
select tests.check('web lead records interview notes',
  tests.try('web_lead', $q$ insert into application_reviews (application_id, reviewer_id, stage, score, notes)
                             values ((select id from tests.ids where key = 'app:ann'), gen_random_uuid(), 'interview', 4, 'Strong portfolio') $q$), 'ok');
select tests.check('reviewer is forced to the real author',
  (select (reviewer_id = (select id from staff where email = 'web_lead@ada.test'))::text from application_reviews), 'true');
select tests.check('finance cannot add review notes',
  tests.try('fin', $q$ insert into application_reviews (application_id, reviewer_id, stage, notes) values ((select id from tests.ids where key = 'app:ann'), gen_random_uuid(), 'interview', 'x') $q$), 'ERR:42501');
select tests.check('web staff cannot read interview notes', tests.scalar('web_staff', 'select count(*)::text from application_reviews'), '0');
select tests.check('tech lead cannot read interview notes', tests.scalar('tech_lead', 'select count(*)::text from application_reviews'), '0');
select tests.check('review notes are immutable', tests.try('web_lead', $q$ update application_reviews set notes = 'edited' $q$), 'ERR:42501');

-- Pipeline -------------------------------------------------------------------------------
select tests.check('cannot skip stages',
  tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'interview')::text $q$), 'ERR:23514');
select tests.check('rejection needs a reason',
  tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'rejected')::text $q$), 'ERR:23514');
select tests.check('tech lead cannot move a Web application',
  tests.scalar('tech_lead', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'screening')::text $q$), 'ERR:P0002');
select tests.check('web staff cannot move applications',
  tests.scalar('web_staff', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'screening')::text $q$), 'ERR:P0002');
select tests.check('screening',    tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'screening')::text $q$), 'screening');
select tests.check('shortlisted',  tests.scalar('web_lead',  $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'shortlisted')::text $q$), 'shortlisted');
select tests.check('interview',    tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'interview')::text $q$), 'interview');
select tests.check('final review', tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'final_review')::text $q$), 'final_review');
select tests.check('final review asks management to decide',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'ceo@ada.test' and n.title like 'Final review decision needed%'), '1');
select tests.check('recruiter cannot reject at final review',
  tests.scalar('recruiter', $q$ select application_transition((select id from tests.ids where key = 'app:ann'), 'rejected', 'no')::text $q$), 'ERR:42501');
select tests.check('recruiter cannot make an offer',
  tests.scalar('recruiter', $q$ select make_offer((select id from tests.ids where key = 'app:ann'), current_date + 14)::text $q$), 'ERR:42501');
select tests.check('web lead cannot make an offer',
  tests.scalar('web_lead', $q$ select make_offer((select id from tests.ids where key = 'app:ann'), current_date + 14)::text $q$), 'ERR:42501');
select tests.check('offer needs a start date',
  tests.scalar('ceo', $q$ select make_offer((select id from tests.ids where key = 'app:ann'), null)::text $q$), 'ERR:23514');
select tests.check('offers cannot be made from earlier stages',
  tests.scalar('ceo', $q$ select make_offer((select id from applications where vacancy_id = (select id from tests.ids where key = 'vac:jr')), current_date + 14)::text $q$), 'ERR:23514');
select tests.check('management makes an offer',
  tests.scalar('ceo', $q$ select make_offer((select id from tests.ids where key = 'app:ann'), current_date + 14, 12000, 'NAD', current_date + 7, 'Standard terms')::text $q$), 'offer');
select tests.check('offer terms visible to management only', tests.scalar('ceo', 'select count(*)::text from application_offers') || tests.scalar('recruiter', 'select count(*)::text from application_offers') || tests.scalar('web_lead', 'select count(*)::text from application_offers'), '100');
select tests.check('every pipeline step is in the history',
  (select count(*)::text from application_status_history where application_id = tests.id('app:ann')), '6');
select tests.check('history records who moved it',
  (select (count(*) filter (where changed_by is not null) = 5)::text from application_status_history where application_id = tests.id('app:ann')), 'true');
select tests.check('history is append-only', tests.try_owner($q$ update application_status_history set reason = 'x' $q$), 'ERR:42501');

-- Controlled hire: guards -------------------------------------------------------------------
select tests.check('recruiter cannot accept', tests.scalar('recruiter', $q$ select accept_application((select id from tests.ids where key = 'app:ann'))::text $q$), 'ERR:42501');
select tests.check('web lead cannot accept', tests.scalar('web_lead', $q$ select accept_application((select id from tests.ids where key = 'app:ann'))::text $q$), 'ERR:42501');
select tests.check('acceptance needs an open offer',
  tests.scalar('ceo', $q$ select accept_application((select id from applications where vacancy_id = (select id from tests.ids where key = 'vac:jr')))::text $q$), 'ERR:23514');
update application_offers set expires_on = current_date - 1 where application_id = tests.id('app:ann');
select tests.check('an expired offer cannot be accepted',
  tests.scalar('ceo', $q$ select accept_application((select id from tests.ids where key = 'app:ann'))::text $q$), 'ERR:23514');
update application_offers set expires_on = current_date + 7 where application_id = tests.id('app:ann');

-- the person is already active staff: no duplicate employee
insert into staff (person_id, full_name, email, employment_status, account_status) values (tests.id('person:ann'), 'Ann Old', 'ann.old@ada.test', 'active', 'active');
select tests.check('an already-active person cannot be hired again',
  tests.scalar('ceo', $q$ select accept_application((select id from tests.ids where key = 'app:ann'))::text $q$), 'ERR:23505');
update staff set employment_status = 'terminated', end_date = current_date - 30 where email = 'ann.old@ada.test';
select tests.check('a former employee is rehired onto the SAME staff record',
  (select (tests.scalar('ceo', $q$ select accept_application((select id from tests.ids where key = 'app:ann'))::text $q$) = id::text)::text from staff where email = 'ann.old@ada.test'), 'true');
select tests.check('exactly one staff record exists for the person', (select count(*)::text from staff where person_id = tests.id('person:ann')), '1');
select tests.check('rehired staff is active, linked to position and division, awaiting a login',
  (select (employment_status = 'active' and account_status = 'invited' and position_id = tests.id('position:Web Developer')
           and primary_division_id = tests.id('div:web') and end_date is null)::text from staff where email = 'ann.old@ada.test'), 'true');
select tests.check('accepting again is idempotent',
  (select (tests.scalar('ceo', $q$ select accept_application((select id from tests.ids where key = 'app:ann'))::text $q$) = id::text)::text from staff where email = 'ann.old@ada.test'), 'true');
select tests.check('vacancy closes as filled', (select status::text from vacancies where id = tests.id('vac:w1')), 'filled');
select tests.check('position now shows as filled', (select (filled >= headcount)::text from position_availability where title = 'Web Developer'), 'true');

-- headcount: a further hire for a filled position is refused
insert into vacancies (position_id, title, description, requirements, status, published_at)
  select id, 'Web Developer (extra)', 'd', 'r', 'published', now() from positions where title = 'Web Developer';
insert into people (full_name, email) values ('Bob Builder', 'bob@example.com');
insert into applications (vacancy_id, person_id, status)
  select v.id, p.id, 'offer' from vacancies v, people p where v.title = 'Web Developer (extra)' and p.email = 'bob@example.com';
insert into application_offers (application_id, start_date) select a.id, current_date + 5 from applications a join people p on p.id = a.person_id where p.email = 'bob@example.com';
select tests.check('hiring into a filled position is refused',
  tests.scalar('ceo', $q$ select accept_application((select a.id from applications a join people p on p.id = a.person_id where p.email = 'bob@example.com'))::text $q$), 'ERR:23514');

-- Public profile & departure guards ----------------------------------------------------------
select tests.check('hire created a draft public profile', (select status::text from staff_profiles where staff_id = (select id from staff where email = 'ann.old@ada.test')), 'draft');
select tests.check('onboarding tasks were generated', (select count(*)::text from onboarding_tasks where kind = 'onboarding' and application_id = tests.id('app:ann')), '5');
select tests.check('recruiter cannot see onboarding tasks', tests.scalar('recruiter', 'select count(*)::text from onboarding_tasks'), '0');
select tests.check('administration sees onboarding tasks', tests.scalar('admin', 'select count(*)::text from onboarding_tasks'), '5');
select tests.check('recruiter cannot see staff profiles', tests.scalar('recruiter', 'select count(*)::text from staff_profiles'), '0');
select tests.check('administration can submit a draft profile',
  tests.scalar('admin', $q$ select profile_transition((select id from staff_profiles limit 1), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('administration cannot approve profiles',
  tests.scalar('admin', $q$ select profile_transition((select id from staff_profiles limit 1), 'approved')::text $q$), 'ERR:42501');
select tests.check('profile status cannot be edited directly',
  tests.try('ceo', $q$ update staff_profiles set status = 'published' $q$), 'ERR:42501');
select tests.check('cannot publish without approval',
  tests.scalar('ceo', $q$ select profile_transition((select id from staff_profiles limit 1), 'published')::text $q$), 'ERR:23514');
select tests.check('departure needs staff.offboard',
  tests.scalar('admin', $q$ select terminate_staff((select id from staff where email = 'ann.old@ada.test'), current_date, 'left')::text $q$), 'ERR:42501');
select tests.check('departure needs a reason',
  tests.scalar('ceo', $q$ select terminate_staff((select id from staff where email = 'ann.old@ada.test'), current_date, ' ')::text $q$), 'ERR:23514');
update staff set start_date = current_date + 10 where email = 'ann.old@ada.test';
select tests.check('an end date before the start date is refused with a clear error',
  tests.scalar('ceo', $q$ select terminate_staff((select id from staff where email = 'ann.old@ada.test'), current_date, 'changed mind')::text $q$), 'ERR:23514');
update staff set start_date = current_date - 10 where email = 'ann.old@ada.test';
select tests.check('nobody can offboard themselves',
  tests.scalar('ceo', $q$ select terminate_staff((select id from staff where email = 'ceo@ada.test'), current_date, 'x')::text $q$), 'ERR:42501');

-- Cross-cutting: events and audit ---------------------------------------------------------------
select tests.check('events never carry personal data',
  (select count(*)::text from events where payload::text ~ '@' or payload::text ilike '%ann%' or payload::text ilike '%applicant%'), '0');
select tests.check('approval of a vacancy is in the audit trail with the approver',
  (select count(*)::text from audit_log where table_name = 'vacancies' and new_data ->> 'status' = 'approved'
     and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')), '1');
select tests.check('hire is in the audit trail',
  (select count(*)::text from audit_log where table_name = 'applications' and new_data ->> 'status' = 'accepted'
     and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')), '1');

select tests.finish();
rollback;
