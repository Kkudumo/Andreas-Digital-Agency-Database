-- Leads and website enquiries: source tracking, person/client matching, ambiguity, privacy, no duplicate records.
begin;
select tests.setup();
select tests.setup_hr();

-- Published services (trusted setup) -----------------------------------------------------------------------------------------
insert into services (division_id, name, summary, description, status, published_at)
  select id, 'Website Development', 's', 'd', 'published', now() from divisions where key = 'web';
insert into services (division_id, name, summary, description, status, published_at)
  select id, 'CCTV Installation', 's', 'd', 'published', now() from divisions where key = 'tech';
insert into tests.ids select 'svc:web', id from services where name = 'Website Development';
insert into tests.ids select 'svc:cctv', id from services where name = 'CCTV Installation';

-- A. A brand-new organization enquires through ADA Main Website -----------------------------------------------------------------
select tests.check('A1. the website receives only a reference (nothing about what was or was not matched)',
  (select string_agg(k, ',') from jsonb_object_keys(tests.enq('main', 'Naomi Shikongo', 'naomi@newco.example', '+264811111111', 'NewCo Trading',
     (select ada_id from services where name = 'Website Development'), 'We need a website for our shop', '/services/web-development', 'https://www.google.com/',
     '{"utm_source":"google","utm_medium":"cpc","utm_campaign":"google_ads_2026"}')::jsonb) k), 'reference');
insert into tests.ids select 'enq:naomi', id from enquiries order by created_at desc limit 1;
select tests.check('A2. the enquiry has an ADA ID and records source website, page, referrer and campaign',
  (select (ada_id ~ '^ADA-ENQ-\d{4}-\d{4}$' and source_website_id = tests.id('site:main') and source_page = '/services/web-development'
           and referrer = 'https://www.google.com/' and utm_source = 'google' and utm_campaign = 'google_ads_2026')::text from enquiries where id = tests.id('enq:naomi')), 'true');
select tests.check('A3. it is routed to the division that owns the requested service', (select d.key from enquiries e join divisions d on d.id = e.division_id where e.id = tests.id('enq:naomi')), 'web');
select tests.check('A4. the sender''s words are kept as an explicit snapshot',
  (select (submitted_name = 'Naomi Shikongo' and submitted_email = 'naomi@newco.example' and submitted_organization = 'NewCo Trading')::text from enquiries where id = tests.id('enq:naomi')), 'true');
select tests.check('A5. a person record was created: identity lives there, not in the enquiry',
  (select (p.full_name = 'Naomi Shikongo' and p.id = e.person_id)::text from enquiries e join people p on p.id = e.person_id where e.id = tests.id('enq:naomi')), 'true');
select tests.check('A6. an unknown organization does NOT silently become a client', (select (client_id is null and status = 'processed')::text from enquiries where id = tests.id('enq:naomi')), 'true');
select tests.check('A7. a lead was opened in the same division, titled without personal data',
  (select (d.key = 'web' and l.status = 'new' and l.title = 'Enquiry about Website Development' and l.person_id = e.person_id and l.client_id is null)::text
   from enquiries e join leads l on l.id = e.lead_id join divisions d on d.id = l.division_id where e.id = tests.id('enq:naomi')), 'true');
select tests.check('A8. the lead has an ADA ID', (select (l.ada_id ~ '^ADA-LED-\d{4}-\d{4}$')::text from enquiries e join leads l on l.id = e.lead_id where e.id = tests.id('enq:naomi')), 'true');
insert into tests.ids select 'lead:naomi', lead_id from enquiries where id = tests.id('enq:naomi');
select tests.check('A9. the division''s lead and staff see it',
  tests.scalar('web_lead', 'select count(*)::text from enquiries') || tests.scalar('web_staff', 'select count(*)::text from enquiries') || tests.scalar('web_lead', 'select count(*)::text from leads'), '111');
select tests.check('A10. the intake desk (administration, org-wide) sees it too', tests.scalar('admin', 'select count(*)::text from enquiries'), '1');
select tests.check('A11. other divisions, finance, auditors, recruiters and outsiders do not',
  tests.scalar('tech_lead', 'select count(*)::text from enquiries') || tests.scalar('fin', 'select count(*)::text from enquiries') || tests.scalar('audit', 'select count(*)::text from leads')
  || tests.scalar('recruiter', 'select count(*)::text from enquiries') || tests.scalar('outsider', 'select count(*)::text from leads'), '00000');
select tests.check('A12. the Web lead is notified; Tech is not',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where n.type = 'lead.new' and s.email = 'web_lead@ada.test') || '/' ||
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where n.type = 'lead.new' and s.email = 'tech_lead@ada.test'), '1/0');
select tests.check('A13. events are published without any personal data',
  (select count(*)::text from events where event_type in ('enquiry.received', 'lead.created') and (payload::text ~* '(@|naomi|shikongo|newco|264)')), '0');
select tests.check('A14. the handler can read the person through the lead; other divisions cannot',
  tests.scalar('web_lead', $q$ select count(*)::text from people where email = 'naomi@newco.example' $q$) || tests.scalar('tech_lead', $q$ select count(*)::text from people where email = 'naomi@newco.example' $q$), '10');

-- B. The same person writes again: same person, same lead ----------------------------------------------------------------------------
select tests.enq('main', 'Naomi S.', 'NAOMI@newco.example', null, 'NewCo Trading', (select ada_id from services where name = 'Website Development'), 'Following up on my enquiry');
select tests.check('B1. still one person', (select count(*)::text from people where lower(email) = 'naomi@newco.example'), '1');
select tests.check('B2. the follow-up attaches to the same open lead', (select count(distinct lead_id)::text || '/' || count(*)::text from enquiries where person_id = (select person_id from enquiries where id = tests.id('enq:naomi'))), '1/2');
select tests.check('B3. the person''s stored name is not overwritten by a later submission', (select full_name from people where lower(email) = 'naomi@newco.example'), 'Naomi Shikongo');

-- C. Anonymous, minimal and invalid enquiries -------------------------------------------------------------------------------------------
select tests.check('C1. an enquiry with only a message is accepted', ((tests.enq('main', null, null, null, null, null, 'How much do you charge for hosting?')::jsonb ->> 'reference') ~ '^ADA-ENQ-')::text, 'true');
insert into tests.ids select 'enq:anon', id from enquiries where message like 'How much%';
select tests.check('C2. no person is invented for an anonymous prospect', (select (person_id is null and client_id is null and match_summary = 'anonymous prospect')::text from enquiries where id = tests.id('enq:anon')), 'true');
select tests.check('C3. with no service or division clue it goes to the organization-level intake (Management)', (select d.key from enquiries e join divisions d on d.id = e.division_id where e.id = tests.id('enq:anon')), 'management');
select tests.check('C4. Web does not see Management''s intake; administration does', tests.scalar('web_lead', $q$ select count(*)::text from enquiries where message like 'How much%' $q$) || tests.scalar('admin', $q$ select count(*)::text from enquiries where message like 'How much%' $q$), '01');
select tests.check('C5. no contact detail and no message is an error', tests.enq('main', 'Nobody', null, null, null, null, null), 'ERR:22023');
select tests.check('C6. a malformed email is an error', tests.enq('main', 'Bad', 'not-an-email', null, null, null, 'hello'), 'ERR:22023');
select tests.check('C7. an over-long message is refused', tests.enq('main', 'Long', 'long@x.example', null, null, null, repeat('x', 5001)), 'ERR:23514');
select tests.check('C8. a site without enquiries.submit is refused', tests.enq('limited', 'X', 'x@x.example', null, null, null, 'hi'), 'ERR:42501');
select tests.check('C9. a suspended site is refused', tests.enq('susp', 'X', 'x@x.example', null, null, null, 'hi'), 'ERR:42501');
select tests.enq('main', 'Y', 'y@x.example', null, null, 'ADA-SVC-1999-0001', 'hi');
select tests.check('C10. an unknown service reference is kept as text, never trusted as a link',
  (select (requested_service_id is null and requested_service_text = 'ADA-SVC-1999-0001')::text from enquiries where submitted_email = 'y@x.example'), 'true');

-- D. A client created in Web is recognised when the enquiry arrives through Tech -------------------------------------------------------
select tests.remember('client:abc', tests.mkclient_id('web_lead', 'ABC Company', 'web'));
select tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'John Director', 'john@abc.example', null, 'Director', true)::text $q$);
insert into tests.ids select 'person:john', id from people where email = 'john@abc.example';
select tests.enq('tech', 'John Director', 'john@abc.example', '+264811000001', 'ABC Company (Pty) Ltd', (select ada_id from services where name = 'CCTV Installation'),
                 'We need CCTV at our warehouse', '/contact', null, '{"utm_campaign":"tech_launch"}');
insert into tests.ids select 'enq:john', id from enquiries where submitted_email = 'john@abc.example' order by created_at desc limit 1;
select tests.check('D1. the enquiry came from the Tech website and is routed to Tech',
  (select (e.source_website_id = tests.id('site:tech') and d.key = 'tech' and sd.key = 'tech')::text from enquiries e join divisions d on d.id = e.division_id left join divisions sd on sd.id = e.source_division_id where e.id = tests.id('enq:john')), 'true');
select tests.check('D2. it resolves to the SAME client record that Web created', (select (client_id = tests.id('client:abc'))::text from enquiries where id = tests.id('enq:john')), 'true');
select tests.check('D3. and the SAME person', (select (person_id = tests.id('person:john'))::text from enquiries where id = tests.id('enq:john')), 'true');
select tests.check('D4. no second client or person was created', (select count(*)::text from clients where name_key = 'abc') || (select count(*)::text from people where lower(email) = 'john@abc.example'), '11');
select tests.check('D5. the Tech lead''s lead already points at the existing client',
  (select (l.client_id = tests.id('client:abc') and d.key = 'tech')::text from enquiries e join leads l on l.id = e.lead_id join divisions d on d.id = l.division_id where e.id = tests.id('enq:john')), 'true');
insert into tests.ids select 'lead:john', lead_id from enquiries where id = tests.id('enq:john');
select tests.check('D6. the match is explained', (select match_summary from enquiries where id = tests.id('enq:john')), 'person recorded; client matched');
select tests.check('D7. Tech cannot read the client yet - it is another division''s record', tests.scalar('tech_lead', $q$ select count(*)::text from clients where name = 'ABC Company' $q$), '0');
select tests.check('D8. qualifying joins Tech to the existing client and reuses the existing contact',
  (tests.scalar('tech_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:john'))::text $q$)::jsonb ->> 'status'), 'qualified');
select tests.check('D9. Tech now sees the same client', tests.scalar('tech_lead', $q$ select count(*)::text from clients where name = 'ABC Company' $q$), '1');
select tests.check('D10. John is still ONE contact of ABC (not duplicated for Tech)', (select count(*)::text from client_contacts where client_id = tests.id('client:abc')), '1');
select tests.check('D11. the lead references the shared contact', (select (contact_id = (select id from client_contacts where client_id = tests.id('client:abc')))::text from leads where id = tests.id('lead:john')), 'true');
select tests.check('D12. the client has relationships with both divisions', (select string_agg(d.key, ',' order by d.key) from client_divisions cd join divisions d on d.id = cd.division_id where cd.client_id = tests.id('client:abc')), 'tech,web');

-- E. Privacy: the same John, several relationships, no leakage between them --------------------------------------------------------------
insert into vacancies (position_id, title, description, requirements, status, published_at)
  select id, 'Web Developer', 'd', 'r', 'published', now() from positions where title = 'Web Developer';
select tests.check('E1. John applies for a job: the application attaches to the same person',
  tests.try('recruiter', $q$ select staff_record_application((select id from vacancies where title = 'Web Developer'), 'John Director', 'john@abc.example') $q$) ||
  (select count(*)::text from people where lower(email) = 'john@abc.example'), 'ok1');
select tests.check('E2. the lead handler sees John but cannot see that he applied for a job',
  tests.scalar('tech_lead', $q$ select count(*)::text from people where email = 'john@abc.example' $q$) || tests.scalar('tech_lead', 'select count(*)::text from applications'), '10');
select tests.check('E3. the recruiter sees no leads, enquiries or client contacts',
  tests.scalar('recruiter', 'select count(*)::text from leads') || tests.scalar('recruiter', 'select count(*)::text from enquiries') || tests.scalar('recruiter', 'select count(*)::text from client_contacts'), '000');
select tests.check('E4. the recruiter cannot reach an enquiry-linked person', tests.scalar('recruiter', $q$ select count(*)::text from people where email = 'naomi@newco.example' $q$), '0');
select tests.check('E5. recruiter records another applicant', tests.try('recruiter', $q$ select staff_record_application((select id from vacancies where title = 'Web Developer'), 'Only Applicant', 'only@applicant.example') $q$), 'ok');
select tests.check('E6. an applicant-only person is invisible to a lead handler in another division', tests.scalar('tech_lead', $q$ select count(*)::text from people where email = 'only@applicant.example' $q$), '0');
select tests.check('E7. finance sees client contacts (it can see the clients) but not enquirers, applicants or restricted contacts',
  tests.scalar('fin', $q$ select count(*)::text from people where email in ('naomi@newco.example', 'only@applicant.example', 'sam@secret.example', 'peter@anon.example') $q$), '0');
select tests.check('E8. administration (hr.view) sees staff people, not client contacts or prospects', tests.scalar('admin', $q$ select count(*)::text from people where email = 'john@abc.example' $q$), '1');

-- F. Ambiguity goes to a human ---------------------------------------------------------------------------------------------------------------
select tests.remember('client:beta', tests.mkclient_id('web_lead', 'Beta Logistics', 'web'));
select tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:beta'), 'John Director', 'john@abc.example', null, 'Advisor')::text $q$);
select tests.enq('main', 'John Director', 'john@abc.example', null, null, null, 'Can you call me about our website?');
insert into tests.ids select 'enq:amb', id from enquiries where message like 'Can you call me%';
select tests.check('F1. a person who is a contact at TWO clients and names no organization is NOT auto-linked', (select (client_id is null and status = 'needs_review')::text from enquiries where id = tests.id('enq:amb')), 'true');
select tests.check('F2. both possibilities are offered to the handler', (select count(*)::text from enquiry_candidates where enquiry_id = tests.id('enq:amb') and not hidden), '2');
select tests.enq('main', 'Sara Beta', 'sara@beta.example', null, 'Beta Logistic', null, 'Quote please');
insert into tests.ids select 'enq:sim', id from enquiries where submitted_email = 'sara@beta.example';
select tests.check('F3. a SIMILAR (not identical) organization name is flagged for review, never merged',
  (select (e.client_id is null and e.status = 'needs_review' and (select count(*) from enquiry_candidates where enquiry_id = e.id and reason = 'similar_name') = 1)::text from enquiries e where e.id = tests.id('enq:sim')), 'true');
select tests.check('F4. a handler outside the division cannot resolve it', tests.try('web_lead', $q$ select enquiry_resolve_candidate((select id from tests.ids where key = 'enq:amb'), (select id from tests.ids where key = 'client:abc'), 'link') $q$), 'ERR:P0002');
select tests.check('F5. a candidate that is not on the list cannot be linked', tests.try('admin', $q$ select enquiry_resolve_candidate((select id from tests.ids where key = 'enq:amb'), gen_random_uuid(), 'link') $q$), 'ERR:P0002');
select tests.check('F6. the intake desk links the right client', tests.try('admin', $q$ select enquiry_resolve_candidate((select id from tests.ids where key = 'enq:amb'), (select id from tests.ids where key = 'client:abc'), 'link') $q$), 'ok');
select tests.check('F7. the enquiry and its lead now reference the chosen client; the other candidate is rejected',
  (select (e.client_id = tests.id('client:abc') and e.status = 'processed' and l.client_id = tests.id('client:abc')
           and (select decision from enquiry_candidates where enquiry_id = e.id and client_id = tests.id('client:beta')) = 'rejected')::text from enquiries e join leads l on l.id = e.lead_id where e.id = tests.id('enq:amb')), 'true');
select tests.check('F8. "none of these" lets a similar-name enquiry proceed as a new organization', tests.try('admin', $q$ select enquiry_resolve_candidate((select id from tests.ids where key = 'enq:sim'), null, 'none') $q$), 'ok');
select tests.check('F9. ...without having linked anything', (select (client_id is null and status = 'processed')::text from enquiries where id = tests.id('enq:sim')), 'true');

-- G. Restricted clients are invisible to the people handling enquiries ----------------------------------------------------------------------
insert into clients (name, classification) values ('Secret Holdings', 'confidential');
insert into people (full_name, email) values ('Sam Secret', 'sam@secret.example');
insert into client_contacts (client_id, person_id) select c.id, p.id from clients c, people p where c.name = 'Secret Holdings' and p.email = 'sam@secret.example';
insert into tests.ids select 'client:secret', id from clients where name = 'Secret Holdings';
select tests.enq('main', 'Sam S', 'sam@secret.example', null, 'Secret Holdings', (select ada_id from services where name = 'Website Development'), 'Interested in a site');
select tests.enq('main', 'Una Known', 'una@unknown.example', null, 'Unknown Org Ltd', (select ada_id from services where name = 'Website Development'), 'Interested in a site');
insert into tests.ids select 'enq:secret', id from enquiries where submitted_email = 'sam@secret.example';
insert into tests.ids select 'enq:unknown', id from enquiries where submitted_email = 'una@unknown.example';
select tests.check('G1. an enquiry matching a restricted client looks IDENTICAL to one matching nothing (what the handler can read)',
  (select string_agg(x, '|' order by x) from (
     select (status::text || ':' || (client_id is null)::text || ':' || match_summary) as x from enquiries where id in (tests.id('enq:secret'), tests.id('enq:unknown'))) q),
  'processed:true:person recorded|processed:true:person recorded');
select tests.check('G2. the handler sees no candidates for either', tests.scalar('web_lead', 'select count(*)::text from enquiry_candidates'), '0');
select tests.check('G3. what the handler reads about the two enquiries has the same shape',
  tests.scalar('web_lead', $q$ select string_agg(status::text || ':' || (client_id is null)::text, ',') from enquiries where id in (select id from tests.ids where key in ('enq:secret', 'enq:unknown')) $q$), 'processed:true,processed:true');
select tests.check('G4. management (matching.review) can see the hidden candidate; the handler cannot',
  tests.scalar('admin', $q$ select count(*)::text from enquiry_candidates where enquiry_id = (select id from tests.ids where key = 'enq:secret') and hidden $q$) ||
  tests.scalar('web_lead', $q$ select count(*)::text from enquiry_candidates where enquiry_id = (select id from tests.ids where key = 'enq:secret') $q$), '10');
select tests.check('G5. linking a restricted client fails EXACTLY like linking one that does not exist',
  tests.try_msg('web_lead', $q$ select enquiry_resolve_candidate((select id from tests.ids where key = 'enq:secret'), (select id from tests.ids where key = 'client:secret'), 'link') $q$),
  tests.try_msg('web_lead', $q$ select enquiry_resolve_candidate((select id from tests.ids where key = 'enq:secret'), gen_random_uuid(), 'link') $q$));
insert into tests.ids select 'lead:secret', lead_id from enquiries where id = tests.id('enq:secret');
select tests.check('G6. qualifying against a restricted client fails EXACTLY like qualifying against one that does not exist',
  tests.try_msg('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:secret'), (select id from tests.ids where key = 'client:secret')) $q$),
  tests.try_msg('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:secret'), gen_random_uuid()) $q$));
select tests.check('G7. naming a new client that collides with a restricted one simply works, like any new name',
  (tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:secret'), null, 'Secret Holdings')::text $q$)::jsonb ->> 'status'), 'qualified');
select tests.check('G8. ...management is told about the possible duplicate; the handler is not', tests.scalar('admin', $q$ select count(*)::text from matching_reviews where status = 'open' $q$) || tests.scalar('web_lead', 'select count(*)::text from matching_reviews'), '10');
select tests.check('G9. ...and the handler sees only their own new client under that name', tests.scalar('web_lead', $q$ select count(*)::text from clients where name_key = 'secretholdings' $q$), '1');

-- H. Lead commands and permissions ---------------------------------------------------------------------------------------------------------------
select tests.check('H1. lead staff (leads.update) can mark a lead contacted', tests.scalar('web_staff', $q$ select lead_transition((select id from tests.ids where key = 'lead:naomi'), 'contacted')::text $q$), 'contacted');
select tests.check('H2. ...but cannot qualify it (that creates/links clients, which needs clients.create)',
  tests.scalar('web_staff', $q$ select lead_qualify((select id from tests.ids where key = 'lead:naomi'), null, 'NewCo Trading')::text $q$), 'ERR:42501');
select tests.check('H3. conversion is not a manual transition', tests.scalar('web_lead', $q$ select lead_transition((select id from tests.ids where key = 'lead:naomi'), 'converted')::text $q$), 'ERR:23514');
select tests.enq('main', null, null, null, null, (select ada_id from services where name = 'Website Development'), 'Anonymous question about websites');
insert into tests.ids select 'lead:anon', lead_id from enquiries where message like 'Anonymous question%';
select tests.check('H4. losing a lead needs a reason', tests.scalar('web_lead', $q$ select lead_transition((select id from tests.ids where key = 'lead:anon'), 'lost')::text $q$), 'ERR:23514');
select tests.check('H5. an anonymous lead cannot be qualified until the prospect''s details are attached',
  tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:anon'), null, 'Anon Trading')::text $q$), 'ERR:23514');
select tests.check('H6. a human attaches the prospect', tests.scalar('web_lead', $q$ select (lead_set_person((select id from tests.ids where key = 'lead:anon'), 'Peter Anon', 'peter@anon.example', '+264811222333') is not null)::text $q$), 'true');
select tests.check('H6b. a person was found-or-created exactly once and the enquiry now points at it', (select count(*)::text from people where email = 'peter@anon.example') || (select (person_id is not null)::text from enquiries where message like 'Anonymous question%'), '1true');
select tests.check('H7. a similar-but-different client name is refused with the candidates named, not silently merged or created',
  tests.try_msg('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:anon'), null, 'Beta Logistic') $q$), '23514: similar clients exist (Beta Logistics); link one of them or give p_distinct_reason');
select tests.check('H8. with a stated reason it is qualified as a distinct legal entity',
  (tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:anon'), null, 'Beta Logistic', 'company', 'Different company in Walvis Bay')::text $q$)::jsonb ->> 'status'), 'qualified');
select tests.enq('main', 'Quinn Exact', 'quinn@exact.example', null, null, (select ada_id from services where name = 'Website Development'), 'Another website question');
insert into tests.ids select 'lead:quinn', lead_id from enquiries where submitted_email = 'quinn@exact.example';
select tests.check('H9. naming an organization that already exists links the existing client instead of creating a duplicate',
  (tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:quinn'), null, 'beta   LOGISTICS')::text $q$)::jsonb ->> 'status') ||
  (select count(*)::text from clients where name_key = 'betalogistics'), 'qualified1');
select tests.check('H10. assigning needs an active staff member', tests.scalar('web_lead', $q$ select lead_assign((select id from tests.ids where key = 'lead:naomi'), (select id from staff where email = 'suspended@ada.test'))::text $q$), 'ERR:23514');
select tests.check('H11. a lead can be assigned', tests.try('web_lead', $q$ select lead_assign((select id from tests.ids where key = 'lead:naomi'), (select id from tests.ids where key = 'staff:web_staff')) $q$), 'ok');
select tests.check('H11b. assigning notifies the assignee', (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where n.type = 'lead.assigned' and s.email = 'web_staff@ada.test'), '1');
select tests.check('H12. lead status cannot be edited directly', tests.try('web_lead', $q$ update leads set status = 'converted' $q$), 'ERR:42501');
select tests.check('H13. follow-up dates can be edited by the division, not by other divisions',
  tests.scalar('web_lead', $q$ with u as (update leads set follow_up_on = current_date + 3 where id = (select id from tests.ids where key = 'lead:naomi') returning 1) select count(*)::text from u $q$) ||
  tests.scalar('tech_lead', $q$ with u as (update leads set follow_up_on = current_date + 3 where id = (select id from tests.ids where key = 'lead:naomi') returning 1) select count(*)::text from u $q$), '10');
select tests.check('H14. staff record a phone enquiry by hand', ((select tests.scalar('admin', $q$ select enquiry_record((select id from tests.ids where key = 'div:web'), 'phone', 'Pat Caller', 'pat@caller.example', '+264811555000', null, (select id from tests.ids where key = 'svc:web'), 'Called about a website') $q$)) ~ '^ADA-ENQ-')::text, 'true');
select tests.check('H15. ...with no source website, the right channel and the person recorded', (select (channel = 'phone' and source_website_id is null and person_id is not null and created_by is not null)::text from enquiries where submitted_email = 'pat@caller.example'), 'true');
select tests.check('H16. staff without leads.create cannot record enquiries', tests.scalar('web_staff', $q$ select enquiry_record((select id from tests.ids where key = 'div:web'), 'phone', 'X', 'x2@x.example', null, null, null, 'hi') $q$), 'ERR:42501');
select tests.check('H17. a "website" enquiry cannot be entered by hand', tests.scalar('admin', $q$ select enquiry_record((select id from tests.ids where key = 'div:web'), 'website', 'X', 'x3@x.example', null, null, null, 'hi') $q$), 'ERR:22023');

-- I. Enquiry -> lead -> client -> quote -> project: references all the way ------------------------------------------------------------------
select tests.remember('p:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'launch')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web'), true)).status::text $q$);
select tests.check('I1. an unqualified lead cannot be quoted', tests.scalar('web_lead', $q$ select quote_create_from_lead((select id from tests.ids where key = 'lead:naomi'))::text $q$), 'ERR:23514');
select tests.check('I2. Web qualifies Naomi''s lead against a NEW client (no match existed)',
  (tests.scalar('web_lead', $q$ select lead_qualify((select id from tests.ids where key = 'lead:naomi'), null, 'NewCo Trading')::text $q$)::jsonb ->> 'status'), 'qualified');
insert into tests.ids select 'client:newco', client_id from leads where id = tests.id('lead:naomi');
select tests.check('I3. the client has exactly one record, Naomi is its contact (the same person), and both enquiries now point at the client',
  (select count(*)::text from clients where name_key = 'newcotrading') || (select count(*)::text from client_contacts cc join people p on p.id = cc.person_id where cc.client_id = tests.id('client:newco') and p.email = 'naomi@newco.example')
  || (select count(*)::text from enquiries where lead_id = tests.id('lead:naomi') and client_id = tests.id('client:newco')), '112');
select tests.remember('quote:naomi', tests.scalar('web_lead', $q$ select quote_create_from_lead((select id from tests.ids where key = 'lead:naomi'))::text $q$));
select tests.check('I4. the quote references the lead''s own client, contact and lead - nothing is re-typed',
  (select (client_id = tests.id('client:newco') and lead_id = tests.id('lead:naomi') and contact_id = (select contact_id from leads where id = tests.id('lead:naomi')) and division_id = tests.id('div:web'))::text from quotes where id = tests.id('quote:naomi')), 'true');
select tests.check('I5. the requested service was added at the catalogue price in force', (select total::text from quotes where id = tests.id('quote:naomi')), '5000.00');
select tests.check('I6. a quote cannot name a lead of a different client',
  tests.try('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web'), 'Wrong', null, null, null, null, null, (select id from tests.ids where key = 'lead:naomi')) $q$), 'ERR:23514');
select tests.check('I7. the lead link cannot be edited by users', tests.try('web_lead', $q$ update quotes set lead_id = null $q$), 'ERR:42501');
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:naomi'), 'pending_approval')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'quote:naomi'), 'approved')::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:naomi'), 'sent')::text $q$);
select tests.check('I8. the client accepts', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'quote:naomi'), 'accepted')::text $q$), 'accepted');
select tests.check('I8b. ...and the lead is converted automatically', (select status::text from leads where id = tests.id('lead:naomi')), 'converted');
select tests.check('I9. conversion is announced without personal data', (select count(*)::text from events where event_type = 'lead.converted' and payload::text !~ '@'), '1');
select tests.remember('prj:newco', tests.scalar('web_lead', $q$ select quote_convert_to_project((select id from tests.ids where key = 'quote:naomi'))::text $q$));
select tests.check('I10. the project references the same client and contact',
  (select (p.client_id = tests.id('client:newco') and exists (select 1 from project_contacts pc where pc.project_id = p.id and pc.contact_id = (select contact_id from leads where id = tests.id('lead:naomi'))))::text from projects p where p.id = tests.id('prj:newco')), 'true');
create temp table c360 as select tests.scalar('ceo', $q$ select client_360((select id from tests.ids where key = 'client:newco'))::text $q$)::jsonb j;
select tests.check('I11. the client 360 shows the whole chain: lead (converted, with its two enquiries), quote, project',
  (select (j -> 'leads' -> 0 ->> 'status' = 'converted' and (j -> 'leads' -> 0 ->> 'enquiries') = '2' and jsonb_array_length(j -> 'quotes') = 1 and jsonb_array_length(j -> 'projects') = 1)::text from c360), 'true');
select tests.check('I12. Tech cannot open that client''s 360', tests.scalar('tech_lead', $q$ select coalesce(client_360((select id from tests.ids where key = 'client:newco'))::text, 'null') $q$), 'null');
select tests.check('I13. the project 360 points back to the lead through the quote', tests.scalar('web_lead', $q$ select project_360((select id from tests.ids where key = 'prj:newco')) -> 'quotes' -> 0 ->> 'lead' $q$), (select ada_id from leads where id = tests.id('lead:naomi')));

-- J. Nothing was duplicated anywhere, and personal data stays out of the audit trail ----------------------------------------------------------
select tests.check('J1. no two discoverable clients share a normalised name', (select count(*)::text from (select name_key from clients where deleted_at is null and classification in ('public', 'internal') group by 1 having count(*) > 1) x), '0');
select tests.check('J2. no two people share an email', (select count(*)::text from (select lower(email) from people where email is not null group by 1 having count(*) > 1) x), '0');
select tests.check('J3. snapshot columns never reach the audit trail', (select count(*)::text from audit_log where table_name = 'enquiries' and (new_data::text ~* '(naomi@|newco|shikongo|264811)')), '0');
select tests.check('J4. every lead, enquiry and person is in the central registry', tests.unregistered_tables(), 'none');
select tests.check('J5. lead and enquiry changes are audited', (select (count(*) > 0)::text from audit_log where table_name in ('leads', 'enquiries') and action in ('INSERT', 'UPDATE')), 'true');

select tests.finish();
rollback;
