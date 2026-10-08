-- PERMANENT: the institutional skeleton - automatic opaque 9-character IDs, the entity registry as a map (never a second source of
-- truth), registry-first routing, division movement, and security escalation for denied / unresolved lookups.
begin;
select tests.setup();
select tests.setup_hr();
create temp table fake as select 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ') as id;

-- Identity: automatic, 9 characters, opaque, unique -------------------------------------------------------------------------------------------------
select tests.check('every registered entity has a 9-character institutional ID from the allowed alphabet (A-Z, 0-9, no punctuation)',
  (select count(*)::text from entity_registry where institutional_id !~ '^[0-9A-HJKMNP-TV-Z]{9}$'), '0');
select tests.check('no ID is longer than 9 characters or contains a hyphen, space or symbol', (select count(*)::text from entity_registry where length(institutional_id) <> 9 or institutional_id ~ '[^A-Z0-9]'), '0');
select tests.check('every ID carries a valid check character (any single wrong character is detected)',
  (select count(*)::text from entity_registry where not ada_id_valid(institutional_id)), '0');
select tests.check('...and a mistyped ID is rejected without touching the registry',
  (select count(*)::text from entity_registry where ada_id_valid(substr(institutional_id, 1, 4) || case when substr(institutional_id, 5, 1) = 'A' then 'B' else 'A' end || substr(institutional_id, 6))), '0');
select tests.check('institutional IDs are unique', (select (count(*) = count(distinct institutional_id))::text from entity_registry), 'true');
select tests.check('the legacy ADA-XXX identifiers are kept as aliases and stay unique', (select (count(ada_id) = count(distinct ada_id))::text from entity_registry), 'true');
select tests.check('users cannot mint or choose IDs', tests.scalar('ceo', $q$ select ada_mint_id('asset') $q$) || tests.scalar('ceo', $q$ select id_scramble(1, 'k')::text $q$), 'ERR:42501ERR:42501');
select tests.check('the ID of a new entity is generated, never supplied: the asset table has no ID input', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name = 'assets' and column_name ~ 'institutional'), 'none');
select tests.check('the mint refuses an entity type that is not in the active codebook', tests.try_owner($q$ select ada_mint_id('spaceship') $q$), 'ERR:22023');
select tests.check('...and a year with no issue cycle in the codebook', tests.try_owner($q$ select ada_mint_id('asset', 2100) $q$), 'ERR:22023');

-- Registration through the central service ----------------------------------------------------------------------------------------------------------
select tests.check('registering an asset returns its generated institutional ID, origin and status (the user never types the ID)',
  ((tests.scalar('web_lead', format($q$ select asset_register(p_name => 'Lenovo ThinkPad X1', p_category => 'laptop', p_division => %L, p_manufacturer => 'Lenovo', p_serial => 'SN-1', p_status => 'in_stock')::text $q$, tests.id('div:web')))::jsonb ->> 'institutional_id') ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, 'true');
insert into tests.ids select 'asset:A', id from assets where serial_number = 'SN-1';
select tests.check('the card shows origin and status', (select (c ->> 'origin_division') || '/' || (c ->> 'status') from (select tests.scalar('web_lead', format($q$ select asset_register(p_name => 'Card test', p_category => 'laptop', p_division => %L, p_status => 'in_stock')::text $q$, tests.id('div:web')))::jsonb c) q), 'web/in_stock');
select tests.check('the registry row has the right family, type and authoritative location, and the right origin',
  (select concat_ws('|', entity_family, entity_type, table_name, (entity_id = tests.id('asset:A'))::text, (origin_division_id = tests.id('div:web'))::text, (origin_year = extract(year from now() at time zone 'Africa/Windhoek')::integer)::text, origin_kind, authorization_scope)
   from entity_registry where entity_id = tests.id('asset:A')), 'operations|asset|assets|true|true|true|created|division');
select tests.check('the registry holds NO business data: its columns are identity, origin, routing and status only',
  (select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema = 'public' and table_name = 'entity_registry'),
  'ada_id,authorization_scope,classification,created_at,created_by,current_division_id,current_location,entity_family,entity_id,entity_type,institutional_id,origin_cycle,origin_division_id,origin_kind,origin_year,routing_version,status,table_name');
select tests.check('the authoritative record is reached through the registry pointer (table_name + entity_id)',
  tests.scalar('web_lead', format($q$ select name from assets where id = (select entity_id from entity_registry where institutional_id = %L) $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:A')))), 'Lenovo ThinkPad X1');
select tests.check('legacy ID mapping: the old ADA-AST identifier resolves to the same entity as the new one',
  (select (tests.scalar('web_lead', format('select entity_resolve(%L)::text', ada_id))::jsonb ->> 'institutional_id') = institutional_id from entity_registry where entity_id = tests.id('asset:A'))::text, 'true');
create temp table seqs (n integer, s text);
do $$ declare g integer; v uuid; begin
  for g in 1..12 loop
    v := asset_create(p_name => 'Seq ' || g, p_category => 'laptop', p_division => (select id from divisions where key = 'web'));
    insert into seqs select g, substr(institutional_id, 4, 5) from entity_registry where entity_id = v;
  end loop;
end $$;
select tests.check('IDs are opaque: the serials of 12 consecutive registrations are distinct and neither ascending nor descending',
  (select (count(distinct s) = 12 and string_agg(s, ',' order by n) <> string_agg(s, ',' order by s) and string_agg(s, ',' order by n) <> string_agg(s, ',' order by s desc))::text from seqs), 'true');
select tests.check('the ID encodes the entity type through the codebook, not through readable text',
  (select (entity_type = 'asset' and issue_year = extract(year from now() at time zone 'Africa/Windhoek')::integer and valid)::text from ada_id_decode((select institutional_id from entity_registry where entity_id = tests.id('asset:A')))), 'true');
select tests.check('...and the ID does not contain the entity type name', (select (institutional_id !~* 'AST|ASSET') ::text from entity_registry where entity_id = tests.id('asset:A')), 'true');
select tests.check('every entity family in the codebook has a unique type code', (select (count(*) = count(distinct id_code))::text from entity_types), 'true');
select tests.check('every built entity type points at a real authoritative table', (select coalesce(string_agg(key, ','), 'none') from entity_types where is_built and domain_table is not null and to_regclass('public.' || domain_table) is null), 'none');
select tests.check('the codebook covers organization, people, commercial, operations, academy and governance families',
  (select string_agg(distinct family, ',' order by family) from entity_types), 'academy,commercial,governance,operations,people_org');
select tests.check('codebook entries and the scramble key are permanent', tests.try_owner($q$ update id_codebook set meaning = 'x' where kind = 'type' $q$) || tests.try_owner('delete from id_codebook') || tests.try_owner($q$ update id_settings set scramble_key = 'x' $q$) || tests.try_owner($q$ update entity_types set id_code = 'ZZ' where key = 'asset' $q$), 'ERR:42501ERR:42501ERR:42501ERR:42501');

-- Atomic registration, rollback, retry, no reuse ----------------------------------------------------------------------------------------------------
create temp table ctr as select last_value v from id_counters where type_code = (select id_code from entity_types where key = 'asset');
do $$ begin
  begin
    insert into assets (name, category_id, division_id) select 'Doomed', (select id from asset_categories where key = 'other'), (select id from divisions where key = 'web');
    raise exception 'simulated failure after the ID was minted';
  exception when others then null;
  end;
end $$;
select tests.check('a failed registration leaves no registry row, no orphan and no counter gap', (select count(*)::text from entity_registry r where r.table_name = 'assets' and not exists (select 1 from assets a where a.id = r.entity_id)) || (select (last_value = (select v from ctr))::text from id_counters where type_code = (select id_code from entity_types where key = 'asset')), '0true');
select tests.check('retrying the same registration succeeds', tests.try('web_lead', format($q$ select asset_create(p_name => 'Doomed', p_category => 'laptop', p_division => %L) $q$, tests.id('div:web'))), 'ok');
select tests.check('...and takes exactly the next serial (no gap, no reuse)', (select (last_value = (select v from ctr) + 1)::text from id_counters where type_code = (select id_code from entity_types where key = 'asset')), 'true');
select tests.check('registry entries are never deleted and their identity never changes (owner)',
  tests.try_owner('delete from entity_registry') || tests.try_owner(format($q$ update entity_registry set institutional_id = 'AAAAAAAAA' where entity_id = %L $q$, tests.id('asset:A'))) || tests.try_owner(format($q$ update entity_registry set origin_division_id = %L where entity_id = %L $q$, tests.id('div:tech'), tests.id('asset:A'))) || tests.try_owner(format($q$ update entity_registry set ada_id = 'X' where entity_id = %L $q$, tests.id('asset:A'))), 'ERR:42501ERR:42501ERR:42501ERR:42501');
insert into tasks (project_id, title) values (tests.id('project:P_web'), 'Throwaway');
create temp table gone as select institutional_id i, entity_id from entity_registry where table_name = 'tasks' and entity_id = (select id from tasks where title = 'Throwaway');
delete from tasks where title = 'Throwaway';
insert into tasks (project_id, title) values (tests.id('project:P_web'), 'Replacement');
select tests.check('a deleted record keeps its ID in the registry (status removed) and the ID is never given to anything else',
  (select status from entity_registry where institutional_id = (select i from gone)) || (select (count(*) = 0)::text from entity_registry where institutional_id = (select i from gone) and entity_id <> (select entity_id from gone)), 'removedtrue');

-- Registry stays consistent with the authoritative records ------------------------------------------------------------------------------------------
select tests.check('every built domain table has exactly one registry row per record', tests.unregistered_tables(), 'none');
select tests.check('the registry mirrors status, division and classification of assets, clients and projects exactly',
  (select count(*)::text from entity_registry r join assets a on a.id = r.entity_id and r.table_name = 'assets' where (r.status, r.current_division_id, r.classification) is distinct from (a.status::text, a.division_id, a.effective_classification))
  || (select count(*)::text from entity_registry r join clients c on c.id = r.entity_id and r.table_name = 'clients' where (r.status, r.current_division_id, r.classification) is distinct from (c.status::text, c.owner_division_id, c.classification))
  || (select count(*)::text from entity_registry r join projects p on p.id = r.entity_id and r.table_name = 'projects' where (r.status, r.current_division_id, r.classification) is distinct from (p.status::text, p.lead_division_id, p.effective_classification)), '000');

-- Division movement: the ID and origin never change ---------------------------------------------------------------------------------------------------
create temp table before_move as select institutional_id, origin_division_id, origin_year, routing_version from entity_registry where entity_id = tests.id('asset:A');
select tests.scalar('ceo', format('select asset_assign(%L, %L, %L, ''Move to Tech'')::text', tests.id('asset:A'), tests.id('staff:tech_staff'), tests.id('div:tech')));
select tests.check('after the asset moves from Web to Tech: the permanent ID and the origin are unchanged, the current division follows',
  (select (r.institutional_id = b.institutional_id and r.origin_division_id = b.origin_division_id and r.origin_year = b.origin_year and r.origin_division_id = tests.id('div:web')
           and r.current_division_id = tests.id('div:tech') and r.routing_version > b.routing_version)::text from entity_registry r, before_move b where r.entity_id = tests.id('asset:A')), 'true');
select tests.scalar('ceo', format('select asset_assign(%L, %L, %L, ''Move to Academy'')::text', tests.id('asset:A'), tests.id('staff:tech_staff'), tests.id('div:academy')));
select tests.scalar('ceo', format('select asset_update(%L, ''{"current_location": "Rundu campus"}'')::text', tests.id('asset:A')));
select tests.check('the registry shows origin Web, current Academy at Rundu, status assigned',
  (select (select key from divisions where id = origin_division_id) || '/' || (select key from divisions where id = current_division_id) || '/' || current_location || '/' || status from entity_registry where entity_id = tests.id('asset:A')), 'web/academy/Rundu campus/assigned');
select tests.check('the movement history is retained: registered, Web -> Tech, Tech -> Academy, location change',
  (select string_agg(coalesce((select key from divisions where id = h.to_division_id), '-') || ':' || h.reason, ' > ' order by h.id) from entity_location_history h where h.institutional_id = (select institutional_id from before_move)),
  'web:registered > tech:moved > academy:moved > academy:moved');
select tests.check('audit identity: new audit rows carry the institutional ID, old ones still join through the registry',
  (select (count(*) > 0 and bool_and(record_institutional_id = (select institutional_id from before_move)))::text from audit_log where table_name = 'assets' and record_id = tests.id('asset:A') and record_institutional_id is not null), 'true');
create temp table staff_before as select institutional_id from entity_registry where entity_id = tests.id('staff:web_staff');
update staff set primary_division_id = tests.id('div:tech') where id = tests.id('staff:web_staff');
select tests.check('a staff member who changes division keeps the same Staff ID; origin stays, current division follows',
  (select (institutional_id = (select institutional_id from staff_before) and current_division_id = tests.id('div:tech'))::text from entity_registry where entity_id = tests.id('staff:web_staff')), 'true');
update projects set lead_division_id = tests.id('div:tech') where id = tests.id('project:P_web');
select tests.check('a project that changes lead division keeps its ID; the origin division is preserved',
  (select ((select key from divisions where id = origin_division_id) || '/' || (select key from divisions where id = current_division_id)) from entity_registry where entity_id = tests.id('project:P_web')), 'web/tech');

-- Routing: the registry first, authorisation before retrieval -----------------------------------------------------------------------------------------
select tests.remember('client:R', tests.mkclient_id('ceo', 'Hidden Holdings'));
update clients set classification = 'restricted' where id = tests.id('client:R');
select tests.check('a restricted client asset', (tests.scalar('ceo', format($q$ select asset_create(p_name => 'Hidden laptop', p_category => 'laptop', p_division => %L, p_client => %L)::text $q$, tests.id('div:web'), tests.id('client:R'))) ~ '^[0-9a-f-]{36}$')::text, 'true');
insert into tests.ids select 'asset:R', id from assets where name = 'Hidden laptop';
insert into tests.ids select 'x:random', gen_random_uuid();
select tests.check('registry-first: an ID resolves straight to its entity type and authoritative domain, with no business data',
  (select (j ->> 'entity_type') || '/' || (j ->> 'authoritative_domain') || '/' || (j ? 'name')::text || (j ? 'serial_number')::text from (select tests.scalar('ceo', format('select entity_resolve(%L)::text', (select institutional_id from entity_registry where entity_id = tests.id('asset:A'))))::jsonb j) q), 'asset/assets/falsefalse');
select tests.check('...and entity_get returns the authoritative record through the type''s 360 view',
  (select (j -> 'record' -> 'overview' ->> 'name') from (select tests.scalar('ceo', format('select entity_get(%L)::text', (select institutional_id from entity_registry where entity_id = tests.id('asset:A'))))::jsonb j) q), 'Lenovo ThinkPad X1');
select tests.check('restricted entity: resolve is identical to a nonexistent ID (same output, same shape)',
  tests.outcome('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:R')))),
  tests.outcome('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select id from fake))));
select tests.check('...entity_get', tests.outcome('web_lead', format($q$ select coalesce(entity_get(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:R')))), tests.outcome('web_lead', format($q$ select coalesce(entity_get(%L)::text, 'null') $q$, (select id from fake))));
select tests.check('...search_route by ID', tests.outcome('web_lead', format($q$ select search_route(%L)::text $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:R')))), tests.outcome('web_lead', format($q$ select search_route(%L)::text $q$, (select id from fake))));
select tests.check('...search_route by legacy ID', tests.outcome('web_lead', format($q$ select search_route(%L)::text $q$, (select ada_id from entity_registry where entity_id = tests.id('asset:R')))), tests.outcome('web_lead', format($q$ select search_route(%L)::text $q$, 'ADA-AST-2026-9999')));
select tests.check('...a direct registry query by ID and by domain key', tests.outcome('web_lead', format($q$ select count(*)::text from entity_registry where institutional_id = %L or entity_id = %L $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:R')), tests.id('asset:R'))), tests.outcome('web_lead', format($q$ select count(*)::text from entity_registry where institutional_id = %L or entity_id = %L $q$, (select id from fake), tests.id('x:random'))));
select tests.check('...the directory view and the location history', tests.same_for('web_lead', $q$ select (select count(*) from entity_directory where authoritative_record_key = %1$L)::text || (select count(*) from entity_location_history h join entity_registry r using (institutional_id) where r.entity_id = %1$L) $q$, tests.id('asset:R'), tests.id('x:random')), 'same');
select tests.check('control: the same lookups DO work for someone authorised', tests.scalar('ceo', format($q$ select (entity_resolve(%L) is not null)::text $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:R')))), 'true');
select tests.check('a classification of Internal alone does not grant access: Tech, which cannot see Web''s unassigned assets, resolves nothing',
  tests.scalar('tech_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = (select id from assets where name = 'Card test')))), 'null');

create function pg_temp.plan(p_sql text) returns text language plpgsql as $$
declare l text; r text := '';
begin for l in execute 'explain ' || p_sql loop r := r || l || E'\n'; end loop; return r; end $$;
select tests.check('registry-first retrieval: looking an ID up uses the registry primary key (an index probe), never a table scan',
  (select (p like '%entity_registry_pkey%' and p not like '%Seq Scan%')::text from (select pg_temp.plan($q$ select * from entity_registry where institutional_id = 'AAAAAAAAA' $q$) p) q), 'true');
select tests.check('...and so does a lookup by legacy ID and by authoritative record key',
  (select (p1 like '%entity_registry_ada_id_key%' and p2 like '%entity_registry_domain_idx%')::text from (select pg_temp.plan($q$ select * from entity_registry where ada_id = 'ADA-AST-2026-0001' $q$) p1, pg_temp.plan($q$ select * from entity_registry where table_name = 'assets' and entity_id = gen_random_uuid() $q$) p2) q), 'true');

-- Every authoritative table is wired to the registry (the rule that tickets, documents and every future module must follow)
select tests.check('every built entity type has a codebook entry and a real authoritative table wired to registration and sync',
  (select coalesce(string_agg(t.key, ','), 'none') from entity_types t where t.is_built and (
      not exists (select 1 from id_codebook c where c.kind = 'type' and c.meaning = t.key and c.code = t.id_code)
      or to_regclass('public.' || t.domain_table) is null
      or not exists (select 1 from pg_trigger g where g.tgrelid = to_regclass('public.' || t.domain_table) and g.tgname = 'ada_id_register')
      or not exists (select 1 from pg_trigger g where g.tgrelid = to_regclass('public.' || t.domain_table) and g.tgname = 'registry_sync_trg'))), 'none');
select tests.check('no table has its own ID generator: the only function that mints identifiers is the central service',
  (select coalesce(string_agg(proname, ','), 'none') from pg_proc where pronamespace = 'public'::regnamespace and prosrc ~* 'id_counters|id_sequences' and proname not in ('ada_mint_id', 'next_ada_id')), 'none');

-- Search index: derived, rebuildable, visibility-bound ---------------------------------------------------------------------------------------------
select tests.check('the search index is maintained incrementally from the authoritative records (and can be rebuilt from them)', (select (count(*) > 5)::text from search_index), 'true');
select tests.check('users cannot rebuild it', tests.scalar('ceo', 'select search_rebuild()::text'), 'ERR:42501');
select search_rebuild() as rebuilt \gset
select tests.check('the rebuild indexes labelled entities', (select (:rebuilt > 5)::text), 'true');
create temp table idx_before as select institutional_id, label from search_index;
delete from search_index;
select search_rebuild();
select tests.check('the index is rebuildable: deleting it and rebuilding reproduces exactly the same rows', (select count(*)::text from (select * from idx_before except select institutional_id, label from search_index) q) || (select count(*)::text from (select institutional_id, label from search_index except select * from idx_before) q), '00');
select tests.check('every index row points at a real registry entry and a real authoritative record', (select count(*)::text from search_index s where not exists (select 1 from entity_registry r where r.institutional_id = s.institutional_id and r.entity_id = s.entity_id)), '0');
select tests.check('text search returns visible entities', tests.scalar('ceo', $q$ select (search_route('Lenovo') -> 'results' -> 0 ->> 'label') $q$), 'Lenovo ThinkPad X1');
select tests.check('text search never reveals a restricted entity: the same answer as for a term that matches nothing',
  tests.outcome('web_lead', $q$ select (search_route('Hidden laptop') -> 'results')::text $q$), tests.outcome('web_lead', $q$ select (search_route('Nothing matches this') -> 'results')::text $q$));
select tests.check('...and the raw index is filtered the same way', tests.outcome('web_lead', $q$ select count(*)::text from search_index where label ilike '%hidden%' $q$), tests.outcome('web_lead', $q$ select count(*)::text from search_index where label ilike '%nothing%' $q$));
select tests.check('control: management finds it', tests.scalar('ceo', $q$ select jsonb_array_length(search_route('Hidden laptop') -> 'results')::text $q$), '1');
select tests.check('free text goes to the index route, an ID to the registry route', tests.scalar('ceo', $q$ select (search_route('Lenovo') ->> 'route') $q$) || tests.scalar('ceo', format($q$ select (search_route(%L) ->> 'route') $q$, (select institutional_id from entity_registry where entity_id = tests.id('asset:A')))), 'indexregistry');

-- Security: staff identity, denial audit, escalation ----------------------------------------------------------------------------------------------
-- (a fresh actor, web_staff, so earlier probes by other users do not count towards its totals)
create temp table hid as select institutional_id i from entity_registry where entity_id = tests.id('asset:R');
select tests.check('a single denied lookup is only an audit event: no flag, no case', tests.scalar('web_staff', format($q$ select (entity_resolve(%L) is null)::text $q$, (select i from hid))), 'true');
select tests.check('...one event, no case', (select count(*)::text from security_events where actor_staff_id = tests.id('staff:web_staff')) || (select count(*)::text from security_cases where actor_staff_id = tests.id('staff:web_staff')), '10');
select tests.check('the event records the authenticated staff identity, the action, classification and that the entity exists (internally)',
  (select (requested_action = 'resolve' and entity_exists and entity_class = 'restricted' and kind = 'lookup' and requested_input = (select i from hid))::text from security_events where actor_staff_id = tests.id('staff:web_staff')), 'true');
select tests.check('an unresolved lookup is recorded the same way (without an entity)', tests.scalar('web_staff', format($q$ select (entity_resolve(%L) is null)::text $q$, (select id from fake))), 'true');
select tests.check('...marked as not existing, internally', (select count(*) filter (where not entity_exists)::text from security_events where actor_staff_id = tests.id('staff:web_staff')), '1');
select tests.check('the actor cannot see the security log or cases', tests.scalar('web_staff', 'select (select count(*) from security_events)::text || (select count(*) from security_cases)'), '00');
select tests.check('repeated denials raise a security flag (5 within 10 minutes)', tests.scalar('web_staff', format($q$ select count(entity_resolve(%L))::text from generate_series(1, 3) $q$, (select i from hid))), '0');
select tests.check('...a flagged, low-severity case exists for that actor', (select status || '/' || severity from security_cases where actor_staff_id = tests.id('staff:web_staff')), 'flagged/low');
select tests.check('the flag is an investigation entity with its own institutional ID', (select count(*)::text from entity_registry where entity_type = 'investigation_case' and entity_family = 'governance' and entity_id = (select id from security_cases where actor_staff_id = tests.id('staff:web_staff'))), '1');
select tests.check('security staff are notified without any entity detail', (select (count(*) >= 1 and bool_and(body is null and entity_ada_id is null))::text from notifications where type = 'security.case' and title like 'Security flag%' and recipient_staff_id = tests.id('staff:ceo')), 'true');
select tests.check('a sustained pattern opens an investigation case (15 within the hour) and escalates its severity', tests.scalar('web_staff', format($q$ select count(entity_resolve(%L))::text from generate_series(1, 11) $q$, (select id from fake))), '0');
select tests.check('...open, medium, 16 events', (select status || '/' || severity || '/' || event_count::text from security_cases where actor_staff_id = tests.id('staff:web_staff')), 'open/medium/16');
select tests.check('one live case per actor, however many events', (select count(*)::text from security_cases where actor_staff_id = tests.id('staff:web_staff') and status <> 'closed'), '1');
select tests.check('another staff member''s denials are counted separately: one lookup by the Tech staff member raises nothing',
  tests.scalar('tech_staff', format($q$ select (entity_resolve(%L) is null)::text $q$, (select i from hid))), 'true');
select tests.check('...for them', (select count(*)::text from security_events where actor_staff_id = tests.id('staff:tech_staff')) || (select count(*)::text from security_cases where actor_staff_id = tests.id('staff:tech_staff')), '10');
select tests.check('a login without a staff record is still recorded (by user id)', tests.scalar('outsider', format($q$ select (entity_resolve(%L) is null)::text $q$, (select id from fake))), 'true');
select tests.check('...with no staff identity and the user id kept', (select count(*)::text from security_events where actor_staff_id is null and actor_user_id = tests.uid('outsider')), '1');
select tests.check('only security staff see events and cases (management, auditor); web staff do not', tests.scalar('ceo', 'select ((select count(*) from security_events) > 0)::text || ((select count(*) from security_cases) > 0)::text') || tests.scalar('audit', 'select ((select count(*) from security_events) > 0)::text'), 'truetruetrue');
select tests.check('a gateway can report a denial it observed (the database cannot log a failure that rolls back)', tests.try('tech_staff', $q$ select security_report_denial('asset_update', 'ADA-AST-2026-0001') $q$), 'ok');
select tests.check('...and it is on record', (select count(*)::text from security_events where requested_action = 'client-reported:asset_update' and actor_staff_id = tests.id('staff:tech_staff')), '1');
select security_report_bypass(tests.id('staff:tech_lead'), 'forged_claim', 'attempted to set role');
select tests.check('a bypass attempt opens a critical, open case immediately (one event)', (select status || '/' || severity from security_cases where actor_staff_id = tests.id('staff:tech_lead')), 'open/critical');
select tests.check('only security.manage can work or close a case, and closing needs a resolution',
  tests.scalar('audit', format($q$ select security_case_update(%L, 'closed', 'x')::text $q$, (select id from security_cases where actor_staff_id = tests.id('staff:tech_lead')))) || tests.scalar('ceo', format($q$ select security_case_update(%L, 'closed', ' ')::text $q$, (select id from security_cases where actor_staff_id = tests.id('staff:tech_lead')))), 'ERR:42501ERR:23514');
select tests.check('...management closes it with a resolution', tests.try('ceo', format($q$ select security_case_update(%L, 'closed', 'False alarm: test')$q$, (select id from security_cases where actor_staff_id = tests.id('staff:tech_lead')))), 'ok');
select tests.check('security events cannot be edited or deleted', tests.try_owner('update security_events set reason = ''x''') || tests.try_owner('delete from security_events'), 'ERR:42501ERR:42501');
select tests.check('the escalation policy is data, configurable by security.manage only', tests.try('audit', $q$ update security_policies set threshold = 1000 $q$) || tests.try('ceo', $q$ update security_policies set threshold = threshold where kind = 'bypass' $q$), 'ok0ok');

select tests.finish();
rollback;
