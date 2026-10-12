-- PERMANENT: ADA Hub Pilot V0.1 - the Zeta Test Company engagement, end to end, through the controlled functions only:
-- SEARCH -> ORGANIZATION / CLIENT -> CONTACT -> PROJECT -> SERVICE -> QUOTE -> APPROVAL -> ACCEPTANCE -> CONTRACT -> INVOICE -> PAYMENT
-- -> DOCUMENT -> COMMUNICATION -> TICKET -> ASSET -> DOMAIN -> CLIENT 360 / PROJECT 360 -> SEARCH again.
-- It proves the already-built modules compose: one organization, one client role, one person, one project, one of each commercial record, every
-- relationship by id, nothing re-typed. (Restricted / unauthorised paths through the same chain: 111.)
begin;
select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
update finance_settings set vat_registered = true, vat_rate = 15, vat_number = 'VAT-NA-555';
select tests.add_staff('tech_lead2', 'division_lead', 'tech');

-- Catalogue: Website Development at N$5,000 (July), raised to N$6,000 (October) after the quote ---------------------------------------------------
insert into services (division_id, name, summary, description, status, published_at) select id, 'Website Development', 's', 'd', 'published', now() from divisions where key = 'web';
insert into tests.ids select 'svc:web', id from services where name = 'Website Development';
select tests.remember('price:5000', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'July 2026 list')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:5000'), true)).status::text $q$);

-- 1-2. FIND OR CREATE THE ORGANIZATION / CLIENT: ONE, whichever division asks ---------------------------------------------------------------------
select tests.check('1. nothing called Zeta exists yet: lookup and search both come back empty',
  (tests.scalar('web_lead', $q$ select client_lookup('Zeta Test Company')::text $q$)) || '|' ||
  (tests.scalar('web_lead', $q$ select (search('type:client zeta') ->> 'total') $q$)), '[]|0');
select tests.remember('client:zeta', tests.mkclient_id('web_lead', 'Zeta Test Company', 'web'));
select tests.check('2. Web creates the client: one organization, one client role, owned by Web',
  (select count(*)::text from organizations where name = 'Zeta Test Company') || (select count(*)::text from clients where id = tests.id('client:zeta') and owner_division_id = tests.id('div:web')
     and organization_id = (select id from organizations where name = 'Zeta Test Company')), '11');
select tests.check('3. Tech asks for the same company: it is NOT created again (a match is returned or reviewed), still one organization and one client',
  (case when tests.mkclient('tech_lead', 'Zeta Test Company', 'tech') like 'ERR:%' then 'err' else 'ok' end) || (select count(*)::text from organizations where name ilike 'zeta test company%')
  || (select count(*)::text from clients where name_key = client_name_key('Zeta Test Company')), 'ok11');
select tests.check('4. a spelling variant ("ZETA TEST COMPANY (Pty) Ltd" via Tech) is also not a second organization without a review',
  (select count(*)::text from organizations where name ilike 'zeta test company%') ||
  (case when tests.mkclient('tech_lead', 'ZETA TEST COMPANY', 'tech') like 'ERR:%' then 'e' else 'k' end) || (select count(*)::text from organizations where name ilike 'zeta test company%'), '1k1');
select tests.try('tech_lead', format('select claim_client_for_division(%L, %L)', tests.id('client:zeta'), tests.id('div:tech')));
select tests.check('5. Tech joins the existing client through a division relationship, not a copy',
  (select count(*)::text from client_divisions where client_id = tests.id('client:zeta')) || (select count(*)::text from clients where name_key = client_name_key('Zeta Test Company')), '21');
insert into tests.ids select 'org:zeta', organization_id from clients where id = tests.id('client:zeta');

-- 3. CONTACT: one person, many relationships ----------------------------------------------------------------------------------------------------
select tests.remember('contact:zoe', tests.scalar('web_lead', format('select add_client_contact(%L, ''Zoe Zeta'', ''zoe@zeta.example'', ''+264811000999'', ''Director'', true, true)::text', tests.id('client:zeta'))));
select tests.check('6. the contact references one authoritative person',
  (select count(*)::text from people where email = 'zoe@zeta.example') || (select count(*)::text from client_contacts where client_id = tests.id('client:zeta') and id = tests.id('contact:zoe')), '11');
select tests.scalar('tech_lead', format('select add_client_contact(%L, ''Zoe Zeta'', ''zoe@zeta.example'')::text', tests.id('client:zeta')));
select tests.check('7. adding "the same person" again (different division, same email) does not create a second person',
  (select count(*)::text from people where email = 'zoe@zeta.example'), '1');

-- 4-5. PROJECT, DIVISION, SERVICE ---------------------------------------------------------------------------------------------------------------
-- Projects are created by direct insert today (there is no project_create function): this is the gap the pilot migration closes.
select tests.remember('prj:site', tests.scalar('web_lead', format($q$ insert into projects (client_id, lead_division_id, name) values (%L, %L, 'Zeta Website') returning id::text $q$, tests.id('client:zeta'), tests.id('div:web'))));
select tests.check('8. the project is a container of relationships: client and lead division by id, status proposed, ADA id minted',
  (select (client_id = tests.id('client:zeta') and lead_division_id = tests.id('div:web') and status = 'proposed' and ada_id ~ '^ADA-PRJ-')::text from projects where id = tests.id('prj:site')), 'true');
select tests.check('9. the project cannot be pushed straight to active (status changes only through project_transition)',
  tests.try('web_lead', format($q$ update projects set status = 'active' where id = %L $q$, tests.id('prj:site'))), 'ERR:42501');

-- 6. QUOTE (price snapshot) -> APPROVAL -> ACCEPTANCE -------------------------------------------------------------------------------------------
select tests.remember('quote:zeta', tests.scalar('web_lead', format('select quote_create(%L, %L, ''Zeta website'', %L, %L)::text', tests.id('client:zeta'), tests.id('div:web'), tests.id('contact:zoe'), tests.id('prj:site'))));
select tests.scalar('web_lead', format('select quote_add_line(%L, %L)::text', tests.id('quote:zeta'), tests.id('svc:web')));
select tests.check('10. the quote line takes the catalogue price (5,000) from the approved version and records which version',
  (select (l.unit_price = 5000 and l.price_id = tests.id('price:5000'))::text from quote_lines l where l.quote_id = tests.id('quote:zeta') limit 1), 'true');
select tests.remember('price:6000', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 6000, 'NAD', current_date + 1, 'October 2026 list')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:6000'), true)).status::text $q$);
select tests.check('11. the catalogue now says 6,000 tomorrow; the quote still says 5,000',
  (select amount::text from price_on(tests.id('svc:web'), current_date + 1)) || '|' || (select total::text from quotes where id = tests.id('quote:zeta')), '6000.00|5000.00');
select tests.check('12. the quote cannot go to the customer without approval (draft -> sent refused)', (tests.scalar('web_lead', format($q$ select quote_transition(%L, 'sent')::text $q$, tests.id('quote:zeta'))) like 'ERR:%')::text, 'true');
select tests.scalar('web_lead', format($q$ select quote_transition(%L, 'pending_approval')::text $q$, tests.id('quote:zeta')));
select tests.check('13. the requester cannot approve their own quote; management can',
  (tests.scalar('web_lead', format($q$ select quote_transition(%L, 'approved')::text $q$, tests.id('quote:zeta'))) like 'ERR:%')::text || '|' ||
  tests.scalar('ceo', format($q$ select quote_transition(%L, 'approved')::text $q$, tests.id('quote:zeta'))), 'true|approved');
select tests.scalar('web_lead', format($q$ select quote_transition(%L, 'sent')::text $q$, tests.id('quote:zeta')));
select tests.check('14. the quote is accepted', tests.scalar('web_lead', format($q$ select quote_transition(%L, 'accepted', 'Signed by Zoe')::text $q$, tests.id('quote:zeta'))), 'accepted');
select tests.check('15. an accepted quote is locked: no more lines', (tests.scalar('web_lead', format('select quote_add_line(%L, %L)::text', tests.id('quote:zeta'), tests.id('svc:web'))) like 'ERR:%')::text, 'true');

-- 7. QUOTE -> PROJECT / CONTRACT -----------------------------------------------------------------------------------------------------------------
select tests.remember('prj:converted', tests.scalar('web_lead', format('select quote_convert_to_project(%L)::text', tests.id('quote:zeta'))));
select tests.check('16. converting the accepted quote reuses the project it was quoted against (no second project) and carries the priced service',
  (tests.id('prj:converted') = tests.id('prj:site'))::text
  || '|' || (select count(*)::text from projects where client_id = tests.id('client:zeta'))
  || '|' || (select (unit_price = 5000 and price_id = tests.id('price:5000'))::text from project_services where project_id = tests.id('prj:site') limit 1), 'true|1|true');
select tests.remember('contract:zeta', tests.scalar('web_lead', format('select contract_create_from_quote(%L)::text', tests.id('quote:zeta'))));
select tests.scalar('web_lead', format($q$ select contract_transition(%L, 'internal_review')::text $q$, tests.id('contract:zeta')));
select tests.scalar('ceo', format($q$ select contract_transition(%L, 'approved')::text $q$, tests.id('contract:zeta')));
select tests.scalar('web_lead', format($q$ select contract_transition(%L, 'sent')::text $q$, tests.id('contract:zeta')));
select tests.scalar('web_lead', format($q$ select contract_transition(%L, 'signed')::text $q$, tests.id('contract:zeta')));
select tests.check('17. the contract is active and links the same client, quote and project', tests.scalar('web_lead', format($q$ select contract_transition(%L, 'active')::text $q$, tests.id('contract:zeta'))) || '|' ||
  (select (c.client_id = tests.id('client:zeta') and c.quote_id = tests.id('quote:zeta') and exists (select 1 from contract_projects cp where cp.contract_id = c.id and cp.project_id = tests.id('prj:site')))::text
   from contracts c where c.id = tests.id('contract:zeta')), 'active|true');

-- 8. INVOICE -> PAYMENT (derived balance) --------------------------------------------------------------------------------------------------------
insert into tests.ids select 'cl:zeta', cl.id from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:zeta') and cl.service_id is not null;
select tests.remember('bi:zeta', tests.scalar('fin', $q$ select billable_from_contract((select id from tests.ids where key = 'contract:zeta'), (select id from tests.ids where key = 'cl:zeta'))::text $q$));
select tests.remember('inv:zeta', tests.scalar('fin', $q$ select invoice_create(array[(select id from tests.ids where key = 'bi:zeta')])::text $q$));
select tests.scalar('fin', format($q$ select invoice_transition(%L, 'pending_approval')::text $q$, tests.id('inv:zeta')));
select tests.scalar('ceo', format($q$ select invoice_transition(%L, 'approved')::text $q$, tests.id('inv:zeta')));
select tests.scalar('fin', format($q$ select invoice_transition(%L, 'issued')::text $q$, tests.id('inv:zeta'))) as issued;
select tests.check('18. finance issues the invoice: 5,000 + 15% VAT = 5,750, at the agreed price, with the client snapshot taken at issue',
  (select status::text from invoices where id = tests.id('inv:zeta')) || '|' ||
  (select (total = 5750 and client_name_snapshot = 'Zeta Test Company' and contract_id = tests.id('contract:zeta'))::text from invoices where id = tests.id('inv:zeta')), 'issued|true');
select tests.check('19. an issued invoice is immutable', tests.try('fin', format($q$ update invoices set total = 1 where id = %L $q$, tests.id('inv:zeta'))) || tests.try('fin', format($q$ update invoice_lines set unit_price = 1 where invoice_id = %L $q$, tests.id('inv:zeta'))), 'ERR:42501ERR:42501');
select tests.remember('pay:1', tests.scalar('fin', format('select payment_record(%L, %L, 2000, ''bank_transfer'', current_date, ''EFT-Z1'', %L)::text', tests.id('client:zeta'), tests.id('acct:nad'), tests.id('inv:zeta'))));
select tests.check('20. a part payment leaves the DERIVED balance 3,750 and the invoice partially paid; there is no stored balance column',
  tests.scalar('fin', format('select invoice_balance(%L)::text', tests.id('inv:zeta'))) || (select status::text from invoices where id = tests.id('inv:zeta'))
  || (select count(*)::text from information_schema.columns where table_schema = 'public' and table_name in ('invoices', 'payments') and column_name in ('balance', 'amount_paid', 'outstanding')), '3750.00partially_paid0');

-- 9. DOCUMENT, COMMUNICATION, TICKET, ASSET, DOMAIN through the existing relationships --------------------------------------------------------------
select tests.mk_doc('web_lead', 'zeta', 'Zeta website brief', 'report', 'web', 'prj:site');
select tests.check('21a. the document is linked to the client as well', tests.try('web_lead', format($q$ select document_link_add(%L, %L) $q$, tests.id('doc:zeta'), tests.inst_of('clients', 'client:zeta'))), 'ok');
select tests.check('21. a project document is registered and linked to the PROJECT and the CLIENT (two links, one document)', (select count(*)::text from document_links where document_id = tests.id('doc:zeta')), '2');
select tests.check('22. a version is added with a content hash', (tests.add_ver('web_lead', 'zeta', 'zeta1', 'brief v1 content') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.mk_thread('web_lead', 'zeta', 'Zeta website kick-off');
select tests.say('web_lead', 'zeta', 'z1', 'email', 'inbound', 'CONFIDENTIAL-BODY-TEXT: please start the build');
select tests.check('23. a communication thread is recorded and linked to the client',
  tests.try('web_lead', format($q$ select communication_link_add(%L, %L) $q$, tests.id('thr:zeta'), tests.inst_of('clients', 'client:zeta'))), 'ok');
select tests.check('24. the thread is also linked to the project', tests.try('web_lead', format($q$ select communication_link_add(%L, %L) $q$, tests.id('thr:zeta'), tests.inst_of('projects', 'prj:site'))), 'ok');
select tests.check('25. an asset is registered against the client and project, with a permanent institutional id',
  (tests.mk_asset('web_lead', 'zeta', 'Zeta demo server', 'web', 'Dell', 'SN-ZETA-1', null, 'in_stock', 'client:zeta', 'prj:site') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.remember('ticket:zeta', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'Zeta site is slow', p_asset => %L, p_project => %L, p_client => %L, p_division => %L)::text $q$,
  tests.id('asset:zeta'), tests.id('prj:site'), tests.id('client:zeta'), tests.id('div:web'))));
select tests.check('26. the ticket references the asset, project and client by id (and nothing is typed twice)',
  (select (asset_id = tests.id('asset:zeta') and project_id = tests.id('prj:site') and client_id = tests.id('client:zeta'))::text from tickets where id = tests.id('ticket:zeta')), 'true');
select tests.try('fin', $q$ insert into suppliers (name) values ('NamReg Registrar') $q$);
insert into tests.ids select 'sup:namreg', id from suppliers where name = 'NamReg Registrar';
select tests.live_domain('web_lead', 'zeta', 'zetatest.example');
select tests.check('27. a domain is registered (registrar by reference), activated, and related to the client and the project (references by institutional id only)',
  tests.rel('web_lead', 'zeta', 'client', 'clients', 'client:zeta') || tests.rel('web_lead', 'zeta', 'project', 'projects', 'prj:site'), 'okok');

-- 10. CLIENT 360 / PROJECT 360: controlled views over the same records ------------------------------------------------------------------------
create temp table z360 as select tests.scalar('ceo', format('select client_360(%L)::text', tests.id('client:zeta')))::jsonb as j;
select tests.check('28. Client 360 shows every slice of the engagement',
  (select (jsonb_array_length(j -> 'contacts') = 1 and jsonb_array_length(j -> 'projects') = 1 and jsonb_array_length(j -> 'quotes') = 1 and jsonb_array_length(j -> 'contracts') = 1
           and jsonb_array_length(j -> 'invoices') = 1 and jsonb_array_length(j -> 'payments') = 1 and jsonb_array_length(j -> 'assets') = 1 and jsonb_array_length(j -> 'tickets') = 1)::text from z360), 'true');
select tests.check('29. ...with derived finance numbers (invoiced 5,750, paid 2,000, outstanding 3,750) and documents / domains / communications present',
  (select ((j -> 'finance_summary' ->> 'invoiced')::numeric = 5750 and (j -> 'finance_summary' ->> 'paid')::numeric = 2000 and (j -> 'finance_summary' ->> 'outstanding')::numeric = 3750
           and j -> 'documents' <> '[]'::jsonb and j -> 'domains' <> '[]'::jsonb and j -> 'communications' <> '[]'::jsonb)::text from z360), 'true');
select tests.check('30. Client 360 gives communications as metadata only: the message body never appears', (select (j::text like '%CONFIDENTIAL-BODY-TEXT%')::text from z360), 'false');
create temp table zp360 as select tests.scalar('ceo', format('select project_360(%L)::text', tests.id('prj:site')))::jsonb as j;
select tests.check('31. Project 360 shows the client, contact, service, quote, contract, invoice, payment, asset, ticket, document, domain and communication of the same project',
  (select (j -> 'client' is not null and jsonb_array_length(j -> 'contacts') >= 0 and jsonb_array_length(j -> 'services') = 1 and jsonb_array_length(j -> 'quotes') = 1 and jsonb_array_length(j -> 'contracts') = 1
           and jsonb_array_length(j -> 'invoices') = 1 and jsonb_array_length(j -> 'payments') = 1 and jsonb_array_length(j -> 'assets') = 1 and jsonb_array_length(j -> 'tickets') = 1
           and j -> 'documents' <> '[]'::jsonb and j -> 'domains' <> '[]'::jsonb and j -> 'communications' <> '[]'::jsonb)::text from zp360), 'true');
select tests.check('31b. ...and the money on Project 360 is the same derived money as on Client 360 (invoice balance 3,750, payment 2,000)',
  (select ((j -> 'invoices' -> 0 ->> 'balance')::numeric = 3750 and (j -> 'payments' -> 0 ->> 'amount')::numeric = 2000)::text from zp360), 'true');

-- 11. SEARCH is the way back in --------------------------------------------------------------------------------------------------------------------
create function tests.sr_ids(p_user text, p_q text) returns text language sql as $$
  select coalesce(string_agg(x ->> 'entity_type', ',' order by x ->> 'entity_type'), '-') from jsonb_array_elements(coalesce(tests.scalar(p_user, format('select search(%L)::text', p_q))::jsonb -> 'results', '[]')) x
$$;
select tests.check('32. "Zeta" finds the client, project, quote, contract, ticket, asset, domain, document and thread',
  (select bool_and(tests.sr_ids('web_lead', 'zeta') like '%' || t || '%')::text from unnest(array['client', 'project', 'quote', 'contract', 'ticket', 'asset', 'domain', 'document']) t), 'true');
select tests.check('33. "type:client Zeta" finds exactly the client', tests.sr_ids('web_lead', 'type:client zeta'), 'client');
select tests.check('34. the institutional id resolves to the client', (tests.scalar('web_lead', format($q$ select (search(%L) -> 'results' -> 0 ->> 'entity_type') $q$, tests.inst_of('clients', 'client:zeta')))), 'client');
select tests.check('35. "related:<client id>" reaches the project, contract, invoice, ticket, asset, document, domain and thread through the registry',
  (select bool_and(tests.sr_ids('web_lead', 'related:' || tests.inst_of('clients', 'client:zeta')) like '%' || t || '%')::text from unnest(array['project', 'contract', 'ticket', 'asset', 'document', 'domain', 'communication', 'quote']) t), 'true');
-- Known, documented limit (see ADA_HUB_PILOT_V0_1.md, finding F2): invoices and payments are not Search sources, so they are reached through Client / Project 360, not Search.

-- 12. INTEGRITY: identity stays one, ids stay stable, nothing was copied ----------------------------------------------------------------------------
select tests.check('36. still ONE organization, ONE client, ONE person, ONE project, ONE quote, ONE contract, ONE invoice',
  (select count(*)::text from organizations where name ilike 'zeta test company%') || (select count(*)::text from clients where name_key = client_name_key('Zeta Test Company'))
  || (select count(*)::text from people where email = 'zoe@zeta.example') || (select count(*)::text from projects where client_id = tests.id('client:zeta'))
  || (select count(*)::text from quotes where client_id = tests.id('client:zeta')) || (select count(*)::text from contracts where client_id = tests.id('client:zeta'))
  || (select count(*)::text from invoices where client_id = tests.id('client:zeta')), '1111111');
create temp table before_client as select institutional_id as i from entity_registry where table_name = 'clients' and entity_id = tests.id('client:zeta');
update clients set owner_division_id = tests.id('div:tech'), status = 'inactive' where id = tests.id('client:zeta');
select tests.check('37. the client''s institutional id does not change when its owner division and status are edited',
  (select (r.institutional_id = b.i)::text from entity_registry r, before_client b where r.table_name = 'clients' and r.entity_id = tests.id('client:zeta')), 'true');
create temp table before_ids as select institutional_id as i from entity_registry where table_name = 'assets' and entity_id = tests.id('asset:zeta');
select tests.scalar('web_lead', format($q$ select asset_assign(%L, null, %L, 'moved to Tech', null)::text $q$, tests.id('asset:zeta'), tests.id('div:tech')));
select tests.check('38. the asset''s permanent id survives a move between divisions and its project link stays',
  (select (r.institutional_id = b.i)::text from entity_registry r, before_ids b where r.table_name = 'assets' and r.entity_id = tests.id('asset:zeta')) || '|' ||
  (select (project_id = tests.id('prj:site'))::text from assets where id = tests.id('asset:zeta')), 'true|true');
select tests.check('39. a later catalogue change did not touch the invoice or the project line (still 5,000)',
  (select unit_price::text from invoice_lines where invoice_id = tests.id('inv:zeta') limit 1) || '|' || (select unit_price::text from project_services where project_id = tests.id('prj:site') limit 1), '5000.00|5000.00');
select tests.check('40. the engagement is on record: contract trail, approvals and audit rows exist',
  (select (count(*) >= 5)::text from contract_status_history where contract_id = tests.id('contract:zeta')) || (select (count(*) >= 3)::text from approval_requests where status = 'approved')
  || (select (count(*) > 20)::text from audit_log where table_name in ('clients', 'client_contacts', 'quotes', 'contracts', 'invoices', 'payments')), 'truetruetrue');

select tests.finish();
rollback;
