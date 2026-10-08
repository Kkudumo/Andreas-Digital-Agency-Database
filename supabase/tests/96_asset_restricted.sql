-- PERMANENT REGRESSION SUITE: assets, tickets, maintenance, documents, warranties and finance links of a restricted client or
-- project are indistinguishable from non-existent records to anyone who may not know they exist - through errors, counts, lookups
-- (by id, client, serial, tag), helper functions, 360 views and duplicate detection - and classification propagates in both directions.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.bank_account('nad');
insert into tests.ids values ('x:random', gen_random_uuid());

-- Ordinary world first (controls) ----------------------------------------------------------------------------------------------------------------------------
select tests.check('A: asset for the client and project', (tests.mk_asset('web_lead', 'A', 'Client laptop', 'web', 'Acme', 'RS-001', 'TAG-R', 'in_stock', 'client:abc', 'project:abc') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('S: an ordinary standalone asset', (tests.mk_asset('web_lead', 'S', 'Standalone', 'web') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('P/C: a parent asset with a component', (tests.mk_asset('web_lead', 'P', 'Parent rack', 'web') ~ '^[0-9a-f-]{36}$')::text || (tests.mk_asset('web_lead', 'C', 'Child switch', 'web', null, null, null, 'in_stock', null, null, 'asset:P') ~ '^[0-9a-f-]{36}$')::text, 'truetrue');
select tests.scalar('web_lead', format('select asset_assign(%L, %L)::text', tests.id('asset:A'), tests.id('staff:web_staff')));
select tests.remember('tkt:A', tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'Client laptop fault', p_asset => %L)::text $q$, tests.id('asset:A'))));
select tests.remember('mnt:A', tests.scalar('web_staff', format($q$ select maintenance_schedule(%L, 'inspection', 'Quarterly check')::text $q$, tests.id('asset:A'))));
select tests.remember('doc:A', tests.scalar('web_lead', format($q$ select asset_add_document(%L, 'manual', 'Manual', 'drive://manual.pdf')::text $q$, tests.id('asset:A'))));
select tests.remember('war:A', tests.scalar('web_lead', format($q$ select asset_add_warranty(%L, current_date - 10, current_date + 300)::text $q$, tests.id('asset:A'))));
select tests.issued_invoice('AI', 'client:abc', 900);
select tests.remember('link:A', tests.scalar('ceo', format($q$ select asset_link_finance(%L, %L, null, 'hardware_charge')::text $q$, tests.id('asset:A'), tests.id('inv:AI'))));
select tests.mk_asset('web_lead', 'dup0', 'Marker', 'web');
select tests.check('control: the division lead, the holder and finance see the client asset and everything attached to it',
  tests.scalar('web_lead', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L) || (select count(*) from asset_maintenance where id = %L) || (select count(*) from asset_documents where id = %L) || (select count(*) from asset_warranties where id = %L) || (select count(*) from asset_assignments where asset_id = %L)', tests.id('asset:A'), tests.id('tkt:A'), tests.id('mnt:A'), tests.id('doc:A'), tests.id('war:A'), tests.id('asset:A'))) ||
  tests.scalar('web_staff', format('select count(*)::text from assets where id = %L', tests.id('asset:A'))) || tests.scalar('fin', format('select count(*)::text from assets where id = %L', tests.id('asset:A'))), '111111' || '1' || '1');
select tests.check('control: the probes can tell a visible asset from a missing one', left(tests.same_for('web_lead', $q$ select can_view_asset(%L)::text $q$, tests.id('asset:A'), tests.id('x:random')), 9), 'DIFFERENT');

-- The client becomes restricted ---------------------------------------------------------------------------------------------------------------------------
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('propagation: the client''s asset, ticket inherit the restriction; unrelated assets do not',
  (select (select effective_classification::text from assets where id = tests.id('asset:A')) || '/' || (select effective_classification::text from tickets where id = tests.id('tkt:A')) || '/' || (select effective_classification::text from assets where id = tests.id('asset:S'))), 'restricted/restricted/internal');
select tests.check('web lead, the holder, a Tech lead and finance see none of it (all tables)',
  tests.scalar('web_lead', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L) || (select count(*) from asset_maintenance) || (select count(*) from asset_documents) || (select count(*) from asset_warranties) || (select count(*) from asset_assignments) || (select count(*) from asset_history where asset_id = %L) || (select count(*) from asset_finance_links) || (select count(*) from asset_current_assignments) || (select count(*) from asset_warranty_status where asset_id = %L)', tests.id('asset:A'), tests.id('tkt:A'), tests.id('asset:A'), tests.id('asset:A'))), '000000000' || '0');
select tests.check('...the holder loses sight of the asset they hold (classification still applies)', tests.scalar('web_staff', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L)', tests.id('asset:A'), tests.id('tkt:A'))), '00');
select tests.check('...finance', tests.scalar('fin', format('select (select count(*) from assets where id = %L)::text || (select count(*) from asset_finance_links) || (select count(*) from tickets)', tests.id('asset:A'))), '000');
select tests.check('the whole visible register shows no trace of it', tests.scalar('web_lead', 'select string_agg(name, '','' order by name) from assets'), 'Child switch,Marker,Parent rack,Standalone');
select tests.check('360 views: asset, client and project are null for them',
  tests.scalar('web_lead', format('select coalesce(asset_360(%L)::text, ''null'')', tests.id('asset:A'))) || tests.scalar('web_lead', format('select coalesce(client_360(%L)::text, ''null'')', tests.id('client:abc'))) || tests.scalar('web_lead', format('select coalesce(project_360(%L)::text, ''null'')', tests.id('project:abc'))), 'nullnullnull');
select tests.check('authorised: management, administration and the auditor still see the asset and its slices',
  tests.scalar('ceo', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L) || (select count(*) from asset_documents)', tests.id('asset:A'), tests.id('tkt:A'))) ||
  tests.scalar('admin', format('select count(*)::text from assets where id = %L', tests.id('asset:A'))) || tests.scalar('audit', format('select count(*)::text from assets where id = %L', tests.id('asset:A'))), '11111');
select tests.check('authorised: the restricted client''s 360 lists its asset for management', tests.scalar('ceo', format('select jsonb_array_length(client_360(%L) -> ''assets'')::text', tests.id('client:abc'))), '1');

-- Identical outcomes: restricted id vs random id -------------------------------------------------------------------------------------------------------------
select tests.check('reads: by id', tests.same_for('web_lead', $q$ select count(*)::text from assets where id = %L $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('reads: by client', tests.same_for('web_lead', $q$ select count(*)::text from assets where client_id = %L $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('reads: by project', tests.same_for('web_lead', $q$ select count(*)::text from assets where project_id = %L $q$, tests.id('project:abc'), tests.id('x:random')), 'same');
select tests.check('reads: tickets by client', tests.same_for('web_lead', $q$ select count(*)::text from tickets where client_id = %L $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('reads: tickets by asset', tests.same_for('web_lead', $q$ select count(*)::text from tickets where asset_id = %L $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('reads: history by asset', tests.same_for('web_lead', $q$ select count(*)::text from asset_history where asset_id = %L $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('reads: by serial number', tests.outcome('web_lead', $q$ select count(*)::text from assets where serial_key = 'RS001' $q$), tests.outcome('web_lead', $q$ select count(*)::text from assets where serial_key = 'ZZ999' $q$));
select tests.check('reads: by asset tag', tests.outcome('web_lead', $q$ select count(*)::text from assets where lower(asset_tag) = 'tag-r' $q$), tests.outcome('web_lead', $q$ select count(*)::text from assets where lower(asset_tag) = 'tag-zz' $q$));
select tests.check('reads: by name search', tests.outcome('web_lead', $q$ select count(*)::text from assets where name ilike '%client laptop%' $q$), tests.outcome('web_lead', $q$ select count(*)::text from assets where name ilike '%no such thing%' $q$));
select tests.check('helper: can_view_asset', tests.same_for('web_lead', $q$ select can_view_asset(%L)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('helper: can_edit_asset', tests.same_for('web_lead', $q$ select can_edit_asset(%L)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('helper: can_view_ticket', tests.same_for('web_lead', $q$ select can_view_ticket(%L)::text $q$, tests.id('tkt:A'), tests.id('x:random')), 'same');
select tests.check('helper: asset_360', tests.same_for('web_lead', $q$ select coalesce(asset_360(%L)::text, 'null') $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_update', tests.same_for('web_lead', $q$ select asset_update(%L, '{"notes": "probe"}')::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_transition', tests.same_for('web_lead', $q$ select asset_transition(%L, 'in_stock')::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_assign', tests.same_for('web_lead', $q$ select asset_assign(%L, (select id from tests.ids where key = 'staff:web_staff'))::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_unassign', tests.same_for('web_lead', $q$ select asset_unassign(%L, 'probe')::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_retire', tests.same_for('web_lead', $q$ select asset_retire(%L, 'probe')::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_set_parent', tests.same_for('web_lead', $q$ select asset_set_parent(%L, null)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_set_parent using the restricted asset AS the parent', tests.same_for('web_lead', $q$ select asset_set_parent((select id from tests.ids where key = 'asset:S'), %L)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_add_document', tests.same_for('web_lead', $q$ select asset_add_document(%L, 'manual', 'probe', 'ref')::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_add_warranty', tests.same_for('web_lead', $q$ select asset_add_warranty(%L, current_date, current_date + 1)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_void_document', tests.same_for('web_lead', $q$ select asset_void_document(%L, 'probe')::text $q$, tests.id('doc:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_void_warranty', tests.same_for('web_lead', $q$ select asset_void_warranty(%L, 'probe')::text $q$, tests.id('war:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_link_finance', tests.same_for('web_lead', $q$ select asset_link_finance(%L, (select id from tests.ids where key = 'inv:AI'))::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: maintenance_schedule', tests.same_for('web_staff', $q$ select maintenance_schedule(%L, 'repair', 'probe')::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: maintenance_start', tests.same_for('web_staff', $q$ select maintenance_start(%L)::text $q$, tests.id('mnt:A'), tests.id('x:random')), 'same');
select tests.check('commands: maintenance_complete', tests.same_for('web_staff', $q$ select maintenance_complete(%L, 'probe')::text $q$, tests.id('mnt:A'), tests.id('x:random')), 'same');
select tests.check('commands: maintenance_cancel', tests.same_for('web_staff', $q$ select maintenance_cancel(%L, 'probe')::text $q$, tests.id('mnt:A'), tests.id('x:random')), 'same');
select tests.check('commands: ticket_create against the asset', tests.same_for('web_staff', $q$ select ticket_create(p_title => 'probe', p_asset => %L)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: ticket_create against the client', tests.same_for('web_lead', $q$ select ticket_create(p_title => 'probe', p_division => (select id from tests.ids where key = 'div:web'), p_client => %L)::text $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('commands: ticket_assign', tests.same_for('web_lead', $q$ select ticket_assign(%L, (select id from tests.ids where key = 'staff:web_staff'))::text $q$, tests.id('tkt:A'), tests.id('x:random')), 'same');
select tests.check('commands: ticket_transition', tests.same_for('web_staff', $q$ select ticket_transition(%L, 'in_progress')::text $q$, tests.id('tkt:A'), tests.id('x:random')), 'same');
select tests.check('commands: asset_create for the restricted client', tests.same_for('web_lead', $q$ select asset_create(p_name => 'probe', p_category => 'laptop', p_division => (select id from tests.ids where key = 'div:web'), p_client => %L)::text $q$, tests.id('client:abc'), tests.id('x:random')), 'same');
select tests.check('commands: asset_create under the restricted project', tests.same_for('web_lead', $q$ select asset_create(p_name => 'probe', p_category => 'laptop', p_division => (select id from tests.ids where key = 'div:web'), p_project => %L)::text $q$, tests.id('project:abc'), tests.id('x:random')), 'same');
select tests.check('commands: asset_create as a component of the restricted asset', tests.same_for('web_lead', $q$ select asset_create(p_name => 'probe', p_category => 'laptop', p_division => (select id from tests.ids where key = 'div:web'), p_parent => %L)::text $q$, tests.id('asset:A'), tests.id('x:random')), 'same');
select tests.check('commands: a ticket for a restricted asset sends no notification', (select count(*)::text from notifications where type = 'ticket.assigned'), '0');

-- Duplicate detection cannot reveal a hidden asset ------------------------------------------------------------------------------------------------------------
select tests.check('registering an asset with the hidden asset''s serial and maker behaves exactly like a fresh serial',
  tests.outcome('web_lead', format($q$ select (asset_create(p_name => 'Look-alike', p_category => 'laptop', p_division => %L, p_manufacturer => 'Acme', p_serial => 'RS-001') is not null)::text $q$, tests.id('div:web'))),
  tests.outcome('web_lead', format($q$ select (asset_create(p_name => 'Fresh', p_category => 'laptop', p_division => %L, p_manufacturer => 'Acme', p_serial => 'ZZ-777') is not null)::text $q$, tests.id('div:web'))));
select tests.check('...and with the hidden asset''s tag, too',
  tests.outcome('web_lead', format($q$ select (asset_create(p_name => 'Tag twin', p_category => 'laptop', p_division => %L, p_tag => 'TAG-R') is not null)::text $q$, tests.id('div:web'))),
  tests.outcome('web_lead', format($q$ select (asset_create(p_name => 'Tag fresh', p_category => 'laptop', p_division => %L, p_tag => 'TAG-FRESH') is not null)::text $q$, tests.id('div:web'))));
select tests.check('the flags were raised, and management can see them', tests.scalar('ceo', 'select count(*)::text from asset_duplicate_flags where reason in (''same_serial'', ''same_tag'')'), '2');
select tests.check('the division lead sees no flag that involves the hidden asset', tests.scalar('web_lead', 'select count(*)::text from asset_duplicate_flags'), '0');
select tests.check('...nor can they resolve one', tests.same_for('web_lead', $q$ select asset_flag_resolve(%L, 'dismissed', 'probe')::text $q$, (select id from asset_duplicate_flags limit 1), tests.id('x:random')), 'same');
select tests.check('...and the look-alike''s own 360 reveals no possible duplicates', tests.scalar('web_lead', 'select jsonb_array_length(asset_360((select id from assets where name = ''Look-alike'')) -> ''possible_duplicates'')::text'), '0');

-- Components, projects ---------------------------------------------------------------------------------------------------------------------------------------
update assets set classification = 'restricted' where id = tests.id('asset:P');
select tests.check('a restricted parent restricts its component (and the component vanishes for ordinary users)',
  (select effective_classification::text from assets where id = tests.id('asset:C')) || tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:C'))), 'restricted0');
update assets set classification = 'internal' where id = tests.id('asset:P');
select tests.check('...the component is visible again', tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:C'))), '1');

update clients set classification = 'internal' where id = tests.id('client:abc');
select tests.check('un-restricting the client restores the asset, ticket and attachments',
  tests.scalar('web_lead', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L) || (select count(*) from asset_documents where id = %L) || (select count(*) from asset_maintenance where id = %L)', tests.id('asset:A'), tests.id('tkt:A'), tests.id('doc:A'), tests.id('mnt:A'))), '1111');
update projects set classification = 'restricted' where id = tests.id('project:abc');
select tests.check('a restricted PROJECT hides its linked assets and tickets from people who are not allowed it (here a Web staff member; the client itself stays visible)',
  tests.scalar('web_staff', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L) || (select count(*) from clients where id = %L)', tests.id('asset:A'), tests.id('tkt:A'), tests.id('client:abc'))), '001');
select tests.check('...even the project''s own account manager (a member) does not see its assets while the project is restricted',
  tests.scalar('web_lead', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L)', tests.id('asset:A'), tests.id('tkt:A'))), '00');
select tests.check('...project-keyed lookups reveal nothing', tests.same_for('web_staff', $q$ select count(*)::text from assets where project_id = %L $q$, tests.id('project:abc'), tests.id('x:random')), 'same');
select tests.check('...nor can anyone attach a new asset or ticket to the restricted project', tests.same_for('web_lead', $q$ select asset_create(p_name => 'probe2', p_category => 'laptop', p_division => (select id from tests.ids where key = 'div:web'), p_project => %L)::text $q$, tests.id('project:abc'), tests.id('x:random')), 'same');
select tests.check('...while management still sees them in the project 360', tests.scalar('ceo', format('select jsonb_array_length(project_360(%L) -> ''assets'')::text', tests.id('project:abc'))), '1');
update projects set classification = 'internal' where id = tests.id('project:abc');
select tests.check('un-restricting the project brings them back', tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:A'))), '1');

-- An asset attached to a client ONLY (no project, no parent) inherits the client's restriction by itself
select tests.mk_asset('web_lead', 'CO', 'Client-only router', 'web', null, null, null, 'in_stock', 'client:abc');
select tests.check('before: the client-only asset is visible to the division lead', tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:CO'))), '1');
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('a client-only asset (no project, no parent) is restricted with its client and invisible to ordinary users',
  (select effective_classification::text from assets where id = tests.id('asset:CO')) || tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:CO'))), 'restricted0');
update clients set classification = 'internal' where id = tests.id('client:abc');
select tests.check('...and visible again when the client is un-restricted', tests.scalar('web_lead', format('select count(*)::text from assets where id = %L', tests.id('asset:CO'))), '1');

-- A ticket inherits the asset's OWN classification as well
select tests.remember('tkt:S', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'Standalone fault', p_asset => %L)::text $q$, tests.id('asset:S'))));
select tests.check('before: the ticket on an ordinary asset is internal and visible', (select effective_classification::text from tickets where id = tests.id('tkt:S')) || tests.scalar('web_lead', format('select count(*)::text from tickets where id = %L', tests.id('tkt:S'))), 'internal1');
update assets set classification = 'confidential' where id = tests.id('asset:S');
select tests.check('classifying the asset classifies its tickets (stricter wins) and hides them from ordinary users',
  (select effective_classification::text from tickets where id = tests.id('tkt:S')) || tests.scalar('web_lead', format('select count(*)::text from tickets where id = %L', tests.id('tkt:S'))), 'confidential0');
update assets set classification = 'internal' where id = tests.id('asset:S');
select tests.check('...and declassifying brings them back', tests.scalar('web_lead', format('select count(*)::text from tickets where id = %L', tests.id('tkt:S'))), '1');

-- Removing a client ----------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('client:gone', tests.mkclient_id('web_lead', 'Gone Soon Ltd', 'web'));
select tests.mk_asset('web_lead', 'G', 'Gone laptop', 'web', null, null, null, 'in_stock', 'client:gone');
select tests.remember('tkt:G', tests.scalar('web_lead', format($q$ select ticket_create(p_title => 'Gone ticket', p_asset => %L)::text $q$, tests.id('asset:G'))));
select tests.scalar('web_lead', format('select asset_retire(%L, ''Done'')::text', tests.id('asset:G')));
select tests.scalar('web_lead', format('select ticket_transition(%L, ''cancelled'', ''Done'')::text', tests.id('tkt:G')));
select tests.check('with its assets retired and tickets closed the client can be removed', tests.try_owner(format('update clients set deleted_at = now(), deletion_reason = ''gone'' where id = %L', tests.id('client:gone'))), 'ok');
select tests.check('removal propagates: the retired asset and the ticket disappear for ordinary users, indistinguishably',
  tests.scalar('web_lead', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L)', tests.id('asset:G'), tests.id('tkt:G'))) || tests.same_for('web_lead', $q$ select count(*)::text from assets where id = %L $q$, tests.id('asset:G'), tests.id('x:random')), '00same');
select tests.check('...and remain traceable for those who may see deleted records', tests.scalar('ceo', format('select (select count(*) from assets where id = %L)::text || (select count(*) from tickets where id = %L)', tests.id('asset:G'), tests.id('tkt:G'))), '11');

select tests.finish();
rollback;
