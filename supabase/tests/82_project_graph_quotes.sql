-- Quote -> Project -> Services -> Contacts -> Milestones -> Portfolio, all on ONE client record.
begin;
select tests.setup();
select tests.setup_hr();

-- The central client (created by Tech) and its contact; the catalogue with approved prices ----------------------------------------
select tests.remember('client:abc', tests.mkclient_id('tech_lead', 'ABC Company', 'tech'));
select tests.try('web_lead', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web')) $q$);
select tests.remember('contact:john', tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'John Director', 'john@abc.example', null, 'Director', true)::text $q$));
select tests.remember('svc:web', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Website Development', 's', 'd' from divisions where key = 'web' returning id::text $q$));
select tests.remember('svc:cctv', tests.scalar('tech_lead', $q$ insert into services (division_id, name, summary, description, billing_unit) select id, 'CCTV Installation', 's', 'd', 'camera' from divisions where key = 'tech' returning id::text $q$));
select tests.remember('price:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'launch')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:web'), true)).status::text $q$);
select tests.remember('price:cctv', tests.scalar('tech_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:cctv'), 1200, 'NAD', current_date, 'launch')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:cctv'), true)).status::text $q$);

-- Quotes ----------------------------------------------------------------------------------------------------------------------------------
select tests.check('web staff (no quotes.create) cannot create quotes',
  tests.scalar('web_staff', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web'), 'X')::text $q$), 'ERR:42501');
select tests.check('Tech cannot quote on behalf of Web',
  tests.scalar('tech_lead', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web'), 'X')::text $q$), 'ERR:42501');
select tests.check('a client the division cannot see cannot be quoted',
  tests.scalar('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:C_tech'), (select id from tests.ids where key = 'div:web'), 'X')::text $q$), 'ERR:P0002');
select tests.remember('quote:1', tests.scalar('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web'),
    'Website for ABC Company', (select id from tests.ids where key = 'contact:john'))::text $q$));
select tests.check('quote has an ADA ID and links to the SAME client', (select (ada_id ~ '^ADA-QUO-\d{4}-\d{4}$' and client_id = tests.id('client:abc'))::text from quotes where id = tests.id('quote:1')), 'true');
select tests.check('a quote cannot be submitted without lines',
  tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'pending_approval')::text $q$), 'ERR:23514');
select tests.remember('line:1', tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), (select id from tests.ids where key = 'svc:web'))::text $q$));
select tests.check('the line snapshots the catalogue price (N$5,000) and records the version used',
  (select (unit_price = 5000 and price_id = tests.id('price:web') and line_total = 5000)::text from quote_lines where id = tests.id('line:1')), 'true');
select tests.check('the quote total follows the lines', (select total::text from quotes where id = tests.id('quote:1')), '5000.00');
select tests.check('a line can mix services of another division (one client, many divisions)',
  tests.try('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), (select id from tests.ids where key = 'svc:cctv'), 4) $q$), 'ok');
select tests.check('total = 5000 + 4 x 1200', (select total::text from quotes where id = tests.id('quote:1')), '9800.00');
select tests.check('a custom line needs a description and price', tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), null, 1, null)::text $q$), 'ERR:23514');
select tests.check('a non-catalogue price needs a reason',
  tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), (select id from tests.ids where key = 'svc:web'), 1, 4500)::text $q$), 'ERR:23514');
select tests.check('a discounted line is allowed with a reason',
  tests.try('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), (select id from tests.ids where key = 'svc:web'), 1, 4500, 'Early adopter discount', 'Extra page', 0) $q$), 'ok');
select tests.check('web staff cannot edit the quote', tests.scalar('web_staff', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), null, 1, 10, null, 'x')::text $q$), 'ERR:42501');
select tests.check('quote lines cannot be written directly', tests.try('web_lead', $q$ update quote_lines set unit_price = 1 $q$), 'ERR:42501');

-- A price change after the line was added does NOT alter the quote ------------------------------------------------------------------------------
select tests.remember('price:web2', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 6000, 'NAD', current_date + 1, 'Increase')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:web2'), true)).status::text $q$);
select tests.check('the quote line still shows N$5,000 after the catalogue changed', (select unit_price::text from quote_lines where id = tests.id('line:1')), '5000.00');

-- Approval & lifecycle -----------------------------------------------------------------------------------------------------------------------------
select tests.check('web lead submits for approval', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('the quote is in the approvals queue', tests.scalar('ceo', $q$ select count(*)::text from approval_requests where kind = 'quote' and status = 'pending' $q$), '1');
select tests.check('lines are locked after submission', tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:1'), null, 1, 10, null, 'late')::text $q$), 'ERR:42501');
select tests.check('...and the database itself refuses any write path to a locked quote''s lines (update)', tests.try_owner($q$ update quote_lines set unit_price = 1 where quote_id = (select id from tests.ids where key = 'quote:1') $q$), 'ERR:42501');
select tests.check('...(delete)', tests.try_owner($q$ delete from quote_lines where quote_id = (select id from tests.ids where key = 'quote:1') $q$), 'ERR:42501');
select tests.check('...(insert)', tests.try_owner($q$ insert into quote_lines (quote_id, description, unit_price) values ((select id from tests.ids where key = 'quote:1'), 'sneaky', 1) $q$), 'ERR:42501');
select tests.check('the content is locked after submission', tests.try('web_lead', $q$ update quotes set title = 'Changed' where id = (select id from tests.ids where key = 'quote:1') $q$), 'ERR:42501');
select tests.check('totals cannot be edited', tests.try('web_lead', $q$ update quotes set total = 1 $q$), 'ERR:42501');
select tests.check('the preparer cannot approve their own quote', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'approved')::text $q$), 'ERR:42501');
select tests.check('finance can see the quote but cannot approve it', tests.scalar('fin', $q$ select count(*)::text from quotes $q$) || tests.scalar('fin', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'approved')::text $q$), '1ERR:42501');
select tests.check('management approves', tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'approved')::text $q$), 'approved');
select tests.check('it cannot be accepted before it has been sent', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'accepted')::text $q$), 'ERR:23514');
select tests.check('web lead sends it', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'sent')::text $q$), 'sent');
select tests.check('an unaccepted quote cannot be converted', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:1'))::text $q$), 'ERR:23514');
select tests.check('the client accepts', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'accepted', 'Signed by John')::text $q$), 'accepted');
select tests.check('accepting notifies people who can create projects', (select (count(*) >= 1)::text from notifications where type = 'quote.accepted'), 'true');

-- Quote -> Project ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('web staff cannot convert', tests.scalar('web_staff', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:1'))::text $q$), 'ERR:42501');
select tests.remember('project:abc', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:1'))::text $q$));
select tests.check('the project belongs to the SAME client and the quoting division',
  (select (client_id = tests.id('client:abc') and lead_division_id = tests.id('div:web') and status = 'approved')::text from projects where id = tests.id('project:abc')), 'true');
select tests.check('the quote links to the project', (select (project_id = tests.id('project:abc') and converted_at is not null)::text from quotes where id = tests.id('quote:1')), 'true');
select tests.check('services carried over with their price snapshots',
  (select string_agg(s.name || '=' || ps.unit_price::text || '/' || ps.quantity::text, ',' order by s.name, ps.unit_price) from project_services ps join services s on s.id = ps.service_id where ps.project_id = tests.id('project:abc')),
  'CCTV Installation=1200.00/4.00,Website Development=4500.00/1.00,Website Development=5000.00/1.00');
select tests.check('the project total of its services equals the quote total', (select sum(line_total)::text from project_services where project_id = tests.id('project:abc')), (select total::text from quotes where id = tests.id('quote:1')));
select tests.check('each website line points at the catalogue version it was priced from (the discounted one also states why it differs)',
  (select count(*)::text from project_services where project_id = tests.id('project:abc') and price_id = tests.id('price:web')) ||
  (select count(*)::text from project_services where project_id = tests.id('project:abc') and price_override_reason = 'Early adopter discount'), '21');
select tests.check('the quote contact is a project contact (the SAME contact record)',
  (select count(*)::text from project_contacts where project_id = tests.id('project:abc') and contact_id = tests.id('contact:john')), '1');
select tests.check('the account manager is on the project', (select count(*)::text from project_members pm join staff s on s.id = pm.staff_id where pm.project_id = tests.id('project:abc') and s.email = 'web_lead@ada.test'), '1');
select tests.check('converting again returns the same project (idempotent)', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:1'))::text $q$), tests.id('project:abc')::text);
select tests.check('...without duplicating services', (select count(*)::text from project_services where project_id = tests.id('project:abc')), '3');
select tests.check('the client still has exactly one record', (select count(*)::text from clients where name_key = 'abc'), '1');

-- The same John on a second project (Tech), no re-typing ---------------------------------------------------------------------------------------------------------
select tests.remember('project:cctv', tests.scalar('tech_lead', $q$ insert into projects (client_id, lead_division_id, name) select (select id from tests.ids where key = 'client:abc'), id, 'ABC CCTV' from divisions where key = 'tech' returning id::text $q$));
select tests.check('Tech attaches the SAME contact record to its project',
  tests.try('tech_lead', $q$ insert into project_contacts (project_id, contact_id, role) values ((select id from tests.ids where key = 'project:cctv'), (select id from tests.ids where key = 'contact:john'), 'site contact') $q$), 'ok');
select tests.check('one contact record, two projects', (select count(*)::text from project_contacts where contact_id = tests.id('contact:john')), '2');
select tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:C_web'), 'Other Person', 'other@x.example')::text $q$);
select tests.check('a contact of a DIFFERENT client cannot be attached to the project',
  tests.try_owner($q$ insert into project_contacts (project_id, contact_id) select (select id from tests.ids where key = 'project:cctv'), cc.id from client_contacts cc join people p on p.id = cc.person_id where p.email = 'other@x.example' $q$), 'ERR:23514');

-- Services on a project directly, with snapshot --------------------------------------------------------------------------------------------------------------------
select tests.check('web staff cannot add services to a project', tests.scalar('web_staff', $q$ select project_add_service((select id from tests.ids where key = 'project:abc'), (select id from tests.ids where key = 'svc:web'))::text $q$), 'ERR:42501');
select tests.check('a lead adds a service at the price in force', tests.try('tech_lead', $q$ select project_add_service((select id from tests.ids where key = 'project:cctv'), (select id from tests.ids where key = 'svc:cctv'), 6) $q$), 'ok');
select tests.check('...snapshot is today''s catalogue price', (select unit_price::text from project_services where project_id = tests.id('project:cctv')), '1200.00');
select tests.check('a service without an approved price needs a stated price and reason',
  tests.scalar('tech_lead', $q$ select project_add_service((select id from tests.ids where key = 'project:cctv'), (select id from services where name = 'Website Development'), 1, 100)::text $q$), 'ERR:23514');
select tests.check('project services cannot be written directly', tests.try('tech_lead', $q$ update project_services set unit_price = 1 $q$), 'ERR:42501');

-- Controlled project lifecycle, milestones, tasks -------------------------------------------------------------------------------------------------------------------------
select tests.check('project cannot go from approved to completed', tests.scalar('web_lead', $q$ select project_transition((select id from tests.ids where key = 'project:abc'), 'completed')::text $q$), 'ERR:23514');
select tests.check('pausing needs a reason', tests.scalar('web_lead', $q$ select project_transition((select id from tests.ids where key = 'project:abc'), 'on_hold')::text $q$), 'ERR:23514');
select tests.check('project starts', tests.scalar('web_lead', $q$ select project_transition((select id from tests.ids where key = 'project:abc'), 'active')::text $q$), 'active');
select tests.remember('ms:1', tests.scalar('web_lead', $q$ insert into milestones (project_id, title, due_date) values ((select id from tests.ids where key = 'project:abc'), 'Design approved', current_date + 14) returning id::text $q$));
select tests.check('a task can belong to a milestone of its own project',
  tests.try('web_lead', $q$ insert into tasks (project_id, title, milestone_id) values ((select id from tests.ids where key = 'project:abc'), 'Wireframes', (select id from tests.ids where key = 'ms:1')) $q$), 'ok');
select tests.check('...but not to another project''s milestone',
  tests.try('tech_lead', $q$ insert into tasks (project_id, title, milestone_id) values ((select id from tests.ids where key = 'project:cctv'), 'Cabling', (select id from tests.ids where key = 'ms:1')) $q$), 'ERR:23514');
select tests.check('Tech (not on the Web project) cannot see its milestones', tests.scalar('tech_staff', $q$ select count(*)::text from milestones $q$), '0');
select tests.check('marking a milestone done stamps the time',
  tests.try('web_lead', $q$ update milestones set status = 'done' $q$) ||
  (select (completed_at is not null)::text from milestones where id = tests.id('ms:1')), 'okfalse');

-- Portfolio: a consent-gated projection of a finished project ------------------------------------------------------------------------------------------------------
select tests.check('a portfolio entry cannot be made for an unfinished project',
  tests.try('web_lead', $q$ insert into portfolio_entries (project_id, title) values ((select id from tests.ids where key = 'project:abc'), 'ABC Website') $q$), 'ERR:23514');
select tests.check('the project is completed', tests.scalar('web_lead', $q$ select project_transition((select id from tests.ids where key = 'project:abc'), 'completed')::text $q$), 'completed');
select tests.check('completing emits project.completed', (select count(*)::text from events where event_type = 'project.completed'), '1');
select tests.remember('pf:1', tests.scalar('web_lead', $q$ insert into portfolio_entries (project_id, title, summary, description, technologies) values
  ((select id from tests.ids where key = 'project:abc'), 'ABC Company Website', 'A fast new site', 'Full redesign', array['Next.js', 'PostgreSQL']) returning id::text $q$));
select tests.check('web staff cannot prepare portfolio entries', tests.try('web_staff', $q$ insert into portfolio_entries (project_id, title) values ((select id from tests.ids where key = 'project:abc'), 'x') $q$), 'ERR:42501');
select tests.check('showing the client name needs consent', tests.try('web_lead', $q$ update portfolio_entries set show_client_name = true $q$), 'ERR:23514');
select tests.check('submission needs the client''s consent', tests.scalar('web_lead', $q$ select portfolio_transition((select id from tests.ids where key = 'pf:1'), 'pending_approval')::text $q$), 'ERR:23514');
select tests.check('consent is recorded', tests.try('web_lead', $q$ update portfolio_entries set client_consent = true $q$), 'ok');
select tests.check('web lead submits', tests.scalar('web_lead', $q$ select portfolio_transition((select id from tests.ids where key = 'pf:1'), 'pending_approval')::text $q$), 'pending_approval');
select tests.check('web lead cannot publish', tests.scalar('web_lead', $q$ select portfolio_transition((select id from tests.ids where key = 'pf:1'), 'approved')::text $q$), 'ERR:42501');
select tests.check('nothing public before approval', tests.pub('main', 'portfolio'), '[]');
select tests.scalar('ceo', $q$ select portfolio_transition((select id from tests.ids where key = 'pf:1'), 'approved')::text $q$);
select tests.check('management publishes', tests.scalar('ceo', $q$ select portfolio_transition((select id from tests.ids where key = 'pf:1'), 'published')::text $q$), 'published');
select tests.check('the website receives only the approved projection (no client name, no money, no internal IDs)',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(tests.pub('main', 'portfolio')::jsonb -> 0) k), 'completed_on,description,division,id,images,summary,technologies,title');
select tests.check('the client is anonymous unless the entry says otherwise', (tests.pub('main', 'portfolio') !~ 'ABC Company(?! Website)')::text, 'true');
select tests.check('no price or contact leaks', (tests.pub('main', 'portfolio') !~ '(5000|4500|1200|john|ADA-CLI|ADA-QUO|ADA-PRJ)')::text, 'true');
select tests.check('statistics follow: one portfolio project', (tests.pub('main', 'statistics')::jsonb ->> 'portfolio_projects'), '1');
select tests.check('publishing queued no event for sites that did not subscribe', (select count(*)::text from event_deliveries), '0');
select tests.check('web lead shows the client name once consented', tests.try('web_lead', $q$ update portfolio_entries set show_client_name = true $q$), 'ok');
select tests.check('...which sends it back for re-approval and it leaves the website', (select status::text from portfolio_entries where id = tests.id('pf:1')), 'draft');
select tests.check('...so the website no longer lists it', tests.pub('main', 'portfolio'), '[]');

-- Expiry ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('quote:old', tests.scalar('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web'), 'Old quote')::text $q$));
select tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:old'), null, 1, 100, null, 'Misc')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:old'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'quote:old'), 'approved')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:old'), 'sent')::text $q$);
update quotes set valid_until = current_date - 1 where id = tests.id('quote:old');
select tests.check('an expired quote cannot be accepted', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:old'), 'accepted')::text $q$), 'ERR:23514');
select tests.check('the scheduled job marks it expired', (select expire_quotes()::text), '1');
select tests.check('users cannot run the expiry job', tests.scalar('ceo', $q$ select expire_quotes()::text $q$), 'ERR:42501');
select tests.check('a declined quote needs a reason', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:old'), 'rejected')::text $q$), 'ERR:23514');

select tests.finish();
rollback;
