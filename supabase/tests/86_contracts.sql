-- Contracts: Client -> Contact -> Quote -> Contract -> Project, versions, amendments, lifecycle, visibility.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();

-- Creation and permissions -----------------------------------------------------------------------------------------------------------------
select tests.check('the fixture produced an ACTIVE contract', (select status::text from contracts where id = tests.id('contract:1')), 'active');
select tests.check('contract has an ADA-CON ID and references the SAME client, quote and division',
  (select (ada_id ~ '^ADA-CON-\d{4}-\d{4}$' and client_id = tests.id('client:abc') and quote_id = tests.id('quote:1') and division_id = tests.id('div:web'))::text from contracts where id = tests.id('contract:1')), 'true');
select tests.check('contacts now use ADA-CTC, contracts ADA-CON (the prefixes do not collide)',
  (select count(*)::text from entity_registry where entity_type = 'contact' and ada_id like 'ADA-CTC-%') || (select count(*)::text from entity_registry where entity_type = 'contact' and ada_id like 'ADA-CON-%'), '10');
select tests.check('the authorised contact is the quote''s contact (a client_contacts row, not a copy)',
  (select (contact_id = tests.id('contact:john'))::text from contract_versions where contract_id = tests.id('contract:1') and version_no = 1), 'true');
select tests.check('web staff (no contracts.create) cannot create a contract',
  tests.scalar('web_staff', format('select contract_create(%L, %L, ''X'')::text', tests.id('client:abc'), tests.id('div:web'))), 'ERR:42501');
select tests.check('finance can view contracts but not create them',
  tests.scalar('fin', 'select count(*)::text from contracts') || tests.scalar('fin', format('select contract_create(%L, %L, ''X'')::text', tests.id('client:abc'), tests.id('div:web'))), '1ERR:42501');
select tests.check('Tech cannot create a contract in Web''s name',
  tests.scalar('tech_lead', format('select contract_create(%L, %L, ''X'')::text', tests.id('client:abc'), tests.id('div:web'))), 'ERR:42501');
select tests.check('a client the division cannot see cannot be contracted',
  tests.scalar('web_lead', format('select contract_create(%L, %L, ''X'')::text', tests.id('client:C_tech'), tests.id('div:web'))), 'ERR:P0002');
select tests.check('the same quote cannot produce a second contract',
  tests.scalar('web_lead', format('select contract_create_from_quote(%L)::text', tests.id('quote:1'))), 'ERR:23505');
select tests.remember('quote:draft', tests.scalar('web_lead', format('select quote_create(%L, %L, ''Not accepted yet'')::text', tests.id('client:abc'), tests.id('div:web'))));
select tests.check('only an ACCEPTED quote can become a contract',
  tests.scalar('web_lead', format('select contract_create_from_quote(%L)::text', tests.id('quote:draft'))), 'ERR:23514');

-- Quote -> contract preserves what was quoted ------------------------------------------------------------------------------------------------
select tests.check('quote -> contract preserves quoted prices, quantities, discounts and price versions line by line',
  (select count(*)::text from quote_lines ql join contract_lines cl on cl.quote_line_id = ql.id
   join contract_versions v on v.id = cl.version_id and v.contract_id = tests.id('contract:1')
   where ql.quote_id = tests.id('quote:1') and (ql.unit_price, ql.quantity, ql.discount_amount, ql.price_id, ql.service_id, ql.line_total)
         = (cl.unit_price, cl.quantity, cl.discount_amount, cl.price_id, cl.service_id, cl.line_total)), '2');
select tests.check('quote -> contract preserves the quote total, subtotal and discount',
  (select (v.total = q.total and v.subtotal = 9800 and v.discount_total = 500 and v.total = 9300)::text from contract_versions v, quotes q
   where v.contract_id = tests.id('contract:1') and v.version_no = 1 and q.id = tests.id('quote:1')), 'true');
select tests.check('the contract covers the project the quote created',
  (select count(*)::text from contract_projects where contract_id = tests.id('contract:1') and project_id = tests.id('project:abc')), '1');

-- Later price changes never alter the contract ----------------------------------------------------------------------------------------------
select tests.remember('price:web2', tests.scalar('web_lead', format('select price_propose(%L, 6000, ''NAD'', current_date + 1, ''Increase'')::text', tests.id('svc:web'))));
select tests.scalar('ceo', format('select (price_decide(%L, true)).status::text', tests.id('price:web2')));
select tests.check('later price changes do not alter the contract (unit prices and total unchanged)',
  (select string_agg(cl.unit_price::text, ',' order by cl.unit_price) || '/' || max(v.total)::text from contract_lines cl join contract_versions v on v.id = cl.version_id
   where v.contract_id = tests.id('contract:1')), '1200.00,5000.00/9300.00');

-- Terms and lines are frozen for EVERY caller once the version leaves draft ---------------------------------------------------------------------
select tests.check('contract lines cannot be written directly by users', tests.try('web_lead', $q$ update contract_lines set unit_price = 1 $q$), 'ERR:42501');
select tests.check('contracts cannot be written directly by users', tests.try('web_lead', $q$ update contracts set status = 'draft' $q$), 'ERR:42501');
select tests.check('a signed version''s lines are immutable even for the database owner (update)',
  tests.try_owner(format('update contract_lines set unit_price = 1 where version_id in (select id from contract_versions where contract_id = %L)', tests.id('contract:1'))), 'ERR:42501');
select tests.check('...(delete)', tests.try_owner(format('delete from contract_lines where version_id in (select id from contract_versions where contract_id = %L)', tests.id('contract:1'))), 'ERR:42501');
select tests.check('...(insert)', tests.try_owner(format('insert into contract_lines (version_id, description, unit_price) select id, ''sneaky'', 1 from contract_versions where contract_id = %L', tests.id('contract:1'))), 'ERR:42501');
select tests.check('a signed version''s terms are immutable even for the owner (total)',
  tests.try_owner(format('update contract_versions set total = 1 where contract_id = %L', tests.id('contract:1'))), 'ERR:42501');
select tests.check('...(end date)', tests.try_owner(format('update contract_versions set end_date = current_date + 1 where contract_id = %L', tests.id('contract:1'))), 'ERR:42501');
select tests.check('...(delete the version)', tests.try_owner(format('delete from contract_versions where contract_id = %L', tests.id('contract:1'))), 'ERR:42501');
select tests.check('a contract cannot be deleted', tests.try_owner(format('delete from contracts where id = %L', tests.id('contract:1'))), 'ERR:42501');
select tests.check('a contract cannot be moved to another client', tests.try_owner(format('update contracts set client_id = %L where id = %L', tests.id('client:C_web'), tests.id('contract:1'))), 'ERR:42501');
select tests.check('the status trail cannot be edited', tests.try_owner('update contract_status_history set note = ''x''') || tests.try_owner('delete from contract_status_history'), 'ERR:42501ERR:42501');
select tests.check('terms cannot be edited on a signed version', tests.scalar('web_lead', format('select contract_set_terms(%L, ''{"end_date": "2099-01-01"}'')::text', tests.id('contract:1'))), 'ERR:42501');
select tests.check('lines cannot be added to a signed contract', tests.scalar('web_lead', format('select contract_add_line(%L, null, 1, 10, null, ''late'')::text', tests.id('contract:1'))), 'ERR:42501');

-- Lifecycle trail ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('the full lifecycle is on record, in order',
  (select string_agg(to_status, '>' order by id) from contract_status_history where contract_id = tests.id('contract:1') and scope = 'contract'),
  'draft>internal_review>approved>sent>signed>active');
select tests.check('the approval was recorded through the shared engine (kind contract, approved)',
  (select status::text from approval_requests where kind = 'contract' and entity_ada_id = (select ada_id from contracts where id = tests.id('contract:1'))), 'approved');
select tests.check('contract approval events reached the outbox', (select count(*)::text from events where entity_table = 'contracts' and event_type = 'contract.signed'), '1');
select tests.check('events carry identifiers only (no client name)', (select (payload::text !~* 'ABC')::text from events where event_type = 'contract.signed'), 'true');

-- Lifecycle rules on a second contract ------------------------------------------------------------------------------------------------------------------
select tests.remember('contract:2', tests.scalar('web_lead', format('select contract_create(%L, %L, ''Retainer'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
select tests.check('a contract cannot be submitted with no lines', tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:2'))), 'ERR:23514');
select tests.scalar('web_lead', format('select contract_add_line(%L, %L, 12, 800, ''Retainer rate'', ''Monthly retainer'')::text', tests.id('contract:2'), tests.id('svc:web')));
select tests.check('a contract cannot skip approval (draft -> sent)', tests.scalar('web_lead', format('select contract_transition(%L, ''sent'')::text', tests.id('contract:2'))), 'ERR:23514');
select tests.check('a non-catalogue price needs a reason', tests.scalar('web_lead', format('select contract_add_line(%L, %L, 1, 100)::text', tests.id('contract:2'), tests.id('svc:web'))), 'ERR:23514');
select tests.check('the end date cannot precede the start date',
  tests.scalar('web_lead', format('select contract_set_terms(%L, jsonb_build_object(''start_date'', current_date, ''end_date'', current_date - 1))::text', tests.id('contract:2'))), 'ERR:23514');
select tests.check('unknown terms are refused', tests.scalar('web_lead', format('select contract_set_terms(%L, ''{"client_id": "x"}'')::text', tests.id('contract:2'))), 'ERR:22023');
select tests.remember('contact:other', tests.scalar('web_lead', format('select add_client_contact(%L, ''Other Person'', ''other@x.example'')::text', tests.id('client:C_web'))));
select tests.check('the authorised contact must belong to the same client',
  tests.scalar('web_lead', format('select contract_set_terms(%L, jsonb_build_object(''contact_id'', %L))::text', tests.id('contract:2'), tests.id('contact:other'))), 'ERR:23514');
select tests.scalar('web_lead', format('select contract_set_terms(%L, jsonb_build_object(''start_date'', current_date, ''end_date'', current_date + 365, ''payment_terms_days'', 14, ''auto_renew'', true, ''renewal_notice_days'', 30, ''renewal_term_months'', 12))::text', tests.id('contract:2')));
select tests.check('submits for internal review', tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:2'))), 'internal_review');
select tests.check('lines are locked in review', tests.scalar('web_lead', format('select contract_add_line(%L, null, 1, 10, null, ''x'')::text', tests.id('contract:2'))), 'ERR:42501');
select tests.check('the preparer cannot approve (no contracts.approve)', tests.scalar('web_lead', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:2'))), 'ERR:42501');
select tests.check('rejection needs a note', tests.scalar('ceo', format('select contract_transition(%L, ''rejected'')::text', tests.id('contract:2'))), 'ERR:23514');
select tests.check('management sends it back to draft', tests.scalar('ceo', format('select contract_transition(%L, ''draft'', ''Terms too generous'')::text', tests.id('contract:2'))), 'draft');
select tests.check('...which cancels the pending request', (select count(*)::text from approval_requests where kind = 'contract' and status = 'pending'), '0');
select tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:2')));
select tests.check('management rejects with a note', tests.scalar('ceo', format('select contract_transition(%L, ''rejected'', ''Declined by management'')::text', tests.id('contract:2'))), 'rejected');
select tests.check('a rejected contract is terminal', tests.scalar('web_lead', format('select contract_transition(%L, ''draft'')::text', tests.id('contract:2'))), 'ERR:23514');

-- Cancel and terminate -----------------------------------------------------------------------------------------------------------------------------
select tests.remember('contract:3', tests.scalar('web_lead', format('select contract_create(%L, %L, ''Cancelled one'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
select tests.check('cancelling needs a reason', tests.scalar('web_lead', format('select contract_transition(%L, ''cancelled'')::text', tests.id('contract:3'))), 'ERR:23514');
select tests.check('a draft can be cancelled', tests.scalar('web_lead', format('select contract_transition(%L, ''cancelled'', ''Client withdrew'')::text', tests.id('contract:3'))), 'cancelled');
select tests.check('only management can terminate', tests.scalar('web_lead', format('select contract_transition(%L, ''terminated'', ''x'')::text', tests.id('contract:1'))), 'ERR:42501');
select tests.check('termination needs a reason', tests.scalar('ceo', format('select contract_transition(%L, ''terminated'')::text', tests.id('contract:1'))), 'ERR:23514');

-- Amendment: a NEW version; the original is never rewritten -----------------------------------------------------------------------------------------
select tests.check('finance can see but cannot amend', tests.scalar('fin', format('select contract_amend(%L, ''x'')::text', tests.id('contract:1'))), 'ERR:42501');
select tests.check('an amendment must say what it changes', tests.scalar('web_lead', format('select contract_amend(%L, '' '')::text', tests.id('contract:1'))), 'ERR:23514');
create temp table v1_before as
  select cl.id, cl.unit_price, cl.quantity, cl.discount_amount, cl.line_total, v.total, v.status::text as status, v.signed_on, v.effective_from, v.effective_to
  from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and v.version_no = 1;
create temp table trail_before as select id, to_status, note from contract_status_history where contract_id = tests.id('contract:1');
create temp table audit_before as select id from audit_log where record_ada_id = (select ada_id from contracts where id = tests.id('contract:1'));
select tests.check('a lead amends a signed contract: version 2', tests.scalar('web_lead', format('select contract_amend(%L, ''Add extra CCTV cameras'')::text', tests.id('contract:1'))), '2');
select tests.check('the amendment starts as a draft copy of the agreed lines at the AGREED prices (not today''s catalogue)',
  (select string_agg(cl.unit_price::text || 'x' || cl.quantity::text, ',' order by cl.unit_price) from contract_lines cl join contract_versions v on v.id = cl.version_id
   where v.contract_id = tests.id('contract:1') and v.version_no = 2), '1200.00x4.00,5000.00x1.00');
select tests.check('amendment lines keep their origin so billing continues across versions',
  (select count(*)::text from contract_lines n join contract_lines o on o.id = n.origin_line_id join contract_versions nv on nv.id = n.version_id and nv.version_no = 2
   join contract_versions ov on ov.id = o.version_id and ov.version_no = 1 where nv.contract_id = tests.id('contract:1')), '2');
select tests.check('only one amendment can be in progress', tests.scalar('web_lead', format('select contract_amend(%L, ''another'')::text', tests.id('contract:1'))), 'ERR:23505');
select tests.check('the original is still signed while the amendment is a draft', (select status::text from contract_versions where contract_id = tests.id('contract:1') and version_no = 1), 'signed');
select tests.check('the header stays active during an amendment', (select status::text from contracts where id = tests.id('contract:1')), 'active');
select tests.check('the amendment adds a line', tests.try('web_lead', format('select contract_add_line(%L, %L, 2)', tests.id('contract:1'), tests.id('svc:cctv'))), 'ok');
select tests.check('...at today''s catalogue price for the NEW line only (1200)',
  (select count(*)::text from contract_lines cl join contract_versions v on v.id = cl.version_id where v.contract_id = tests.id('contract:1') and v.version_no = 2 and cl.unit_price = 1200 and cl.quantity = 2), '1');
select tests.check('the amendment total follows its lines (9300 + 2400)', (select total::text from contract_versions where contract_id = tests.id('contract:1') and version_no = 2), '11700.00');
select tests.check('the amendment goes through the same approval', tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:1'))), 'active');
select tests.check('...and has its own pending request', (select count(*)::text from approval_requests where kind = 'contract' and status = 'pending'), '1');
select tests.check('...approved', tests.scalar('ceo', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:1'))), 'active');
select tests.scalar('web_lead', format('select contract_transition(%L, ''sent'')::text', tests.id('contract:1')));
select tests.check('the original remains the version in force until the amendment is signed',
  (select string_agg(version_no::text || ':' || status::text, ',' order by version_no) from contract_versions where contract_id = tests.id('contract:1')), '1:signed,2:sent');
select tests.check('the amendment is signed', tests.scalar('web_lead', format('select contract_transition(%L, ''signed'')::text', tests.id('contract:1'))), 'active');
select tests.check('the original is superseded with an end date, the amendment is in force',
  (select string_agg(version_no::text || ':' || status::text || ':' || (effective_to is not null)::text, ',' order by version_no) from contract_versions where contract_id = tests.id('contract:1')), '1:superseded:true,2:signed:false');
select tests.check('contract_terms returns the amended terms', tests.scalar('web_lead', format('select (contract_terms(%L)).total::text', tests.id('contract:1'))), '11700.00');
select tests.check('version 1 is exactly as it was signed (lines, prices, total, signature date)',
  (select count(*)::text from v1_before b join contract_lines cl on cl.id = b.id join contract_versions v on v.id = cl.version_id
   where (cl.unit_price, cl.quantity, cl.discount_amount, cl.line_total) = (b.unit_price, b.quantity, b.discount_amount, b.line_total)
     and v.total = b.total and v.signed_on is not distinct from b.signed_on and v.effective_from is not distinct from b.effective_from), '2');
select tests.check('audit history survives status changes and amendments: the earlier trail is untouched and extended',
  (select count(*)::text from trail_before t join contract_status_history h on h.id = t.id and h.to_status = t.to_status and h.note is not distinct from t.note), (select count(*)::text from trail_before));
select tests.check('...the trail now also shows the amendment and the supersession',
  (select count(*)::text from contract_status_history where contract_id = tests.id('contract:1') and scope = 'version' and to_status in ('superseded', 'signed') and version_no in (1, 2)), '3');
select tests.check('...and audit_log rows written before the amendment are all still there',
  (select count(*)::text from audit_before a join audit_log l on l.id = a.id), (select count(*)::text from audit_before));
select tests.check('...with new audit rows for the amendment', (select (count(*) > (select count(*) from audit_before))::text from audit_log where record_ada_id = (select ada_id from contracts where id = tests.id('contract:1'))), 'true');
select tests.check('the superseded version cannot be edited even by the owner', tests.try_owner(format('update contract_versions set total = 5 where contract_id = %L and version_no = 1', tests.id('contract:1'))), 'ERR:42501');
select tests.check('a superseded version cannot change status again', tests.try_owner(format('update contract_versions set status = ''signed'' where contract_id = %L and version_no = 1', tests.id('contract:1'))), 'ERR:23514');

-- Visibility: authorisation slices of ONE record ------------------------------------------------------------------------------------------------
select tests.check('web lead sees the contract', tests.scalar('web_lead', format('select count(*)::text from contracts where id = %L', tests.id('contract:1'))), '1');
select tests.check('finance and management see it (org-wide contracts.view)',
  tests.scalar('fin', format('select count(*)::text from contracts where id = %L', tests.id('contract:1'))) || tests.scalar('ceo', format('select count(*)::text from contracts where id = %L', tests.id('contract:1'))), '11');
select tests.check('cross-division: Tech staff and Tech lead cannot see Web''s contract, versions, lines or history',
  tests.scalar('tech_lead', 'select (select count(*) from contracts)::text || (select count(*) from contract_versions) || (select count(*) from contract_lines) || (select count(*) from contract_status_history) || (select count(*) from contract_projects)'), '00000');
select tests.check('web staff (no contracts.view), auditor and recruiter see nothing',
  tests.scalar('web_staff', 'select count(*)::text from contracts') || tests.scalar('audit', 'select count(*)::text from contracts') || tests.scalar('recruiter', 'select count(*)::text from contracts'), '000');
select tests.check('a hidden contract is indistinguishable from a missing one (function calls)',
  tests.same_for('tech_lead', $q$ select contract_transition(%L, 'cancelled', 'probe')::text $q$, tests.id('contract:1'), gen_random_uuid()), 'same');
select tests.check('...(amend)', tests.same_for('tech_lead', $q$ select contract_amend(%L, 'probe')::text $q$, tests.id('contract:1'), gen_random_uuid()), 'same');
select tests.check('...(add line)', tests.same_for('tech_lead', $q$ select contract_add_line(%L, null, 1, 1, null, 'probe')::text $q$, tests.id('contract:1'), gen_random_uuid()), 'same');
select tests.check('...(link project)', tests.same_for('tech_lead', $q$ select contract_link_project(%L, (select id from projects limit 1))::text $q$, tests.id('contract:1'), gen_random_uuid()), 'same');
select tests.check('...(helper)', tests.same_for('tech_lead', $q$ select can_view_contract(%L)::text $q$, tests.id('contract:1'), gen_random_uuid()), 'same');
select tests.check('...(terms)', tests.same_for('tech_lead', $q$ select count(*)::text from contract_terms(%L) $q$, tests.id('contract:1'), gen_random_uuid()), 'same');
select tests.check('control: the probes can tell a visible contract from a missing one', left(tests.same_for('web_lead', $q$ select can_view_contract(%L)::text $q$, tests.id('contract:1'), gen_random_uuid()), 9), 'DIFFERENT');

-- Projects ------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('a project of ANOTHER client cannot be linked', tests.scalar('web_lead', format('select contract_link_project(%L, %L)::text', tests.id('contract:1'), tests.id('project:P_web'))), 'ERR:P0002');
select tests.remember('project:abc2', tests.scalar('web_lead', format('insert into projects (client_id, lead_division_id, name) values (%L, %L, ''Phase 2'') returning id::text', tests.id('client:abc'), tests.id('div:web'))));
select tests.check('a contract can cover another project of the same client', tests.try('web_lead', format('select contract_link_project(%L, %L)', tests.id('contract:1'), tests.id('project:abc2'))), 'ok');
select tests.check('a project link cannot be removed', tests.try_owner(format('delete from contract_projects where contract_id = %L', tests.id('contract:1'))), 'ERR:42501');
select tests.check('the database refuses a link to another client''s project even for the owner',
  tests.try_owner(format('insert into contract_projects (contract_id, project_id) values (%L, %L)', tests.id('contract:1'), tests.id('project:P_web'))), 'ERR:23514');

-- Expiry and renewal ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('users cannot run the contract jobs', tests.scalar('ceo', 'select expire_contracts()::text') || tests.scalar('ceo', 'select activate_contracts()::text'), 'ERR:42501ERR:42501');
select tests.check('a contract that has not reached its end cannot be marked expired', tests.scalar('web_lead', format('select contract_transition(%L, ''expired'')::text', tests.id('contract:1'))), 'ERR:23514');
select tests.remember('contract:4', tests.scalar('web_lead', format('select contract_create(%L, %L, ''Short term'', %L)::text', tests.id('client:abc'), tests.id('div:web'), tests.id('contact:john'))));
select tests.scalar('web_lead', format('select contract_add_line(%L, %L, 1)::text', tests.id('contract:4'), tests.id('svc:cctv')));
select tests.scalar('web_lead', format('select contract_set_terms(%L, jsonb_build_object(''start_date'', current_date - 60, ''end_date'', current_date - 1, ''renewal_term_months'', 6))::text', tests.id('contract:4')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:4')));
select tests.scalar('ceo', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:4')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''sent'')::text', tests.id('contract:4')));
select tests.check('a signature cannot be dated in the future', tests.scalar('web_lead', format('select contract_transition(%L, ''signed'', null, current_date + 5)::text', tests.id('contract:4'))), 'ERR:23514');
select tests.scalar('web_lead', format('select contract_transition(%L, ''signed'', null, current_date - 60)::text', tests.id('contract:4')));
select tests.check('the scheduled job activates a signed contract whose start date has arrived', (select activate_contracts())::text, '1');
select tests.check('the scheduled job expires an active contract past its end date', (select expire_contracts())::text, '1');
select tests.check('the contract is expired', (select status::text from contracts where id = tests.id('contract:4')), 'expired');
select tests.check('finance can see but cannot renew', tests.scalar('fin', format('select contract_renew(%L)::text', tests.id('contract:4'))), 'ERR:42501');
select tests.remember('contract:4r', tests.scalar('web_lead', format('select contract_renew(%L)::text', tests.id('contract:4'))));
select tests.check('the renewal references the old contract, the same client, at the AGREED prices (not today''s catalogue)',
  (select (c.renewed_from_id = tests.id('contract:4') and c.client_id = tests.id('client:abc') and v.total = 1200 and cl.unit_price = 1200 and v.start_date = current_date and c.status = 'draft')::text
   from contracts c join contract_versions v on v.contract_id = c.id join contract_lines cl on cl.version_id = v.id where c.id = tests.id('contract:4r')), 'true');
select tests.check('a contract cannot be renewed twice', tests.scalar('web_lead', format('select contract_renew(%L)::text', tests.id('contract:4'))), 'ERR:23505');
select tests.scalar('web_lead', format('select contract_transition(%L, ''internal_review'')::text', tests.id('contract:4r')));
select tests.scalar('ceo', format('select contract_transition(%L, ''approved'')::text', tests.id('contract:4r')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''sent'')::text', tests.id('contract:4r')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''signed'')::text', tests.id('contract:4r')));
select tests.scalar('web_lead', format('select contract_transition(%L, ''active'')::text', tests.id('contract:4r')));
select tests.check('activating the renewal marks the old contract renewed', (select status::text from contracts where id = tests.id('contract:4')), 'renewed');

-- Termination ----------------------------------------------------------------------------------------------------------------------------------
select tests.check('management terminates with a reason', tests.scalar('ceo', format('select contract_transition(%L, ''terminated'', ''Client closed down'')::text', tests.id('contract:4r'))), 'terminated');
select tests.check('a terminated contract is final', tests.scalar('ceo', format('select contract_transition(%L, ''active'')::text', tests.id('contract:4r'))), 'ERR:23514');

-- Structure: Finance is not its own mini-database --------------------------------------------------------------------------------------------------
select tests.check('contract tables hold no client or contact identity columns',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns
   where table_schema = 'public' and table_name like 'contract%' and column_name ~ '(name|email|phone)' and column_name not in ('title', 'document_ref')), 'none');
select tests.check('every contract reference to a client/contact/quote/project/service/staff is a foreign key to the central record',
  (select coalesce(string_agg(a.attname, ',' order by a.attname), 'none') from pg_attribute a where a.attrelid in ('contracts'::regclass, 'contract_versions'::regclass, 'contract_lines'::regclass)
   and a.attname in ('client_id', 'contact_id', 'quote_id', 'service_id', 'price_id', 'owner_staff_id', 'division_id') and not exists
   (select 1 from pg_constraint c where c.conrelid = a.attrelid and c.contype = 'f' and c.conkey[1] = a.attnum)), 'none');
select tests.check('the registry knows every contract', tests.unregistered_tables(), 'none');

select tests.finish();
rollback;
