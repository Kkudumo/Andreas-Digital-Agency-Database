-- 0041_search: ADA Hub Search - a RETRIEVAL layer over the institutional registry. It is never a source of truth.
--  * Authoritative records stay in their modules. `search_index` is DERIVED data: one row per registered entity that has a search source, linked to the
--    Entity Registry by institutional ID, rebuildable at any time from the authoritative tables (search_rebuild) and verifiable against them (search_drift).
--  * What is indexed is configuration (search_sources): a label and a few metadata attributes per entity type, each an expression over the authoritative
--    table's OWN columns. Only columns that every viewer of the row may read can be configured (a constraint forbids content-like columns by name, a
--    permanent test proves every configured column is readable by API users). Document and communication CONTENT is never indexed: documents are indexed by
--    title / description (their metadata), communication threads by status only (no subject, no participants, no body).
--  * Authorization happens BEFORE anything is exposed, and it is the authoritative record's own: the search functions are SECURITY INVOKER and the index rows
--    are visible only where entity_visible() (the caller's row-level security on the authoritative table) says the record is. Matching, ranking, totals,
--    facets and suggestions are all computed over rows the caller may see - a record the caller cannot see contributes nothing, not even to a count.
--  * Freshness is verified, not assumed: every candidate is re-read from the authoritative record (with the caller's rights) and compared with the hash the
--    index holds; a stale row is never returned and is queued for refresh. Index rows are also maintained incrementally by triggers, so staleness needs a
--    bypass of the triggers to arise at all.
--  * Deterministic: text -> a structured request (search_parse) -> search_execute(request). No AI is involved or required. A future interpreter is only a
--    translator from natural language to that same request; it never sees data before authorization and is not a user-facing product.
--  * Historical: an `as_of` date answers "what existed then and how was it related then" from the entities' creation and the relationship histories of
--    documents, domains and communications. Labels are the current labels (see docs/workflows/SEARCH.md).
--  * Not public. Public search waits for the Publication Layer and the Public API.

-- ---------------------------------------------------------------------------
-- Configuration: what is searchable for each entity type
-- ---------------------------------------------------------------------------
create table search_sources (
  entity_type      text primary key references entity_types (key),
  label_expr       text not null,
  attribute_exprs  text[] not null default '{}',
  is_active        boolean not null default true,
  note             text,
  check ((label_expr || ' ' || array_to_string(attribute_exprs, ' ')) !~* '(subject|body|storage|content|notes|national_id|salary|password|secret|token|api_key|hash|terms|conditions|resolution|reason|private)')
);
comment on table search_sources is 'Purpose: which metadata of each entity type is searchable. label_expr and attribute_exprs are SQL expressions over the authoritative table (alias x) and may use only its own columns that every viewer of the row can read. The check forbids content-like names; a permanent test proves API users can read every configured column. Owner-maintained configuration; no API access. [class: internal]';

insert into search_sources (entity_type, label_expr, attribute_exprs, note) values
  ('client',                'x.name', array['x.legal_name', 'x.trading_name', 'x.registration_number', 'x.email', 'x.city', 'x.industry'], 'identity attributes of the client record'),
  ('external_organization', 'x.name', array['x.legal_name', 'x.trading_name', 'x.registration_number', 'x.email', 'x.city', 'x.industry'], 'the one organization identity record'),
  ('supplier',              'x.name', array['x.registration_number', 'x.website'], null),
  ('partner',               'x.name', array['x.kind'], null),
  ('person',                'x.full_name', array['x.email'], null),
  ('staff',                 'x.full_name', array['x.email'], null),
  ('project',               'x.name', array['x.project_type'], null),
  ('ticket',                'x.title', array[]::text[], null),
  ('asset',                 'x.name', array['x.asset_tag', 'x.serial_number', 'x.manufacturer', 'x.model'], null),
  ('document',              'x.title', array['x.description'], 'document METADATA only; there is no content in the database'),
  ('domain',                'x.name', array['x.purpose'], null),
  ('website',               'x.name', array['x.domain'], null),
  ('service',               'x.name', array['x.category', 'x.summary'], null),
  ('contract',              'x.title', array[]::text[], null),
  ('quote',                 'x.title', array[]::text[], null),
  ('lead',                  'x.title', array[]::text[], null),
  ('programme',             'x.name', array['x.level', 'x.programme_family'], null),
  ('cohort',                'x.name', array[]::text[], null),
  ('vacancy',               'x.title', array[]::text[], null),
  ('task',                  'x.title', array[]::text[], null),
  ('division',              'x.name', array[]::text[], null),
  ('communication',         '''Communication thread''', array['x.status::text'], 'METADATA only: no subject, no participants, no bodies');

-- ---------------------------------------------------------------------------
-- The derived index
-- ---------------------------------------------------------------------------
-- trigram similarity without giving API users the extensions schema (a pure function of its two inputs)
create function search_sim(p_a text, p_b text) returns real
language sql immutable parallel safe security definer set search_path = public, extensions, pg_temp as $$ select similarity(p_a, p_b) $$;

create function search_norm(p_text text) returns text
language sql immutable parallel safe as $$
  select btrim(regexp_replace(lower(coalesce(p_text, '')), '[^[:alnum:]]+', ' ', 'g'))
$$;

alter table search_index
  add column terms        text not null default '',
  add column source_hash  text not null default '',
  add column label_norm   text generated always as (search_norm(label)) stored,
  add column tsv          tsvector generated always as (to_tsvector('simple', search_norm(label || ' ' || terms))) stored;
create index search_index_tsv_idx on search_index using gin (tsv);
create index search_index_label_norm_trgm on search_index using gin (label_norm extensions.gin_trgm_ops);
create index search_index_type_idx on search_index (entity_type);
create unique index search_index_entity_unique on search_index (table_name, entity_id);
comment on table search_index is 'Purpose: DERIVED retrieval structure - one row per searchable entity: its label and metadata terms (from search_sources), a hash of them, and the tsvector / trigram structures built from them. Linked to the registry by institutional ID; rebuildable at any time from the authoritative records by search_rebuild(); checked by search_drift(). Not authoritative, not the registry, holds no content. Visible only for entities the caller may read. [class: internal]';
comment on column search_index.terms is 'DERIVED: the configured metadata attributes of the authoritative record, normalised. Never content.';
comment on column search_index.source_hash is 'DERIVED: md5 of the label and terms when the row was built. Used by the drift check and the backup manifest; at query time every candidate label and its terms are compared with the authoritative record and a stale row is refused.';

create table search_refresh_queue (
  institutional_id text primary key,
  reason           text not null default 'stale',
  queued_at        timestamptz not null default now()
);
comment on table search_refresh_queue is 'Purpose: entities whose index row was found stale (or whose refresh failed) and awaits search_process_queue(). Derived bookkeeping; no API access. [class: internal]';

-- What the authoritative record says now (SECURITY INVOKER: the caller\'s own row security and column privileges apply)
create function search_live(p_table text, p_entity uuid, out label text, out terms text)
language plpgsql stable set search_path = public, pg_temp as $$
declare s search_sources%rowtype; t text; v_attrs text;
begin
  select r.entity_type into t from entity_registry r where r.table_name = p_table and r.entity_id = p_entity;
  select * into s from search_sources where entity_type = t and is_active;
  if not found then return; end if;
  v_attrs := case when cardinality(s.attribute_exprs) = 0 then '''''' else array_to_string(s.attribute_exprs, ', ') end;
  execute format('select (%s)::text, search_norm(concat_ws('' '', %s)) from public.%I x where x.id = $1', s.label_expr, v_attrs, p_table) into label, terms using p_entity;
end $$;

-- Builds (or removes) the index row of one registered entity from the authoritative record. Service code and triggers only.
create function search_refresh_row(p_table text, p_entity uuid, p_only_if_changed boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r entity_registry%rowtype; s search_sources%rowtype; v_attrs text; v_label text; v_terms text;
begin
  select * into r from entity_registry where table_name = p_table and entity_id = p_entity;
  if not found or r.status = 'removed' then delete from search_index where table_name = p_table and entity_id = p_entity; return; end if;
  select * into s from search_sources where entity_type = r.entity_type and is_active;
  if not found then delete from search_index where table_name = p_table and entity_id = p_entity; return; end if;
  v_attrs := case when cardinality(s.attribute_exprs) = 0 then '''''' else array_to_string(s.attribute_exprs, ', ') end;
  execute format('select (%s)::text, search_norm(concat_ws('' '', %s)) from public.%I x where x.id = $1', s.label_expr, v_attrs, p_table) into v_label, v_terms using p_entity;
  if v_label is null or btrim(v_label) = '' then delete from search_index where table_name = p_table and entity_id = p_entity; return; end if;
  -- a rebuild leaves rows that are already right alone (no lock, no conflict with live writers)
  if p_only_if_changed and exists (select 1 from search_index i where i.institutional_id = r.institutional_id and i.table_name = p_table and i.entity_id = p_entity and i.entity_type = r.entity_type and i.label = v_label and i.terms = coalesce(v_terms, '')) then return; end if;
  insert into search_index (institutional_id, entity_type, table_name, entity_id, label, terms, source_hash, refreshed_at)
  values (r.institutional_id, r.entity_type, p_table, p_entity, v_label, v_terms, md5(search_norm(v_label) || '|' || coalesce(v_terms, '')), clock_timestamp())
  on conflict (institutional_id) do update set entity_type = excluded.entity_type, label = excluded.label, terms = excluded.terms, source_hash = excluded.source_hash, refreshed_at = excluded.refreshed_at;
  delete from search_refresh_queue where institutional_id = r.institutional_id;
end $$;
revoke execute on function search_refresh_row(text, uuid, boolean) from public, anon, authenticated;

create function search_refresh_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then delete from search_index where table_name = tg_table_name and entity_id = old.id; return null; end if;
  perform search_refresh_row(tg_table_name, new.id);
  return null;
end $$;
revoke execute on function search_refresh_trigger() from public, anon, authenticated;

-- Incremental maintenance: every authoritative table that has a search source keeps its index rows current
create function attach_search(p_table regclass) returns void
language plpgsql as $$
begin
  execute format('create trigger zz_search_refresh after insert or update or delete on %s for each row execute function search_refresh_trigger()', p_table);
end $$;
revoke execute on function attach_search(regclass) from public, anon, authenticated;
do $$
declare r record;
begin
  for r in select distinct t.domain_table from search_sources s join entity_types t on t.key = s.entity_type where t.domain_table is not null and to_regclass('public.' || t.domain_table) is not null loop
    perform attach_search(('public.' || quote_ident(r.domain_table))::regclass);
  end loop;
end $$;

-- Full rebuild from the authoritative records (service role). Safe beside live writes: it upserts, then removes only rows that were NOT seen and are older than the rebuild.
create or replace function search_rebuild() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n integer := 0;
begin
  for r in select e.table_name, e.entity_id from entity_registry e join search_sources s on s.entity_type = e.entity_type and s.is_active where e.status is distinct from 'removed' order by e.institutional_id loop
    perform search_refresh_row(r.table_name, r.entity_id, true); n := n + 1;
  end loop;
  -- rows whose entity is no longer searchable (removed, deactivated source, unknown) are dropped; rows of entities created meanwhile are untouched (they are in the registry)
  delete from search_index i
   where not exists (select 1 from entity_registry e join search_sources s on s.entity_type = e.entity_type and s.is_active where e.institutional_id = i.institutional_id and e.table_name = i.table_name and e.entity_id = i.entity_id and e.entity_type = i.entity_type and e.status is distinct from 'removed');
  delete from search_refresh_queue;
  return n;
end $$;
revoke execute on function search_rebuild() from public, anon, authenticated;
grant execute on function search_rebuild() to service_role;

-- Processes entities found stale since the last run (service role)
create function search_process_queue() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n integer := 0;
begin
  for r in select q.institutional_id, e.table_name, e.entity_id from search_refresh_queue q join entity_registry e on e.institutional_id = q.institutional_id loop
    perform search_refresh_row(r.table_name, r.entity_id); n := n + 1;
  end loop;
  delete from search_refresh_queue q where not exists (select 1 from entity_registry e where e.institutional_id = q.institutional_id);
  return n;
end $$;
revoke execute on function search_process_queue() from public, anon, authenticated;
grant execute on function search_process_queue() to service_role;

-- Compares the index with the authoritative records (service role): what is missing, orphaned or stale
create function search_drift() returns table (institutional_id text, problem text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_label text; v_terms text; s search_sources%rowtype; v_attrs text;
begin
  for r in select e.institutional_id, e.table_name, e.entity_id, e.entity_type from entity_registry e join search_sources c on c.entity_type = e.entity_type and c.is_active where e.status is distinct from 'removed' loop
    select * into s from search_sources where entity_type = r.entity_type;
    v_attrs := case when cardinality(s.attribute_exprs) = 0 then '''''' else array_to_string(s.attribute_exprs, ', ') end;
    execute format('select (%s)::text, search_norm(concat_ws('' '', %s)) from public.%I x where x.id = $1', s.label_expr, v_attrs, r.table_name) into v_label, v_terms using r.entity_id;
    if v_label is null or btrim(v_label) = '' then
      if exists (select 1 from search_index i where i.institutional_id = r.institutional_id) then institutional_id := r.institutional_id; problem := 'indexed but nothing to index'; return next; end if;
    elsif not exists (select 1 from search_index i where i.institutional_id = r.institutional_id) then institutional_id := r.institutional_id; problem := 'missing'; return next;
    elsif not exists (select 1 from search_index i where i.institutional_id = r.institutional_id and i.source_hash = md5(search_norm(v_label) || '|' || coalesce(v_terms, '')) and i.label = v_label and i.terms = coalesce(v_terms, '')) then
      institutional_id := r.institutional_id; problem := 'stale'; return next;
    end if;
  end loop;
  return query select i.institutional_id, 'orphan'::text from search_index i
    where not exists (select 1 from entity_registry e join search_sources c on c.entity_type = e.entity_type and c.is_active
                       where e.institutional_id = i.institutional_id and e.table_name = i.table_name and e.entity_id = i.entity_id and e.entity_type = i.entity_type and e.status is distinct from 'removed');
end $$;
revoke execute on function search_drift() from public, anon, authenticated;
grant execute on function search_drift() to service_role;

create function search_backup_manifest() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('rows', (select count(*) from search_index), 'sources', (select count(*) from search_sources where is_active),
    'index_md5', (select md5(coalesce(string_agg(concat_ws('|', institutional_id, entity_type, label, terms, source_hash), ';' order by institutional_id), '')) from search_index),
    'queue', (select count(*) from search_refresh_queue))
$$;
revoke execute on function search_backup_manifest() from public, anon, authenticated;
grant execute on function search_backup_manifest() to service_role;

-- A stale row is never returned; any signed-in user's search may ask for it to be refreshed (it flows no information)
create function search_flag_stale(p_ids text[]) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into search_refresh_queue (institutional_id, reason)
  select e.institutional_id, 'stale' from entity_registry e where e.institutional_id = any (p_ids) and current_staff_id() is not null
  on conflict (institutional_id) do nothing
$$;
revoke execute on function search_flag_stale(text[]) from public, anon;
grant execute on function search_flag_stale(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Deterministic interpretation: text -> request
-- ---------------------------------------------------------------------------
-- Filters: type:x  status:x  division:key  related:ID  asof:YYYY-MM-DD  limit:n   (everything else is free text). A bare institutional / legacy ID is an exact lookup.
create function search_parse(p_query text) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare v text := left(btrim(coalesce(p_query, '')), 300); tok text; v_free text[] := '{}'; v_ids text[] := '{}'; v_types text[] := '{}'; v_status text[] := '{}';
        v_div text; v_rel text; v_asof text; v_limit integer; k text; val text;
begin
  for tok in select (regexp_matches(v, '"[^"]*"|\S+', 'g'))[1] loop
    if tok ~ '^"' then v_free := v_free || btrim(tok, '"');
    elsif tok ~* '^(type|status|division|related|asof|limit):.+$' then
      k := lower(split_part(tok, ':', 1)); val := substr(tok, length(k) + 2);
      if k = 'type' then v_types := v_types || lower(val);
      elsif k = 'status' then v_status := v_status || lower(val);
      elsif k = 'division' then v_div := lower(val);
      elsif k = 'related' then v_rel := upper(val);
      elsif k = 'asof' then v_asof := val;
      elsif k = 'limit' then begin v_limit := least(greatest(val::integer, 1), 50); exception when others then v_limit := null; end;
      end if;
    elsif upper(tok) ~ '^ADA-[A-Z]{3}-[0-9]{4}-[0-9]{4}$' or (upper(tok) ~ '^[0-9A-HJKMNP-TV-Z]{9}$' and ada_id_valid(upper(tok))) then v_ids := v_ids || upper(tok);
    else v_free := v_free || tok;
    end if;
  end loop;
  return jsonb_strip_nulls(jsonb_build_object('q', nullif(btrim(array_to_string(v_free, ' ')), ''), 'ids', to_jsonb(v_ids), 'types', to_jsonb(v_types), 'status', to_jsonb(v_status),
         'division', v_div, 'related_to', v_rel, 'as_of', v_asof, 'limit', v_limit));
end $$;

-- The one request shape every caller (the parser above, a UI, a future interpreter) must produce. Unknown keys are refused; nothing here touches data.
create function search_request_validate(p_request jsonb) returns jsonb
language plpgsql immutable set search_path = public, pg_temp as $$
declare k text; v_allowed constant text[] := array['q', 'ids', 'types', 'status', 'division', 'related_to', 'as_of', 'limit', 'offset', 'facets']; v_ts timestamptz;
begin
  if p_request is null or jsonb_typeof(p_request) <> 'object' then raise exception 'a search request is a JSON object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_request) loop
    if not (k = any (v_allowed)) then raise exception 'unknown search request key: %', left(k, 40) using errcode = '22023'; end if;
  end loop;
  if p_request ? 'q' and jsonb_typeof(p_request -> 'q') not in ('string', 'null') then raise exception 'q must be text' using errcode = '22023'; end if;
  foreach k in array array['ids', 'types', 'status'] loop
    if p_request ? k and jsonb_typeof(p_request -> k) <> 'array' then raise exception '% must be a list', k using errcode = '22023'; end if;
  end loop;
  if jsonb_array_length(coalesce(p_request -> 'ids', '[]')) > 20 then raise exception 'at most 20 IDs per request' using errcode = '22023'; end if;
  if p_request ? 'as_of' and p_request ->> 'as_of' is not null then begin v_ts := (p_request ->> 'as_of')::timestamptz; exception when others then raise exception 'as_of must be a date or timestamp' using errcode = '22023'; end; end if;
  return jsonb_build_object(
    'q', nullif(btrim(left(coalesce(p_request ->> 'q', ''), 300)), ''),
    'ids', coalesce((select jsonb_agg(upper(btrim(x))) from jsonb_array_elements_text(coalesce(p_request -> 'ids', '[]')) x), '[]'),
    'types', coalesce((select jsonb_agg(lower(btrim(x))) from jsonb_array_elements_text(coalesce(p_request -> 'types', '[]')) x), '[]'),
    'status', coalesce((select jsonb_agg(lower(btrim(x))) from jsonb_array_elements_text(coalesce(p_request -> 'status', '[]')) x), '[]'),
    'division', lower(nullif(btrim(coalesce(p_request ->> 'division', '')), '')),
    'related_to', upper(nullif(btrim(coalesce(p_request ->> 'related_to', '')), '')),
    'as_of', v_ts,
    'limit', least(greatest(coalesce((p_request ->> 'limit')::integer, 20), 1), 50),
    'offset', least(greatest(coalesce((p_request ->> 'offset')::integer, 0), 0), 1000),
    'facets', coalesce((p_request ->> 'facets')::boolean, false));
end $$;

-- ---------------------------------------------------------------------------
-- Execution: SECURITY INVOKER throughout. The caller's row security decides what exists for them, at every step.
-- ---------------------------------------------------------------------------
create function search_execute(p_request jsonb) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare q jsonb := search_request_validate(p_request); v_text text := q ->> 'q'; v_norm text; v_tsq tsquery; v_toks text[]; v_ts timestamptz := coalesce((q ->> 'as_of')::timestamptz, now());
        v_has_ts boolean := (q ->> 'as_of') is not null; v_types text[]; v_status text[]; v_div uuid; v_related text[]; v_anchor entity_registry%rowtype; v_rel_mode boolean := false;
        v_ids jsonb := '[]'; v_id text; v_res jsonb; v_cand jsonb; v_out jsonb := '[]'; v_stale text[] := '{}'; x jsonb; v_live record; v_cap constant integer := 500; v_n integer; v_route text;
        v_page jsonb; v_total integer; v_facets jsonb := '{}'; v_reg record; v_pass integer; v_verified integer := 0; v_need integer;
begin
  v_need := (q ->> 'offset')::int + (q ->> 'limit')::int;
  v_types := array(select jsonb_array_elements_text(q -> 'types'));
  v_status := array(select jsonb_array_elements_text(q -> 'status'));
  if current_staff_id() is null then
    return jsonb_build_object('route', 'none', 'query', q - 'as_of', 'total', 0, 'capped', false, 'results', '[]'::jsonb);
  end if;
  if q ->> 'division' is not null then select id into v_div from divisions where key = q ->> 'division'; if v_div is null then v_div := '00000000-0000-0000-0000-000000000000'; end if; end if;

  -- 1. Exact institutional IDs go straight through the registry (an unknown and a hidden ID are the same; the denial is recorded by entity_resolve)
  for v_id in select jsonb_array_elements_text(q -> 'ids') loop
    v_res := entity_resolve(v_id);
    if v_res is not null and (cardinality(v_types) = 0 or (v_res ->> 'entity_type') = any (v_types)) then
      v_ids := v_ids || jsonb_build_array(jsonb_build_object('institutional_id', v_res ->> 'institutional_id', 'entity_type', v_res ->> 'entity_type', 'status', v_res ->> 'status', 'label', null, 'route', 'registry',
                                                              'live', (select jsonb_build_object('label', l.label) from search_live(v_res ->> 'authoritative_domain', (v_res ->> 'authoritative_record_key')::uuid) l)));
    end if;
  end loop;
  if jsonb_array_length(q -> 'ids') > 0 and v_text is null and q ->> 'related_to' is null then
    return jsonb_build_object('route', 'registry', 'query', q - 'as_of', 'total', jsonb_array_length(v_ids), 'capped', false,
      'results', (select coalesce(jsonb_agg(jsonb_build_object('institutional_id', e ->> 'institutional_id', 'entity_type', e ->> 'entity_type', 'label', e -> 'live' ->> 'label', 'status', e ->> 'status')), '[]') from jsonb_array_elements(v_ids) e));
  end if;

  -- 2. Relationship search: everything related to an anchor entity, as the relationships stood at as_of
  if q ->> 'related_to' is not null then
    v_rel_mode := true;
    v_res := entity_resolve(q ->> 'related_to');
    if v_res is null then
      return jsonb_build_object('route', 'related', 'query', q - 'as_of', 'total', 0, 'capped', false, 'results', '[]'::jsonb);
    end if;
    select * into v_anchor from entity_registry where institutional_id = v_res ->> 'institutional_id';
    v_related := document_family_ids(v_anchor.institutional_id);
    v_related := v_related || array(
        select er.institutional_id from document_links dl join entity_registry er on er.table_name = 'documents' and er.entity_id = dl.document_id
         where dl.entity_institutional_id = any (v_related) and dl.linked_at <= v_ts and (dl.removed_at is null or dl.removed_at > v_ts)
        union
        select er.institutional_id from domain_relations dr join entity_registry er on er.table_name = 'domains' and er.entity_id = dr.domain_id
         where dr.entity_institutional_id = any (v_related) and dr.valid_from <= v_ts and (dr.valid_to is null or dr.valid_to > v_ts)
        union
        select er.institutional_id from communication_links cl join entity_registry er on er.table_name = 'communication_threads' and er.entity_id = cl.thread_id
         where cl.entity_institutional_id = any (v_related) and cl.linked_at <= v_ts and (cl.removed_at is null or cl.removed_at > v_ts)
        union
        select er.institutional_id from communication_attachments ca join entity_registry de on de.table_name = 'documents' and de.entity_id = ca.document_id
          join entity_registry er on er.table_name = 'communication_threads' and er.entity_id = ca.thread_id
         where de.institutional_id = any (v_related) and ca.attached_at <= v_ts and (ca.removed_at is null or ca.removed_at > v_ts)
        union
        select er.institutional_id from communication_participant_hits(v_related) h join entity_registry er on er.table_name = 'communication_threads' and er.entity_id = h.thread_id where h.recorded_at <= v_ts);
    v_related := array(select distinct e from unnest(v_related) e where e <> v_anchor.institutional_id);
  end if;

  -- 3. Text: normalised prefix tokens (all must match) or close spelling of the label
  v_norm := search_norm(v_text);
  v_toks := array(select t from regexp_split_to_table(v_norm, ' ') t where t <> '');
  if cardinality(v_toks) > 0 then
    v_tsq := to_tsquery('simple', (select string_agg(quote_literal(t) || ':*', ' & ') from unnest(v_toks) t));
  end if;
  if v_text is null and not v_rel_mode and cardinality(v_types) = 0 and jsonb_array_length(v_ids) = 0 then
    return jsonb_build_object('route', 'none', 'query', q - 'as_of', 'total', 0, 'capped', false, 'results', '[]'::jsonb);
  end if;

  -- 4. Candidates: row security on the index AND on the registry applies before anything is ranked or counted
  if v_rel_mode then
    -- relationships come from the authoritative links; the index is not needed to find them (it is only a convenience for text), so losing it loses nothing here
    select coalesce(jsonb_agg(to_jsonb(c) order by c.institutional_id), '[]') into v_cand from (
      select r.institutional_id, r.entity_type, r.table_name, r.entity_id, r.status from entity_registry r
       where r.institutional_id = any (v_related)
         and (cardinality(v_types) = 0 or r.entity_type = any (v_types))
         and (cardinality(v_status) = 0 or r.status = any (v_status))
         and (v_div is null or r.current_division_id = v_div)
         and (not v_has_ts or r.created_at <= v_ts)
       order by r.institutional_id limit v_cap) c;
    for x in select * from jsonb_array_elements(v_cand) loop
      select * into v_live from search_live(x ->> 'table_name', (x ->> 'entity_id')::uuid);
      if v_live.label is null then continue; end if;
      if v_tsq is not null and not (to_tsvector('simple', search_norm(v_live.label || ' ' || coalesce(v_live.terms, ''))) @@ v_tsq or search_sim(search_norm(v_live.label), v_norm) >= 0.4) then continue; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('institutional_id', x ->> 'institutional_id', 'entity_type', x ->> 'entity_type', 'label', v_live.label, 'status', x ->> 'status',
                                          'score', round((case when v_norm = '' then 0 else search_sim(search_norm(v_live.label), v_norm) * 0.5 end)::numeric, 4)));
    end loop;
    select coalesce(jsonb_agg(o order by (o ->> 'score')::numeric desc, o ->> 'label', o ->> 'institutional_id'), '[]') into v_out from jsonb_array_elements(v_out) o;
  else
  -- the index is searched under the caller's row security; the cheap match is stated first (see search_ctx_match) so authorization runs only on matching rows.
  -- Pass 1 is strict (every word, as a prefix). Only if nothing is found does pass 2 allow near spellings.
  for v_pass in 1..2 loop
    v_out := '[]'; v_stale := '{}'; v_verified := 0;
    perform set_config('ada.search_tsq', coalesce((select string_agg(quote_literal(t) || ':*', ' & ') from unnest(v_toks) t), ''), true);
    perform set_config('ada.search_norm', v_norm, true);
    perform set_config('ada.search_sim', case when cardinality(v_toks) > 0 and v_pass = 2 then '0.4' else '' end, true);
    perform set_config('ada.search_types', array_to_string(v_types, ','), true);
    select coalesce(jsonb_agg(to_jsonb(c) order by c.score desc, c.label, c.institutional_id), '[]') into v_cand from (
      select s.institutional_id, s.entity_type, s.table_name, s.entity_id, s.label, s.terms,
             (case when v_tsq is null then 0 else ts_rank(s.tsv, v_tsq) end) + (case when v_norm = '' then 0 else search_sim(s.label_norm, v_norm) * 0.5 end)
               + (case when v_norm <> '' and s.label_norm = v_norm then 1 else 0 end) as score
        from search_index s                       -- the match itself (words, near spelling, types) is stated once, in search_ctx_match, through the settings above
       order by score desc, s.label, s.institutional_id
       limit v_cap) c;
    perform set_config('ada.search_tsq', '', true); perform set_config('ada.search_norm', '', true); perform set_config('ada.search_sim', '', true); perform set_config('ada.search_types', '', true);

    -- Registry facts for every candidate; freshness (the authoritative record, read with the caller's rights) for the ones that will be shown. A stale or unreadable row is dropped.
    for x in select * from jsonb_array_elements(v_cand) loop
      select r.status, r.current_division_id, r.created_at into v_reg from entity_registry r where r.institutional_id = x ->> 'institutional_id';
      if not found then continue; end if;
      if cardinality(v_status) > 0 and not (v_reg.status = any (v_status)) then continue; end if;
      if v_div is not null and v_reg.current_division_id is distinct from v_div then continue; end if;
      if v_has_ts and v_reg.created_at > v_ts then continue; end if;
      if v_verified < v_need then
        select * into v_live from search_live(x ->> 'table_name', (x ->> 'entity_id')::uuid);
        if v_live.label is null then v_stale := v_stale || (x ->> 'institutional_id'); continue; end if;
        if v_live.label is distinct from (x ->> 'label') or coalesce(v_live.terms, '') <> coalesce(x ->> 'terms', '') then v_stale := v_stale || (x ->> 'institutional_id'); continue; end if;
        v_verified := v_verified + 1;
        v_out := v_out || jsonb_build_array(jsonb_build_object('institutional_id', x ->> 'institutional_id', 'entity_type', x ->> 'entity_type', 'label', v_live.label, 'status', v_reg.status, 'score', round((x ->> 'score')::numeric, 4)));
      else
        v_out := v_out || jsonb_build_array(jsonb_build_object('institutional_id', x ->> 'institutional_id', 'entity_type', x ->> 'entity_type', 'status', v_reg.status));
      end if;
    end loop;
    exit when jsonb_array_length(v_out) > 0 or v_tsq is null or v_pass = 2;
  end loop;
  end if;
  if cardinality(v_stale) > 0 then perform search_flag_stale(v_stale); end if;
  v_total := jsonb_array_length(v_out);
  -- exact IDs given together with other criteria are merged in first
  for x in select * from jsonb_array_elements(v_ids) loop
    if not exists (select 1 from jsonb_array_elements(v_out) o where o ->> 'institutional_id' = x ->> 'institutional_id') then
      v_out := jsonb_build_array(jsonb_build_object('institutional_id', x ->> 'institutional_id', 'entity_type', x ->> 'entity_type', 'label', x -> 'live' ->> 'label', 'status', x ->> 'status', 'score', 2)) || v_out;
    end if;
  end loop;
  v_total := jsonb_array_length(v_out);
  if (q ->> 'facets')::boolean then
    v_facets := jsonb_build_object(
      'entity_type', coalesce((select jsonb_object_agg(k, c) from (select o ->> 'entity_type' k, count(*) c from jsonb_array_elements(v_out) o group by 1) f), '{}'),
      'status', coalesce((select jsonb_object_agg(k, c) from (select coalesce(o ->> 'status', '-') k, count(*) c from jsonb_array_elements(v_out) o group by 1) f), '{}'));
  end if;
  select coalesce(jsonb_agg(o), '[]') into v_page from (select o from jsonb_array_elements(v_out) with ordinality t(o, n) where n > (q ->> 'offset')::int and n <= (q ->> 'offset')::int + (q ->> 'limit')::int order by n) p;
  v_route := case when v_rel_mode then 'related' when jsonb_array_length(q -> 'ids') > 0 then 'registry+index' else 'index' end;
  return jsonb_build_object('route', v_route, 'query', (q - 'as_of') || case when v_has_ts then jsonb_build_object('as_of', v_ts) else '{}' end, 'total', v_total, 'capped', jsonb_array_length(v_cand) >= v_cap,
                            'results', v_page) || case when v_facets = '{}' then '{}'::jsonb else jsonb_build_object('facets', v_facets) end;
end $$;

create function search(p_query text, p_limit integer default null, p_offset integer default 0, p_facets boolean default false) returns jsonb
language sql volatile set search_path = public, pg_temp as $$
  select search_execute(search_parse(p_query) || jsonb_build_object('offset', coalesce(p_offset, 0), 'facets', coalesce(p_facets, false))
                        || case when p_limit is not null then jsonb_build_object('limit', p_limit) else '{}' end)
$$;

-- Autocomplete: labels of entities the caller may see, nothing else. No counts, no popularity, no vocabulary of rows the caller cannot see.
create function search_suggest(p_prefix text, p_types text[] default null, p_limit integer default 8) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare v_norm text := search_norm(left(coalesce(p_prefix, ''), 80)); v_toks text[]; v_tsq tsquery; v_cand jsonb; x jsonb; v_live record; v_out jsonb := '[]'; v_stale text[] := '{}'; v_lim integer := least(greatest(coalesce(p_limit, 8), 1), 10); v_pass integer;
begin
  if current_staff_id() is null or length(v_norm) < 2 then return '[]'::jsonb; end if;
  v_toks := array(select t from regexp_split_to_table(v_norm, ' ') t where t <> '');
  v_tsq := to_tsquery('simple', (select string_agg(quote_literal(t) || ':*', ' & ') from unnest(v_toks) t));
  for v_pass in 1..2 loop
    v_out := '[]'; v_stale := '{}';
    perform set_config('ada.search_tsq', (select string_agg(quote_literal(t) || ':*', ' & ') from unnest(v_toks) t), true);
    perform set_config('ada.search_norm', v_norm, true);
    perform set_config('ada.search_sim', case when v_pass = 2 then '0.5' else '' end, true);
    perform set_config('ada.search_types', coalesce(array_to_string(p_types, ','), ''), true);
    select coalesce(jsonb_agg(to_jsonb(c)), '[]') into v_cand from (
      select s.institutional_id, s.entity_type, s.table_name, s.entity_id, s.label, s.terms
        from search_index s
       order by (s.label_norm like v_norm || '%') desc, search_sim(s.label_norm, v_norm) desc, s.label, s.institutional_id
       limit v_lim * 3) c;
    perform set_config('ada.search_tsq', '', true); perform set_config('ada.search_norm', '', true); perform set_config('ada.search_sim', '', true); perform set_config('ada.search_types', '', true);
    for x in select * from jsonb_array_elements(v_cand) loop
      select * into v_live from search_live(x ->> 'table_name', (x ->> 'entity_id')::uuid);
      if v_live.label is null or v_live.label is distinct from (x ->> 'label') or coalesce(v_live.terms, '') <> coalesce(x ->> 'terms', '') then v_stale := v_stale || (x ->> 'institutional_id'); continue; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('institutional_id', x ->> 'institutional_id', 'entity_type', x ->> 'entity_type', 'label', v_live.label));
      exit when jsonb_array_length(v_out) >= v_lim;
    end loop;
    exit when jsonb_array_length(v_out) > 0 or v_pass = 2;
  end loop;
  if cardinality(v_stale) > 0 then perform search_flag_stale(v_stale); end if;
  return v_out;
end $$;

create function search_capabilities() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object('request_keys', jsonb_build_array('q', 'ids', 'types', 'status', 'division', 'related_to', 'as_of', 'limit', 'offset', 'facets'),
    'filters_in_text', jsonb_build_array('type:', 'status:', 'division:', 'related:', 'asof:', 'limit:'),
    'types', (select coalesce(jsonb_agg(entity_type order by entity_type), '[]') from search_sources where is_active),
    'limits', jsonb_build_object('results', 50, 'offset', 1000, 'candidates', 500, 'suggestions', 10, 'min_suggest_chars', 2, 'ids', 20),
    'deterministic', true, 'public', false)
$$;


-- The cheap half of the row-level policy. Row security is applied BEFORE the query's own conditions (they are not leakproof), so on a large index the expensive
-- authorization check would run for every row. search_execute / search_suggest therefore state what they are looking for through four transaction-local
-- settings, and this function (cost 1, evaluated first) lets only rows that match them reach the authorization check. It can only NARROW what a caller sees
-- (their own settings, applied to a row's own content): it can never widen anything, and a caller who sets them by hand merely searches the index themselves.
create function search_ctx_match(p_tsv tsvector, p_label_norm text, p_type text) returns boolean
language plpgsql stable cost 1 set search_path = public, pg_temp as $$
declare v_q text := current_setting('ada.search_tsq', true); v_n text := current_setting('ada.search_norm', true); v_t text := current_setting('ada.search_sim', true); v_ty text := current_setting('ada.search_types', true);
begin
  if v_ty is not null and v_ty <> '' and not (p_type = any (string_to_array(v_ty, ','))) then return false; end if;
  if v_q is null or v_q = '' then return true; end if;
  if p_tsv @@ to_tsquery('simple', v_q) then return true; end if;
  return v_t is not null and v_t <> '' and search_sim(p_label_norm, coalesce(v_n, '')) >= v_t::real;
end $$;

drop policy search_index_select on search_index;
create policy search_index_select on search_index for select to authenticated
  using (search_ctx_match(tsv, label_norm, entity_type) and entity_visible(table_name, entity_id));

-- ---------------------------------------------------------------------------
-- Grants and row-level security
-- ---------------------------------------------------------------------------
alter table search_sources enable row level security;
alter table search_refresh_queue enable row level security;
revoke all on search_sources, search_refresh_queue from anon, authenticated;
grant select on search_sources to authenticated;
create policy search_sources_select on search_sources for select to authenticated using (true);
revoke all on search_index from anon, authenticated;
grant select (institutional_id, entity_type, table_name, entity_id, label, terms, label_norm, tsv, refreshed_at, source_hash) on search_index to authenticated;

revoke execute on function search_ctx_match(tsvector, text, text), search_sim(text, text), search_norm(text), search_live(text, uuid), search_parse(text), search_request_validate(jsonb), search_execute(jsonb), search(text, integer, integer, boolean),
  search_suggest(text, text[], integer), search_capabilities() from public, anon;
grant execute on function search_ctx_match(tsvector, text, text), search_sim(text, text), search_norm(text), search_live(text, uuid), search_parse(text), search_request_validate(jsonb), search_execute(jsonb), search(text, integer, integer, boolean),
  search_suggest(text, text[], integer), search_capabilities() to authenticated;

-- Initial build from the records that already exist (later changes are maintained incrementally)
select search_rebuild();
