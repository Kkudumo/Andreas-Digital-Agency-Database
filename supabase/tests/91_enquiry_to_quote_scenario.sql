-- Acceptance scenario: PUBLIC WEBSITE -> ENQUIRY -> LEAD -> CLIENT/CONTACT MATCH -> QUALIFICATION -> QUOTE -> APPROVAL
-- -> ACCEPTANCE -> PROJECT, twice, through two divisions and two websites, for ONE client and ONE contact.
begin;
select tests.setup();
select tests.setup_hr();
insert into services (division_id, name, summary, description, status, published_at) select id, 'Website Development', 's', 'd', 'published', now() from divisions where key = 'web';
insert into services (division_id, name, summary, description, status, published_at) select id, 'CCTV Installation', 's', 'd', 'published', now() from divisions where key = 'tech';
insert into tests.ids select 'svc:web', id from services where name = 'Website Development';
insert into tests.ids select 'svc:cctv', id from services where name = 'CCTV Installation';
select tests.remember('p:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'launch')::text $q$));
select tests.remember('p:cctv', tests.scalar('tech_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:cctv'), 1200, 'NAD', current_date, 'launch')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web'), true)).status::text $q$);
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:cctv'), true)).status::text $q$);

-- 1. A stranger from a new organization writes through the ADA Main Website ----------------------------------------------------------
select tests.check('1. the website submits an enquiry',
  ((tests.enq('main', 'Dana Delta', 'dana@deltaretail.example', '+264811000777', 'Delta Retail', (select ada_id from services where name = 'Website Development'),
     'We want an online shop', '/services/web-development', 'https://www.google.com/', '{"utm_source":"google","utm_campaign":"google_ads_2026"}')::jsonb ->> 'reference') ~ '^ADA-ENQ-')::text, 'true');
insert into tests.ids select 'enq:1', id from enquiries where source_website_id = tests.id('site:main');
insert into tests.ids select 'lead:1', lead_id from enquiries where id = tests.id('enq:1');
select tests.check('2. it is a lead for Web, tied to a new person, not yet a client', (select (l.status = 'new' and l.person_id is not null and l.client_id is null and d.key = 'web')::text from leads l join divisions d on d.id = l.division_id where l.id = tests.id('lead:1')), 'true');
select tests.check('3. Web qualifies it: the new organization becomes the client, the person becomes its contact',
  (tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:1'), null, 'Delta Retail')::text $q$)::jsonb ->> 'status'), 'qualified');
insert into tests.ids select 'client:delta', client_id from leads where id = tests.id('lead:1');
insert into tests.ids select 'person:dana', person_id from leads where id = tests.id('lead:1');
select tests.check('4. one client, one person, one contact relationship',
  (select count(*)::text from clients where name_key = client_name_key('Delta Retail')) || (select count(*)::text from people where email = 'dana@deltaretail.example') ||
  (select count(*)::text from client_contacts where client_id = tests.id('client:delta')), '111');

-- 2. Quote from the lead, approved, sent, accepted, converted ---------------------------------------------------------------------------
select tests.remember('quote:1', tests.scalar('web_lead', $q$ select quote_create_from_lead((select id from tests.ids where key = 'lead:1'))::text $q$));
select tests.check('5. the quote references the lead, client, contact and the price version in force',
  (select (q.lead_id = tests.id('lead:1') and q.client_id = tests.id('client:delta') and q.contact_id is not null and l.unit_price = 5000
           and l.price_id = tests.id('p:web'))::text from quotes q join quote_lines l on l.quote_id = q.id where q.id = tests.id('quote:1')), 'true');
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'pending_approval')::text $q$);
select tests.check('6. the CEO approves (the preparer is someone else, so no self-approval is involved)',
  tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'approved')::text $q$) || (select self_approved::text from approval_requests where entity_id = tests.id('quote:1')), 'approvedfalse');
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'sent')::text $q$);
select tests.check('7. accepted: the lead is converted', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:1'), 'accepted')::text $q$), 'accepted');
select tests.check('7b. lead status', (select status::text from leads where id = tests.id('lead:1')), 'converted');
select tests.remember('prj:1', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:1'))::text $q$));

-- 3. Later the SAME contact writes through the ADA Tech website ----------------------------------------------------------------------------
select tests.remember('p:web2', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 6000, 'NAD', current_date + 1, 'increase')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web2'), true)).status::text $q$);
select tests.enq('tech', 'Dana D.', 'DANA@deltaretail.example', null, 'Delta Retail Pty Ltd', (select ada_id from services where name = 'CCTV Installation'), 'And we need CCTV for the warehouse', '/contact');
insert into tests.ids select 'enq:2', id from enquiries where source_website_id = tests.id('site:tech');
insert into tests.ids select 'lead:2', lead_id from enquiries where id = tests.id('enq:2');
select tests.check('8. the Tech enquiry resolves to the SAME client and the SAME person - nothing new was created',
  (select (client_id = tests.id('client:delta') and person_id = tests.id('person:dana'))::text from enquiries where id = tests.id('enq:2')) ||
  (select count(*)::text from clients where name_key = client_name_key('Delta Retail')) || (select count(*)::text from people where email = 'dana@deltaretail.example'), 'true11');
select tests.check('9. it is a separate lead in the other division (the Web lead is already converted)', (select (d.key = 'tech' and l.id <> tests.id('lead:1'))::text from leads l join divisions d on d.id = l.division_id where l.id = tests.id('lead:2')), 'true');
select tests.check('10. Tech cannot read the client before joining', tests.scalar('tech_lead', $q$ select count(*)::text from clients where name = 'Delta Retail' $q$), '0');
select tests.check('11. Tech qualifies: joins the existing client and reuses the existing contact',
  (tests.scalar('tech_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:2'))::text $q$)::jsonb ->> 'status') || (select count(*)::text from client_contacts where client_id = tests.id('client:delta')), 'qualified1');
select tests.remember('quote:2', tests.scalar('tech_lead', $q$ select quote_create_from_lead((select id from tests.ids where key = 'lead:2'))::text $q$));
select tests.scalar('tech_lead', $q$ select quote_add_line((select id from tests.ids where key = 'quote:2'), null, 1, 300, null, 'Site survey')::text $q$);
select tests.scalar('tech_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:2'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'quote:2'), 'approved')::text $q$);
select tests.scalar('tech_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:2'), 'sent')::text $q$);
select tests.scalar('tech_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:2'), 'accepted')::text $q$);
select tests.remember('prj:2', tests.scalar('tech_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:2'))::text $q$));

-- 4. History is true and the graph is one graph ------------------------------------------------------------------------------------------
select tests.check('12. the first quote still says N$5,000 although the catalogue is N$6,000 from tomorrow', (select (l.unit_price = 5000)::text from quote_lines l where l.quote_id = tests.id('quote:1') and l.service_id = tests.id('svc:web')), 'true');
select tests.check('12b. and so does the project built from it', (select unit_price::text from project_services where project_id = tests.id('prj:1')), '5000.00');
select tests.check('13. both projects, one client, the same contact', (select count(distinct client_id)::text from projects where id in (tests.id('prj:1'), tests.id('prj:2'))) ||
  (select count(distinct contact_id)::text from project_contacts where project_id in (tests.id('prj:1'), tests.id('prj:2'))), '11');
create temp table c360 as select tests.scalar('ceo', $q$ select client_360((select id from tests.ids where key = 'client:delta'))::text $q$)::jsonb j;
select tests.check('14. management''s client 360: 2 leads converted, 2 quotes accepted, 2 projects, both divisions',
  (select (jsonb_array_length(j -> 'leads') = 2 and (select count(*) from jsonb_array_elements(j -> 'leads') x where x ->> 'status' = 'converted') = 2
           and (j -> 'quote_summary' ->> 'accepted') = '2' and jsonb_array_length(j -> 'projects') = 2
           and (select string_agg(x ->> 'code', ',' order by x ->> 'code') from jsonb_array_elements(j -> 'relationship' -> 'divisions') x) = 'tech,web')::text from c360), 'true');
select tests.check('14b. accepted value = N$5,000 (website) + N$1,200 (CCTV, from the lead) + N$300 (survey)', (select (j -> 'quote_summary' ->> 'accepted_value') from c360), '6500.00');
create temp table c360w as select tests.scalar('web_lead', $q$ select client_360((select id from tests.ids where key = 'client:delta'))::text $q$)::jsonb j;
select tests.check('15. Web''s slice: its own lead, quote and project only', (select (jsonb_array_length(j -> 'leads') = 1 and jsonb_array_length(j -> 'quotes') = 1 and jsonb_array_length(j -> 'projects') = 1 and (j -> 'projects' -> 0 ->> 'division') = 'web')::text from c360w), 'true');
create temp table c360f as select tests.scalar('fin', $q$ select client_360((select id from tests.ids where key = 'client:delta'))::text $q$)::jsonb j;
select tests.check('16. Finance''s slice: all quotes and projects, but no sales leads', (select (jsonb_array_length(j -> 'quotes') = 2 and jsonb_array_length(j -> 'projects') = 2 and jsonb_array_length(j -> 'leads') = 0)::text from c360f), 'true');
select tests.check('17. a recruiter and an auditor cannot open it at all', tests.scalar('recruiter', $q$ select coalesce(client_360((select id from tests.ids where key = 'client:delta'))::text, 'null') $q$) || tests.scalar('audit', $q$ select coalesce(client_360((select id from tests.ids where key = 'client:delta'))::text, 'null') $q$), 'nullnull');
select tests.check('18. the person is one record seen through different relationships', (select count(*)::text from people where email = 'dana@deltaretail.example'), '1');

-- 5. The record of what happened ------------------------------------------------------------------------------------------------------------------
select tests.check('19. every step is announced as an event without personal data',
  (select string_agg(event_type, ',' order by event_type) from (select distinct event_type from events where event_type in ('enquiry.received', 'lead.created', 'lead.qualified', 'lead.converted', 'quote.accepted')) q),
  'enquiry.received,lead.converted,lead.created,lead.qualified,quote.accepted');
select tests.check('19b. none of them carries a name, email or phone', (select count(*)::text from events where payload::text ~* '(@|dana|delta|264811)'), '0');
select tests.check('20. the approvals queue shows both quotes as approved by the CEO, neither self-approved',
  (select count(*)::text from approval_requests where kind = 'quote' and status = 'approved' and not self_approved), '2');
select tests.check('21. qualification, quoting and conversion are in the audit trail', (select (count(*) filter (where table_name = 'leads') > 0 and count(*) filter (where table_name = 'quotes') > 0 and count(*) filter (where table_name = 'projects') > 0)::text from audit_log), 'true');
select tests.check('22. no snapshot or personal data leaked into the audit trail', (select count(*)::text from audit_log where table_name = 'enquiries' and new_data::text ~* '(dana@|deltaretail|delta retail)'), '0');
select tests.check('23. every record created along the way has an ADA ID in the registry', tests.unregistered_tables(), 'none');

select tests.finish();
rollback;
