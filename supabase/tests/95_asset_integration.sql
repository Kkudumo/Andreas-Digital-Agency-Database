-- Assets with tickets, maintenance, warranties, documents, suppliers and finance links; client deletion rules.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.bank_account('nad');

-- A supplier is one record ------------------------------------------------------------------------------------------------------------------------
select tests.check('web staff cannot create suppliers', tests.try('web_staff', $q$ insert into suppliers (name) values ('Evil Corp') $q$), 'ERR:42501');
select tests.check('finance creates a supplier', tests.try('fin', $q$ insert into suppliers (name) values ('Pinnacle Computers (Pty) Ltd') $q$), 'ok');
select tests.check('the same supplier written differently is the same record (normalised)', tests.try('fin', $q$ insert into suppliers (name) values ('PINNACLE COMPUTERS') $q$), 'ERR:23505');
select tests.check('suppliers have an ADA-SUP ID', (select (ada_id ~ '^ADA-SUP-\d{4}-\d{4}$')::text from suppliers limit 1), 'true');
insert into tests.ids select 'sup:1', id from suppliers limit 1;

-- A laptop deployed at a client, assigned to a technician -------------------------------------------------------------------------------------------
select tests.check('web lead registers an asset for the client with a project and supplier', (tests.scalar('web_lead', format($q$ select asset_create(p_name => 'Lenovo ThinkPad X1', p_category => 'laptop', p_division => %L, p_manufacturer => 'Lenovo', p_model => 'X1 Carbon', p_serial => 'XYZ-123',
   p_status => 'in_stock', p_method => 'purchased', p_cost => 25000, p_supplier => %L, p_client => %L, p_project => %L, p_location => 'Windhoek office')::text $q$,
   tests.id('div:web'), tests.id('sup:1'), tests.id('client:abc'), tests.id('project:abc'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'asset:lap', id from assets where serial_number = 'XYZ-123';
select tests.check('the asset REFERENCES client, project and supplier by id (no names copied)',
  (select (client_id = tests.id('client:abc') and project_id = tests.id('project:abc') and supplier_id = tests.id('sup:1') and acquisition_currency = 'NAD' and acquisition_method = 'purchased')::text from assets where id = tests.id('asset:lap')), 'true');
select tests.check('a project of another client is refused', tests.mk_asset('web_lead', 'x', 'X', 'web', null, null, null, 'in_stock', 'client:C_web', 'project:abc'), 'ERR:23514');
select tests.check('a client the user cannot see is refused like a missing client', tests.mk_asset('web_lead', 'x', 'X', 'web', null, null, null, 'in_stock', 'client:C_tech'), 'ERR:P0002');
select tests.check('the asset table holds no client / supplier / person names', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns
   where table_schema = 'public' and table_name in ('assets', 'asset_assignments', 'asset_maintenance', 'asset_warranties', 'asset_documents', 'asset_finance_links', 'tickets') and column_name ~ '(client_name|supplier_name|staff_name|holder|email|phone|contact_name|invoice_number|payment_ref|amount_paid)'), 'none');

-- Tickets reference the asset instead of retyping it ---------------------------------------------------------------------------------------------------
select tests.check('web staff can open a ticket against the asset (tickets.create in the division)', (tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'Screen flickers', p_asset => %L, p_priority => 'high')::text $q$, tests.id('asset:lap'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'tkt:1', id from tickets where title = 'Screen flickers';
select tests.check('the ticket took client, project and division from the asset and has an ADA-TKT ID',
  (select (ada_id ~ '^ADA-TKT-\d{4}-\d{4}$' and client_id = tests.id('client:abc') and project_id = tests.id('project:abc') and division_id = tests.id('div:web') and asset_id = tests.id('asset:lap') and reporter_staff_id = tests.id('staff:web_staff'))::text from tickets where id = tests.id('tkt:1')), 'true');
select tests.check('a ticket cannot claim a different client than its asset', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'x', p_asset => %L, p_client => %L)::text $q$, tests.id('asset:lap'), tests.id('client:C_web'))), 'ERR:23514');
select tests.remember('contact:other', tests.scalar('web_lead', format('select add_client_contact(%L, ''Other Person'', ''other@x.example'')::text', tests.id('client:C_web'))));
select tests.check('a contact must belong to the ticket''s client', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'x', p_asset => %L, p_contact => %L)::text $q$, tests.id('asset:lap'), tests.id('contact:other'))), 'ERR:23514');
select tests.check('Tech cannot open tickets against Web''s asset (it cannot see it)', tests.scalar('tech_lead', format($q$ select ticket_create(p_title => 'x', p_asset => %L)::text $q$, tests.id('asset:lap'))), 'ERR:P0002');
select tests.check('the reporter sees their own ticket', tests.scalar('web_staff', format('select count(*)::text from tickets where id = %L', tests.id('tkt:1'))), '1');
select tests.check('Tech does not', tests.scalar('tech_lead', format('select count(*)::text from tickets where id = %L', tests.id('tkt:1'))), '0');
select tests.check('web lead assigns it to a technician (tickets.assign)', tests.try('web_lead', format('select ticket_assign(%L, %L)', tests.id('tkt:1'), tests.id('staff:web_staff'))), 'ok');
select tests.check('web staff cannot assign', tests.scalar('web_staff', format('select ticket_assign(%L, %L)::text', tests.id('tkt:1'), tests.id('staff:web_lead'))), 'ERR:42501');
select tests.check('a suspended person cannot be assigned', tests.scalar('web_lead', format('select ticket_assign(%L, %L)::text', tests.id('tkt:1'), tests.id('staff:suspended'))), 'ERR:23514');
select tests.check('lifecycle: open -> in progress', tests.scalar('web_staff', format('select ticket_transition(%L, ''in_progress'')::text', tests.id('tkt:1'))), 'in_progress');
select tests.check('closing straight from in progress is refused', tests.scalar('web_staff', format('select ticket_transition(%L, ''closed'')::text', tests.id('tkt:1'))), 'ERR:23514');
select tests.check('resolving needs a note', tests.scalar('web_staff', format('select ticket_transition(%L, ''resolved'')::text', tests.id('tkt:1'))), 'ERR:23514');

-- Maintenance history ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('web staff (assets.maintain) schedule a repair linked to the ticket', (tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'repair', 'Replace display cable', current_date, %L, %L)::text $q$, tests.id('asset:lap'), tests.id('tkt:1'), tests.id('sup:1'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'mnt:1', id from asset_maintenance where asset_id = tests.id('asset:lap');
select tests.check('maintenance is not editable by users', tests.try('web_staff', $q$ update asset_maintenance set description = 'x' $q$), 'ERR:42501');
select tests.mk_asset('web_lead', 'other', 'Other laptop', 'web');
select tests.check('a ticket about another asset cannot be linked', tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'repair', 'x', null, %L)::text $q$, tests.id('asset:other'), tests.id('tkt:1'))), 'ERR:23514');
select tests.check('starting maintenance puts the asset in maintenance', tests.try('web_staff', format('select maintenance_start(%L)', tests.id('mnt:1'))), 'ok');
select tests.check('...the asset status follows', (select status::text from assets where id = tests.id('asset:lap')), 'in_maintenance');
select tests.check('only one maintenance can be in progress per asset', tests.scalar('web_staff', format($q$ select maintenance_start(maintenance_schedule(%L, 'inspection', 'Second job'))::text $q$, tests.id('asset:lap'))), 'ERR:23514');
select tests.check('an asset in maintenance cannot be retired', tests.scalar('web_lead', format('select asset_retire(%L, ''x'')::text', tests.id('asset:lap'))), 'ERR:23514');
select tests.check('completing needs an outcome', tests.scalar('web_staff', format('select maintenance_complete(%L, '' '')::text', tests.id('mnt:1'))), 'ERR:23514');
select tests.check('completing returns the asset to stock and can update its condition', tests.try('web_staff', format('select maintenance_complete(%L, ''Cable replaced, tested OK'', ''good'')', tests.id('mnt:1'))), 'ok');
select tests.check('...asset back in stock, maintenance history kept', (select status::text from assets where id = tests.id('asset:lap')) || (select status::text || (outcome is not null)::text from asset_maintenance where id = tests.id('mnt:1')), 'in_stockcompletedtrue');
select tests.check('completed maintenance is final and cannot be deleted (owner)', tests.try_owner(format('update asset_maintenance set outcome = ''x'' where id = %L', tests.id('mnt:1'))) || tests.try_owner(format('delete from asset_maintenance where id = %L', tests.id('mnt:1'))), 'ERR:42501ERR:42501');
select tests.scalar('web_lead', format('select asset_assign(%L, %L)::text', tests.id('asset:lap'), tests.id('staff:web_staff')));
select tests.check('maintenance on an assigned asset returns it to assigned afterwards (scheduled next)', (select status::text from assets where id = tests.id('asset:lap')), 'assigned');
select tests.remember('mnt:2', tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'preventive', 'Annual service')::text $q$, tests.id('asset:lap'))));
select tests.scalar('web_staff', format('select maintenance_start(%L)', tests.id('mnt:2')));
select tests.check('...(in maintenance while assigned)', (select status::text from assets where id = tests.id('asset:lap')), 'in_maintenance');
select tests.scalar('web_staff', format('select maintenance_complete(%L, ''Serviced'')::text', tests.id('mnt:2')));
select tests.check('...(back to assigned, the assignment never closed)', (select status::text from assets where id = tests.id('asset:lap')) || (select count(*)::text from asset_current_assignments where asset_id = tests.id('asset:lap')), 'assigned1');
select tests.scalar('web_lead', format('select asset_unassign(%L, ''Back in store'')::text', tests.id('asset:lap')));

select tests.mk_asset('web_lead', 'old', 'Old kit', 'web');
select tests.scalar('web_lead', format('select asset_retire(%L, ''Obsolete'')::text', tests.id('asset:old')));
select tests.check('a retired asset cannot be maintained', tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'repair', 'x')::text $q$, tests.id('asset:old'))), 'ERR:23514');
select tests.scalar('ceo', format('select asset_dispose(%L, ''scrapped'')::text', tests.id('asset:old')));
select tests.check('...nor a disposed one', tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'repair', 'x')::text $q$, tests.id('asset:old'))), 'ERR:23514');
select tests.check('scheduled maintenance is cancelled when its asset is retired', (tests.mk_asset('web_lead', 'sched', 'Scheduled kit', 'web') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'inspection', 'Planned')::text $q$, tests.id('asset:sched')));
select tests.scalar('web_lead', format('select asset_retire(%L, ''Replaced'')::text', tests.id('asset:sched')));
select tests.check('...recorded as cancelled with the reason', (select status::text || '/' || cancel_reason from asset_maintenance where asset_id = tests.id('asset:sched')), 'cancelled/asset retired');

-- Resolve and close the ticket ------------------------------------------------------------------------------------------------------------------------
select tests.check('resolve with a resolution', tests.scalar('web_staff', format('select ticket_transition(%L, ''resolved'', ''Display cable replaced'')::text', tests.id('tkt:1'))), 'resolved');
select tests.check('a resolved ticket can be reopened', tests.scalar('web_lead', format('select ticket_transition(%L, ''open'')::text', tests.id('tkt:1'))), 'open');
select tests.scalar('web_lead', format('select ticket_transition(%L, ''resolved'', ''Confirmed fixed'')::text', tests.id('tkt:1')));
select tests.check('closing is final', tests.scalar('web_lead', format('select ticket_transition(%L, ''closed'')::text', tests.id('tkt:1'))) || tests.scalar('web_lead', format('select ticket_transition(%L, ''open'')::text', tests.id('tkt:1'))), 'closedERR:23514');
select tests.check('tickets are never deleted', tests.try_owner('delete from tickets'), 'ERR:42501');
select tests.check('a ticket cannot be re-pointed at another asset', tests.try_owner(format('update tickets set asset_id = %L where id = %L', tests.id('asset:other'), tests.id('tkt:1'))), 'ERR:42501');

-- Warranty and documents ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('warranty: end must follow start', tests.scalar('web_lead', format('select asset_add_warranty(%L, current_date, current_date - 1)::text', tests.id('asset:lap'))), 'ERR:23514');
select tests.remember('war:1', tests.scalar('web_lead', format($q$ select asset_add_warranty(%L, current_date - 30, current_date + 700, %L, 'LW-9917', 'Next business day on-site')::text $q$, tests.id('asset:lap'), tests.id('sup:1'))));
select tests.check('the warranty state is derived, not stored', (select in_warranty::text from asset_warranty_status where asset_id = tests.id('asset:lap')) || (select (warranty_ends_on = current_date + 700)::text from asset_warranty_status where asset_id = tests.id('asset:lap')), 'truetrue');
select tests.check('a warranty entry cannot be edited, only voided with a reason', tests.try_owner(format('update asset_warranties set ends_on = current_date + 9999 where id = %L', tests.id('war:1'))) || tests.scalar('web_lead', format('select asset_void_warranty(%L, '' '')::text', tests.id('war:1'))), 'ERR:42501ERR:23514');
select tests.remember('doc:1', tests.scalar('web_lead', format($q$ select asset_add_document(%L, 'warranty', 'Lenovo warranty certificate', 'drive://warranty/LW-9917.pdf')::text $q$, tests.id('asset:lap'))));
select tests.check('web staff cannot attach documents (assets.update)', tests.scalar('web_staff', format($q$ select asset_add_document(%L, 'manual', 'x', 'ref')::text $q$, tests.id('asset:lap'))), 'ERR:42501');
select tests.check('asset documents are visible with the asset', tests.scalar('web_staff', format('select count(*)::text from asset_documents where asset_id = %L', tests.id('asset:lap'))) || tests.scalar('tech_lead', format('select count(*)::text from asset_documents where asset_id = %L', tests.id('asset:lap'))), '10');
select tests.check('a document is voided with a reason, never edited', tests.try_owner(format('update asset_documents set document_ref = ''x'' where id = %L', tests.id('doc:1'))) || tests.try_owner('delete from asset_documents'), 'ERR:42501ERR:42501');

-- Finance stays authoritative ------------------------------------------------------------------------------------------------------------------------------
select tests.issued_invoice('HW', 'client:abc', 30000);
select tests.check('an invoice of the asset''s own client can be linked by someone who can see it', (tests.scalar('ceo', format($q$ select asset_link_finance(%L, %L, null, 'hardware_charge', 'Laptop billed to the client')::text $q$, tests.id('asset:lap'), tests.id('inv:HW'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.issued_invoice('OTH', 'client:C_web', 100);
select tests.check('an invoice of another client cannot be linked', tests.scalar('ceo', format($q$ select asset_link_finance(%L, %L)::text $q$, tests.id('asset:lap'), tests.id('inv:OTH'))), 'ERR:P0002');
select tests.remember('pay:1', tests.scalar('fin', format('select payment_record(%L, %L, 100, ''cash'')::text', tests.id('client:abc'), tests.id('acct:nad'))));
select tests.check('a division lead cannot link a payment (no payments.view)', tests.scalar('web_lead', format($q$ select asset_link_finance(%L, null, %L)::text $q$, tests.id('asset:lap'), tests.id('pay:1'))), 'ERR:P0002');
select tests.check('management can link the client''s payment', (tests.scalar('ceo', format($q$ select asset_link_finance(%L, null, %L, 'client_payment')::text $q$, tests.id('asset:lap'), tests.id('pay:1'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the same invoice cannot be linked twice', tests.scalar('ceo', format($q$ select asset_link_finance(%L, %L)::text $q$, tests.id('asset:lap'), tests.id('inv:HW'))), 'ERR:23505');
select tests.check('an asset with no client cannot be linked to client invoices', tests.scalar('ceo', format($q$ select asset_link_finance(%L, %L)::text $q$, tests.id('asset:other'), tests.id('inv:HW'))), 'ERR:23514');
select tests.check('the link table carries no invoice or payment identity beyond the foreign keys', (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'asset_finance_links'), 'id,asset_id,invoice_id,payment_id,relation,note,linked_by,linked_at');
select tests.check('the link is visible only to people who can see the invoice too (a division lead sees the invoice link but not the payment link; web staff neither)',
  tests.scalar('ceo', format('select count(*)::text from asset_finance_links where asset_id = %L', tests.id('asset:lap'))) || tests.scalar('web_staff', format('select count(*)::text from asset_finance_links where asset_id = %L', tests.id('asset:lap'))) || tests.scalar('web_lead', format('select count(*)::text from asset_finance_links where asset_id = %L', tests.id('asset:lap'))), '201');
select tests.check('links cannot be edited or deleted', tests.try_owner('update asset_finance_links set note = ''x''') || tests.try_owner('delete from asset_finance_links'), 'ERR:42501ERR:42501');
create temp table a360 as select tests.scalar('ceo', format('select asset_360(%L)::text', tests.id('asset:lap')))::jsonb as j;
select tests.check('the asset 360 resolves the invoice through finance, by its own ADA ID', (select j -> 'finance' -> 0 ->> 'invoice' from a360), (select ada_id from invoices where id = tests.id('inv:HW')));
select tests.check('...and an asset viewer without finance rights sees no finance in the 360', tests.scalar('web_staff', format('select jsonb_array_length(asset_360(%L) -> ''finance'')::text', tests.id('asset:lap'))), '0');
select tests.check('the 360 shows holder history, maintenance, tickets, warranty and documents of the same record',
  (select (jsonb_array_length(j -> 'maintenance') = 2 and jsonb_array_length(j -> 'tickets') = 1 and jsonb_array_length(j -> 'warranties') = 1 and jsonb_array_length(j -> 'documents') = 1 and jsonb_array_length(j -> 'assignment_history') >= 1)::text from a360), 'true');

-- Deleting a client with linked assets is blocked where appropriate ------------------------------------------------------------------------------
select tests.remember('client:ast', tests.mkclient_id('web_lead', 'Asset Holder Co', 'web'));
select tests.mk_asset('web_lead', 'held', 'Router at client site', 'web', null, null, null, 'in_stock', 'client:ast');
select tests.check('a client with a live asset cannot be removed', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:ast'))), 'ERR:23514');
select tests.remember('tkt:2', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'Router offline', p_asset => %L)::text $q$, tests.id('asset:held'))));
select tests.scalar('web_lead', format('select asset_retire(%L, ''Replaced'')::text', tests.id('asset:held')));
select tests.check('a retired asset no longer blocks, but an open ticket still does', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:ast'))), 'ERR:23514');
select tests.scalar('web_lead', format('select ticket_transition(%L, ''cancelled'', ''No longer relevant'')::text', tests.id('tkt:2')));
select tests.check('once assets are retired and tickets closed the client can be removed', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:ast'))), 'ok');
select tests.check('...and its (retired) asset and ticket then disappear for ordinary users but stay for those who may see deleted records',
  tests.scalar('web_lead', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L)', tests.id('asset:held'), tests.id('tkt:2'))) || tests.scalar('ceo', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L)', tests.id('asset:held'), tests.id('tkt:2'))), '0011');

-- Views and structure -------------------------------------------------------------------------------------------------------------------------------
select tests.check('the client 360 lists the client''s assets and tickets', (tests.scalar('ceo', format('select client_360(%L)::text', tests.id('client:abc')))::jsonb) -> 'assets' -> 0 ->> 'name', 'Lenovo ThinkPad X1');
select tests.check('the project 360 lists them too', jsonb_array_length((tests.scalar('ceo', format('select project_360(%L)::text', tests.id('project:abc')))::jsonb) -> 'tickets')::text, '1');
select tests.check('the staff 360 lists the assets a person holds', jsonb_array_length((tests.scalar('ceo', format('select staff_360(%L)::text', tests.id('staff:web_staff')))::jsonb) -> 'assets')::text, '0');
select tests.check('the registry knows every supplier, asset and ticket', tests.unregistered_tables(), 'none');

select tests.finish();
rollback;
