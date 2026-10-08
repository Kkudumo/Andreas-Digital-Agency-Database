-- ONE client = ONE record; ONE person = ONE record; centralisation without unrestricted access.
begin;
select tests.setup();
select tests.setup_hr();

-- ABC Company first contacts ADA Tech: Tech creates the central client ----------------------------------------------
select tests.remember('client:abc', tests.mkclient_id('tech_lead', 'ABC Company', 'tech', '2019/0042'));
select tests.try('tech_lead', $q$ update clients set legal_name = 'ABC Company (Pty) Ltd', trading_name = 'ABC', industry = 'Retail' where name = 'ABC Company' $q$);
select tests.check('the central client has one ADA ID', (select (ada_id ~ '^ADA-CLI-\d{4}-\d{4}$')::text from clients where id = tests.id('client:abc')), 'true');
select tests.check('clients can only be created through the controlled function', tests.try('tech_lead', $q$ insert into clients (name, owner_division_id) values ('Direct', gen_random_uuid()) $q$), 'ERR:42501');

-- ...later ADA Web wants to sell to the same company: it is pointed at the existing record, not given a new one ---------
select tests.check('Web cannot create a second ABC Company (exact name): it is told the record exists',
  (tests.mkclient('web_lead', 'ABC Company', 'web')::jsonb ->> 'status'), 'exists');
select tests.check('...nor one that differs only by punctuation and legal suffix',
  (tests.mkclient('web_lead', 'A.B.C. Co Pty Ltd', 'web')::jsonb ->> 'status'), 'exists');
select tests.check('...nor by capitalisation and whitespace', (tests.mkclient('web_lead', '  abc   COMPANY ', 'web')::jsonb ->> 'status'), 'exists');
select tests.check('...and the reply names the existing record and the right way to join it',
  (((tests.mkclient('web_lead', 'ABC Company', 'web')::jsonb ->> 'client') = (select ada_id from clients where id = tests.id('client:abc')))
   and ((tests.mkclient('web_lead', 'ABC Company', 'web')::jsonb ->> 'next') = 'claim_client_for_division'))::text, 'true');
select tests.check('the same name with a DIFFERENT registration number is a different legal entity: it is not merged, and the creator is asked for a distinguishing name',
  (tests.mkclient('web_lead', 'ABC Company', 'web', '2021/0999')::jsonb ->> 'status') || '/' || (select count(*)::text from clients where name_key = 'abc'), 'name_conflict/1');
select tests.check('...and once the name is distinguished it is created as its own client',
  (tests.mkclient('web_lead', 'ABC Company Walvis Bay', 'web', '2021/0999')::jsonb ->> 'status'), 'created');
select tests.check('the same registration number cannot be registered twice, whatever the name',
  (tests.mkclient('web_lead', 'Totally Different Name', 'web', '2019/0042')::jsonb ->> 'status'), 'exists');
select tests.check('nothing was created by any of that', (select count(*)::text from clients where name_key = 'abc'), '1');
select tests.check('before joining, Web cannot see the client', tests.scalar('web_lead', $q$ select count(*)::text from clients where name = 'ABC Company' $q$), '0');
select tests.check('Web can look it up safely by name',
  tests.scalar('web_lead', $q$ select (client_lookup('ABC Co.') -> 0 ->> 'client') $q$), (select ada_id from clients where id = tests.id('client:abc')));
select tests.check('...or by registration number', tests.scalar('web_lead', $q$ select (client_lookup(p_registration => '2019/0042') -> 0 ->> 'client') $q$), (select ada_id from clients where id = tests.id('client:abc')));
select tests.check('staff without clients.create cannot use the lookup', tests.scalar('web_staff', $q$ select client_lookup('ABC')::text $q$), 'ERR:42501');
select tests.check('staff without clients.create cannot create (and learn nothing about duplicates)', tests.mkclient('web_staff', 'ABC Company', 'web'), 'ERR:42501');

-- Genuinely different entities are not merged just because the names look alike -------------------------------------------------
select tests.remember('client:hw', tests.mkclient_id('tech_lead', 'Windhoek Hardware Supplies', 'tech'));
select tests.check('a SIMILAR but not identical name is flagged for a human decision, and nothing is created yet',
  (tests.mkclient('web_lead', 'Windhoek Hardware Supply', 'web')::jsonb ->> 'status') || '/' ||
  (select count(*)::text from clients where name_key like 'windhoekhardware%'), 'similar/1');
select tests.check('...the candidates are shown so the person can decide',
  (tests.mkclient('web_lead', 'Windhoek Hardware Supply', 'web')::jsonb -> 'candidates' -> 0 ->> 'name'), 'Windhoek Hardware Supplies');
select tests.check('with a stated reason it is created as a distinct legal entity',
  (tests.mkclient('web_lead', 'Windhoek Hardware Supply', 'web', null, 'Different company: sole proprietor in Swakopmund')::jsonb ->> 'status'), 'created');
select tests.check('...and the decision is recorded so it is not flagged again', (select count(*)::text from client_distinct_pairs), '1');
select tests.check('...visible only to people who review matches', tests.scalar('web_lead', 'select count(*)::text from client_distinct_pairs') || tests.scalar('admin', 'select count(*)::text from client_distinct_pairs'), '01');

-- joining the existing record, not creating another ---------------------------------------------------------------------------------
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

-- Restricted clients are indistinguishable from clients that do not exist -----------------------------------------------------------------
select tests.check('a lookup of a confidential client returns NOTHING (exactly what a non-existent name returns)',
  tests.scalar('web_lead', $q$ select client_lookup('C_conf')::text $q$) || tests.scalar('web_lead', $q$ select client_lookup('No Such Client Anywhere')::text $q$), '[][]');
select tests.check('claiming a confidential client fails exactly like claiming one that does not exist',
  tests.try_msg('web_lead', $q$ select claim_client_for_division((select id from tests.ids where key = 'client:C_conf'), (select id from tests.ids where key = 'div:web')) $q$),
  tests.try_msg('web_lead', $q$ select claim_client_for_division(gen_random_uuid(), (select id from tests.ids where key = 'div:web')) $q$));
select tests.check('creating a client whose name matches a confidential one simply succeeds, like any new name',
  (tests.mkclient('web_lead', 'C_conf', 'web')::jsonb ->> 'status'), 'created');
select tests.check('...the creator is told nothing: they see only their own new record', tests.scalar('web_lead', $q$ select count(*)::text from clients where name_key = 'cconf' $q$), '1');
select tests.check('...but management receives a review item about the possible duplicate',
  tests.scalar('admin', $q$ select count(*)::text from matching_reviews where status = 'open' $q$), '1');
select tests.check('...which the creator cannot see', tests.scalar('web_lead', 'select count(*)::text from matching_reviews') || tests.scalar('web_staff', 'select count(*)::text from matching_reviews'), '00');
select tests.check('...nor can a client lookup reveal either', tests.scalar('web_lead', $q$ select jsonb_array_length(client_lookup('C_conf'))::text $q$), '1');   -- only the creator's own, discoverable record
select tests.check('management resolves the review as two distinct entities', tests.try('admin', $q$ select matching_resolve((select id from matching_reviews where status = 'open'), 'distinct', 'Confirmed separate legal entities') $q$), 'ok');
select tests.check('a resolution needs a note and the right permission',
  tests.try('web_lead', $q$ select matching_resolve(gen_random_uuid(), 'distinct', 'x') $q$) || tests.try('admin', $q$ select matching_resolve(gen_random_uuid(), 'distinct', ' ') $q$), 'ERR:42501ERR:23514');

-- Contacts: one person, referenced by relationship -------------------------------------------------------------------------------------------
select tests.remember('contact:john', tests.scalar('tech_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'John Director', 'John@abc.example', '+264811000001', 'Director', true)::text $q$));
select tests.check('adding the same John from Web returns the SAME contact (no duplicate)',
  tests.scalar('web_lead', $q$ select add_client_contact((select id from tests.ids where key = 'client:abc'), 'Johnny D', 'john@ABC.example')::text $q$), tests.id('contact:john')::text);
select tests.check('one person record behind the contact', (select count(*)::text from people where lower(email) = 'john@abc.example'), '1');
select tests.check('the existing identity is not overwritten by a later entry', (select full_name from people where lower(email) = 'john@abc.example'), 'John Director');
select tests.check('contact has an ADA ID', (select (ada_id ~ '^ADA-CTC-\d{4}-\d{4}$')::text from client_contacts where id = tests.id('contact:john')), 'true');
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

-- Privacy: centralisation is not unrestricted access ----------------------------------------------------------------------------------------
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

-- Editing a person is by relationship too -----------------------------------------------------------------------------------------------------
select tests.check('the client team may correct a contact''s phone number',
  tests.scalar('tech_lead', $q$ with u as (update people set phone = '+264811999999' where lower(email) = 'john@abc.example' returning 1) select count(*)::text from u $q$), '1');
select tests.check('...but cannot edit an applicant-only person',
  tests.scalar('tech_lead', $q$ with u as (update people set phone = '0' where email = 'only@applicant.example' returning 1) select count(*)::text from u $q$), '0');
select tests.check('web staff cannot edit contacts they do not manage',
  tests.scalar('web_staff', $q$ with u as (update people set phone = '0' returning 1) select count(*)::text from u $q$), '0');
select tests.check('email is the identity key and cannot be edited by users', tests.try('tech_lead', $q$ update people set email = 'hijack@x.example' where lower(email) = 'john@abc.example' $q$), 'ERR:42501');

-- Client profile & ownership ------------------------------------------------------------------------------------------------------------------
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
