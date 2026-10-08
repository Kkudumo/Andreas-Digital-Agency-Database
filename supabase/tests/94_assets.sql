-- Assets: identity, lifecycle, assignment history, duplicates, retirement, audit.
begin;
select tests.setup();
select tests.setup_hr();

-- Creation, IDs, permissions -----------------------------------------------------------------------------------------------------------------
select tests.check('web staff (no assets.create) cannot register assets', tests.mk_asset('web_staff', 'x', 'X'), 'ERR:42501');
select tests.check('Tech''s lead cannot register an asset for Web', tests.mk_asset('tech_lead', 'x', 'X', 'web'), 'ERR:42501');
select tests.check('finance and the auditor can read the register but not register assets', tests.mk_asset('fin', 'x', 'X') || tests.mk_asset('audit', 'x', 'X'), 'ERR:42501ERR:42501');
select tests.check('an unknown category is refused', tests.scalar('web_lead', format('select asset_create(p_name => ''X'', p_category => ''spaceship'', p_division => %L)::text', tests.id('div:web'))), 'ERR:23514');
select tests.check('web lead registers a laptop', (tests.mk_asset('web_lead', 'lap1', 'Lenovo ThinkPad X1', 'web', 'Lenovo', 'PF-3A9X21', 'TAG-0001', 'proposed') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('it has an ADA-AST ID, is registered, and starts as proposed in Web',
  (select (ada_id ~ '^ADA-AST-\d{4}-\d{4}$' and status = 'proposed' and division_id = tests.id('div:web') and created_by = tests.id('staff:web_lead'))::text from assets where id = tests.id('asset:lap1')), 'true');
select tests.check('the registry knows every asset', tests.unregistered_tables(), 'none');
select tests.check('an asset cannot be registered straight into a later state', tests.mk_asset('web_lead', 'x', 'X', 'web', null, null, null, 'assigned'), 'ERR:23514');
select tests.check('assets are never deleted (owner)', tests.try_owner(format('delete from assets where id = %L', tests.id('asset:lap1'))), 'ERR:42501');
select tests.check('users have no write path to the register', tests.try('web_lead', $q$ update assets set name = 'x' $q$) || tests.try('web_lead', $q$ insert into assets (name, category_id, division_id) select 'x', id, id from asset_categories limit 1 $q$), 'ERR:42501ERR:42501');

-- Serial numbers and tags: flag, never merge --------------------------------------------------------------------------------------------------
select tests.check('the same serial from a DIFFERENT manufacturer is a different asset (no flag, no merge)',
  (tests.mk_asset('web_lead', 'dell', 'Dell Latitude', 'web', 'Dell', 'PF-3A9X21') ~ '^[0-9a-f-]{36}$')::text || (select count(*)::text from asset_duplicate_flags), 'true0');
select tests.check('the same manufacturer and serial, written differently, is created (not refused)', (tests.mk_asset('web_lead', 'lap2', 'ThinkPad (second entry)', 'web', 'LENOVO', 'pf 3a9x-21') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('...and FLAGGED for review, not merged', (select count(*)::text || string_agg(reason, ',') from asset_duplicate_flags), '1same_serial');
select tests.check('...both assets still exist as separate records', (select count(*)::text from assets where serial_key = 'PF3A9X21'), '3');
select tests.check('a matching serial with no known maker is created', (tests.mk_asset('web_lead', 'lap3', 'Mystery laptop', 'web', null, 'PF3A9X21') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('...and flagged against every asset sharing that serial, for review', (select count(*)::text from asset_duplicate_flags where reason = 'same_serial_unknown_maker'), '3');
select tests.check('blank serials never match each other', (tests.mk_asset('web_lead', 'b1', 'No serial 1', 'web') ~ '^[0-9a-f-]{36}$')::text || (tests.mk_asset('web_lead', 'b2', 'No serial 2', 'web') ~ '^[0-9a-f-]{36}$')::text, 'truetrue');
select tests.check('...no new flags', (select count(*)::text from asset_duplicate_flags), '4');
select tests.check('web lead sees the flags on assets they can see', tests.scalar('web_lead', 'select count(*)::text from asset_duplicate_flags'), '4');
select tests.check('a flag needs a note to resolve', tests.scalar('web_lead', 'select asset_flag_resolve((select id from asset_duplicate_flags where reason = ''same_serial''), ''dismissed'', '' '')::text'), 'ERR:23514');
select tests.check('a person decides the flag (dismissed: these really are different machines)', tests.try('web_lead', 'select asset_flag_resolve((select id from asset_duplicate_flags where reason = ''same_serial''), ''dismissed'', ''Different asset tags and locations'')'), 'ok');
select tests.check('...a reviewed flag is final', tests.scalar('web_lead', 'select asset_flag_resolve((select id from asset_duplicate_flags where reason = ''same_serial''), ''confirmed_duplicate'', ''x'')::text'), 'ERR:23514');
select tests.check('a visible duplicate TAG is refused (tags are labels on the item), whatever the case', tests.mk_asset('web_lead', 'x', 'Tag clash', 'web', null, null, 'tag-0001'), 'ERR:23505');
select tests.check('an asset keeps its own distinct identity: nothing was merged or re-pointed', (select count(distinct id)::text from assets), '6');

-- Lifecycle is controlled for every caller --------------------------------------------------------------------------------------------------------
select tests.check('proposed cannot jump to in stock', tests.scalar('web_lead', format('select asset_transition(%L, ''in_stock'')::text', tests.id('asset:lap1'))), 'ERR:23514');
select tests.check('the database refuses it for the owner too', tests.try_owner(format('update assets set status = ''in_stock'' where id = %L', tests.id('asset:lap1'))), 'ERR:23514');
select tests.check('web staff cannot move assets through the lifecycle', tests.scalar('web_staff', format('select asset_transition(%L, ''acquired'')::text', tests.id('asset:lap1'))), 'ERR:42501');
select tests.check('the proposal is acquired', tests.scalar('web_lead', format('select asset_transition(%L, ''acquired'')::text', tests.id('asset:lap1'))), 'acquired');
select tests.check('...the acquisition date defaults to today', (select (acquisition_date = current_date)::text from assets where id = tests.id('asset:lap1')), 'true');
select tests.check('...then into stock', tests.scalar('web_lead', format('select asset_transition(%L, ''in_stock'', ''Received and tagged'')::text', tests.id('asset:lap1'))), 'in_stock');
select tests.check('assignment, retirement and disposal have their own commands (no back door through transition)',
  tests.scalar('web_lead', format('select asset_transition(%L, ''assigned'')::text', tests.id('asset:lap1'))) || tests.scalar('web_lead', format('select asset_transition(%L, ''retired'')::text', tests.id('asset:lap1'))) || tests.scalar('web_lead', format('select asset_transition(%L, ''disposed'')::text', tests.id('asset:lap1'))), 'ERR:23514ERR:23514ERR:23514');
select tests.mk_asset('web_lead', 'prop', 'Proposed monitor', 'web', null, null, null, 'proposed');
select tests.check('a proposal that never happened needs a reason to be cancelled', tests.scalar('web_lead', format('select asset_transition(%L, ''cancelled'')::text', tests.id('asset:prop'))), 'ERR:23514');
select tests.check('...and then it is final', tests.scalar('web_lead', format('select asset_transition(%L, ''cancelled'', ''Never ordered'')::text', tests.id('asset:prop'))), 'cancelled');
select tests.check('...for every caller', tests.try_owner(format('update assets set status = ''acquired'' where id = %L', tests.id('asset:prop'))), 'ERR:23514');

-- Assignment is history, not a field ---------------------------------------------------------------------------------------------------------------
select tests.check('the asset table has no holder column: assignment is a separate history',
  (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name = 'assets' and column_name ~ '(assign|holder|staff|owner_id|user)'), 'none');
select tests.check('web staff cannot assign', tests.scalar('web_staff', format('select asset_assign(%L, %L)::text', tests.id('asset:lap1'), tests.id('staff:web_staff'))), 'ERR:42501');
select tests.check('only active staff can hold an asset', tests.scalar('web_lead', format('select asset_assign(%L, %L)::text', tests.id('asset:lap1'), tests.id('staff:suspended'))), 'ERR:23514');
select tests.check('web lead assigns the laptop to a Web staff member', (tests.scalar('web_lead', format('select asset_assign(%L, %L, null, ''Onboarding'')::text', tests.id('asset:lap1'), tests.id('staff:web_staff'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the asset is assigned and the holder is derived from the open assignment',
  (select status::text from assets where id = tests.id('asset:lap1')) || '/' || (select staff_id = tests.id('staff:web_staff') and division_id = tests.id('div:web') from asset_current_assignments where asset_id = tests.id('asset:lap1'))::text, 'assigned/true');
select tests.check('the one-open-assignment rule is backed by a unique partial index (race-proof, not only a trigger)',
  (select count(*)::text from pg_indexes where tablename = 'asset_assignments' and indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%ended_at IS NULL%'), '1');
select tests.check('an asset cannot have two open assignments (the database refuses it for the owner)',
  tests.try_owner(format('insert into asset_assignments (asset_id, staff_id, division_id) values (%L, %L, %L)', tests.id('asset:lap1'), tests.id('staff:tech_staff'), tests.id('div:tech'))), 'ERR:23505');
select tests.check('...nor an overlapping historic period',
  tests.try_owner(format('insert into asset_assignments (asset_id, staff_id, division_id, started_at, ended_at, end_reason) values (%L, %L, %L, now() - interval ''1 day'', now() + interval ''1 day'', ''x'')', tests.id('asset:lap1'), tests.id('staff:tech_staff'), tests.id('div:tech'))), 'ERR:23505');
select tests.check('web lead cannot move it to Tech (no assets.assign there)', tests.scalar('web_lead', format('select asset_assign(%L, %L, %L)::text', tests.id('asset:lap1'), tests.id('staff:tech_staff'), tests.id('div:tech'))), 'ERR:42501');
select tests.check('management moves the laptop to a Tech staff member: a NEW assignment, the old one is ended',
  (tests.scalar('ceo', format('select asset_assign(%L, %L, %L, ''Moved to Tech'')::text', tests.id('asset:lap1'), tests.id('staff:tech_staff'), tests.id('div:tech'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('history now holds both periods; only the new one is open',
  (select string_agg((staff_id = tests.id('staff:web_staff'))::text || ':' || (ended_at is not null)::text || ':' || coalesce(end_reason, '-'), ',' order by ended_at nulls last) from asset_assignments where asset_id = tests.id('asset:lap1')), 'true:true:reassigned,false:false:-');
select tests.check('responsibility moved with the assignment (and that is logged)', (select division_id = tests.id('div:tech') from assets where id = tests.id('asset:lap1'))::text || (select count(*)::text from asset_history where asset_id = tests.id('asset:lap1') and field = 'division_id'), 'true1');
select tests.check('an assignment cannot be edited or deleted: history cannot be rewritten (owner)',
  tests.try_owner(format('update asset_assignments set staff_id = %L where asset_id = %L', tests.id('staff:ceo'), tests.id('asset:lap1'))) || tests.try_owner(format('delete from asset_assignments where asset_id = %L', tests.id('asset:lap1'))) ||
  tests.try_owner(format('update asset_assignments set ended_at = now(), end_reason = ''x'' where asset_id = %L and ended_at is not null', tests.id('asset:lap1'))), 'ERR:42501ERR:42501ERR:42501');
select tests.check('the new division sees it', tests.scalar('tech_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:lap1'))) || tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:lap1'))), '10');
select tests.check('unassigning needs a reason', tests.scalar('ceo', format('select asset_unassign(%L, '' '')::text', tests.id('asset:lap1'))), 'ERR:23514');
select tests.scalar('ceo', format('select asset_unassign(%L, ''Returned by user'')::text', tests.id('asset:lap1')));
select tests.check('removing the assignment moves the asset to returned and keeps every historical row',
  (select status::text from assets where id = tests.id('asset:lap1')) || '/' || (select count(*)::text from asset_assignments where asset_id = tests.id('asset:lap1')) || '/' || (select count(*)::text from asset_current_assignments where asset_id = tests.id('asset:lap1')), 'returned/2/0');
select tests.check('an asset with no open assignment cannot be unassigned again', tests.scalar('ceo', format('select asset_unassign(%L, ''x'')::text', tests.id('asset:lap1'))), 'ERR:23514');
-- A holder sees the asset they hold even from outside its division, and loses sight of it when the assignment ends
select tests.mk_asset('web_lead', 'loan', 'Loaned projector', 'web');
select tests.check('before it is loaned out, a Tech member cannot see a Web asset', tests.scalar('tech_staff', format('select count(*)::text from assets where id = %L', tests.id('asset:loan'))), '0');
select tests.scalar('web_lead', format('select asset_assign(%L, %L, %L, ''Loan'')::text', tests.id('asset:loan'), tests.id('staff:tech_staff'), tests.id('div:web')));
select tests.check('the holder sees the asset they hold without any register permission in its division', tests.scalar('tech_staff', format('select count(*)::text from assets where id = %L', tests.id('asset:loan'))), '1');
select tests.check('...but not the rest of the Web register', tests.scalar('tech_staff', format('select count(*)::text from assets where division_id = %L and id <> %L', tests.id('div:web'), tests.id('asset:loan'))), '0');
select tests.scalar('web_lead', format('select asset_unassign(%L, ''Loan over'')::text', tests.id('asset:loan')));
select tests.check('when the assignment ends the holder loses sight of it', tests.scalar('tech_staff', format('select count(*)::text from assets where id = %L', tests.id('asset:loan'))), '0');
select tests.check('assigning to a division pool (no person) is allowed', (tests.scalar('ceo', format('select asset_assign(%L, null, %L, ''Shared pool'')::text', tests.id('asset:lap1'), tests.id('div:web'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.scalar('ceo', format('select asset_unassign(%L, ''Back to stock'')::text', tests.id('asset:lap1')));

-- Updates are whitelisted and logged ---------------------------------------------------------------------------------------------------------------
select tests.check('status, division and ids are not editable through asset_update', tests.scalar('ceo', format('select asset_update(%L, ''{"status": "in_stock"}'')::text', tests.id('asset:lap1'))) || tests.scalar('ceo', format('select asset_update(%L, ''{"ada_id": "X"}'')::text', tests.id('asset:lap1'))), 'ERR:22023ERR:22023');
select tests.check('a tech lead cannot edit a Web asset', tests.scalar('tech_lead', format('select asset_update(%L, ''{"notes": "x"}'')::text', tests.id('asset:lap1'))), 'ERR:P0002');
select tests.check('condition and location changes are applied and recorded with old and new value',
  tests.try('ceo', format('select asset_update(%L, ''{"condition": "fair", "current_location": "Store room B"}'')', tests.id('asset:lap1'))), 'ok');
select tests.check('...with old and new value in the history', (select string_agg(field || ':' || coalesce(from_value, '-') || '>' || to_value, ',' order by field) from asset_history where asset_id = tests.id('asset:lap1') and kind = 'field' and field in ('condition', 'current_location')), 'condition:good>fair,current_location:->Store room B');
select tests.check('changing the classification needs records.classify', tests.scalar('web_lead', format('select asset_update(%L, ''{"classification": "restricted"}'')::text', tests.id('asset:lap2'))), 'ERR:42501');
select tests.check('acquisition cost is recorded with its currency', tests.try('ceo', format('select asset_update(%L, ''{"acquisition_cost": 21500, "acquisition_currency": "NAD", "acquisition_method": "purchased"}'')', tests.id('asset:lap1'))), 'ok');
select tests.check('...as stored', (select acquisition_cost::text || acquisition_currency from assets where id = tests.id('asset:lap1')), '21500.00NAD');
select tests.check('a cost without a currency is refused', tests.scalar('ceo', format('select asset_update(%L, ''{"acquisition_currency": null}'')::text', tests.id('asset:lap1'))), 'ERR:23514');
select tests.check('the cost column is documented as a snapshot, not a financial record', (select (col_description('assets'::regclass, ordinal_position) like 'SNAPSHOT:%')::text from information_schema.columns where table_schema = 'public' and table_name = 'assets' and column_name = 'acquisition_cost'), 'true');

-- Components -----------------------------------------------------------------------------------------------------------------------------------
select tests.mk_asset('web_lead', 'dock', 'USB-C dock', 'web');
select tests.check('a component can be attached to a parent asset', tests.try('web_lead', format('select asset_set_parent(%L, %L)', tests.id('asset:dock'), tests.id('asset:lap1'))), 'ok');
select tests.check('an asset cannot be its own ancestor', tests.scalar('web_lead', format('select asset_set_parent(%L, %L)::text', tests.id('asset:lap1'), tests.id('asset:dock'))) || tests.scalar('web_lead', format('select asset_set_parent(%L, %L)::text', tests.id('asset:lap1'), tests.id('asset:lap1'))), 'ERR:23514ERR:23514');
select tests.check('a parent with live components cannot be retired', tests.scalar('web_lead', format('select asset_retire(%L, ''Old'')::text', tests.id('asset:lap1'))), 'ERR:23514');

-- Retirement is not deletion ----------------------------------------------------------------------------------------------------------------------
select tests.scalar('web_lead', format('select asset_set_parent(%L, null)::text', tests.id('asset:dock')));
select tests.check('retiring needs a reason', tests.scalar('web_lead', format('select asset_retire(%L, '' '')::text', tests.id('asset:lap1'))), 'ERR:23514');
select tests.check('an assigned asset must be returned before it is retired', (select tests.scalar('ceo', format('select asset_assign(%L, %L)::text', tests.id('asset:dock'), tests.id('staff:web_staff'))) is not null)::text || tests.scalar('web_lead', format('select asset_retire(%L, ''Old'')::text', tests.id('asset:dock'))), 'trueERR:23514');
select tests.check('web staff cannot retire', tests.scalar('web_staff', format('select asset_retire(%L, ''Old'')::text', tests.id('asset:lap1'))), 'ERR:42501');
select tests.check('web lead retires the laptop', tests.try('web_lead', format('select asset_retire(%L, ''End of life, battery failure'')', tests.id('asset:lap1'))), 'ok');
select tests.check('retired is not deleted: the record, its retirement and its history remain',
  (select status::text from assets where id = tests.id('asset:lap1')) || '/' || (select reason from asset_retirements where asset_id = tests.id('asset:lap1')) || '/' || (select count(*)::text from asset_assignments where asset_id = tests.id('asset:lap1')), 'retired/End of life, battery failure/3');
select tests.check('a retired asset cannot silently return to active status (function)', tests.scalar('ceo', format('select asset_transition(%L, ''in_stock'')::text', tests.id('asset:lap1'))) || tests.scalar('ceo', format('select asset_assign(%L, %L)::text', tests.id('asset:lap1'), tests.id('staff:web_staff'))), 'ERR:23514ERR:23514');
select tests.check('...nor through the database (owner)', tests.try_owner(format('update assets set status = ''in_stock'' where id = %L', tests.id('asset:lap1'))) || tests.try_owner(format('update assets set status = ''assigned'' where id = %L', tests.id('asset:lap1'))), 'ERR:23514ERR:23514');
select tests.check('a retired asset''s record is frozen (owner and users)', tests.try_owner(format('update assets set name = ''Renamed'' where id = %L', tests.id('asset:lap1'))) || tests.scalar('ceo', format('select asset_update(%L, ''{"condition": "good"}'')::text', tests.id('asset:lap1'))), 'ERR:42501ERR:42501');
select tests.check('...though a note can still be added', tests.try('ceo', format('select asset_update(%L, ''{"notes": "Battery swollen"}'')', tests.id('asset:lap1'))), 'ok');
select tests.check('the retirement record cannot be rewritten', tests.try_owner(format('update asset_retirements set reason = ''x'' where asset_id = %L', tests.id('asset:lap1'))) || tests.try_owner('delete from asset_retirements'), 'ERR:42501ERR:42501');
select tests.check('only management disposes', tests.scalar('web_lead', format('select asset_dispose(%L, ''recycled'')::text', tests.id('asset:lap1'))), 'ERR:42501');
select tests.check('an asset that is not retired cannot be disposed', tests.scalar('ceo', format('select asset_dispose(%L, ''recycled'')::text', tests.id('asset:dock'))), 'ERR:23514');
select tests.check('management disposes of the retired laptop', tests.try('ceo', format('select asset_dispose(%L, ''recycled'', current_date, ''E-waste partner'')', tests.id('asset:lap1'))), 'ok');
select tests.check('disposal is recorded and the asset is still traceable', (select a.status::text || '/' || r.disposal_method::text from assets a join asset_retirements r on r.asset_id = a.id where a.id = tests.id('asset:lap1')), 'disposed/recycled');
select tests.check('disposed is terminal', tests.try_owner(format('update assets set status = ''retired'' where id = %L', tests.id('asset:lap1'))), 'ERR:23514');
select tests.check('a disposal cannot be recorded twice', tests.try_owner(format('update asset_retirements set disposal_note = ''again'' where asset_id = %L', tests.id('asset:lap1'))), 'ERR:42501');

-- Audit history cannot be rewritten -------------------------------------------------------------------------------------------------------------------
select tests.check('the asset history is append-only (owner)', tests.try_owner(format('update asset_history set note = ''x'' where asset_id = %L', tests.id('asset:lap1'))) || tests.try_owner(format('delete from asset_history where asset_id = %L', tests.id('asset:lap1'))), 'ERR:42501ERR:42501');
select tests.check('the story of the laptop is complete and in order',
  (select string_agg(coalesce(field, kind) || ':' || coalesce(to_value, '-'), ' > ' order by id) from asset_history where asset_id = tests.id('asset:lap1') and (kind = 'status' or kind = 'created')),
  'created:proposed > status:acquired > status:in_stock > status:assigned > status:returned > status:assigned > status:returned > status:retired > status:disposed');
select tests.check('audit_log has the row-level trail and it survives retirement and disposal',
  (select (count(*) filter (where action = 'INSERT') >= 1 and count(*) filter (where action = 'UPDATE') >= 6)::text from audit_log where table_name = 'assets' and record_id = tests.id('asset:lap1')), 'true');
select tests.check('audit rows cannot be rewritten', tests.try_owner(format('update audit_log set action = ''x'' where record_id = %L', tests.id('asset:lap1'))), 'ERR:42501');

-- Cross-division slices ---------------------------------------------------------------------------------------------------------------------------------
select tests.mk_asset('tech_lead', 'tech1', 'Tech server', 'tech');
select tests.check('each division sees its own assets and not the other''s',
  tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:tech1'))) || tests.scalar('tech_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:tech1'))) ||
  tests.scalar('tech_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:dock'))), '010');
select tests.check('management, administration, finance and the auditor see the whole (non-restricted) register',
  tests.scalar('ceo', 'select (count(*) >= 6)::text from assets') || tests.scalar('admin', 'select (count(*) >= 6)::text from assets') || tests.scalar('fin', 'select (count(*) >= 6)::text from assets') || tests.scalar('audit', 'select (count(*) >= 6)::text from assets'), 'truetruetruetrue');
select tests.check('the recruiter sees no assets', tests.scalar('recruiter', 'select count(*)::text from assets'), '0');
select tests.check('children of an asset (history, assignments, retirements) follow its visibility',
  tests.scalar('tech_lead', 'select (select count(*) from asset_history)::text || (select count(*) from asset_assignments where asset_id in (select id from assets where division_id = ' || quote_literal(tests.id('div:web')) || '))'), (select count(*)::text from asset_history where asset_id = tests.id('asset:tech1')) || '0');

select tests.finish();
rollback;
