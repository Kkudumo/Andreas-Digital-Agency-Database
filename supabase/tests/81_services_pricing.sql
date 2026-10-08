-- ONE service catalogue, ONE pricing system with immutable history and approval; the shared approvals inbox.
begin;
select tests.setup();
select tests.setup_hr();
-- website subscribes to catalogue events
insert into event_subscriptions (website_id, url, event_types) values (tests.id('site:main'), 'https://main.ada.test/api/revalidate', array['service.published', 'service.unpublished', 'price.changed']);

-- Catalogue basics ---------------------------------------------------------------------------------------------------
select tests.remember('svc:web', tests.scalar('web_lead', $q$ insert into services (division_id, name, category, summary, description, pricing_model, billing_unit)
  select id, 'Website Development', 'Web', 'A professional business website', 'Design, build and launch of your website', 'fixed', 'project' from divisions where key = 'web' returning id::text $q$));
select tests.check('service gets an ADA ID', (select (ada_id ~ '^ADA-SVC-\d{4}-\d{4}$')::text from services where id = tests.id('svc:web')), 'true');
select tests.check('Tech cannot create a service in Web''s catalogue',
  tests.try('tech_lead', $q$ insert into services (division_id, name) select id, 'Sneaky' from divisions where key = 'web' $q$), 'ERR:42501');
select tests.check('division staff without services.create cannot create services',
  tests.try('web_staff', $q$ insert into services (division_id, name) select id, 'Nope' from divisions where key = 'web' $q$), 'ERR:42501');
select tests.check('service names are unique within a division (case-insensitive)',
  tests.try('web_lead', $q$ insert into services (division_id, name) select id, 'WEBSITE development' from divisions where key = 'web' $q$), 'ERR:23505');
select tests.remember('svc:cctv', tests.scalar('tech_lead', $q$ insert into services (division_id, name, summary, description, billing_unit)
  select id, 'CCTV Installation', 'Cameras installed and configured', 'Site survey, supply and installation of CCTV', 'camera' from divisions where key = 'tech' returning id::text $q$));
select tests.check('services cannot be created already published',
  tests.try('web_lead', $q$ insert into services (division_id, name, status) select id, 'X', 'published' from divisions where key = 'web' $q$), 'ERR:42501');
select tests.check('service status cannot be edited directly', tests.try('ceo', $q$ update services set status = 'published' $q$), 'ERR:42501');
select tests.check('a service cannot move between divisions', tests.try('web_lead', $q$ update services set division_id = (select id from tests.ids where key = 'div:tech') where id = (select id from tests.ids where key = 'svc:web') $q$), 'ERR:42501');
select tests.check('every active staff member sees the same catalogue', tests.scalar('web_staff', 'select count(*)::text from services') || tests.scalar('fin', 'select count(*)::text from services') || tests.scalar('tech_staff', 'select count(*)::text from services'), '222');
select tests.check('a login without a staff record sees nothing', tests.scalar('outsider', 'select count(*)::text from services'), '0');

-- Price proposals -------------------------------------------------------------------------------------------------------------------
select tests.check('negative price rejected',
  tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), -5, 'NAD', current_date, 'x')::text $q$), 'ERR:23514');
select tests.check('a reason is required',
  tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, ' ')::text $q$), 'ERR:23514');
select tests.check('the past cannot be rewritten',
  tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date - 1, 'backdated')::text $q$), 'ERR:23514');
select tests.check('Tech cannot price Web''s service',
  tests.scalar('tech_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'x')::text $q$), 'ERR:42501');
select tests.check('web staff cannot propose prices',
  tests.scalar('web_staff', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'x')::text $q$), 'ERR:42501');
select tests.remember('price:web1', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'Launch price')::text $q$));
select tests.check('proposal is version 1 and pending', (select version::text || status::text from service_prices where id = tests.id('price:web1')), '1pending_approval');
select tests.check('only one pending proposal per service',
  tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5500, 'NAD', current_date, 'again')::text $q$), 'ERR:23505');
select tests.check('a pending price is invisible to ordinary staff', tests.scalar('web_staff', 'select count(*)::text from service_prices'), '0');
select tests.check('...visible to its proposer and to approvers', tests.scalar('web_lead', 'select count(*)::text from service_prices') || tests.scalar('ceo', 'select count(*)::text from service_prices'), '11');
select tests.check('the proposal is in the approvals queue',
  (select count(*)::text from approval_requests where kind = 'price_change' and status = 'pending' and entity_id = tests.id('price:web1')), '1');
select tests.check('approvers see the queue entry; ordinary staff and proposers-only roles do not',
  tests.scalar('ceo', $q$ select count(*)::text from approval_requests where kind = 'price_change' $q$) || tests.scalar('web_staff', $q$ select count(*)::text from approval_requests $q$) || tests.scalar('fin', $q$ select count(*)::text from approval_requests where kind = 'price_change' $q$), '100');
select tests.check('approvers were notified',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'ceo@ada.test' and n.title like 'Price change awaiting approval%'), '1');

-- Approval, with the four-eyes rule ------------------------------------------------------------------------------------------------------
select tests.check('the proposer (no pricing.approve) cannot approve',
  tests.scalar('web_lead', $q$ select (price_decide((select id from tests.ids where key = 'price:web1'), true)).status::text $q$), 'ERR:42501');
insert into roles (key, name) values ('pricing_approver', 'Pricing approver');
insert into role_permissions (role_id, permission_id) select r.id, p.id from roles r, permissions p where r.key = 'pricing_approver' and p.key in ('pricing.approve', 'pricing.propose');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'admin@ada.test' and r.key = 'pricing_approver';
select tests.remember('price:adm', tests.scalar('admin', $q$ select price_propose((select id from tests.ids where key = 'svc:cctv'), 12000, 'NAD', current_date, 'CCTV launch')::text $q$));
select tests.check('someone with pricing.approve but without approve_own cannot approve their OWN proposal',
  tests.scalar('admin', $q$ select (price_decide((select id from tests.ids where key = 'price:adm'), true)).status::text $q$), 'ERR:42501');
select tests.check('a rejection needs a note', tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:adm'), false)).status::text $q$), 'ERR:23514');
select tests.check('a different approver can approve', tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:adm'), true, 'ok')).status::text $q$), 'approved');
select tests.check('management approves the Web price', tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:web1'), true)).status::text $q$), 'approved');
select tests.check('the approver and time are recorded', (select (approved_by = (select id from staff where email = 'ceo@ada.test') and approved_at is not null)::text from service_prices where id = tests.id('price:web1')), 'true');
select tests.check('the queue entry is closed as approved by management',
  (select (status = 'approved' and decided_by = (select id from staff where email = 'ceo@ada.test'))::text from approval_requests where entity_id = tests.id('price:web1')), 'true');
select tests.check('the price in force today is N$5,000', (select (price_on(tests.id('svc:web'))).amount::text), '5000.00');
select tests.check('every active staff member sees the approved price', tests.scalar('web_staff', 'select amount::text from service_prices where service_id = (select id from tests.ids where key = ''svc:web'')'), '5000.00');
select tests.check('the proposer was told', (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'web_lead@ada.test' and n.type = 'price.approved'), '1');
select tests.check('price.changed was emitted', (select count(*)::text from events where event_type = 'price.changed' and payload ->> 'service' = (select ada_id from services where id = tests.id('svc:web'))), '1');

-- History: a new version never overwrites the old ----------------------------------------------------------------------------------------
select tests.remember('price:web2', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 6000, 'NAD', current_date + 30, 'Annual increase')::text $q$));
select tests.check('a new version must start after the current one',
  tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 7000, 'NAD', current_date, 'same day')::text $q$), 'ERR:23514');
select tests.check('approve version 2', tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:web2'), true)).status::text $q$), 'approved');
select tests.check('until the effective date, the old price still applies', (select (price_on(tests.id('svc:web'))).amount::text), '5000.00');
select tests.check('from the effective date, the new price applies', (select (price_on(tests.id('svc:web'), current_date + 30)).amount::text), '6000.00');
select tests.check('version 1 was closed the day before version 2 starts', (select (effective_to = current_date + 29)::text from service_prices where id = tests.id('price:web1')), 'true');
select tests.check('both versions are still stored', (select count(*)::text from service_prices where service_id = tests.id('svc:web') and status = 'approved'), '2');
select tests.check('a version before the earliest approved one does not exist', (select (price_on(tests.id('svc:web'), current_date - 400)).id is null)::text, 'true');
select tests.check('the next proposal must start after the latest approved version',
  tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 7000, 'NAD', current_date + 10, 'too early')::text $q$), 'ERR:23514');
select tests.check('an approved amount cannot be changed - not by users', tests.try('ceo', $q$ update service_prices set amount = 1 $q$), 'ERR:42501');
select tests.check('an approved amount cannot be changed - not even by the database owner', tests.try_owner($q$ update service_prices set amount = 1 where status = 'approved' $q$), 'ERR:42501');
select tests.check('an approved effective date cannot be moved', tests.try_owner($q$ update service_prices set effective_from = effective_from + 1 where status = 'approved' $q$), 'ERR:42501');
select tests.check('approved prices cannot be deleted', tests.try_owner($q$ delete from service_prices where status = 'approved' $q$), 'ERR:42501');
select tests.check('users cannot write prices directly', tests.try('ceo', $q$ insert into service_prices (service_id, version, amount, effective_from, reason) values (gen_random_uuid(), 9, 1, current_date, 'x') $q$), 'ERR:42501');

-- the N$4,000 -> N$5,000 -> N$6,000 example, as history ----------------------------------------------------------------------------------
insert into services (division_id, name) select id, 'History Demo' from divisions where key = 'web';
insert into service_prices (service_id, version, amount, effective_from, effective_to, status, reason)
  select s.id, v.version, v.amount, v.f, v.t, 'approved', 'history' from services s, (values
    (1, 4000, date '2026-01-01', date '2026-06-30'), (2, 5000, date '2026-07-01', date '2026-12-31'), (3, 6000, date '2027-01-01', null)) v(version, amount, f, t)
  where s.name = 'History Demo';
select tests.check('March 2026 price was N$4,000', (select (price_on(id, date '2026-03-15')).amount::text from services where name = 'History Demo'), '4000.00');
select tests.check('July 2026 price was N$5,000 (what an invoice of that month must show)', (select (price_on(id, date '2026-07-10')).amount::text from services where name = 'History Demo'), '5000.00');
select tests.check('2027 price is N$6,000', (select (price_on(id, date '2027-02-01')).amount::text from services where name = 'History Demo'), '6000.00');

-- Rejection & withdrawal -------------------------------------------------------------------------------------------------------------------
select tests.remember('price:cctv2', tests.scalar('tech_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:cctv'), 15000, 'NAD', current_date + 5, 'Increase')::text $q$));
select tests.check('another proposer cannot withdraw it', tests.try('web_lead', $q$ select price_withdraw((select id from tests.ids where key = 'price:cctv2')) $q$), 'ERR:42501');
select tests.check('the proposer can withdraw', tests.try('tech_lead', $q$ select price_withdraw((select id from tests.ids where key = 'price:cctv2')) $q$), 'ok');
select tests.check('a withdrawn price is withdrawn', (select status::text from service_prices where id = tests.id('price:cctv2')), 'withdrawn');
select tests.remember('price:cctv3', tests.scalar('tech_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:cctv'), 99999, 'NAD', current_date + 5, 'too high')::text $q$));
select tests.check('rejecting records the reason',
  tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:cctv3'), false, 'Not competitive')).status::text $q$), 'rejected');
select tests.check('a rejected price never takes effect', (select (price_on(tests.id('svc:cctv'), current_date + 10)).amount::text), '12000.00');
select tests.check('a decided proposal cannot be decided again', tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:cctv3'), true)).status::text $q$), 'ERR:23514');

-- Publication of the service ----------------------------------------------------------------------------------------------------------------------
select tests.check('a service without a summary cannot be submitted',
  tests.scalar('web_lead', $q$ select service_transition((select id from services where name = 'History Demo'), 'pending_approval')::text $q$), 'ERR:23514');
select tests.check('web lead submits the service', tests.scalar('web_lead', $q$ select service_transition((select id from tests.ids where key = 'svc:web'), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('the service is in the approvals queue', tests.scalar('ceo', $q$ select count(*)::text from approval_requests where kind = 'service_publication' and status = 'pending' $q$), '1');
select tests.check('web lead cannot approve their own service', tests.scalar('web_lead', $q$ select service_transition((select id from tests.ids where key = 'svc:web'), 'approved')::text $q$), 'ERR:42501');
select tests.check('nothing public yet', tests.pub('main', 'services'), '[]');
select tests.check('management approves', tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:web'), 'approved')::text $q$), 'approved');
select tests.check('approved is still not public', tests.pub('main', 'services'), '[]');
select tests.check('management publishes', tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:web'), 'published')::text $q$), 'published');
select tests.check('the website now receives the service with the price in force, and nothing else',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(tests.pub('main', 'services')::jsonb -> 0) k), 'billing_unit,category,description,division,id,name,price,pricing_model,summary');
select tests.check('...with the right price', (tests.pub('main', 'services')::jsonb -> 0 -> 'price' ->> 'amount'), '5000.00');
select tests.check('...price DTO is only amount, currency and effective_from', (select string_agg(k, ',' order by k) from jsonb_object_keys(tests.pub('main', 'services')::jsonb -> 0 -> 'price') k), 'amount,currency,effective_from');
select tests.check('publishing queued a revalidation for the website', (select count(*)::text from event_deliveries d join events e on e.id = d.event_id where e.event_type = 'service.published' and d.status = 'pending'), '1');
select tests.scalar('tech_lead', $q$ select service_transition((select id from tests.ids where key = 'svc:cctv'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:cctv'), 'approved')::text $q$);
select tests.check('Tech publishes CCTV with its approved price', tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:cctv'), 'published')::text $q$), 'published');
select tests.check('...and the website sees N$12,000', (select x -> 'price' ->> 'amount' from jsonb_array_elements(tests.pub('main', 'services')::jsonb) x where x ->> 'name' = 'CCTV Installation'), '12000.00');
select tests.remember('svc:noprice', tests.scalar('tech_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Unpriced Service', 's', 'd' from divisions where key = 'tech' returning id::text $q$));
select tests.scalar('tech_lead', $q$ select service_transition((select id from tests.ids where key = 'svc:noprice'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:noprice'), 'approved')::text $q$);
select tests.check('a service with a visible price but no price in force cannot be published',
  tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:noprice'), 'published')::text $q$), 'ERR:23514');
select tests.remember('svc:contact', tests.scalar('tech_lead', $q$ insert into services (division_id, name, summary, description, show_price) select id, 'Contact-us Service', 's', 'd', false from divisions where key = 'tech' returning id::text $q$));
select tests.scalar('tech_lead', $q$ select service_transition((select id from tests.ids where key = 'svc:contact'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:contact'), 'approved')::text $q$);
select tests.check('a service may be published with the price hidden ("contact us")', tests.scalar('ceo', $q$ select service_transition((select id from tests.ids where key = 'svc:contact'), 'published')::text $q$), 'published');
select tests.check('a hidden price never reaches the website', (select ((x -> 'price') is null)::text from jsonb_array_elements(tests.pub('main', 'services')::jsonb) x where x ->> 'name' = 'Contact-us Service'), 'true');
select tests.check('the division filter works', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'services', quote_literal('tech'))::jsonb)), '2');
select tests.check('the catalogue is one list for every site that may read it', tests.pub('limited', 'services'), 'ERR:42501');
select tests.check('editing a published service is allowed...', tests.try('web_lead', $q$ update services set description = 'New wording' where id = (select id from tests.ids where key = 'svc:web') $q$), 'ok');
select tests.check('...but sends it back to draft for re-approval', (select status::text from services where id = tests.id('svc:web')), 'draft');
select tests.check('...the website no longer lists it', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'services')::jsonb) x where x ->> 'name' = 'Website Development'), '0');
select tests.check('...and was told to revalidate', (select count(*)::text from event_deliveries d join events e on e.id = d.event_id where e.event_type = 'service.unpublished'), '1');
select tests.check('a price change on its own does not unpublish anything: price changes use versions, not service edits',
  (select status::text from services where id = tests.id('svc:cctv')), 'published');

-- Shared approvals inbox covers vacancies and profiles too ----------------------------------------------------------------------------------------
select tests.remember('vac:q', tests.scalar('web_lead', $q$ insert into vacancies (position_id, title, description, requirements)
  select id, 'Web Developer', 'd', 'r' from positions where title = 'Web Developer' returning id::text $q$));
select tests.scalar('web_lead', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:q'), 'pending_approval')::text $q$);
select tests.check('a vacancy awaiting approval appears in the same queue', tests.scalar('ceo', $q$ select count(*)::text from approval_requests where kind = 'vacancy' and status = 'pending' $q$), '1');
select tests.check('the recruiter (cannot approve vacancies) does not see it', tests.scalar('recruiter', $q$ select count(*)::text from approval_requests where kind = 'vacancy' $q$), '0');
select tests.scalar('ceo', $q$ select vacancy_transition((select id from tests.ids where key = 'vac:q'), 'draft', 'needs more detail')::text $q$);
select tests.check('returning it with a reason records a rejection with the note',
  (select status::text || ':' || coalesce(decision_note, '') from approval_requests where kind = 'vacancy'), 'rejected:needs more detail');

-- Regression: demotion by an EDIT (a BEFORE trigger changes status) must still emit events and close queue entries.
insert into staff_profiles (staff_id, public_name, public_title, status, published_at)
  select id, 'Edit Me', 'Dev', 'published', now() from staff where email = 'web_staff@ada.test';
select tests.check('web staff edits their own published profile', tests.try('web_staff', $q$ update staff_profiles set bio = 'new bio' $q$), 'ok');
select tests.check('...it drops to draft', (select status::text from staff_profiles where public_name = 'Edit Me'), 'draft');
select tests.check('...and the websites are told (profile.unpublished)', (select count(*)::text from events where event_type = 'profile.unpublished'), '1');
insert into staff_profiles (staff_id, public_name, public_title, status)
  select id, 'Pending Edit', 'Dev', 'pending_approval' from staff where email = 'tech_staff@ada.test';
select tests.check('a pending profile enters the queue', (select count(*)::text from approval_requests where kind = 'profile' and status = 'pending'), '1');
select tests.check('the owner edits it while pending', tests.try('tech_staff', $q$ update staff_profiles set bio = 'changed while pending' $q$), 'ok');
select tests.check('...and the stale queue entry is closed rather than left dangling', (select count(*)::text from approval_requests where kind = 'profile' and status = 'pending'), '0');

select tests.finish();
rollback;
