-- Acceptance scenario (master spec, central-graph clarification): ONE client, ONE contact, ONE catalogue, many divisions.
begin;
select tests.setup();
select tests.setup_hr();

-- 1. ABC Company first contacts ADA Tech: Tech creates the central client and its contact.
select tests.remember('client:abc', tests.mkclient_id('tech_lead', 'ABC Company', 'tech'));
select tests.try('tech_lead', $q$ update clients set legal_name = 'ABC Company (Pty) Ltd', industry = 'Retail' where name = 'ABC Company' $q$);
select tests.remember('contact:john', tests.scalar('tech_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'John Director', 'john@abc.example', '+264811000001', 'Director', true)::text $q$));
select tests.try('tech_lead', $q$ select set_client_owner((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'staff:tech_lead')) $q$);

-- 2. ADA Web later wants to sell to the same company: it joins the existing record instead of creating another.
select tests.check('2. a second ABC Company is not created: Web is pointed at the existing record',
  (tests.mkclient('web_lead', 'ABC Company', 'web')::jsonb ->> 'status') || '/' || (select count(*)::text from clients where name_key = 'abc'), 'exists/1');
select tests.check('2b. Web joins the same client', tests.try('web_lead', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web')) $q$), 'ok');

-- 3. One catalogue, one price list, both divisions.
select tests.remember('svc:web', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Website Development', 's', 'd' from divisions where key = 'web' returning id::text $q$));
select tests.remember('svc:cctv', tests.scalar('tech_lead', $q$ insert into services (division_id, name, summary, description, billing_unit) select id, 'CCTV Installation', 's', 'd', 'camera' from divisions where key = 'tech' returning id::text $q$));
select tests.remember('p:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'launch')::text $q$));
select tests.remember('p:cctv', tests.scalar('tech_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:cctv'), 1200, 'NAD', current_date, 'launch')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web'), true)).status::text $q$);
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:cctv'), true)).status::text $q$);

-- 4. Web quotes the website; the quote references client, contact, service, price version.
select tests.remember('q:web', tests.scalar('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web'), 'ABC website', (select id from tests.ids where key = 'contact:john'))::text $q$));
select tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'q:web'), (select id from tests.ids where key = 'svc:web'))::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:web'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'q:web'), 'approved')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:web'), 'sent')::text $q$);
select tests.check('4. ABC accepts the website quote', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:web'), 'accepted')::text $q$), 'accepted');
select tests.remember('prj:web', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'q:web'))::text $q$));

-- 5. The price list changes afterwards. Nothing that happened before changes.
select tests.remember('p:web2', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 6000, 'NAD', current_date + 1, 'Annual increase')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web2'), true)).status::text $q$);
select tests.check('5. tomorrow''s catalogue price is N$6,000', (select (price_on(tests.id('svc:web'), current_date + 1)).amount::text), '6000.00');
select tests.check('5b. the accepted quote still says N$5,000', (select total::text from quotes where id = tests.id('q:web')), '5000.00');
select tests.check('5c. so does the project''s service line', (select unit_price::text from project_services where project_id = tests.id('prj:web')), '5000.00');

-- 6. Tech quotes CCTV for the SAME client and the SAME contact.
select tests.remember('q:cctv', tests.scalar('tech_lead', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:tech'), 'ABC CCTV', (select id from tests.ids where key = 'contact:john'))::text $q$));
select tests.scalar('tech_lead', $q$ select quote_add_line((select id from tests.ids where key = 'q:cctv'), (select id from tests.ids where key = 'svc:cctv'), 4)::text $q$);
select tests.scalar('tech_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:cctv'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'q:cctv'), 'approved')::text $q$);
select tests.scalar('tech_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:cctv'), 'sent')::text $q$);
select tests.scalar('tech_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:cctv'), 'accepted')::text $q$);
select tests.remember('prj:cctv', tests.scalar('tech_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'q:cctv'))::text $q$));
select tests.scalar('web_lead', $q$ select project_transition((select id from tests.ids where key = 'prj:web'), 'active')::text $q$);

-- 7. The graph: still ONE client, ONE person, two projects, two divisions.
select tests.check('7. one client record', (select count(*)::text from clients where name_key = 'abc'), '1');
select tests.check('7b. one John', (select count(*)::text from people where lower(email) = 'john@abc.example'), '1');
select tests.check('7c. two projects, one client', (select count(distinct client_id)::text || '/' || count(*)::text from projects where id in (tests.id('prj:web'), tests.id('prj:cctv'))), '1/2');
select tests.check('7d. both projects use the same contact record', (select count(distinct contact_id)::text || '/' || count(*)::text from project_contacts where project_id in (tests.id('prj:web'), tests.id('prj:cctv'))), '1/2');
select tests.check('7e. both quotes belong to the same client', (select count(distinct client_id)::text from quotes), '1');

-- 8. CLIENT 360: management sees everything the graph connects.
create temp table c360_ceo as select tests.scalar('ceo', $q$ select client_360((select id from tests.ids where key = 'client:abc'))::text $q$)::jsonb j;
select tests.check('8. overview', (select (j -> 'overview' ->> 'name' = 'ABC Company' and j -> 'overview' ->> 'id' ~ '^ADA-CLI-' and j -> 'overview' ->> 'legal_name' = 'ABC Company (Pty) Ltd')::text from c360_ceo), 'true');
select tests.check('8b. owner and contact', (select (j -> 'overview' -> 'owner' ->> 'name' = 'Tech Lead' and jsonb_array_length(j -> 'contacts') = 1 and j -> 'contacts' -> 0 ->> 'name' = 'John Director')::text from c360_ceo), 'true');
select tests.check('8c. divisions used', (select (select string_agg(x ->> 'code', ',' order by x ->> 'code') from jsonb_array_elements(j -> 'relationship' -> 'divisions') x) from c360_ceo), 'tech,web');
select tests.check('8d. services purchased, with what each cost',
  (select string_agg((x ->> 'service') || '=' || (x ->> 'spent'), ',' order by x ->> 'service') from c360_ceo, jsonb_array_elements(j -> 'relationship' -> 'services_purchased') x), 'CCTV Installation=4800.00,Website Development=5000.00');
select tests.check('8e. both projects are listed with their divisions', (select string_agg((x ->> 'division') || ':' || (x ->> 'status'), ',' order by x ->> 'division') from c360_ceo, jsonb_array_elements(j -> 'projects') x), 'tech:approved,web:active');
select tests.check('8f. quotes: two accepted, total value N$9,800', (select (j -> 'quote_summary' ->> 'accepted')::text || '/' || (j -> 'quote_summary' ->> 'accepted_value') from c360_ceo), '2/9800.00');
select tests.check('8g. activity from the audit log is included for management', (select (jsonb_array_length(j -> 'activity') > 0)::text from c360_ceo), 'true');
select tests.check('8h. sections for modules not built yet are declared, not faked', (select ((j -> 'pending') ? 'tickets' and not ((j -> 'pending') ? 'invoices') and j ? 'invoices' and j ? 'contracts' and j ? 'payments') from c360_ceo)::text, 'true');

-- 9. ...and each other viewer gets only THEIR slice of the same record.
create temp table c360_web as select tests.scalar('web_lead', $q$ select client_360((select id from tests.ids where key = 'client:abc'))::text $q$)::jsonb j;
select tests.check('9. Web sees the client and contact', (select (j -> 'overview' ->> 'name' = 'ABC Company' and jsonb_array_length(j -> 'contacts') = 1)::text from c360_web), 'true');
select tests.check('9b. Web sees its own project only', (select string_agg(x ->> 'division', ',') from c360_web, jsonb_array_elements(j -> 'projects') x), 'web');
select tests.check('9c. Web sees only its own quote and spend', (select (jsonb_array_length(j -> 'quotes') = 1 and j -> 'quote_summary' ->> 'accepted_value' = '5000.00')::text from c360_web), 'true');
select tests.check('9d. Web sees only its own service lines', (select string_agg(x ->> 'service', ',') from c360_web, jsonb_array_elements(j -> 'relationship' -> 'services_purchased') x), 'Website Development');
select tests.check('9e. Web has no audit view, so no activity', (select jsonb_array_length(j -> 'activity')::text from c360_web), '0');
create temp table c360_tech as select tests.scalar('tech_lead', $q$ select client_360((select id from tests.ids where key = 'client:abc'))::text $q$)::jsonb j;
select tests.check('9f. Tech sees its own project and quote only', (select (select string_agg(x ->> 'division', ',') from jsonb_array_elements(j -> 'projects') x) || '/' || (j -> 'quote_summary' ->> 'accepted_value') from c360_tech), 'tech/4800.00');
create temp table c360_fin as select tests.scalar('fin', $q$ select client_360((select id from tests.ids where key = 'client:abc'))::text $q$)::jsonb j;
select tests.check('9g. Finance sees the whole commercial picture', (select (jsonb_array_length(j -> 'projects') = 2 and j -> 'quote_summary' ->> 'accepted_value' = '9800.00')::text from c360_fin), 'true');
select tests.check('9h. ...but no audit activity', (select jsonb_array_length(j -> 'activity')::text from c360_fin), '0');
select tests.check('9i. an auditor has no client access: the 360 view is null', tests.scalar('audit', $q$ select coalesce(client_360((select id from tests.ids where key = 'client:abc'))::text, 'null') $q$), 'null');
select tests.check('9j. a login without staff access gets nothing either', tests.scalar('outsider', $q$ select coalesce(client_360((select id from tests.ids where key = 'client:abc'))::text, 'null') $q$), 'null');
select tests.check('9k. the recruiter, who works with people but not clients, gets nothing', tests.scalar('recruiter', $q$ select coalesce(client_360((select id from tests.ids where key = 'client:abc'))::text, 'null') $q$), 'null');

-- 10. PROJECT 360
create temp table p360_web as select tests.scalar('web_lead', $q$ select project_360((select id from tests.ids where key = 'prj:web'))::text $q$)::jsonb j;
select tests.check('10. project links client, contact, services, quote and staff in one view',
  (select (j -> 'client' ->> 'name' = 'ABC Company' and j -> 'contacts' -> 0 ->> 'name' = 'John Director'
           and j -> 'services' -> 0 ->> 'service' = 'Website Development' and (j -> 'services' -> 0 ->> 'unit_price') = '5000.00'
           and j -> 'services' -> 0 ->> 'quote' ~ '^ADA-QUO-' and j -> 'quotes' -> 0 ->> 'status' = 'accepted'
           and j -> 'staff' -> 0 ->> 'name' = 'Web_Lead')::text from p360_web), 'true');
select tests.check('10b. the project''s budget is hidden from Web (finance only)', (select (jsonb_typeof(j -> 'budget') = 'null')::text from p360_web), 'true');
select tests.check('10c. Tech cannot open the Web project''s 360', tests.scalar('tech_lead', $q$ select coalesce(project_360((select id from tests.ids where key = 'prj:web'))::text, 'null') $q$), 'null');
insert into project_financials (project_id, budget) values (tests.id('prj:web'), 3000);
select tests.check('10d. Finance sees the budget in the same view', tests.scalar('fin', $q$ select project_360((select id from tests.ids where key = 'prj:web')) -> 'budget' ->> 'budget' $q$), '3000.00');
select tests.check('10e. nothing but the allowed money appears for Web even after the budget exists', tests.scalar('web_lead', $q$ select coalesce(project_360((select id from tests.ids where key = 'prj:web')) ->> 'budget', 'null') $q$), 'null');

-- 11. STAFF 360
select tests.check('11. management sees roles, projects and assignment history of a staff member',
  tests.scalar('ceo', $q$ select (jsonb_array_length(s -> 'roles') >= 1 and jsonb_array_length(s -> 'projects') = 1 and jsonb_array_length(s -> 'assignments') >= 0)::text
                          from (select staff_360((select id from tests.ids where key = 'staff:web_lead')) s) q $q$), 'true');
select tests.check('11b. a colleague sees the profile but not the roles', tests.scalar('web_staff', $q$ select (jsonb_array_length(s -> 'roles') = 0 and s -> 'profile' ->> 'name' = 'Web_Lead')::text
                          from (select staff_360((select id from tests.ids where key = 'staff:web_lead')) s) q $q$), 'true');
select tests.check('11c. HR details only for people with hr.view (or the person)', tests.scalar('web_staff', $q$ select coalesce(staff_360((select id from tests.ids where key = 'staff:web_staff')) ->> 'hr', 'null') $q$) || '|' ||
  tests.scalar('web_lead', $q$ select coalesce(staff_360((select id from tests.ids where key = 'staff:web_staff')) ->> 'hr', 'null') $q$), '{"emergency_contact": "Someone"}|null');

-- 12. Registry: every ADA-identified record in the system is registered once.
select tests.check('12. every record with an ADA ID is in the central entity registry', tests.unregistered_tables(), 'none');
select tests.check('12b. ADA IDs of all kinds are unique across the whole system', (select (count(*) = count(distinct ada_id))::text from entity_registry), 'true');

select tests.finish();
rollback;
