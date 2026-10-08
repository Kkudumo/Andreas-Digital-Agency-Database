-- ONE client = ONE record; ONE person = ONE record; centralisation without unrestricted access.
begin;
select tests.setup();
select tests.setup_hr();

-- ABC Company first contacts ADA Tech: Tech creates the central client ----------------------------------------------
select tests.remember('client:abc', tests.scalar('tech_lead', $q$ insert into clients (name, legal_name, trading_name, industry, owner_division_id, registration_number)
  select 'ABC Company', 'ABC Company (Pty) Ltd', 'ABC', 'Retail', id, '2019/0042' from divisions where key = 'tech' returning id::text $q$));
select tests.check('the central client has one ADA ID', (select (ada_id ~ '^ADA-CLI-\d{4}-\d{4}$')::text from clients where id = tests.id('client:abc')), 'true');

-- ...later ADA Web wants to sell to the same company: it cannot create a second record ---------------------------------
select tests.check('Web cannot create a duplicate of ABC Company (exact)',
  left(tests.try_msg('web_lead', $q$ insert into clients (name, owner_division_id) select 'ABC Company', id from divisions where key = 'web' $q$), 6), '23505:');
select tests.check('...nor a near-duplicate that differs only by punctuation or legal suffix',
  tests.try('web_lead', $q$ insert into clients (name, owner_division_id) select 'A.B.C. Co Pty Ltd', id from divisions where key = 'web' $q$), 'ERR:23505');
select tests.check('...and the message points to the existing record and the right way to join it',
  (tests.try_msg('web_lead', $q$ insert into clients (name, owner_division_id) select 'abc company', id from divisions where key = 'web' $q$) ~ 'ADA-CLI-\d{4}-\d{4}.*claim_client_for_division')::text, 'true');
select tests.check('the same registration number cannot be registered twice',
  tests.try('web_lead', $q$ insert into clients (name, owner_division_id, registration_number) select 'Totally Different Name', id, '2019/0042' from divisions where key = 'web' $q$), 'ERR:23505');
select tests.check('before joining, Web cannot see the client', tests.scalar('web_lead', $q$ select count(*)::text from clients where name = 'ABC Company' $q$), '0');
select tests.check('Web can look it up safely by name',
  tests.scalar('web_lead', $q$ select (client_lookup('ABC Co.') -> 0 ->> 'client') $q$), (select ada_id from clients where id = tests.id('client:abc')));
select tests.check('the lookup tells Web it is shareable', tests.scalar('web_lead', $q$ select (client_lookup(p_registration => '2019/0042') -> 0 ->> 'shareable') $q$), 'true');
select tests.check('staff without clients.create cannot use the lookup', tests.scalar('web_staff', $q$ select client_lookup('ABC')::text $q$), 'ERR:42501');
select tests.check('staff without clients.create learn nothing from the duplicate check',
  tests.try_msg('web_staff', $q$ insert into clients (name) values ('ABC Company') $q$), '42501: new row violates row-level security policy for table "clients"');

-- joining the existing record, not creating another ---------------------------------------------------------------------
select tests.check('Web staff (no clients.create) cannot claim a client',
  tests.try('web_staff', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web')) $q$), 'ERR:42501');
select tests.check('Web lead cannot claim a client into another division',
  tests.try('web_lead', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:tech')) $q$), 'ERR:42501');
select tests.check('Web lead links Web to the existing client',
  tests.try('web_lead', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'div:web')) $q$), 'ok');
select tests.check('Web now sees the SAME record', tests.scalar('web_lead', $q$ select ada_id from clients where name = 'ABC Company' $q$), (select ada_id from clients where id = tests.id('client:abc')));
select tests.check('still exactly one ABC Company in ADA', (select count(*)::text from clients where name_key = 'abc'), '1');
select tests.check('the owning division was told Web started working with the client',
  (select count(*)::text from notifications n join staff s on s.id = n.recipient_staff_id where s.email = 'tech_lead@ada.test' and n.type = 'client.shared'), '1');
select tests.check('the client now has relationships with both divisions',
  (select string_agg(d.key, ',' order by d.key) from client_divisions cd join divisions d on d.id = cd.division_id where cd.client_id = tests.id('client:abc') and cd.relationship_status = 'active'), 'tech,web');
select tests.check('Web staff (not just the lead) now see the same record too', tests.scalar('web_staff', $q$ select count(*)::text from clients where name = 'ABC Company' $q$), '1');
select tests.check('a Finance officer sees it (clients.view org-wide) - one record, not a Finance copy', tests.scalar('fin', $q$ select count(*)::text from clients where name = 'ABC Company' $q$), '1');

-- restricted / confidential clients are never revealed, and cannot be claimed ------------------------------------------
select tests.check('a confidential client is not shareable by claim',
  tests.try('web_lead', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:C_conf'), (select id from tests.ids where key = 'div:web')) $q$), 'ERR:P0002');
select tests.check('a lookup of a confidential client reveals no ID or name',
  tests.scalar('web_lead', $q$ select (client_lookup('C_conf') -> 0)::text $q$), '{"match": "name", "shareable": false}');
select tests.check('creating a duplicate of a confidential client reveals nothing but its existence',
  tests.try_msg('web_lead', $q$ insert into clients (name, owner_division_id) select 'C_conf', id from divisions where key = 'web' $q$), '23505: a matching client already exists but is restricted; ask management to share it with your division');

-- Contacts: one person, referenced by relationship -------------------------------------------------------------------------
select tests.remember('contact:john', tests.scalar('tech_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'John Director', 'John@abc.example', '+264811000001', 'Director', true)::text $q$));
select tests.check('adding the same John from Web returns the SAME contact (no duplicate)',
  tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'Johnny D', 'john@ABC.example')::text $q$), tests.id('contact:john')::text);
select tests.check('one person record behind the contact', (select count(*)::text from people where lower(email) = 'john@abc.example'), '1');
select tests.check('the existing identity is not overwritten by a later entry', (select full_name from people where lower(email) = 'john@abc.example'), 'John Director');
select tests.check('contact has an ADA ID', (select (ada_id ~ '^ADA-CON-\d{4}-\d{4}$')::text from client_contacts where id = tests.id('contact:john')), 'true');
select tests.check('the same John can be a contact of a second client - still one person',
  tests.try('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:C_web'), 'John Director', 'john@abc.example', null, 'Consultant') $q$) ||
  (select count(*)::text from people where lower(email) = 'john@abc.example'), 'ok1');
select tests.check('...with two contact relationships', (select count(*)::text from client_contacts where person_id = (select id from people where lower(email) = 'john@abc.example')), '2');
select tests.check('a contact needs a valid email when one is given', tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:C_web'), 'Bad Mail', 'nope')::text $q$), 'ERR:22023');
select tests.check('a contact with no email is allowed', tests.try('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:C_web'), 'Phone Only', null, '+264811000009') $q$), 'ok');
select tests.check('web staff (cannot edit) cannot add contacts', tests.scalar('web_staff', $q$ select add_client_contact((select id from tests.ids where key = 'client:C_web'), 'Nope', 'nope@x.example')::text $q$), 'ERR:42501');
select tests.check('only one primary contact per client',
  tests.try('tech_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'Mary Finance', 'mary@abc.example', null, 'Finance', true, true) $q$) ||
  (select count(*)::text from client_contacts where client_id = tests.id('client:abc') and is_primary), 'ok1');
select tests.check('billing contact flagged', (select is_billing::text from client_contacts cc join people p on p.id = cc.person_id where cc.client_id = tests.id('client:abc') and p.email = 'mary@abc.example'), 'true');

-- Privacy: centralisation is not unrestricted access ----------------------------------------------------------------------------
insert into vacancies (position_id, title, description, requirements, status, published_at)
  select id, 'Web Developer', 'd', 'r', 'published', now() from positions where title = 'Web Developer';
select tests.check('John''s application attaches to the SAME person record',
  tests.try('recruiter', $q$ select staff_record_application((select id from vacancies where title = 'Web Developer'), 'John Director', 'john@abc.example') $q$) ||
  (select count(*)::text from people where lower(email) = 'john@abc.example'), 'ok1');
select tests.check('Tech (client team) sees John as a contact...', tests.scalar('tech_lead', $q$ select count(*)::text from people where lower(email) = 'john@abc.example' $q$), '1');
select tests.check('...but cannot see that he applied for a job', tests.scalar('tech_lead', 'select count(*)::text from applications'), '0');
select tests.check('...nor any interview notes or offers about him', tests.scalar('tech_lead', 'select count(*)::text from application_reviews') || tests.scalar('tech_lead', 'select count(*)::text from application_offers'), '00');
select tests.check('a person who is only an applicant stays invisible to client teams',
  (tests.try('recruiter', $q$ select staff_record_application((select id from vacancies where title = 'Web Developer'), 'Only Applicant', 'only@applicant.example') $q$)) ||
  tests.scalar('tech_lead', $q$ select count(*)::text from people where email = 'only@applicant.example' $q$), 'ok0');
select tests.check('the recruiter sees John as an applicant', tests.scalar('recruiter', $q$ select count(*)::text from people where lower(email) = 'john@abc.example' $q$), '1');
select tests.check('...but not his client-contact relationships', tests.scalar('recruiter', 'select count(*)::text from client_contacts'), '0');
select tests.check('a client contact is never on the public team page',
  (select count(*)::text from staff_profiles sp join staff s on s.id = sp.staff_id join people p on p.id = s.person_id where lower(p.email) = 'john@abc.example'), '0');

-- Editing a person is by relationship too -------------------------------------------------------------------------------------------
select tests.check('the client team may correct a contact''s phone number',
  tests.scalar('tech_lead', $q$ with u as (update people set phone = '+264811999999' where lower(email) = 'john@abc.example' returning 1) select count(*)::text from u $q$), '1');
select tests.check('...but cannot edit an applicant-only person',
  tests.scalar('tech_lead', $q$ with u as (update people set phone = '0' where email = 'only@applicant.example' returning 1) select count(*)::text from u $q$), '0');
select tests.check('web staff cannot edit contacts they do not manage',
  tests.scalar('web_staff', $q$ with u as (update people set phone = '0' returning 1) select count(*)::text from u $q$), '0');
select tests.check('email is the identity key and cannot be edited by users', tests.try('tech_lead', $q$ update people set email = 'hijack@x.example' where lower(email) = 'john@abc.example' $q$), 'ERR:42501');

-- Client profile & ownership ----------------------------------------------------------------------------------------------------------
select tests.check('the full client profile can be maintained',
  tests.scalar('tech_lead', $q$ with u as (update clients set billing_address = 'PO Box 1, Windhoek', city = 'Windhoek', website = 'https://abc.example',
      social_links = '{"facebook":"https://facebook.com/abc"}' where name = 'ABC Company' returning 1) select count(*)::text from u $q$), '1');
select tests.check('social links must be a JSON object', tests.try('tech_lead', $q$ update clients set social_links = '["x"]' where name = 'ABC Company' $q$), 'ERR:23514');
select tests.check('Web staff cannot appoint an owner', tests.try('web_staff', $q$ select set_client_owner((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'staff:web_staff')) $q$), 'ERR:42501');
select tests.check('the client team appoints an owner', tests.try('tech_lead', $q$ select set_client_owner((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'staff:tech_staff')) $q$), 'ok');
select tests.check('re-assigning keeps exactly one owner',
  tests.try('tech_lead', $q$ select set_client_owner((select id from tests.ids where key = 'client:abc'), (select id from tests.ids where key = 'staff:tech_lead')) $q$) ||
  (select count(*)::text from client_staff where client_id = tests.id('client:abc') and assignment_role = 'owner'), 'ok1');
select tests.check('an inactive staff member cannot own a client',
  tests.try('ceo', $q$ select set_client_owner((select id from tests.ids where key = 'client:abc'), (select id from staff where email = 'suspended@ada.test')) $q$), 'ERR:23514');

select tests.finish();
rollback;
