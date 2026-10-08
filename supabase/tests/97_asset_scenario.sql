-- Acceptance scenario: the life of ADA-AST-…-0001, a Lenovo ThinkPad X1 - bought, stocked, assigned to Tech, moved to Web, deployed
-- on a client project, repaired under a ticket, covered by warranty and documents, billed to the client, returned, retired, disposed.
-- Nothing about the laptop, the person, the client or the invoice is ever retyped; history is never overwritten.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.bank_account('nad');
select tests.check('0. the supplier is one record', tests.try('fin', $q$ insert into suppliers (name) values ('Pinnacle Computers') $q$), 'ok');
insert into tests.ids select 'sup:1', id from suppliers where name = 'Pinnacle Computers';

select tests.remember('asset:lap', tests.scalar('tech_lead', format($q$ select asset_create(p_name => 'Lenovo ThinkPad X1', p_category => 'laptop', p_division => %L, p_manufacturer => 'Lenovo', p_model => 'X1 Carbon Gen 11',
   p_serial => 'PF-3A9X21', p_tag => 'ADA-IT-0001', p_status => 'proposed', p_method => 'purchased', p_cost => 28500, p_supplier => %L, p_location => 'Windhoek HQ')::text $q$, tests.id('div:tech'), tests.id('sup:1'))));
select tests.check('1. registered: ADA-AST ID, proposed, in Tech', (select (ada_id ~ '^ADA-AST-\d{4}-\d{4}$' and status = 'proposed' and division_id = tests.id('div:tech'))::text from assets where id = tests.id('asset:lap')), 'true');
select tests.scalar('tech_lead', format('select asset_transition(%L, ''acquired'')::text', tests.id('asset:lap')));
select tests.scalar('tech_lead', format('select asset_transition(%L, ''in_stock'')::text', tests.id('asset:lap')));
select tests.scalar('tech_lead', format($q$ select asset_add_warranty(%L, current_date, current_date + 1095, %L, 'LW-0001', '3 years on-site')::text $q$, tests.id('asset:lap'), tests.id('sup:1')));
select tests.scalar('tech_lead', format($q$ select asset_add_document(%L, 'warranty', 'Warranty certificate', 'drive://lw-0001.pdf')::text $q$, tests.id('asset:lap')));
select tests.check('2. assigned to a Tech staff member: a holder record, not a field',
  (tests.scalar('tech_lead', format('select asset_assign(%L, %L, %L, ''New hire kit'')::text', tests.id('asset:lap'), tests.id('staff:tech_staff'), tests.id('div:tech'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('3. the holder (not in the register role of any division but Tech) sees it, Web does not', tests.scalar('tech_staff', format('select count(*)::text from assets where id = %L', tests.id('asset:lap'))) || tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:lap'))), '10');
select tests.check('4. management moves it from Tech to Web: a second assignment, the first is preserved',
  (tests.scalar('ceo', format('select asset_assign(%L, %L, %L, ''Needed on the ABC project'')::text', tests.id('asset:lap'), tests.id('staff:web_staff'), tests.id('div:web'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('5. history: Tech holder (ended, reassigned) then Web holder (current)',
  (select string_agg(d.key || ':' || (g.ended_at is not null)::text, ' > ' order by g.ended_at nulls last) from asset_assignments g join divisions d on d.id = g.division_id where g.asset_id = tests.id('asset:lap')), 'tech:true > web:false');
select tests.check('6. responsibility is now Web', (select division_id = tests.id('div:web') from assets where id = tests.id('asset:lap'))::text, 'true');
select tests.scalar('web_lead', format('select asset_update(%L, ''{"client_id": "%s", "project_id": "%s", "current_location": "ABC site office"}'')::text', tests.id('asset:lap'), tests.id('client:abc'), tests.id('project:abc')));
select tests.check('7. deployed to the client project by reference', (select (client_id = tests.id('client:abc') and project_id = tests.id('project:abc') and current_location = 'ABC site office')::text from assets where id = tests.id('asset:lap')), 'true');
select tests.remember('tkt:1', tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'Keyboard keys sticking', p_asset => %L, p_priority => 'normal')::text $q$, tests.id('asset:lap'))));
select tests.check('8. the ticket carries asset, client, project and division without retyping', (select (asset_id = tests.id('asset:lap') and client_id = tests.id('client:abc') and project_id = tests.id('project:abc') and division_id = tests.id('div:web'))::text from tickets where id = tests.id('tkt:1')), 'true');
select tests.remember('mnt:1', tests.scalar('web_lead', format($q$ select maintenance_schedule(%L, 'repair', 'Replace keyboard', current_date, %L, %L)::text $q$, tests.id('asset:lap'), tests.id('tkt:1'), tests.id('sup:1'))));
select tests.scalar('web_lead', format('select maintenance_start(%L)::text', tests.id('mnt:1')));
select tests.scalar('web_lead', format('select maintenance_complete(%L, ''Keyboard replaced under warranty'', ''good'')::text', tests.id('mnt:1')));
select tests.scalar('web_staff', format('select ticket_transition(%L, ''resolved'', ''Keyboard replaced'')::text', tests.id('tkt:1')));
select tests.scalar('web_lead', format('select ticket_transition(%L, ''closed'')::text', tests.id('tkt:1')));
select tests.check('9. maintenance returned the asset to its holder and the ticket is closed', (select status::text from assets where id = tests.id('asset:lap')) || (select status::text from tickets where id = tests.id('tkt:1')), 'assignedclosed');
select tests.issued_invoice('HW', 'client:abc', 28500);
select tests.scalar('ceo', format($q$ select asset_link_finance(%L, %L, null, 'hardware_charge', 'Laptop billed at cost')::text $q$, tests.id('asset:lap'), tests.id('inv:HW')));
select tests.check('10. the asset points at the invoice - finance still owns it (no amounts on the asset side except the labelled cost snapshot)',
  (select (invoice_id = tests.id('inv:HW'))::text from asset_finance_links where asset_id = tests.id('asset:lap')) || (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'asset_finance_links' and column_name ~ '(amount|total|price|cost)'), 'truenone');
select tests.scalar('web_lead', format('select asset_unassign(%L, ''Project finished'')::text', tests.id('asset:lap')));
select tests.scalar('web_lead', format('select asset_retire(%L, ''Replaced by newer model'')::text', tests.id('asset:lap')));
select tests.scalar('ceo', format('select asset_dispose(%L, ''sold'', current_date, ''Sold to staff'')::text', tests.id('asset:lap')));
select tests.check('11. returned, retired, disposed - and still fully traceable', (select a.status::text || '/' || r.disposal_method::text from assets a join asset_retirements r on r.asset_id = a.id where a.id = tests.id('asset:lap')), 'disposed/sold');

create temp table a360 as select tests.scalar('ceo', format('select asset_360(%L)::text', tests.id('asset:lap')))::jsonb as j;
select tests.check('12. the 360 holds the whole life: 2 assignments, 1 maintenance, 1 ticket, 1 warranty, 1 document, 1 finance link, 1 retirement',
  (select (jsonb_array_length(j -> 'assignment_history') = 2 and jsonb_array_length(j -> 'maintenance') = 1 and jsonb_array_length(j -> 'tickets') = 1 and jsonb_array_length(j -> 'warranties') = 1
           and jsonb_array_length(j -> 'documents') = 1 and jsonb_array_length(j -> 'finance') = 1 and j -> 'retirement' ->> 'disposal_method' = 'sold' and j -> 'holder' = 'null'::jsonb)::text from a360), 'true');
select tests.check('13. every status the asset went through is in its history, in order',
  (select string_agg(to_value, '>' order by id) from asset_history where asset_id = tests.id('asset:lap') and kind in ('created', 'status')), 'proposed>acquired>in_stock>assigned>in_maintenance>assigned>returned>retired>disposed');
select tests.check('14. one asset, one client, one project, one person per assignment - nothing was duplicated',
  (select count(*)::text from assets where serial_key = 'PF3A9X21') || (select count(*)::text from clients where name_key = client_name_key('ABC Renamed Holdings') or name_key = client_name_key('ABC Company')) || (select count(distinct staff_id)::text from asset_assignments where asset_id = tests.id('asset:lap')), '112');
select tests.check('15. the client 360 resolves to the same asset record', (tests.scalar('ceo', format('select client_360(%L)::text', tests.id('client:abc')))::jsonb -> 'assets' -> 0 ->> 'id'), (select ada_id from assets where id = tests.id('asset:lap')));
select tests.check('16. no duplicates were flagged for this laptop', (select count(*)::text from asset_duplicate_flags), '0');

select tests.finish();
rollback;
