-- PERMANENT: Domains on the institutional foundation - identity through the central registry, record vs relationships (references with history),
-- explicit lifecycle, an append-only registration / renewal ledger, controlled transfers, expiry sweeps, website compatibility.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.try('fin', $q$ insert into suppliers (name) values ('NamReg Registrar') $q$);
select tests.try('fin', $q$ insert into suppliers (name) values ('Other Registrar') $q$);
insert into tests.ids select 'sup:namreg', id from suppliers where name = 'NamReg Registrar';
insert into tests.ids select 'sup:other', id from suppliers where name = 'Other Registrar';
create function tests.dstatus(p_key text) returns text language sql as $$ select status::text from domains where id = tests.id('dom:' || p_key) $$;
create function tests.dexp(p_key text) returns text language sql as $$ select expires_on::text from domains where id = tests.id('dom:' || p_key) $$;

-- Identity ------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('the web lead creates a domain record: it comes back with an institutional ID, status requested, origin division web', (tests.mk_domain('web_lead', 'ex', 'Example.COM.') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('the domain is a registered entity (family operations) with a well-formed opaque ID and no legacy alias; the name was normalised',
  (select concat_ws('|', (r.institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, (r.ada_id is null)::text, r.entity_family, r.entity_type, r.table_name, (r.origin_division_id = tests.id('div:web'))::text, r.origin_kind, d.name, d.status::text)
     from entity_registry r join domains d on d.id = r.entity_id where r.entity_id = tests.id('dom:ex') and r.table_name = 'domains'), 'true|true|operations|domain|domains|true|created|example.com|requested');
select tests.check('domains have no ID input and no generator of their own, and are never public (publication layer first)',
  (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'domains' and column_name ~ 'institutional|ada_id|number|code|public')
  || (select (not publishable and is_built and domain_table = 'domains')::text from entity_types where key = 'domain'), 'nonetrue');
select tests.check('the domain type is in the codebook', (select (c.code = t.id_code)::text from entity_types t join id_codebook c on c.kind = 'type' and c.meaning = t.key where t.key = 'domain'), 'true');
select tests.check('the same name (any spelling) is the same record: creating it again reports the existing one instead of a duplicate',
  tests.scalar('web_lead', $q$ select (domain_create(' EXAMPLE.com ', (select id from divisions where key = 'web')) ->> 'status') $q$) || (select count(*)::text from domains where name = 'example.com'), 'exists1');
select tests.check('invalid names are refused (single label, underscore, empty label, leading hyphen, too long)',
  tests.mk_domain('web_lead', 'b1', 'localhost') || tests.mk_domain('web_lead', 'b2', 'a_b.com') || tests.mk_domain('web_lead', 'b3', 'x..com') || tests.mk_domain('web_lead', 'b4', '-a.com') || tests.mk_domain('web_lead', 'b5', repeat('a', 64) || '.com'), repeat('ERR:22023', 5));
select tests.check('creating needs domains.create in THAT division', tests.mk_domain('web_staff', 'b6', 'staff.example') || tests.mk_domain('tech_lead', 'b7', 'tl.example', 'web') || tests.mk_domain('recruiter', 'b8', 'rec.example'), 'ERR:42501ERR:42501ERR:42501');
create temp table ctr_before as select coalesce((select last_value from id_counters where type_code = (select id_code from entity_types where key = 'domain')), 0) v;
select tests.check('a failed registration leaves no registry row and no counter gap', tests.try_owner($q$ insert into domains (name, division_id) values ('nodot', (select id from divisions where key = 'web')) $q$), 'ERR:23514');
select tests.check('...the next ID takes exactly the next serial', (select (coalesce(last_value, 0) = (select v from ctr_before))::text from id_counters where type_code = (select id_code from entity_types where key = 'domain')), 'true');
select tests.check('the name, creator and creation time are permanent, and a domain is never deleted (not by the owner either)',
  tests.try_owner(format($q$ update domains set name = 'other.com' where id = %L $q$, tests.id('dom:ex'))) || tests.try_owner(format('delete from domains where id = %L', tests.id('dom:ex'))), 'ERR:42501ERR:42501');
select tests.check('the registry resolves it for those who may see it and routes to domain_360; others get null',
  tests.scalar('web_lead', format($q$ select (entity_get(%L) -> 'record' -> 'record' ->> 'name') $q$, (select institutional_id from entity_registry where entity_id = tests.id('dom:ex')))) || tests.scalar('tech_staff', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = tests.id('dom:ex')))), 'example.comnull');

-- Lifecycle: requested -> active (a registration makes it so) ------------------------------------------------------------------------------------------
select tests.check('a registration cannot be recorded until a registrar (a supplier) is named', tests.try('web_lead', format($q$ select domain_activate(%L, current_date - 10, current_date + 355, 'ORD-1') $q$, tests.id('dom:ex'))), 'ERR:23514');
select tests.check('the registrar must be a supplier (a client is refused)', tests.rel('web_lead', 'ex', 'registrar', 'clients', 'client:abc'), 'ERR:23514');
select tests.check('the registrar is named (a reference to the supplier role, nothing copied)', tests.rel('web_lead', 'ex', 'registrar', 'suppliers', 'sup:namreg', 'our usual registrar'), 'ok');
select tests.check('registering needs domains.renew: division staff cannot', tests.try('web_staff', format($q$ select domain_activate(%L, current_date - 10, current_date + 355) $q$, tests.id('dom:ex'))), 'ERR:42501');
select tests.check('an impossible period is refused (end before start, longer than ten years)', tests.try('web_lead', format($q$ select domain_activate(%L, current_date, current_date - 1) $q$, tests.id('dom:ex'))) || tests.try('web_lead', format($q$ select domain_activate(%L, current_date, current_date + 4000) $q$, tests.id('dom:ex'))), 'ERR:23514ERR:23514');
select tests.check('the web lead records the registration (10 days ago, one year)', tests.try('web_lead', format($q$ select domain_activate(%L, current_date - 10, current_date + 355, 'ORD-1', 'initial registration') $q$, tests.id('dom:ex'))), 'ok');
select tests.check('...the domain is now active with the ledger''s end as its expiry', tests.dstatus('ex') || '|' || tests.dexp('ex'), 'active|' || (current_date + 355)::text);
select tests.check('the expiry is a mirror of the ledger: never written directly, and the ledger is append-only', tests.try_owner(format($q$ update domains set expires_on = current_date + 1 where id = %L $q$, tests.id('dom:ex'))) || tests.try_owner('update domain_registrations set period_end = period_end + 1') || tests.try_owner('delete from domain_registrations'), 'ERR:42501ERR:42501ERR:42501');
select tests.check('a domain cannot be made active (or expired) by a plain update', tests.try_owner(format($q$ update domains set status = 'requested' where id = %L $q$, tests.id('dom:ex'))) || tests.try_owner(format($q$ update domains set status = 'expired' where id = %L $q$, tests.id('dom:ex'))), 'ERR:23514ERR:23514');
select tests.check('a second registration for an active domain is refused', tests.try('web_lead', format($q$ select domain_activate(%L, current_date, current_date + 365) $q$, tests.id('dom:ex'))), 'ERR:23514');

-- Renewal: a gap-free, idempotent ledger ---------------------------------------------------------------------------------------------------------------
select tests.check('the lead renews for 2 years: the new period starts exactly where the last ended', tests.scalar('web_lead', format($q$ select (domain_renew(%L, 2, 'ORD-2') ->> 'period_start') $q$, tests.id('dom:ex'))), (current_date + 355)::text);
select tests.check('...the expiry moved to the end of that period', tests.dexp('ex'), (current_date + 355 + interval '2 years')::date::text);
select tests.check('repeating the same order reference is a no-op (a double click never double-renews)', tests.scalar('web_lead', format($q$ select (domain_renew(%L, 2, 'ORD-2') ->> 'duplicate') $q$, tests.id('dom:ex'))) || (select count(*)::text from domain_registrations where domain_id = tests.id('dom:ex')), 'true2');
select tests.check('...even if spelled differently', tests.scalar('web_lead', format($q$ select (domain_renew(%L, 5, ' ord-2 ') ->> 'duplicate') $q$, tests.id('dom:ex'))), 'true');
select tests.check('renewing 0 or 11 years is refused; so is renewing beyond ten years from today', tests.try('web_lead', format($q$ select domain_renew(%L, 0) $q$, tests.id('dom:ex'))) || tests.try('web_lead', format($q$ select domain_renew(%L, 11) $q$, tests.id('dom:ex'))) || tests.try('web_lead', format($q$ select domain_renew(%L, 9, 'ORD-9') $q$, tests.id('dom:ex'))), 'ERR:22023ERR:22023ERR:23514');
select tests.check('the ledger is contiguous: each period starts where the previous ended, no overlaps, no gaps',
  (select count(*)::text from (select period_start, lag(period_end) over (order by period_start) prev from domain_registrations where domain_id = tests.id('dom:ex')) x where prev is not null and period_start <> prev), '0');
select tests.check('division staff and others cannot renew', tests.try('web_staff', format($q$ select domain_renew(%L, 1, 'ORD-S') $q$, tests.id('dom:ex'))) || tests.try('tech_lead', format($q$ select domain_renew(%L, 1, 'ORD-T') $q$, tests.id('dom:ex'))), 'ERR:42501ERR:P0002');
select tests.check('finance may record a renewal (domains.renew, organisation-wide) but not edit or suspend', tests.try('fin', format($q$ select domain_renew(%L, 1, 'ORD-F') $q$, tests.id('dom:ex'))) || tests.try('fin', format($q$ select domain_update(%L, jsonb_build_object('description', 'x')) $q$, tests.id('dom:ex'))) || tests.try('fin', format($q$ select domain_transition(%L, 'suspended', 'x') $q$, tests.id('dom:ex'))), 'okERR:42501ERR:42501');
select tests.check('renewal and registration are in the domain''s history with who and when', (select string_agg(kind || ':' || coalesce(detail ->> 'order_reference', '-'), ',' order by id) from domain_events where domain_id = tests.id('dom:ex') and kind in ('activated', 'renewed')), 'activated:ORD-1,renewed:ORD-2,renewed:ORD-F');
select tests.check('...with the staff identity', (select count(*)::text from domain_events where domain_id = tests.id('dom:ex') and actor_staff_id is null), '0');

-- Suspend / restore / retire -------------------------------------------------------------------------------------------------------------------------------
select tests.check('suspending needs domains.suspend and a reason', tests.try('web_staff', format($q$ select domain_transition(%L, 'suspended', 'x') $q$, tests.id('dom:ex'))) || tests.try('web_lead', format($q$ select domain_transition(%L, 'suspended', ' ') $q$, tests.id('dom:ex'))) || tests.try('web_lead', format($q$ select domain_transition(%L, 'suspended', 'abuse report') $q$, tests.id('dom:ex'))), 'ERR:42501ERR:23514ok');
select tests.check('a suspended domain can still be renewed (so it is not lost) and restored', tests.try('web_lead', format($q$ select domain_renew(%L, 1, 'ORD-3') $q$, tests.id('dom:ex'))) || tests.try('web_lead', format($q$ select domain_transition(%L, 'active', 'resolved') $q$, tests.id('dom:ex'))) || tests.dstatus('ex'), 'okokactive');
select tests.check('a domain cannot be taken to any state by the transition command (activation / expiry / transfer have their own paths)',
  tests.try('ceo', format($q$ select domain_transition(%L, 'expired', 'x') $q$, tests.id('dom:ex'))) || tests.try('ceo', format($q$ select domain_transition(%L, 'transfer_pending', 'x') $q$, tests.id('dom:ex'))) || tests.try('ceo', format($q$ select domain_transition(%L, 'requested', 'x') $q$, tests.id('dom:ex'))), 'ERR:23514ERR:23514ERR:23514');
select tests.check('retiring needs domains.retire (not the web lead) and a reason', tests.try('web_lead', format($q$ select domain_transition(%L, 'retired', 'dropped') $q$, tests.id('dom:ex'))) || tests.try('adm2', format($q$ select domain_transition(%L, 'retired', ' ') $q$, tests.id('dom:ex'))), 'ERR:42501ERR:23514');
select tests.check('administration retires it', tests.try('adm2', format($q$ select domain_transition(%L, 'retired', 'client left; domain dropped') $q$, tests.id('dom:ex'))) || tests.dstatus('ex'), 'okretired');
select tests.check('a retired domain is a closed record: no renewal, edit, suspension, transfer or new relationship',
  tests.try('adm2', format($q$ select domain_renew(%L, 1, 'ORD-R') $q$, tests.id('dom:ex'))) || tests.try('adm2', format($q$ select domain_update(%L, jsonb_build_object('description', 'x')) $q$, tests.id('dom:ex'))) || tests.try_owner(format($q$ update domains set description = 'x' where id = %L $q$, tests.id('dom:ex')))
  || tests.rel('adm2', 'ex', 'client', 'clients', 'client:abc'), 'ERR:42501ERR:42501ERR:42501ERR:42501');
select tests.check('its identity, history and ledger are intact (nothing deleted, same ID)', (select count(*)::text from domain_registrations where domain_id = tests.id('dom:ex')) || (select count(*)::text from entity_registry where entity_id = tests.id('dom:ex') and status = 'retired'), '41');
select tests.check('re-registration is the SAME record: retired -> requested (retire permission, reason)', tests.try('web_lead', format($q$ select domain_reregister(%L, 'client came back') $q$, tests.id('dom:ex'))) || tests.try('adm2', format($q$ select domain_reregister(%L, 'client came back') $q$, tests.id('dom:ex'))) || tests.dstatus('ex'), 'ERR:42501okrequested');
select tests.check('a re-registered record cannot become active by a plain update, even though its old expiry is still in the future', tests.try_owner(format($q$ update domains set status = 'active' where id = %L $q$, tests.id('dom:ex'))), 'ERR:42501');
select tests.check('...a new registration may not overlap the old ledger', tests.try('web_lead', format($q$ select domain_activate(%L, current_date, current_date + 365) $q$, tests.id('dom:ex'))), 'ERR:23514');
select tests.check('...but may start where the old one ended', tests.try('web_lead', format($q$ select domain_activate(%L, %L, %L, 'ORD-NEW') $q$, tests.id('dom:ex'), (select max(period_end) from domain_registrations where domain_id = tests.id('dom:ex')), (select max(period_end) + 365 from domain_registrations where domain_id = tests.id('dom:ex')))) || tests.dstatus('ex'), 'okactive');
select tests.check('...the history tells the whole story in order', (select string_agg(kind, ',' order by id) from domain_events where domain_id = tests.id('dom:ex') and kind in ('created', 'activated', 'renewed', 'status', 'reregistered')), 'created,activated,renewed,renewed,status,renewed,status,status,reregistered,activated');

-- Expiry ----------------------------------------------------------------------------------------------------------------------------------------------------------
select tests.mk_domain('web_lead', 'lapsed', 'lapsed.example');
select tests.rel('web_lead', 'lapsed', 'registrar', 'suppliers', 'sup:namreg');
select tests.check('a lapsed registration is adopted as expired', tests.try('web_lead', format($q$ select domain_activate(%L, current_date - 1200, current_date - 800, 'LAPSED-1') $q$, tests.id('dom:lapsed'))) || tests.dstatus('lapsed'), 'okexpired');
select tests.check('an expired domain cannot be suspended or marked expired again', tests.try('web_lead', format($q$ select domain_transition(%L, 'suspended', 'x') $q$, tests.id('dom:lapsed'))) || tests.try('web_lead', format($q$ select domain_mark_expired(%L) $q$, tests.id('dom:lapsed'))), 'ERR:23514ERR:23514');
select tests.check('a renewal that still does not reach today leaves it expired (the ledger stays contiguous)', tests.try('web_lead', format($q$ select domain_renew(%L, 1, 'LAPSED-2') $q$, tests.id('dom:lapsed'))) || tests.dstatus('lapsed') || tests.dexp('lapsed'), 'okexpired' || (current_date - 800 + interval '1 year')::date::text);
select tests.check('...and a renewal that does reach it restores service', tests.try('web_lead', format($q$ select domain_renew(%L, 3, 'LAPSED-3') $q$, tests.id('dom:lapsed'))), 'ok');
select tests.check('...(active again, with the full renewal trail in the ledger)', tests.dstatus('lapsed') || (select count(*)::text from domain_registrations where domain_id = tests.id('dom:lapsed')), 'active3');
select tests.live_domain('web_lead', 'soon', 'soon.example', 10);
select tests.live_domain('web_lead', 'late', 'late.example', 20);
select set_config('ada.domain_ledger', 'on', true);
update domains set expires_on = current_date - 3 where id = tests.id('dom:late');
select set_config('ada.domain_ledger', 'off', true);
select tests.check('manual expiry works once the date has passed', tests.try('web_lead', format($q$ select domain_mark_expired(%L) $q$, tests.id('dom:ex'))) , 'ERR:23514');
create temp table sweep1 as select domain_expiry_sweep() j;
select tests.check('the sweep marks past-due active domains expired and notices those due within 30 days', (select (j ->> 'expired') || '|' || (j ->> 'notices') from sweep1), '1|1');
select tests.check('...recorded in history by the system (no staff actor), with the date that lapsed', (select (actor_staff_id is null and detail ->> 'by' = 'sweep')::text from domain_events where domain_id = tests.id('dom:late') and kind = 'expired'), 'true');
select tests.check('...nothing is deleted or retired by the sweep', tests.dstatus('late') || tests.dstatus('soon'), 'expiredactive');
select tests.check('running the sweep again repeats nothing (one notice per expiry date)', (select (domain_expiry_sweep() ->> 'expired') || '|' || (domain_expiry_sweep() ->> 'notices')), '0|0');
select tests.check('the expiry notice reached the people who can renew (internal domains only)', (select (count(*) > 0)::text from notifications where type = 'domain.expiring'), 'true');
select tests.check('the derived expiry view says due_soon / lapsed (nothing stored)', (select expiry_state from domain_expiry_status where domain_id = tests.id('dom:soon')) || '|' || (select expiry_state from domain_expiry_status where domain_id = tests.id('dom:late')), 'due_soon|lapsed');
select tests.check('the sweep is for the service role only', tests.scalar('ceo', 'select domain_expiry_sweep()::text'), 'ERR:42501');

-- Relationships: references with history ---------------------------------------------------------------------------------------------------------------
select tests.live_domain('web_lead', 'rel', 'relations.example');
insert into tests.ids select 'org:abc', organization_id from clients where id = tests.id('client:abc');
select tests.check('the web lead relates the domain to its client, project and registrant organization (references by institutional ID only)',
  tests.rel('web_lead', 'rel', 'client', 'clients', 'client:abc') || tests.rel('web_lead', 'rel', 'project', 'projects', 'project:abc') || tests.rel('web_lead', 'rel', 'registrant', 'organizations', 'org:abc'), 'okokok');
select tests.check('nothing about those entities is copied into the domain tables (no name / email / title columns)',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name in ('domains', 'domain_relations', 'domain_registrations', 'domain_transfers', 'domain_events')
     and column_name ~ '(client|organi[sz]ation|project|registrant|registrar|website|person|staff)_?(name|email|phone|title)|^(email|phone)'), 'none');
select tests.check('relationship types are enforced: a project is not a client, a client is not a registrar', tests.rel('web_lead', 'rel', 'client', 'projects', 'project:abc') || tests.rel('web_lead', 'rel', 'website', 'clients', 'client:abc'), 'ERR:23514ERR:23514');
select tests.check('re-stating the current client is refused', tests.rel('web_lead', 'rel', 'client', 'clients', 'client:abc'), 'ERR:23505');
select tests.check('the same project twice is refused; a second project is fine', tests.rel('web_lead', 'rel', 'project', 'projects', 'project:abc') , 'ERR:23505');
select tests.mkclient_id('web_lead', 'Second Domain Client', 'web');
insert into tests.ids select 'client:second', id from clients where name = 'Second Domain Client';
select tests.check('changing the client ends the old relationship (kept, with the reason) and opens the new one', tests.rel('web_lead', 'rel', 'client', 'clients', 'client:second', 'client changed hands'), 'ok');
select tests.check('...exactly one current client; the old one is history with valid_to and a reason',
  (select count(*)::text from domain_relations where domain_id = tests.id('dom:rel') and relation = 'client' and valid_to is null) || '|' || (select count(*)::text from domain_relations where domain_id = tests.id('dom:rel') and relation = 'client' and valid_to is not null and end_reason = 'replaced: client changed hands'), '1|1');
select tests.check('relationships can be ended explicitly with a reason, never deleted or edited', tests.try('web_lead', format($q$ select domain_relation_end((select id from domain_relations where domain_id = %L and relation = 'project' and valid_to is null), ' ') $q$, tests.id('dom:rel'))) ||
  tests.try('web_lead', format($q$ select domain_relation_end((select id from domain_relations where domain_id = %L and relation = 'project' and valid_to is null), 'project closed') $q$, tests.id('dom:rel'))) ||
  tests.try_owner('delete from domain_relations') || tests.try_owner('update domain_relations set relation = ''client'' where relation = ''project''') || tests.try('web_lead', 'update domain_relations set reason = ''x'''), 'ERR:23514okERR:42501ERR:42501ERR:42501');
select tests.check('...an ended relationship cannot be ended twice', tests.try('web_lead', format($q$ select domain_relation_end((select id from domain_relations where domain_id = %L and relation = 'project' limit 1), 'again') $q$, tests.id('dom:rel'))), 'ERR:23514');
select tests.check('relationships need domains.update', tests.rel('web_staff', 'rel', 'project', 'projects', 'project:abc') || tests.rel('fin', 'rel', 'project', 'projects', 'project:abc'), 'ERR:42501ERR:42501');

-- Historical review ------------------------------------------------------------------------------------------------------------------------------------------
alter table domain_relations disable trigger domain_relations_before_trg;
update domain_relations set valid_from = valid_from - interval '40 days', valid_to = valid_to - interval '10 days' where domain_id = tests.id('dom:rel') and relation = 'client' and valid_to is not null;
update domain_relations set valid_from = valid_from - interval '10 days' where domain_id = tests.id('dom:rel') and relation = 'client' and valid_to is null;
alter table domain_relations enable trigger domain_relations_before_trg;
select tests.check('"which domains did the OLD client have 20 days ago?" - answered from the relationship history (the old client yes, the new client not yet)',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), now() - interval '20 days'))::text $q$, tests.id('client:abc'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), now() - interval '20 days'))::text $q$, tests.id('client:second'))), '10');
select tests.check('...today it is the other way round', tests.scalar('web_lead', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L))) $q$, tests.id('client:abc'))) || tests.scalar('web_lead', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L))) $q$, tests.id('client:second'))), '01');
alter table domain_relations disable trigger domain_relations_before_trg;
insert into domain_relations (domain_id, relation, entity_institutional_id, valid_from, valid_to, reason) select tests.id('dom:rel'), 'client', er.institutional_id, now() - interval '100 days', now() - interval '50 days', 'historical' from entity_registry er where er.entity_id = tests.id('client:second');
alter table domain_relations enable trigger domain_relations_before_trg;
select tests.check('a historical lookup returns, per domain, only the relationships in force on the date (an earlier, ended relationship of the same client is not mixed with the current one)',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), now() - interval '75 days') -> 0 -> 'relations')::text $q$, tests.id('client:second'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), now() - interval '3 days') -> 0 -> 'relations')::text $q$, tests.id('client:second'))), '11');
select tests.check('the historical answer lists only relationships that were in force on that date (none ended before it, none started after it)',
  tests.scalar('web_lead', format($q$ select (select count(*) from jsonb_array_elements(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), now() - interval '20 days')) d, jsonb_array_elements(d -> 'relations') r where (r ->> 'until') is not null and (r ->> 'until')::timestamptz <= now() - interval '20 days' or (r ->> 'since')::timestamptz > now() - interval '20 days')::text $q$, tests.id('client:abc'))), '0');
select tests.check('a client''s 360 and a project''s 360 have a Domains section, and Domains is no longer pending',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(client_360(%L) -> 'domains')::text || ((client_360(%L) -> 'pending') ? 'domains')::text $q$, tests.id('client:second'), tests.id('client:second'))) ||
  tests.scalar('web_lead', format($q$ select jsonb_array_length(project_360(%L) -> 'domains')::text $q$, tests.id('project:abc'))), '1false0');
select tests.check('the organization 360 carries the domains of the organization and its clients'' families', tests.scalar('ceo', format($q$ select jsonb_array_length(organization_360(%L) -> 'domains')::text $q$, tests.id('org:abc'))), '1');
select tests.check('a client whose domain relationships have all ended (client changed, project closed) lists none - children included; only CURRENT relationships count',
  tests.scalar('ceo', format($q$ select jsonb_array_length(domains_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true)) $q$, tests.id('client:abc'))), '0');

-- Websites (compatibility) ------------------------------------------------------------------------------------------------------------------------------------
select tests.live_domain('ceo', 'ada', 'ada.test');
select tests.check('websites keep their hostname string untouched; the registered domain they sit under is DERIVED on read (nothing stored)',
  (select string_agg(h.hostname || '>' || d.name, ',' order by h.hostname) from website_hostname_domains h join domains d on d.id = h.domain_id), 'limited.ada.test>ada.test,main.ada.test>ada.test,suspended.ada.test>ada.test,tech.ada.test>ada.test');
select tests.check('an explicit website relationship is allowed (website entity) and the domain 360 lists the derived hostnames', tests.rel('ceo', 'ada', 'website', 'websites', 'site:main') || tests.scalar('ceo', format($q$ select jsonb_array_length(domain_360(%L) -> 'websites')::text $q$, tests.id('dom:ada'))), 'ok4');
select tests.check('the websites table is unchanged by Domains (columns and constraints)', (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_name = 'websites' and column_name in ('domain', 'environment', 'status')), 'domain,environment,status');

-- Transfers: controlled, approved, append-only -------------------------------------------------------------------------------------------------------------
select tests.live_domain('web_lead', 'tr', 'transfer.example');
select tests.check('the web lead requests a transfer to another registrar (a supplier visible to them)', (tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'registrar', (select institutional_id from entity_registry where entity_id = %L), p_reason => 'cheaper renewals')::text $q$, tests.id('dom:tr'), tests.id('sup:other'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'tr:1', id from domain_transfers where domain_id = tests.id('dom:tr');
select tests.check('the domain is transfer_pending, an approval is pending, and no second transfer can be opened', tests.dstatus('tr') || '|' || (select count(*)::text from approval_requests where entity_id = tests.id('tr:1') and status = 'pending' and kind = 'domain_transfer') || '|' ||
  tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'out', p_destination_note => 'x', p_reason => 'again')::text $q$, tests.id('dom:tr'))), 'transfer_pending|1|ERR:23505');
select tests.check('no renewal, suspension or retirement while a transfer is open', tests.try('web_lead', format($q$ select domain_renew(%L, 1, 'TR-R') $q$, tests.id('dom:tr'))) || tests.try('web_lead', format($q$ select domain_transition(%L, 'suspended', 'x') $q$, tests.id('dom:tr'))) || tests.try('adm2', format($q$ select domain_transition(%L, 'retired', 'x') $q$, tests.id('dom:tr'))), 'ERR:23514ERR:23514ERR:23514');
select tests.check('the status cannot be flipped around the workflow, even by the owner', tests.try_owner(format($q$ update domains set status = 'active' where id = %L $q$, tests.id('dom:tr'))), 'ERR:42501');
select tests.check('the requester cannot approve their own transfer, nor can people without domains.approve', tests.try('web_lead', format($q$ select domain_transfer_decide(%L, true) $q$, tests.id('tr:1'))) || tests.try('adm2', format($q$ select domain_transfer_decide(%L, true) $q$, tests.id('tr:1'))), 'ERR:42501ERR:42501');
select tests.check('a rejection needs a note', tests.try('ceo', format($q$ select domain_transfer_decide(%L, false) $q$, tests.id('tr:1'))), 'ERR:23514');
select tests.check('completing before approval is refused', tests.try('web_lead', format($q$ select domain_transfer_complete(%L, 'EPP-1') $q$, tests.id('tr:1'))), 'ERR:23514');
select tests.check('the CEO (a different person) approves', tests.scalar('ceo', format($q$ select domain_transfer_decide(%L, true, 'ok') $q$, tests.id('tr:1'))), 'approved');
select tests.check('the lead completes it: the registrar relationship moves (old one kept as history), the domain is active again, the transfer is closed',
  tests.try('web_lead', format($q$ select domain_transfer_complete(%L, 'registrar order 77') $q$, tests.id('tr:1'))), 'ok');
select tests.check('...registrar now Other Registrar; NamReg ended with the transfer as reason', (select (select count(*) from domain_relations where domain_id = tests.id('dom:tr') and relation = 'registrar' and valid_to is null and entity_institutional_id = (select institutional_id from entity_registry where entity_id = tests.id('sup:other')))::text ||
  (select count(*) from domain_relations where domain_id = tests.id('dom:tr') and relation = 'registrar' and valid_to is not null and end_reason like 'replaced: transfer %')::text), '11');
select tests.check('...status and closure', tests.dstatus('tr') || '|' || (select state || '/' || closing_note from domain_transfers where id = tests.id('tr:1')), 'active|completed/registrar order 77');
select tests.check('a closed transfer is final and a transfer''s request can never be edited or deleted', tests.try_owner(format($q$ update domain_transfers set state = 'cancelled' where id = %L $q$, tests.id('tr:1'))) || tests.try_owner(format($q$ update domain_transfers set reason = 'x' where id = %L $q$, tests.id('tr:1'))) || tests.try_owner('delete from domain_transfers'), 'ERR:23514ERR:42501ERR:42501');
select tests.check('a registrar transfer to the registrar that already holds the domain is refused; so is a non-supplier', tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'registrar', (select institutional_id from entity_registry where entity_id = %L), p_reason => 'x')::text $q$, tests.id('dom:tr'), tests.id('sup:other'))) ||
  tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'registrar', (select institutional_id from entity_registry where entity_id = %L), p_reason => 'x')::text $q$, tests.id('dom:tr'), tests.id('client:abc'))), 'ERR:23514ERR:23514');
select tests.check('a rejected transfer returns the domain to its previous status', (tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'out', p_destination_note => 'to another agency', p_reason => 'client leaving')::text $q$, tests.id('dom:tr'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'tr:2', id from domain_transfers where domain_id = tests.id('dom:tr') and kind = 'out';
select tests.check('...rejected by the CEO with a note', tests.scalar('ceo', format($q$ select domain_transfer_decide(%L, false, 'client has not paid') $q$, tests.id('tr:2'))) || '|' || tests.dstatus('tr'), 'rejected|active');
select tests.check('a transfer can be cancelled by the lead (reason required) and the domain returns to its status', (tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'out', p_destination_note => 'maybe', p_reason => 'considering')::text $q$, tests.id('dom:tr'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'tr:3', id from domain_transfers where domain_id = tests.id('dom:tr') and state = 'requested';
select tests.check('...cancel', tests.try('web_lead', format($q$ select domain_transfer_cancel(%L, ' ') $q$, tests.id('tr:3'))) || tests.try('web_lead', format($q$ select domain_transfer_cancel(%L, 'client changed their mind') $q$, tests.id('tr:3'))) || tests.dstatus('tr'), 'ERR:23514okactive');
select tests.mkclient_id('web_lead', 'New Owner Co', 'web');
insert into tests.ids select 'client:newowner', id from clients where name = 'New Owner Co';
insert into tests.ids select 'org:newowner', organization_id from clients where name = 'New Owner Co';
select tests.check('an ownership transfer to another organization (and its client record) is requested, approved and completed', (tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'ownership', (select institutional_id from entity_registry where entity_id = %L), (select institutional_id from entity_registry where entity_id = %L), p_reason => 'sold to New Owner')::text $q$, tests.id('dom:rel'), tests.id('org:newowner'), tests.id('client:newowner'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'tr:4', id from domain_transfers where domain_id = tests.id('dom:rel') and kind = 'ownership';
select tests.scalar('ceo', format($q$ select domain_transfer_decide(%L, true, 'ok') $q$, tests.id('tr:4')));
select tests.check('...completed: new registrant and client are current, the old ones are history', tests.try('web_lead', format($q$ select domain_transfer_complete(%L, 'deed 12') $q$, tests.id('tr:4'))), 'ok');
select tests.check('...(registrant and client now the new owner; one current of each)', (select string_agg(relation || ':' || (entity_institutional_id = (select institutional_id from entity_registry where entity_id = case relation when 'registrant' then tests.id('org:newowner') else tests.id('client:newowner') end))::text, ',' order by relation)
   from domain_relations where domain_id = tests.id('dom:rel') and relation in ('registrant', 'client') and valid_to is null), 'client:true,registrant:true');
select tests.check('...and the previous owner''s link remains as history', (select count(*)::text from domain_relations where domain_id = tests.id('dom:rel') and relation = 'registrant' and valid_to is not null), '1');
select tests.live_domain('web_lead', 'out', 'leaving.example');
select tests.rel('web_lead', 'out', 'client', 'clients', 'client:abc');
select tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'out', p_destination_note => 'moving to another provider', p_reason => 'client terminated')::text $q$, tests.id('dom:out')));
insert into tests.ids select 'tr:5', id from domain_transfers where domain_id = tests.id('dom:out');
select tests.scalar('ceo', format($q$ select domain_transfer_decide(%L, true, 'ok') $q$, tests.id('tr:5')));
select tests.try('web_lead', format($q$ select domain_transfer_complete(%L, 'released') $q$, tests.id('tr:5')));
select tests.check('a transfer OUT retires the domain and ends every current relationship - but the record, its ID and its whole history stay',
  tests.dstatus('out') || '|' || (select count(*)::text from domain_relations where domain_id = tests.id('dom:out') and valid_to is null) || '|' || (select count(*)::text from domain_relations where domain_id = tests.id('dom:out') and valid_to is not null) || '|' || (select count(*)::text from entity_registry where entity_id = tests.id('dom:out') and status = 'retired'), 'retired|0|2|1');
select tests.check('transfers carry no secrets (no auth-code / EPP / password column anywhere)', (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name like 'domain%' and column_name ~* 'auth|epp|secret|password|code'), 'none');
select tests.check('transfer events are in the domain history in order', (select string_agg(kind, ',' order by id) from domain_events where domain_id = tests.id('dom:tr') and kind like 'transfer_%'), 'transfer_requested,transfer_decided,transfer_completed,transfer_requested,transfer_decided,transfer_requested,transfer_cancelled');

-- Rules pinned from the other side (database-level layers that the commands alone would never reach) -----------------------------------------------------
select tests.check('a retired domain cannot be made active again by a plain update', tests.try_owner(format($q$ update domains set status = 'active' where id = %L $q$, tests.id('dom:out'))), 'ERR:23514');
select tests.mk_domain('web_lead', 'req', 'requested-only.example');
select tests.check('even with the ledger flag set, a domain cannot become active with an expiry in the past', tests.try_owner(format($q$ do $d$ begin perform set_config('ada.domain_ledger', 'on', true); update domains set expires_on = current_date - 5, status = 'active' where id = %L; end $d$ $q$, tests.id('dom:req'))), 'ERR:23514');
select tests.check('a retired domain takes no new relationship even from a caller that bypasses row security', tests.try_owner(format($q$ insert into domain_relations (domain_id, relation, entity_institutional_id) values (%L, 'project', (select institutional_id from entity_registry where entity_id = %L)) $q$, tests.id('dom:out'), tests.id('project:abc'))), 'ERR:23514');
select tests.check('relationship rows cannot be reopened or closed outside the system''s own paths', tests.try_owner(format('update domain_relations set valid_to = null where domain_id = %L', tests.id('dom:out'))) || tests.try_owner(format('update domain_relations set valid_to = now() where domain_id = %L and valid_to is null', tests.id('dom:tr'))), 'ERR:42501ERR:42501');
select tests.check('the ledger enforces contiguity for every writer (a gap is refused)',
  tests.try_owner(format($q$ insert into domain_registrations (domain_id, kind, period_start, period_end) values (%L, 'renewal', %L, %L) $q$, tests.id('dom:tr'), (select max(period_end) + 10 from domain_registrations where domain_id = tests.id('dom:tr')), (select max(period_end) + 375 from domain_registrations where domain_id = tests.id('dom:tr')))), 'ERR:23514');
select tests.check('...and period length (five days is refused)',
  tests.try_owner(format($q$ insert into domain_registrations (domain_id, kind, period_start, period_end) values (%L, 'renewal', %L, %L) $q$, tests.id('dom:tr'), (select max(period_end) from domain_registrations where domain_id = tests.id('dom:tr')), (select max(period_end) + 5 from domain_registrations where domain_id = tests.id('dom:tr')))), 'ERR:23514');
select tests.check('an active domain takes no second registration even when the new period does not overlap', tests.try('web_lead', format($q$ select domain_activate(%L, %L, %L) $q$, tests.id('dom:tr'), (select max(period_end) from domain_registrations where domain_id = tests.id('dom:tr')), (select max(period_end) + 365 from domain_registrations where domain_id = tests.id('dom:tr')))), 'ERR:23514');
select tests.check('a domain that is only requested cannot be transferred', tests.scalar('web_lead', format($q$ select domain_transfer_request(%L, 'out', p_destination_note => 'x', p_reason => 'x')::text $q$, tests.id('dom:req'))), 'ERR:23514');
select tests.check('...also for a caller that bypasses the command: the table itself refuses a transfer of a requested domain, for its own reason', (tests.try_msg('web_lead', format($q$ insert into domain_transfers (domain_id, kind, destination_note, reason) values (%L, 'out', 'x', 'x') $q$, tests.id('dom:req'))) ~ 'only an active or suspended domain')::text, 'true');
select tests.check('the CEO requests a transfer', (tests.scalar('ceo', format($q$ select domain_transfer_request(%L, 'out', p_destination_note => 'to a partner agency', p_reason => 'planned move')::text $q$, tests.id('dom:tr'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'tr:6', id from domain_transfers where domain_id = tests.id('dom:tr') and state = 'requested';
select tests.check('separation of duties: the CEO cannot approve the transfer the CEO requested', tests.try('ceo', format($q$ select domain_transfer_decide(%L, true) $q$, tests.id('tr:6'))), 'ERR:42501');
select tests.check('completing an unapproved transfer is refused by the command, in its own words', tests.try_msg('web_lead', format($q$ select domain_transfer_complete(%L) $q$, tests.id('tr:6'))), '23514: only an approved transfer can be completed (this one is requested)');
select tests.check('a transfer cannot skip approval even for a caller that sets the workflow flag', tests.try_owner(format($q$ do $d$ begin perform set_config('ada.domain_transfer', 'on', true); update domain_transfers set state = 'completed' where id = %L; end $d$ $q$, tests.id('tr:6'))), 'ERR:23514');
select tests.check('an open request''s facts cannot be edited, nor a closed transfer''s closing note', tests.try_owner(format($q$ update domain_transfers set reason = 'edited' where id = %L $q$, tests.id('tr:6'))) || tests.try_owner(format($q$ update domain_transfers set closing_note = 'edited' where id = %L $q$, tests.id('tr:1'))), 'ERR:42501ERR:42501');
select tests.try('ceo', format($q$ select domain_transfer_cancel(%L, 'tidy up') $q$, tests.id('tr:6')));


select tests.finish();
rollback;
