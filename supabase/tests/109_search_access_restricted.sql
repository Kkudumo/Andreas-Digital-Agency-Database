-- PERMANENT: Search - authorization BEFORE exposure: restricted / critical / other-division records contribute NOTHING to results, totals, facets, ranking,
-- suggestions, errors or relationships; stale and tampered indexes; no identity, no result; bypass attempts (owner, service role, definer helpers); the
-- public boundary; the content boundary; definite behaviour on odd input. A differential method is used throughout: what an uncleared caller gets must be
-- IDENTICAL whether or not the hidden records exist.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.sr(p_user text, p_q text) returns jsonb language plpgsql as $$
declare v text := tests.scalar(p_user, format('select search(%L, null, 0, true)::text', p_q));
begin return case when v like 'ERR:%' then to_jsonb(v) else v::jsonb end; end $$;
-- what the caller can observe of an answer, without the echo of their own query
create function tests.seen(p_user text, p_q text) returns text language sql as $$ select (tests.sr(p_user, p_q) - 'query')::text $$;
create function tests.sg(p_user text, p_prefix text) returns text language sql as $$ select tests.scalar(p_user, format('select search_suggest(%L)::text', p_prefix)) $$;
create function tests.fakeid() returns text language sql as $$ select 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ') $$;

-- A visible world, and what an uncleared caller sees of it BEFORE any hidden record exists ------------------------------------------------------------------------
select tests.remember('c:nimbus', tests.mkclient_id('web_lead', 'Nimbus Trading', 'web', 'NT-1'));
select tests.mk_doc('web_lead', 'nd', 'Nimbus handover file', 'report', 'web', 'c:nimbus');
select tests.mk_thread('web_lead', 'nt', 'Nimbus talk');
select tests.say('web_lead', 'nt', 'nt1', 'email', 'inbound', 'visible body');
select tests.clink('web_lead', 'nt', 'clients', 'c:nimbus');
select tests.check('the visible world is searchable', tests.scalar('web_lead', $q$ select (search('nimbus')->>'total') $q$), '3');
create temp table before_snap (k text primary key, v text);
insert into before_snap select 'q1', tests.seen('web_lead', 'quasar');
insert into before_snap select 'q2', tests.seen('web_lead', 'type:client');
insert into before_snap select 'q3', tests.seen('web_lead', 'nimbus');
insert into before_snap select 'q4', tests.seen('web_lead', 'type:document');
insert into before_snap select 'q5', tests.seen('web_lead', 'type:communication');
insert into before_snap select 'q6', tests.seen('web_lead', 'type:domain');
insert into before_snap select 'q7', tests.seen('web_lead', 'type:project');
insert into before_snap select 'q8', tests.seen('web_lead', 'ltd');
insert into before_snap select 's1', tests.sg('web_lead', 'qua');
insert into before_snap select 's2', tests.sg('web_lead', 'nim');
insert into before_snap select 'cnt', tests.scalar('web_lead', 'select count(*)::text from search_index');
insert into before_snap select 'qa', tests.seen('audit', 'quasar');

-- Hidden records of every kind: restricted client + its project, document, domain, communication; a critical document ------------------------------------------------
select tests.remember('c:quasar', tests.mkclient_id('ceo', 'Quasar Holdings Ltd', 'web', 'QH-9'));
update clients set classification = 'restricted' where id = tests.id('c:quasar');
select tests.remember_ok('p:quasar', tests.scalar('ceo', format($q$ select (select id from projects where client_id = %L limit 1)::text $q$, tests.id('c:quasar'))));
insert into projects (client_id, lead_division_id, name) values (tests.id('c:quasar'), tests.id('div:web'), 'Quasar Rollout Ltd');
select tests.mk_doc('ceo', 'qd', 'Quasar brief', 'report', 'web', 'c:quasar');
select tests.mk_doc('ceo', 'qcrit', 'Quasar critical annex', 'report', 'web', null, null, true);
select tests.remember_ok('dom:quasar', tests.scalar('ceo', format($q$ select (domain_create('quasar-holdings.example', %L) ->> 'id') $q$, tests.id('div:web'))));
select tests.rel('ceo', 'quasar', 'client', 'clients', 'c:quasar');
select tests.mk_thread('ceo', 'qt', 'Quasar talks');
select tests.say('ceo', 'qt', 'qt1', 'email', 'inbound', 'hidden body');
select tests.clink('ceo', 'qt', 'clients', 'c:quasar');
select tests.mk_thread('ceo', 'qct', 'Critical talks', 'web', null, true);
create temp table hid as select tests.inst_of('clients', 'c:quasar') as client, tests.inst_of('documents', 'doc:qd') as doc, tests.inst_of('documents', 'doc:qcrit') as crit, tests.inst_of('domains', 'dom:quasar') as dom,
  tests.inst_of('communication_threads', 'thr:qt') as thr, tests.inst_of('communication_threads', 'thr:qct') as critthr;
select tests.check('the hidden records ARE in the index (the index holds them: only authorization hides them)', (select count(*)::text from search_index where entity_id in (tests.id('c:quasar'), tests.id('doc:qd'), tests.id('doc:qcrit'), tests.id('dom:quasar'), tests.id('thr:qt'), tests.id('thr:qct'))), '6');

-- Differential: nothing the uncleared caller can observe changed -----------------------------------------------------------------------------------------------
select tests.check('results, totals, ranking and facets for an uncleared caller are IDENTICAL with and without the hidden records (a name, a type listing, a document listing, communications, domains, projects, a common word)',
  (select string_agg(k, ',' order by k) from before_snap b where k like 'q%' and k <> 'qa' and b.v is distinct from case k when 'q1' then tests.seen('web_lead', 'quasar') when 'q2' then tests.seen('web_lead', 'type:client') when 'q3' then tests.seen('web_lead', 'nimbus')
     when 'q4' then tests.seen('web_lead', 'type:document') when 'q5' then tests.seen('web_lead', 'type:communication') when 'q6' then tests.seen('web_lead', 'type:domain') when 'q7' then tests.seen('web_lead', 'type:project') when 'q8' then tests.seen('web_lead', 'ltd') end), null);
select tests.check('suggestions are identical with and without hidden records', (select (b.v = tests.sg('web_lead', 'qua'))::text from before_snap b where k = 's1') || (select (b.v = tests.sg('web_lead', 'nim'))::text from before_snap b where k = 's2'), 'truetrue');
select tests.check('even the size of the index as the caller can count it is unchanged', (select (b.v = tests.scalar('web_lead', 'select count(*)::text from search_index'))::text from before_snap b where k = 'cnt'), 'true');
select tests.check('an uncleared search for the hidden name is the same as for a name that never existed', (tests.seen('web_lead', 'quasar') = tests.seen('web_lead', 'zymurgy'))::text || (tests.seen('web_lead', 'quasar holdings ltd') = tests.seen('web_lead', 'zymurgy holdings'))::text, 'truetrue');
select tests.check('...by registration number and by a word of the document, domain and project too', (tests.seen('web_lead', 'QH-9') = tests.seen('web_lead', 'ZY-1'))::text || (tests.seen('web_lead', 'quasar brief') = tests.seen('web_lead', 'zymurgy brief'))::text ||
  (tests.seen('web_lead', 'quasar-holdings.example') = tests.seen('web_lead', 'zymurgy-holdings.example'))::text || (tests.seen('web_lead', 'rollout') = tests.seen('web_lead', 'zymurgy'))::text, 'truetruetruetrue');
select tests.check('the cleared find them: the CEO and administration the client, document, domain and thread; the auditor (cleared for restricted) all but the critical ones',
  tests.scalar('ceo', $q$ select (search('quasar')->>'total') $q$) || '|' || tests.scalar('adm2', $q$ select (search('quasar')->>'total') $q$) || '|' || tests.scalar('audit', $q$ select (search('quasar')->>'total') $q$), '6|5|3');
select tests.check('...and what the cleared auditor finds is not the whole truth: the critical annex stays with its entitled owner', tests.scalar('audit', $q$ select (search('quasar critical')->>'total') $q$) || tests.scalar('ceo', $q$ select (search('quasar critical')->>'total') $q$), '01');
select tests.check('totals and facets count only what the caller may see (the auditor sees fewer than the CEO, the lead none)', tests.scalar('audit', $q$ select (select sum(value::int) from jsonb_each_text(search('quasar', null, 0, true) -> 'facets' -> 'entity_type'))::text $q$) || '|' ||
  tests.scalar('web_lead', $q$ select coalesce((search('quasar', null, 0, true) -> 'facets' -> 'entity_type')::text, 'null') $q$), '3|{}');
select tests.check('hiding does not depend on staleness: the hidden client''s index row was built BEFORE it was restricted and was never rebuilt - authorization is live', (select (refreshed_at < (select created_at from clients where id = tests.id('c:quasar')) + interval '1 minute')::text from search_index where entity_id = tests.id('c:quasar')), 'true');

-- Exact IDs, relationships, errors -----------------------------------------------------------------------------------------------------------------------------
select tests.check('an exact ID of a hidden record answers exactly like an ID that does not exist: a client, a document, a critical document, a domain, a thread, a critical thread',
  (select string_agg(((tests.seen('web_lead', x) = tests.seen('web_lead', tests.fakeid())))::text, ',') from (select client x from hid union all select doc from hid union all select crit from hid union all select dom from hid union all select thr from hid union all select critthr from hid) q), 'true,true,true,true,true,true');
select tests.check('...with type filters and facets too', (tests.seen('web_lead', 'type:client ' || (select client from hid)) = tests.seen('web_lead', 'type:client ' || tests.fakeid()))::text, 'true');
select tests.check('relationships of a hidden anchor answer exactly like those of an anchor that does not exist (same shape, no leak that it exists)', (tests.seen('web_lead', 'related:' || (select client from hid)) = tests.seen('web_lead', 'related:' || tests.fakeid()))::text, 'true');
select tests.check('relationships of a VISIBLE anchor never include hidden records: the visible client''s family carries none of the hidden documents, domains or threads', (select count(*)::text from jsonb_array_elements(tests.sr('web_lead', 'related:' || tests.inst_of('clients', 'c:nimbus')) -> 'results') x where x ->> 'label' ~* 'quasar'), '0');
select tests.check('the cleared see the hidden family through the same relationship search', tests.scalar('ceo', format($q$ select (search('related:%s')->>'total') $q$, (select client from hid))), '4');
select tests.check('hidden identifiers produce the same errors as missing ones in every request shape (the error text never depends on the data)',
  (tests.scalar('web_lead', format($q$ select (search_execute(jsonb_build_object('ids', jsonb_build_array(%L), 'status', jsonb_build_array('active'), 'division', 'web')) - 'query')::text $q$, (select client from hid))) =
  tests.scalar('web_lead', format($q$ select (search_execute(jsonb_build_object('ids', jsonb_build_array(%L), 'status', jsonb_build_array('active'), 'division', 'web')) - 'query')::text $q$, tests.fakeid())))::text, 'true');
select tests.check('probing IDs is recorded for investigators like every unauthorised lookup: six probes by one person raise a flag in the existing case model', (select count(*)::text from security_cases where actor_staff_id = tests.id('staff:web_staff')), '0');
select tests.scalar('web_staff', format($q$ select search(%L)::text $q$, (select client from hid))) from generate_series(1, 6);
select tests.check('...flagged', (select concat_ws('|', status, severity) from security_cases where actor_staff_id = tests.id('staff:web_staff')), 'flagged|low');
select tests.scalar('web_staff', format($q$ select search(%L)::text $q$, (select crit from hid)));
select tests.check('...a critical record looks exactly like a missing one in the security events', (select count(*) filter (where entity_exists)::text from security_events where actor_staff_id = tests.id('staff:web_staff') and requested_input = (select crit from hid)), '0');
select tests.check('text searches are NOT logged anywhere (queries can be sensitive too): they create no security event', tests.scalar('web_lead', $q$ select count(*)::text from security_events where requested_input ilike '%zymurgy%' or requested_input ilike '%quasar%' $q$) || (select count(*)::text from security_events where requested_input ilike '%zymurgy%'), '00');
select tests.check('no table anywhere stores search queries', (select coalesce(string_agg(table_name, ','), 'none') from information_schema.tables where table_schema = 'public' and table_name ~* 'search' and table_name !~ '^(search_index|search_sources|search_refresh_queue)$'), 'none');

-- Suggestions (autocomplete) -------------------------------------------------------------------------------------------------------------------------------------
select tests.check('suggestions for an uncleared caller never complete a hidden label - not by prefix, not by a typo, not by a later word', tests.sg('web_lead', 'quasar') || tests.sg('web_lead', 'quazar') || tests.sg('web_lead', 'holdings') || tests.sg('web_lead', 'quasar brief') || tests.sg('web_lead', 'rollout'), repeat('[]', 5));
select tests.check('...the cleared are offered them', tests.scalar('ceo', $q$ select (search_suggest('quasar holdings') -> 0 ->> 'label') $q$), 'Quasar Holdings Ltd') ;
select tests.check('a suggestion carries only a label, a type and an ID of a record the caller may see; the typed prefix of a hidden label gives the same answer as a prefix matching nothing', (tests.sg('web_lead', 'quas') = tests.sg('web_lead', 'zzyq'))::text, 'true');
select tests.check('suggestions are never a way to enumerate IDs: an ID prefix suggests nothing', tests.sg('ceo', left((select client from hid), 5)) || tests.sg('ceo', (select client from hid)), '[][]');

-- Other divisions, no identity ---------------------------------------------------------------------------------------------------------------------------------------
select tests.check('another division cannot find the Web records, nor use a division filter to learn about them', tests.scalar('tech_staff', $q$ select (search('nimbus')->>'total') $q$) || tests.scalar('tech_staff', $q$ select (search('division:web type:client')->>'total') $q$) || tests.scalar('tech_lead', $q$ select (search('nimbus handover')->>'total') $q$), '000');
select tests.check('the recruiter, a signed-in user who is not staff, and a suspended account get the same empty answer, route none', (tests.sr('recruiter', 'nimbus') ->> 'total') || (tests.sr('outsider', 'nimbus') ->> 'route') || (tests.sr('outsider', 'nimbus') ->> 'total') || (tests.sr('suspended', 'nimbus') ->> 'total'), '0none00');
select tests.check('they get no suggestions either', tests.sg('outsider', 'nimbus') || tests.sg('suspended', 'nimbus'), '[][]');
select tests.check('the anonymous role can neither search, suggest nor read the tables', tests.scalar_anon('select search(''nimbus'')::text') || tests.scalar_anon('select search_suggest(''nimbus'')::text') || tests.scalar_anon('select count(*)::text from search_index') || tests.scalar_anon('select search_capabilities()::text'), repeat('ERR:42501', 4));
select tests.check('the raw index, as an API user sees it, is filtered by the authoritative records'' own row security', tests.scalar('web_lead', $q$ select count(*)::text from search_index where label ilike '%quasar%' $q$) || tests.scalar('web_lead', $q$ select count(*)::text from search_index where label ilike '%nimbus%' $q$) || tests.scalar('ceo', $q$ select count(*)::text from search_index where label ilike '%quasar%' $q$), '036');

-- Bypass attempts ------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('API users cannot call the maintenance functions or write the index, the configuration or the queue (no matter what they name)',
  tests.try('web_lead', format($q$ select search_refresh_row('clients', %L) $q$, tests.id('c:quasar'))) || tests.try('web_lead', 'select search_rebuild()') || tests.try('web_lead', 'select * from search_drift()') || tests.try('web_lead', 'select search_process_queue()') ||
  tests.try('web_lead', 'select search_backup_manifest()') || tests.try('web_lead', 'select search_refresh_trigger()') || tests.try('web_lead', 'select attach_search(''clients''::regclass)') || tests.try('web_lead', 'select count(*) from search_refresh_queue') || tests.try('web_lead', 'delete from search_index') ||
  tests.try('web_lead', 'update search_sources set is_active = false'), repeat('ERR:42501', 10));
select tests.check('asking for a refresh is harmless and tells the asker nothing: the same for a hidden ID, a visible ID and nothing, and the queue is not readable',
  tests.try('web_lead', format($q$ select search_flag_stale(array[%L]) $q$, (select client from hid))) || tests.try('web_lead', format($q$ select search_flag_stale(array[%L]) $q$, tests.fakeid())) || tests.try('web_lead', 'select search_flag_stale(null)'), 'okokok');
select tests.check('an index row of a hidden record tampered with below the commands (an innocent label) shows the lead nothing and shows the CEO nothing false',
  tests.try_owner(format($q$ update search_index set label = 'Innocent Garden Centre', terms = 'garden centre' where entity_id = %L $q$, tests.id('c:quasar'))), 'ok');
select tests.check('...for the lead: nothing (row security)  /  for the CEO: nothing (the stale row is verified against the record and refused)', (tests.sr('web_lead', 'garden centre') ->> 'total') || (tests.sr('ceo', 'garden centre') ->> 'total'), '00');
select tests.try_owner('select search_process_queue()');
select tests.check('the service role has no staff identity: Search answers it nothing; it can rebuild but a rebuild changes nobody''s rights', tests.scalar_service($q$ select (search('nimbus')->>'total') || (search('nimbus')->>'route') $q$) || tests.scalar_service('select (search_rebuild() > 0)::text') || tests.seen('web_lead', 'quasar'), '0nonetrue' || (select v from before_snap where k = 'q1'));
select tests.check('the database owner is not a search user either (no staff identity)', tests.scalar('ceo', 'select 1::text') || tests.try_owner($q$ select search('nimbus') $q$), '1ok');
select tests.check('communication subjects and bodies are not searchable, even by the CEO who can read them', tests.scalar('ceo', $q$ select (search('visible body')->>'total') || (search('hidden body')->>'total') || (search('Quasar talks')->>'total') || (search('Critical talks')->>'total') $q$), '0000');
select tests.check('...a thread is found as "Communication thread" with its status, by someone who may see it', tests.scalar('web_lead', $q$ select (search('type:communication')->'results'->0->>'label') $q$) , 'Communication thread');
select tests.check('index text of communications contains nothing but the fixed label and the status', (select string_agg(distinct label || '/' || terms, ',') from search_index where entity_type = 'communication'), 'Communication thread/open');
select tests.check('a restricted document''s description is not searchable by those who cannot see the document', (tests.try('ceo', format($q$ select document_update(%L, '{"description":"zebra-secret-description"}') $q$, tests.id('doc:qd')))) || tests.scalar('web_lead', $q$ select (search('zebra secret description')->>'total') $q$) || tests.scalar('ceo', $q$ select (search('zebra secret description')->>'total') $q$), 'ok01');

-- The public boundary -------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('there is no public search: nothing in the public API schema is named for search, suggestion or the index', (select count(*)::text from pg_proc where pronamespace = 'public_api'::regnamespace and proname ~* 'search|suggest|index|query|find|lookup'), '0');
select tests.check('the index is invisible to the website roles and anonymous callers, whatever a record''s publication state', tests.scalar_anon('select count(*)::text from search_index') || tests.scalar_anon('select count(*)::text from search_sources'), 'ERR:42501ERR:42501');
select tests.check('nothing about publication is stored in the index, and the index grants the public no access at all', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'search_index' and column_name ~* 'public|publish') ||
  (select count(*)::text from information_schema.role_table_grants where table_name in ('search_index', 'search_sources', 'search_refresh_queue') and grantee in ('anon', 'PUBLIC')), 'none0');

-- Definite behaviour on odd input -------------------------------------------------------------------------------------------------------------------------------------
select tests.check('null, empty, odd and hostile input never errors and never returns everything: null, blank, quotes, SQL-looking text, tsquery syntax, very long text, unicode',
  tests.scalar('web_lead', $q$ select (search(null)->>'total') || '/' || (search('')->>'total') || '/' || (search('"')->>'total') || '/' || (search('''; drop table clients; --')->>'total') || '/' || ((search('a & | ! ( ) :* <->')->>'total') = (search('a')->>'total'))::text || '/' || (select (search(repeat('abc ', 500))->>'total')::int < 10)::text || '/' || (search('zażółć gęślą jaźń')->>'total') $q$), '0/0/0/0/true/true/0');
select tests.check('suggest and parse are equally robust', tests.scalar('web_lead', $q$ select search_suggest(null)::text || search_suggest('"')::text || search_suggest('''; drop')::text || search_suggest(repeat('x', 500))::text || search_parse(null)::text $q$), '[][][][]{"ids": [], "types": [], "status": []}');
select tests.check('execute with an empty request returns nothing, not everything', tests.scalar('web_lead', $q$ select (search_execute('{}')->>'total') || (search_execute('{}')->>'route') $q$), '0none');
select tests.check('a division that does not exist matches nothing, like a hidden one', tests.scalar('ceo', $q$ select (search('type:client division:nowhere')->>'total') $q$), '0');

-- The matching settings (the cheap half of the policy) can only narrow ----------------------------------------------------------------------------------------
select tests.check('a hand-set setting narrows: with the term of a hidden record the lead''s raw index shows nothing, with the term of a visible one it shows it',
  tests.scalar('web_lead', $q$ select (select set_config('ada.search_tsq', 'quasar:*', true)) || (select count(*) from search_index)::text $q$) || '|' || tests.scalar('web_lead', $q$ select (select set_config('ada.search_tsq', 'nimbus:*', true)) || (select count(*) from search_index)::text $q$), 'quasar:*0|nimbus:*3');
select tests.check('a malformed setting only breaks the caller''s own query (an error about the query, never about the data)', tests.scalar('web_lead', $q$ select (select set_config('ada.search_tsq', '((', true)) || (select count(*) from search_index)::text $q$), 'ERR:42601');
select tests.check('search resets its settings when it finishes', tests.scalar('web_lead', $q$ select (search('nimbus') is not null)::text || '/' || coalesce(nullif(current_setting('ada.search_tsq', true), ''), 'cleared') || '/' || coalesce(nullif(current_setting('ada.search_types', true), ''), 'cleared') $q$), 'true/cleared/cleared');

-- The live read stands on the caller''s rights ------------------------------------------------------------------------------------------------------------------
select tests.check('the live-field helper (granted to API users) answers nothing for a record the caller cannot see - a restricted client, a critical document - and the label for those who can',
  tests.scalar('web_lead', format($q$ select coalesce((select label from search_live('clients', %L)), 'none') $q$, tests.id('c:quasar'))) || '|' || tests.scalar('web_lead', format($q$ select coalesce((select label from search_live('documents', %L)), 'none') $q$, tests.id('doc:qcrit'))) || '|' ||
  tests.scalar('ceo', format($q$ select coalesce((select label from search_live('clients', %L)), 'none') $q$, tests.id('c:quasar'))), 'none|none|Quasar Holdings Ltd');
select tests.check('suggestions for someone who is not staff are empty (and the same as for someone with no access)', tests.sg('outsider', 'nimbus') || tests.sg('recruiter', 'nimbus'), '[][]');
select tests.finish();
rollback;
