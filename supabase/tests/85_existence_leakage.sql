-- PERMANENT REGRESSION SUITE: a restricted record must be indistinguishable from a record that does not exist,
-- to anyone not authorised to know it exists - through errors, counts, lookups, helper functions and API results.
-- Every probe runs the same call against the restricted client's id and against a random id and requires
-- IDENTICAL observable outcomes (value, SQLSTATE and message). Control checks prove the probes can tell a visible
-- record from a hidden one, so a green result is meaningful.
begin;
select tests.setup();
select tests.setup_hr();

-- A restricted client with real relationships (contact, project, quote, lead), a confidential one, and a random id.
insert into clients (name, classification, owner_division_id) select 'Secret Corp', 'restricted', id from divisions where key = 'web';
insert into tests.ids select 'client:R', id from clients where name = 'Secret Corp';
insert into people (full_name, email) values ('Sam Secret', 'sam@secret.example');
insert into client_contacts (client_id, person_id) select tests.id('client:R'), id from people where email = 'sam@secret.example';
insert into projects (client_id, lead_division_id, name) select tests.id('client:R'), id, 'Secret project' from divisions where key = 'web';
insert into leads (division_id, title, client_id) select id, 'Secret lead', tests.id('client:R') from divisions where key = 'web';
insert into tests.ids values ('x:random', gen_random_uuid());
insert into tests.ids select 'staff:target', id from staff where email = 'web_staff@ada.test';
insert into tests.ids select 'lead:probe', id from leads where title = 'Secret lead';
select tests.mkclient('web_lead', 'Visible Corp', 'web');
insert into tests.ids select 'client:V', id from clients where name = 'Visible Corp';

-- Controls: the probes DO distinguish a visible record from a hidden one ----------------------------------------------------------------
select tests.check('control: a visible client is distinguishable from a hidden one (count)',
  left(tests.same_for('web_lead', $q$ select count(*)::text from clients where id = %L $q$, tests.id('client:V'), tests.id('client:R')), 9), 'DIFFERENT');
select tests.check('control: a visible client is distinguishable from a hidden one (360 view)',
  left(tests.same_for('web_lead', $q$ select (client_360(%L) is null)::text $q$, tests.id('client:V'), tests.id('client:R')), 9), 'DIFFERENT');

-- Reads ----------------------------------------------------------------------------------------------------------------------------------
select tests.check('select count by id', tests.same_for('web_lead', $q$ select count(*)::text from clients where id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('select count by id (division staff)', tests.same_for('web_staff', $q$ select count(*)::text from clients where id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('select count by id (finance, who can see most clients)', tests.same_for('fin', $q$ select count(*)::text from clients where id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('client_360', tests.same_for('web_lead', $q$ select coalesce(client_360(%L)::text, 'null') $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('contacts of the client', tests.same_for('web_lead', $q$ select count(*)::text from client_contacts where client_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('divisions of the client', tests.same_for('web_lead', $q$ select count(*)::text from client_divisions where client_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('projects of the client', tests.same_for('web_lead', $q$ select count(*)::text from projects where client_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('quotes of the client', tests.same_for('web_lead', $q$ select count(*)::text from quotes where client_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('leads of the client', tests.same_for('web_lead', $q$ select count(*)::text from leads where client_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('the whole visible client list shows no trace of the restricted client',
  tests.scalar('web_lead', $q$ select string_agg(name, ',' order by name) from clients $q$), 'C_web,Visible Corp');
select tests.check('the registry and sequences are not readable', tests.same_for('web_lead', $q$ select count(*)::text from entity_registry where entity_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');

-- Commands: errors must not betray existence ---------------------------------------------------------------------------------------------
select tests.check('claim_client_for_division', tests.same_for('web_lead', $q$ select claim_client_for_division(%L, (select id from tests.ids where key = 'div:web'))::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('set_client_owner', tests.same_for('web_lead', $q$ select set_client_owner(%L, (select id from tests.ids where key = 'staff:target'))::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('add_client_contact', tests.same_for('web_lead', $q$ select add_client_contact(%L, 'Zed Probe', 'zed@probe.example')::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('quote_create', tests.same_for('web_lead', $q$ select quote_create(%L, (select id from tests.ids where key = 'div:web'), 'Probe')::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('update client', tests.same_for('web_lead', $q$ with u as (update clients set notes = 'probe' where id = %L returning 1) select count(*)::text from u $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('insert project for the client', tests.same_for('web_lead', $q$ with i as (insert into projects (client_id, lead_division_id, name) values (%L, (select id from tests.ids where key = 'div:web'), 'Probe') returning id) select count(*)::text from i $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('lead_qualify against the client', tests.same_for('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:probe'), %L)::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('enquiry candidate linking', tests.same_for('web_lead', $q$ select enquiry_resolve_candidate(gen_random_uuid(), %L, 'link')::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('authorization helper: can_view_client', tests.same_for('web_lead', $q$ select can_view_client(%L)::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('authorization helper: can_edit_client', tests.same_for('web_lead', $q$ select can_edit_client(%L)::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');

-- Website enquiries ------------------------------------------------------------------------------------------------------------------------------
select tests.enq('main', 'Sam S', 'sam@secret.example', null, 'Secret Corp', null, 'Looking for help');
select tests.enq('main', 'Una K', 'una@unknown.example', null, 'Zzz Unknown Holdings', null, 'Looking for help');
select tests.check('the website receives the same kind of response either way',
  (select count(distinct k)::text from (select jsonb_object_keys(tests.enq('main', 'A', 'a1@x.example', null, 'Secret Corp', null, 'hi')::jsonb) k union all
                                         select jsonb_object_keys(tests.enq('main', 'B', 'b1@x.example', null, 'Zzz Other Ltd', null, 'hi')::jsonb)) q), '1');
select tests.check('the intake handler sees the same state for both enquiries (status, client link, candidates)',
  (select string_agg(status::text || ':' || (client_id is null)::text || ':' || (select count(*) from enquiry_candidates c where c.enquiry_id = e.id and not c.hidden)::text, ',' order by submitted_email)
     from enquiries e where submitted_email in ('sam@secret.example', 'una@unknown.example')), 'processed:true:0,processed:true:0');
select tests.check('management sees the hidden candidate rows; the handler cannot see any',
  tests.scalar('admin', 'select (count(*) > 0)::text from enquiry_candidates where hidden') || tests.scalar('web_lead', 'select count(*)::text from enquiry_candidates'), 'true0');
select tests.check('the handler''s match explanation is identical for both',
  (select count(distinct match_summary)::text from enquiries where submitted_email in ('sam@secret.example', 'una@unknown.example')), '1');

-- Names: lookup, creation and duplicate checks ----------------------------------------------------------------------------------------------
select tests.check('client_lookup by name', tests.outcome('web_lead', $q$ select client_lookup('Secret Corp')::text $q$), tests.outcome('web_lead', $q$ select client_lookup('Zzz Unknown Holdings')::text $q$));
select tests.check('client_lookup by a contact email of the restricted client', tests.outcome('web_lead', $q$ select client_lookup(p_email => 'sam@secret.example')::text $q$), tests.outcome('web_lead', $q$ select client_lookup(p_email => 'nobody@nowhere.example')::text $q$));
update clients set registration_number = '2020/9999' where id = tests.id('client:R');
select tests.check('client_lookup by the restricted client''s registration number', tests.outcome('web_lead', $q$ select client_lookup(p_registration => '2020/9999')::text $q$), tests.outcome('web_lead', $q$ select client_lookup(p_registration => '1999/0001')::text $q$));
select tests.check('client_create with the restricted client''s registration number behaves like a fresh number',
  tests.outcome('web_lead', $q$ select (client_create('Quartz Mining Holdings', (select id from tests.ids where key = 'div:web'), 'company', '2020/9999') ->> 'status') $q$),
  tests.outcome('web_lead', $q$ select (client_create('Zephyr Aviation Services', (select id from tests.ids where key = 'div:web'), 'company', '1999/0002') ->> 'status') $q$));
select tests.check('duplicate-message helper', tests.outcome('web_lead', $q$ select coalesce(client_duplicate_message('Secret Corp', null, null), 'null') $q$), tests.outcome('web_lead', $q$ select coalesce(client_duplicate_message('Zzz Unknown Holdings', null, null), 'null') $q$));
select tests.check('client_create: same response shape for a colliding and a fresh name',
  tests.outcome('web_lead', $q$ select (client_create('Secret Corp', (select id from tests.ids where key = 'div:web')) ->> 'status') $q$),
  tests.outcome('web_lead', $q$ select (client_create('Zzz Unknown Holdings', (select id from tests.ids where key = 'div:web')) ->> 'status') $q$));
select tests.check('...and the creator sees only their own record under that name', tests.scalar('web_lead', $q$ select count(*)::text from clients where name_key = client_name_key('Secret Corp') $q$), '1');

-- Other record types: hidden applications, services, vacancies ------------------------------------------------------------------------------------------
insert into vacancies (position_id, title, description, requirements, status, published_at) select id, 'Web Developer', 'd', 'r', 'published', now() from positions where title = 'Web Developer';
select tests.try('recruiter', $q$ select staff_record_application((select id from vacancies where title = 'Web Developer'), 'Hidden Applicant', 'hidden@applicant.example') $q$);
insert into tests.ids select 'app:hidden', id from applications order by created_at desc limit 1;
select tests.check('application_division on an application the caller cannot see', tests.same_for('tech_lead', $q$ select coalesce(application_division(%L)::text, 'null') $q$, tests.id('app:hidden'), tests.id('x:random')), 'same');
select tests.check('can_view_application_row on an invisible vacancy', tests.same_for('tech_lead', $q$ select can_view_application_row(%L)::text $q$, (select vacancy_id from applications where id = tests.id('app:hidden')), tests.id('x:random')), 'same');
select tests.check('reading an invisible application', tests.same_for('tech_lead', $q$ select count(*)::text from applications where id = %L $q$, tests.id('app:hidden'), tests.id('x:random')), 'same');
insert into services (division_id, name, classification) select id, 'Secret Service', 'restricted' from divisions where key = 'web';
insert into tests.ids select 'svc:R', id from services where name = 'Secret Service';
select tests.check('service_division on a restricted service', tests.same_for('web_staff', $q$ select coalesce(service_division(%L)::text, 'null') $q$, tests.id('svc:R'), tests.id('x:random')), 'same');
select tests.check('reading a restricted service', tests.same_for('web_staff', $q$ select count(*)::text from services where id = %L $q$, tests.id('svc:R'), tests.id('x:random')), 'same');

-- Positive control: the people who ARE authorised do see it ---------------------------------------------------------------------------------------------
select tests.check('authorised: the CEO sees the restricted client and its 360', tests.scalar('ceo', $q$ select count(*)::text from clients where name = 'Secret Corp' and classification = 'restricted' $q$) || tests.scalar('ceo', $q$ select (client_360((select id from tests.ids where key = 'client:R')) is not null)::text $q$), '1true');
select tests.check('authorised: management sees the match review that was raised for the colliding creation', tests.scalar('admin', $q$ select (count(*) >= 1)::text from matching_reviews $q$), 'true');

select tests.finish();
rollback;
