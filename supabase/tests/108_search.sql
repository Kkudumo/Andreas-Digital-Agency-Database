-- PERMANENT: Search - a derived, rebuildable retrieval layer: configuration and what is (not) indexed, incremental maintenance, exact IDs, text / prefix /
-- spelling, filters, determinism, the request contract, relationships across modules, historical (as-of) retrieval, stale indexes, rebuild and drift,
-- suggestions. (Authorization / non-disclosure: 109.)
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create function tests.sr(p_user text, p_q text) returns jsonb language plpgsql as $$
declare v text := tests.scalar(p_user, format('select search(%L)::text', p_q));
begin return case when v like 'ERR:%' then to_jsonb(v) else v::jsonb end; end $$;
create function tests.labels(p_user text, p_q text) returns text language sql as $$
  select coalesce((select string_agg(x ->> 'label', '|' order by ord) from jsonb_array_elements(tests.sr(p_user, p_q) -> 'results') with ordinality t(x, ord)), '-')
$$;
create function tests.total(p_user text, p_q text) returns text language sql as $$ select tests.sr(p_user, p_q) ->> 'total' $$;

-- Configuration, and what the index is --------------------------------------------------------------------------------------------------------------------
select tests.check('every configured source is an entity type of the registry, and the configuration has no content-like attribute (the table refuses one)',
  (select count(*)::text from search_sources s where not exists (select 1 from entity_types t where t.key = s.entity_type and t.is_built)) ||
  tests.try_owner($q$ insert into search_sources (entity_type, label_expr) values ('lead', 'x.title || x.subject') on conflict (entity_type) do update set label_expr = excluded.label_expr $q$) ||
  tests.try_owner($q$ update search_sources set attribute_exprs = array['x.body'] where entity_type = 'lead' $q$) || tests.try_owner($q$ update search_sources set attribute_exprs = array['x.storage_key'] where entity_type = 'document' $q$) ||
  tests.try_owner($q$ update search_sources set attribute_exprs = array['x.notes'] where entity_type = 'supplier' $q$), '0ERR:23514ERR:23514ERR:23514ERR:23514');
select tests.check('API users cannot change the configuration, the index or the queue', tests.try('ceo', $q$ update search_sources set is_active = false $q$) || tests.try('ceo', $q$ insert into search_index (institutional_id, entity_type, table_name, entity_id, label) values ('ZZZZZZZZZ', 'client', 'clients', gen_random_uuid(), 'x') $q$) ||
  tests.try('ceo', 'delete from search_index') || tests.try('ceo', 'update search_index set label = ''x''') || tests.try('ceo', 'select count(*) from search_refresh_queue'), repeat('ERR:42501', 5));
select tests.check('the index holds no content-like column', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'search_index' and column_name ~* 'body|subject|content|storage|notes|class'), 'none');
select tests.check('every configured expression is readable by API users (column privileges): the select runs without a privilege error for every active source',
  (select string_agg(tests.try('ceo', format('select (%s)::text, concat_ws('' '', %s) from public.%I x limit 0', s.label_expr, case when cardinality(s.attribute_exprs) = 0 then '''''' else array_to_string(s.attribute_exprs, ', ') end, t.domain_table)), ',' order by s.entity_type) from search_sources s join entity_types t on t.key = s.entity_type),
  (select string_agg('ok0', ',' order by s.entity_type) from search_sources s));
select tests.check('the index is derived: every row points at a real registry entry and a real authoritative record, and the drift check finds nothing', (select count(*)::text from search_index s where not exists (select 1 from entity_registry r where r.institutional_id = s.institutional_id and r.entity_id = s.entity_id and r.table_name = s.table_name))
  || (select count(*)::text from search_drift()), '00');
select tests.check('users cannot run the rebuild, the drift check, the queue processor, the manifest, or the row refresh', tests.try('ceo', 'select search_rebuild()') || tests.try('ceo', 'select * from search_drift()') || tests.try('ceo', 'select search_process_queue()') || tests.try('ceo', 'select search_backup_manifest()') ||
  tests.try('ceo', format($q$ select search_refresh_row('clients', %L) $q$, tests.id('client:abc'))), repeat('ERR:42501', 5));

-- Incremental maintenance ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('a new client is searchable at once, by name and by registration number', tests.remember_ok('c:zeta', tests.mkclient_id('web_lead', 'Zeta Plumbing', 'web', 'ZP-2026/77')) , 'ok');
select tests.check('...by name (prefix, any case)', tests.labels('web_lead', 'type:client zeta plum') || '|' || tests.labels('web_lead', 'type:client ZETA'), 'Zeta Plumbing|Zeta Plumbing');
select tests.check('...by registration number (punctuation is not significant)', tests.labels('web_lead', 'type:client zp 2026 77') || '|' || tests.labels('web_lead', 'type:client ZP-2026/77'), 'Zeta Plumbing|Zeta Plumbing');
update clients set name = 'Zeta Pipes Ltd' where id = tests.id('c:zeta');
select tests.check('a rename moves the index with it: the new name is found, the old one is gone', tests.labels('web_lead', 'type:client zeta pipes') || '|' || tests.labels('web_lead', 'type:client plumbing'), 'Zeta Pipes Ltd|-');
select tests.check('the index follows the record without any rebuild (drift is empty)', (select count(*)::text from search_drift()), '0');
select tests.check('a rename of the organization record behind a client is also found', tests.total('ceo', 'zeta') , '2');
select tests.check('communication threads are indexed by a fixed label and status only: searchable as metadata, never by subject', (tests.mk_thread('web_lead', 'sbj', 'Confidential price negotiation') ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.say('web_lead', 'sbj', 'sbj1', 'email', 'inbound', 'Secret body words');
select tests.check('...the subject, body and participants are not searchable (even by the CEO), the thread is found as a communication', tests.total('ceo', 'confidential price negotiation') || tests.total('ceo', 'secret body words') || (select (terms = 'open')::text from search_index where entity_id = tests.id('thr:sbj')), '00true');
select tests.check('...and messages are not indexed at all', (select count(*)::text from search_index where table_name = 'communication_messages'), '0');
select tests.mk_doc('web_lead', 'sd1', 'Handover checklist', 'report', 'web', 'client:Zeta Pipes Ltd');
select tests.check('documents are indexed by title and description (metadata), found by title', tests.labels('web_lead', 'handover check'), 'Handover checklist');

-- Exact IDs -------------------------------------------------------------------------------------------------------------------------------------------------------
create temp table ids as select tests.inst_of('clients', 'c:zeta') as zeta, (select ada_id from entity_registry where table_name = 'clients' and entity_id = tests.id('c:zeta')) as zeta_ada, tests.inst_of('documents', 'doc:sd1') as sd1;
select tests.check('an institutional ID is an exact lookup through the registry', tests.sr('web_lead', (select zeta from ids)) ->> 'route' || '|' || tests.labels('web_lead', (select zeta from ids)), 'registry|Zeta Pipes Ltd');
select tests.check('...so is the legacy ADA identifier, in any case, and with surrounding words', tests.labels('web_lead', lower((select zeta_ada from ids))) || '|' || tests.labels('web_lead', 'type:client ' || (select zeta from ids)), 'Zeta Pipes Ltd|Zeta Pipes Ltd');
select tests.check('an ID with the wrong type filter finds nothing; an unknown ID finds nothing', tests.total('web_lead', 'type:document ' || (select zeta from ids)) || tests.total('web_lead', 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ')), '00');
select tests.check('IDs and text can be combined: the lookup and the text matches are merged without repeating', tests.labels('web_lead', (select zeta from ids) || ' type:client zeta') , 'Zeta Pipes Ltd');
select tests.check('the registry route does not scan: an ID answer carries label, type and status', tests.sr('web_lead', (select sd1 from ids)) -> 'results' -> 0 ->> 'entity_type', 'document');

-- Text, prefix, spelling, ranking -----------------------------------------------------------------------------------------------------------------------------
select tests.check('all words must match (as prefixes): "abc comp" finds ABC Company; "abc zzz" finds nothing', tests.labels('ceo', 'abc comp') || '|' || tests.total('ceo', 'abc zzz'), 'ABC Company|ABC Company|0');
select tests.check('a close spelling still finds it (trigram similarity on the label)', tests.labels('ceo', 'ABC Compnay'), 'ABC Company|ABC Company');
select tests.check('a quoted phrase is one term; punctuation and case do not matter', tests.labels('ceo', '"website and cctv for abc"') , 'Website and CCTV for ABC|Website and CCTV for ABC|Website and CCTV for ABC');
select tests.check('an exact label match ranks first', (tests.sr('ceo', 'zeta pipes ltd') -> 'results' -> 0 ->> 'label'), 'Zeta Pipes Ltd');
select tests.check('the same query gives the same answer every time (deterministic, no AI)', ((tests.sr('ceo', 'abc') -> 'results')::text = (tests.sr('ceo', 'abc') -> 'results')::text)::text || ((tests.sr('ceo', 'abc') -> 'results')::text = (tests.sr('ceo', 'ABC  ') -> 'results')::text)::text, 'truetrue');
select tests.check('an empty or blank query returns nothing, not everything', tests.total('ceo', '') || tests.total('ceo', '   '), '00');

-- Filters, facets, paging -------------------------------------------------------------------------------------------------------------------------------------
select tests.check('type: narrows by entity type; status: by the registry''s status', tests.labels('ceo', 'type:client abc') || '|' || tests.total('ceo', 'type:client status:active abc') || tests.total('ceo', 'type:client status:nonexistent abc'), 'ABC Company|10');
select tests.check('facets equal the result count', tests.scalar('ceo', $q$ select ((select sum(value::int) from jsonb_each_text(search_execute(jsonb_build_object('q', 'abc', 'facets', true)) -> 'facets' -> 'entity_type')) = (search_execute(jsonb_build_object('q', 'abc')) ->> 'total')::int)::text $q$), 'true');
select tests.check('limit and offset page through a stable order; the total does not change', tests.scalar('ceo', $q$ select (search_execute(jsonb_build_object('q', 'abc', 'limit', 2)) -> 'results' -> 1 ->> 'institutional_id') = (search_execute(jsonb_build_object('q', 'abc', 'limit', 1, 'offset', 1)) -> 'results' -> 0 ->> 'institutional_id') $q$) ||
  tests.scalar('ceo', $q$ select (search_execute(jsonb_build_object('q', 'abc', 'limit', 1, 'offset', 1)) ->> 'total') = (search_execute(jsonb_build_object('q', 'abc')) ->> 'total') $q$), 'truetrue');
select tests.check('the request contract is strict: unknown keys, wrong types, bad dates, too many IDs are refused with the same error whatever the data',
  tests.scalar('ceo', $q$ select search_execute('{"q":"a","sql":"drop"}')::text $q$) || tests.scalar('ceo', $q$ select search_execute('{"ids":"x"}')::text $q$) || tests.scalar('ceo', $q$ select search_execute('{"as_of":"not a date"}')::text $q$) ||
  tests.scalar('ceo', $q$ select search_execute('[1]')::text $q$) || tests.scalar('ceo', format($q$ select search_execute(jsonb_build_object('ids', (select jsonb_agg('ZZZZZZZZ' || n) from generate_series(1, 21) n)))::text $q$)), repeat('ERR:22023', 5));
select tests.check('limits: a huge limit is capped at 50, a negative offset at 0', tests.scalar('ceo', $q$ select (search_request_validate('{"q":"a","limit":5000,"offset":-5}') ->> 'limit') || '/' || (search_request_validate('{"q":"a","limit":5000,"offset":-5}') ->> 'offset') $q$), '50/0');
select tests.check('the parser knows its filters (type, status, division, related, asof, limit), IDs and phrases', tests.scalar('ceo', format($q$ select (search_parse('type:client status:active related:abcdefgh1 limit:5 "ABC Co" %s') - 'ids')::text $q$, (select zeta from ids))), '{"q": "ABC Co", "limit": 5, "types": ["client"], "status": ["active"], "related_to": "ABCDEFGH1"}');
select tests.check('the capability description is static and says search is deterministic and not public', tests.scalar('ceo', $q$ select (search_capabilities() ->> 'deterministic') || (search_capabilities() ->> 'public') $q$), 'truefalse');
select tests.check('there is no model, network or external dependency in search: no function of the module references anything but the database', (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'search%' and prosrc ~* '\y(http|https|curl|openai|anthropic|embedding|llm|pgvector)\y'), '0');

-- Relationships across modules ("everything related to X", resolved through the registry and each module's own relationship tables) --------------------------------
select tests.mk_doc('web_lead', 'rd', 'Brief for ABC', 'report', 'web', 'client:abc');
select tests.mk_doc('web_lead', 'rd2', 'Project plan for ABC', 'report', 'web', 'project:abc');
select tests.remember_ok('dom:abc', tests.scalar('web_lead', format($q$ select (domain_create('abc-company.example', %L) ->> 'id') $q$, tests.id('div:web'))));
select tests.rel('web_lead', 'abc', 'client', 'clients', 'client:abc');
select tests.mk_thread('web_lead', 'rel', 'ABC correspondence');
select tests.say('web_lead', 'rel', 'rel1', 'email', 'inbound', 'Related body');
select tests.clink('web_lead', 'rel', 'clients', 'client:abc');
create temp table rel as select tests.inst_of('clients', 'client:abc') as abc, tests.inst_of('projects', 'project:abc') as prj;
select tests.check('what is related to a client: its project, contract and quote (the family), its documents, its domain, its communication - found by relationship, not by name',
  (select string_agg(x ->> 'entity_type', ',' order by x ->> 'entity_type') from jsonb_array_elements(tests.sr('web_lead', 'related:' || (select abc from rel)) -> 'results') x), 'communication,contract,document,document,domain,project,quote');
select tests.check('...narrowed by type', tests.labels('web_lead', 'type:document related:' || (select abc from rel)), 'Brief for ABC|Project plan for ABC') ;
select tests.check('...narrowed by text as well', tests.labels('web_lead', 'plan type:document related:' || (select abc from rel)), 'Project plan for ABC');
select tests.check('the anchor itself is not in its own relationships, and the answer says it is a relationship search', tests.sr('web_lead', 'related:' || (select abc from rel)) ->> 'route' || (select count(*)::text from jsonb_array_elements(tests.sr('web_lead', 'related:' || (select abc from rel)) -> 'results') x where x ->> 'institutional_id' = (select abc from rel)), 'related0');
select tests.check('relationships of a project: its documents (not the client''s)', tests.labels('web_lead', 'type:document related:' || (select prj from rel)), 'Project plan for ABC');
select tests.check('an unknown anchor answers exactly like a hidden one: an empty related result', (tests.sr('web_lead', 'related:ZZZZZZZZ' || id_check_char('ZZZZZZZZ')) - 'query')::text, '{"route": "related", "total": 0, "capped": false, "results": []}');
select tests.check('relationship search reaches what a name never would: the domain is found through the client even though its name shares nothing with it', tests.labels('web_lead', 'type:domain related:' || (select abc from rel)), 'abc-company.example');

-- Historical retrieval ----------------------------------------------------------------------------------------------------------------------------------------
select tests.backdate_doc('doc:rd', interval '60 days');
select tests.try('web_lead', format($q$ select document_link_remove((select id from document_links where document_id = %L and removed_at is null), 'client link replaced') $q$, tests.id('doc:rd')));
select tests.check('today the client no longer has the brief; a month ago it did (and the project plan did not yet exist) - the document is found "as of" a date from the link history',
  tests.labels('web_lead', 'type:document related:' || (select abc from rel)) || '|' || tests.labels('web_lead', 'type:document asof:' || to_char(now() - interval '30 days', 'YYYY-MM-DD') || ' related:' || (select abc from rel)), 'Project plan for ABC|Brief for ABC');
select tests.check('...and before the document existed, nothing', tests.total('web_lead', 'type:document asof:' || to_char(now() - interval '90 days', 'YYYY-MM-DD') || ' related:' || (select abc from rel)), '0');
select tests.backdate_thread('thr:rel', interval '60 days');
select tests.try('web_lead', format($q$ select communication_link_remove((select id from communication_links where thread_id = %L and removed_at is null), 'moved to another client') $q$, tests.id('thr:rel')));
select tests.check('communications likewise: related today = none, a month ago = the thread', tests.total('web_lead', 'type:communication related:' || (select abc from rel)) || tests.total('web_lead', 'type:communication asof:' || to_char(now() - interval '30 days', 'YYYY-MM-DD') || ' related:' || (select abc from rel)), '01');
select tests.check('entities that did not exist yet are not returned for a past date (existence comes from the registry)', tests.total('web_lead', 'type:client zeta asof:' || to_char(now() - interval '10 days', 'YYYY-MM-DD')) || tests.total('web_lead', 'type:client zeta'), '01');
select tests.check('the as-of date is part of the request contract: a timestamp works the same way', tests.scalar('web_lead', format($q$ select (search_execute(jsonb_build_object('related_to', %L, 'types', jsonb_build_array('document'), 'as_of', (now() - interval '30 days')::text)) ->> 'total') $q$, (select abc from rel))), '1');

-- Stale indexes ------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('tamper below the triggers: someone changes the index row (the owner can) - the lie is not returned, because every candidate is re-read from the authoritative record',
  tests.try_owner(format($q$ update search_index set label = 'Zeta Pipes Ltd (tampered)', terms = 'tampered words' where institutional_id = %L $q$, (select zeta from ids))), 'ok');
select tests.check('...the tampered text finds nothing', tests.total('web_lead', 'type:client tampered'), '0');
select tests.check('...and the stale row was queued for repair and is reported by the drift check', (select count(*)::text from search_refresh_queue where institutional_id = (select zeta from ids)) || (select problem from search_drift() where institutional_id = (select zeta from ids)), '1stale');
select tests.try_owner('select search_process_queue()');
select tests.check('processing the queue restores the row from the authoritative record', tests.labels('web_lead', 'type:client zeta pipes') || (select count(*)::text from search_drift()), 'Zeta Pipes Ltd0');
select tests.check('a change that bypassed the triggers (a trigger disabled by someone with the keys) is never served stale: the old name stops matching, nothing wrong is shown',
  tests.try_owner(format($q$ alter table clients disable trigger zz_search_refresh; update clients set name = 'Eta Roofing' where id = %L; alter table clients enable trigger zz_search_refresh $q$, tests.id('c:zeta'))), 'ok');
select tests.check('...the index still says "zeta pipes", the record says "eta roofing": the stale row is withheld, and neither query returns the wrong thing', tests.total('web_lead', 'type:client zeta pipes') || tests.labels('web_lead', 'type:client eta'), '0-');
select tests.check('...the drift check names it; the queue repairs it; then the new name is found', (select problem from search_drift() where institutional_id = (select zeta from ids)), 'stale');
select tests.try_owner('select search_process_queue()');
select tests.check('...repaired', tests.labels('web_lead', 'type:client eta roofing') || '|' || tests.total('web_lead', 'type:client zeta pipes') || (select count(*)::text from search_drift()), 'Eta Roofing|00');
select tests.check('a missing row is reported as missing; an orphan as an orphan', tests.try_owner(format($q$ delete from search_index where institutional_id = %L $q$, (select zeta from ids))) || (select problem from search_drift() where institutional_id = (select zeta from ids)), 'okmissing');
select tests.check('...an index row for an entity that is not in the registry is an orphan (and the foreign key makes that hard to write)', tests.try_owner($q$ insert into search_index (institutional_id, entity_type, table_name, entity_id, label) values ('ZZZZZZZZZ', 'client', 'clients', gen_random_uuid(), 'x') $q$), 'ERR:23503');

-- Rebuild and recovery -----------------------------------------------------------------------------------------------------------------------------------
select tests.scalar_service('select search_rebuild()::text');
create temp table idx_before as select institutional_id, entity_type, label, terms, source_hash from search_index;
select tests.check('the whole index can be thrown away: until it is rebuilt text search finds nothing, but IDs and relationships (the authoritative links) still resolve',
  tests.try_owner('delete from search_index') || tests.total('web_lead', 'abc') || tests.total('web_lead', (select abc from rel)) || tests.total('web_lead', 'type:document related:' || (select abc from rel)), 'ok011');
select tests.check('a rebuild by the service role reports how many rows it built', tests.scalar_service('select (search_rebuild() > 20)::text'), 'true');
select tests.check('...the rebuilt index equals the one before, row for row (label, terms, hash)', (select count(*)::text from (select institutional_id, entity_type, label, terms, source_hash from search_index except select * from idx_before) q) || (select count(*)::text from (select * from idx_before except select institutional_id, entity_type, label, terms, source_hash from search_index) q), '00');
select tests.check('...the queue is empty and nothing drifts', (select count(*)::text from search_refresh_queue) || (select count(*)::text from search_drift()), '00');
select tests.check('a rebuild is idempotent and removes orphans: an index row of a record no longer indexable disappears', tests.try_owner(format($q$ update search_sources set is_active = false where entity_type = 'lead' $q$)) || tests.scalar_service('select (search_rebuild() > 0)::text') || (select count(*)::text from search_index where entity_type = 'lead'), 'oktrue0');
update search_sources set is_active = true where entity_type = 'lead';
select tests.scalar_service('select search_rebuild()::text');
select tests.check('the manifest counts the index rows', tests.scalar_service($q$ select ((search_backup_manifest() ->> 'rows')::int = (select count(*) from search_index))::text $q$), 'true');

-- Suggestions (autocomplete) --------------------------------------------------------------------------------------------------------------------------------------
select tests.check('suggestions complete a prefix with labels the caller may see (no counts, no scores), with their type', tests.scalar('web_lead', $q$ select (search_suggest('abc') -> 0 ->> 'label') || '|' || (select string_agg(k, ',' order by k) from jsonb_object_keys(search_suggest('abc') -> 0) k) $q$), 'ABC Company|entity_type,institutional_id,label');
select tests.check('they need two characters', tests.scalar('web_lead', $q$ select jsonb_array_length(search_suggest('a'))::text || jsonb_array_length(search_suggest(''))::text || jsonb_array_length(search_suggest(null))::text $q$), '000');
select tests.check('they are capped at 10 even when asked for more', tests.scalar('ceo', $q$ select (jsonb_array_length(search_suggest('a', null, 500)) <= 10)::text $q$), 'true');
select tests.check('a typo still suggests', tests.scalar('web_lead', $q$ select (search_suggest('ABC Compnay') -> 0 ->> 'label') $q$), 'ABC Company');
select tests.check('a stale index row is never suggested: the old name does not appear after a silent rename',
  tests.try_owner(format($q$ alter table clients disable trigger zz_search_refresh; update clients set name = 'Theta Glass' where id = %L; alter table clients enable trigger zz_search_refresh $q$, tests.id('c:zeta'))) || tests.scalar('web_lead', $q$ select jsonb_array_length(search_suggest('eta roof'))::text $q$), 'ok0');
select tests.try_owner('select search_process_queue()');
select tests.check('...and the repaired row is suggested under its new name', tests.scalar('web_lead', $q$ select (search_suggest('theta gl') -> 0 ->> 'label') $q$), 'Theta Glass');
select tests.check('suggestions do not complete institutional IDs (an ID is never guessable from a prefix)', tests.scalar('ceo', format($q$ select jsonb_array_length(search_suggest(%L))::text $q$, left((select zeta from ids), 5))), '0');

-- Pins found by mutation testing -------------------------------------------------------------------------------------------------------------------------
select tests.remember('c:knap', tests.mkclient_id('web_lead', 'Knappsack', 'web'));
select tests.check('an ordinary word that happens to look like an identifier (nine letters from the ID alphabet) is searched as text, not as an ID', tests.labels('web_lead', 'type:client knappsack'), 'Knappsack');
select tests.check('divisions are searchable (a source of their own)', tests.scalar('ceo', $q$ select ((search('type:division')->>'total')::int > 3)::text $q$), 'true');
select tests.mkclient_id('web_lead', 'Rank Test', 'web');
select tests.mkclient_id('web_lead', 'Rank Rank Rank Test Test Test Holdings', 'web');
select tests.check('an exact label match outranks a longer label that repeats the words', tests.labels('web_lead', 'type:client "rank test"'), 'Rank Test|Rank Rank Rank Test Test Test Holdings');
select tests.mkclient_id('web_lead', 'Pinnacle Works', 'web');
select tests.try_owner($q$ insert into clients (name, owner_division_id) values ('Pinnacle Wokrs', (select id from divisions where key = 'web')) $q$);
select tests.check('near spellings are offered only when nothing matches exactly: "pinnacle works" suggests the one name', tests.scalar('web_lead', $q$ select jsonb_array_length(search_suggest('pinnacle works', array['client']))::text $q$), '1');
select tests.check('a search likewise answers with exact matches only when there are any (the near spelling is not mixed in)', tests.labels('web_lead', 'type:client pinnacle works'), 'Pinnacle Works');
select tests.check('...while a typo that matches nothing exactly still finds the near names', tests.scalar('web_lead', $q$ select (jsonb_array_length(search_suggest('pinnacle wrks', array['client'])) >= 1)::text $q$), 'true');
select tests.mkclient_id('web_lead', 'Cap Test ' || w, 'web') from unnest(array['Alpha','Bravo','Charlie','Delta','Echo','Foxtrot','Golf','Hotel','Juliet','Kilo','Mike','November','Papa','Quebec']) w;
select tests.check('a type filter on suggestions is honoured; suggestions never exceed 10 however many are asked for', tests.scalar('web_lead', $q$ select (select string_agg(distinct x ->> 'entity_type', ',') from jsonb_array_elements(search_suggest('abc', array['client'])) x) || '/' || jsonb_array_length(search_suggest('cap test', null, 500))::text $q$), 'client/10');
select tests.check('a page never exceeds 50 results and the offset is bounded; the total is the whole count', tests.scalar('web_lead', $q$ select (jsonb_array_length(search_execute(jsonb_build_object('q', 'cap test', 'limit', 5000)) -> 'results'))::text || '/' || (search_execute(jsonb_build_object('q', 'cap test', 'limit', 5000)) ->> 'total') || '/' || (search_request_validate('{"offset":99999}') ->> 'offset') $q$), '28/28/1000');
select tests.check('a page shows at most the limit and the offset moves through the list', tests.scalar('web_lead', $q$ select jsonb_array_length(search_execute(jsonb_build_object('q', 'cap test', 'limit', 5)) -> 'results')::text || jsonb_array_length(search_execute(jsonb_build_object('q', 'cap test', 'limit', 5, 'offset', 10)) -> 'results')::text $q$), '55');
-- relationships as of a date --------------------------------------------------------------------------------------------------------------------------------
select tests.rel('web_lead', 'abc', 'client', 'clients', 'c:zeta');
alter table domain_relations disable trigger domain_relations_before_trg;
update domain_relations set valid_from = now() - interval '90 days', valid_to = now() - interval '20 days' where domain_id = tests.id('dom:abc') and valid_to is not null;
update domain_relations set valid_from = now() - interval '20 days' where domain_id = tests.id('dom:abc') and valid_to is null;
alter table domain_relations enable trigger domain_relations_before_trg;
alter table entity_registry disable trigger entity_registry_guard_trg;
update entity_registry set created_at = now() - interval '100 days' where table_name = 'domains' and entity_id = tests.id('dom:abc');
alter table entity_registry enable trigger entity_registry_guard_trg;
select tests.check('a domain moved from one client to another is related to the first client as of before the move, to the second afterwards, and only to the second today',
  tests.total('web_lead', 'type:domain related:' || (select abc from rel) || ' asof:' || to_char(now() - interval '45 days', 'YYYY-MM-DD')) || tests.total('web_lead', 'type:domain related:' || (select abc from rel)) ||
  tests.total('web_lead', 'type:domain related:' || (select zeta from ids)) || tests.total('web_lead', 'type:domain related:' || (select zeta from ids) || ' asof:' || to_char(now() - interval '45 days', 'YYYY-MM-DD')), '1010');
select tests.check('entities that did not yet exist are not related to anything as of a past date: the client''s project was created today', tests.total('web_lead', 'type:project related:' || (select abc from rel)) || tests.total('web_lead', 'type:project related:' || (select abc from rel) || ' asof:' || to_char(now() - interval '45 days', 'YYYY-MM-DD')), '10');
select tests.mk_doc('web_lead', 'att', 'Attached once', 'report', 'web');
select tests.mk_thread('web_lead', 'att', 'Attachment history');
select tests.say('web_lead', 'att', 'att1', 'email', 'inbound', 'with an attachment');
select tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:att1'), tests.id('doc:att')));
select tests.backdate_doc('doc:att', interval '90 days');
select tests.backdate_thread('thr:att', interval '60 days');
select tests.try('web_lead', format($q$ select communication_attachment_remove((select id from communication_attachments where thread_id = %L), 'detached') $q$, tests.id('thr:att')));
select tests.check('a communication that carried a document and later dropped it is related to the document as of before the removal, and not today',
  tests.total('web_lead', 'type:communication related:' || tests.inst_of('documents', 'doc:att')) || tests.total('web_lead', 'type:communication related:' || tests.inst_of('documents', 'doc:att') || ' asof:' || to_char(now() - interval '30 days', 'YYYY-MM-DD')), '01');
select tests.mk_thread('web_lead', 'late', 'Participant recorded later');
select tests.backdate_thread('thr:late', interval '60 days');
select tests.say('web_lead', 'late', 'late1', 'email', 'inbound', 'hello', jsonb_build_array(jsonb_build_object('role', 'from', 'entity', (select institutional_id from entity_registry where entity_id = tests.id('contact:john')))));
select tests.check('a thread that existed earlier but whose participant was recorded only now is related to that person today, not as of a month ago',
  tests.scalar('web_lead', format($q$ select (search('type:communication related:%s')->>'total') $q$, (select institutional_id from entity_registry where entity_id = tests.id('contact:john')))) ||
  tests.scalar('web_lead', format($q$ select (search('type:communication related:%s asof:%s')->>'total') $q$, (select institutional_id from entity_registry where entity_id = tests.id('contact:john')), to_char(now() - interval '30 days', 'YYYY-MM-DD'))), '10');
-- maintenance pins
select tests.check('services are indexed while their source is on', (select (count(*) > 0)::text from search_index where entity_type = 'service'), 'true');
select tests.try_owner($q$ update search_sources set is_active = false where entity_type = 'service' $q$);
select tests.scalar_service('select search_rebuild()::text');
select tests.check('a source switched off stops being indexed: its rows go on a rebuild', (select count(*)::text from search_index where entity_type = 'service'), '0');
select tests.try_owner($q$ update services set summary = 'changed once more' $q$);
select tests.check('...an update of a service does not index it while its source is off', (select count(*)::text from search_index where entity_type = 'service'), '0');
update search_sources set is_active = true where entity_type = 'service';
select tests.scalar_service('select search_rebuild()::text');
select tests.check('...and switching it on again, a rebuild brings the rows back', (select (count(*) > 0)::text from search_index where entity_type = 'service'), 'true');
select tests.check('a rebuild corrects a row whose label is right but whose terms are wrong (not only wrong labels)', tests.try_owner(format($q$ update search_index set terms = 'wrong terms' where institutional_id = %L $q$, (select zeta from ids))) || (select problem from search_drift() where institutional_id = (select zeta from ids)), 'okstale');
select tests.scalar_service('select search_rebuild()::text');
select tests.check('...after the rebuild nothing drifts', (select count(*)::text from search_drift()), '0');
select tests.check('the task is indexed', (select count(*)::text from search_index where label = 'T_web'), '1');
select tests.try_owner($q$ delete from tasks where title = 'T_web' $q$);
select tests.check('a hard delete of a record removes its index row (the trigger follows deletions)', (select count(*)::text from search_index where label = 'T_web'), '0');
select tests.try('outsider', format($q$ select search_flag_stale(array[%L]) $q$, (select zeta from ids)));
select tests.check('a refresh request from someone who is not staff is ignored', (select count(*)::text from search_refresh_queue), '0');
select tests.try('ceo', format($q$ select search_flag_stale(array[%L]) $q$, (select zeta from ids)));
select tests.check('...from staff it queues the entity', (select count(*)::text from search_refresh_queue), '1');
select tests.try_owner('select search_process_queue()');
select tests.finish();
rollback;
