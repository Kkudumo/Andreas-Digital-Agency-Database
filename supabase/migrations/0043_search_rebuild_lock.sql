-- 0043_search_rebuild_lock: two concurrency defects in Search (migration 0041), found by the pilot's CI.
-- Defect 1: two sessions running search_rebuild() at the same time can deadlock on `delete from search_refresh_queue` (each holds some queue rows the
-- other needs) - PostgreSQL aborts one of them with "deadlock detected". Seen intermittently in scripts/test-db.sh (concurrent_search: two sessions rebuild
-- three times each while eight others rename and search), with the statement's error text visible once the test kept stderr.
-- Fix 1: rebuilds are serialised with a transaction-level advisory lock taken first, and the final clearing of the queue skips rows another session holds
-- instead of waiting for them (a still-queued row only costs one extra refresh). Same result, same grants; readers and the incremental triggers are not
-- blocked (they never take the advisory lock).
create or replace function search_rebuild() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('ada.search_rebuild'));   -- one rebuild at a time
  for r in select e.table_name, e.entity_id from entity_registry e join search_sources s on s.entity_type = e.entity_type and s.is_active where e.status is distinct from 'removed' order by e.institutional_id loop
    perform search_refresh_row(r.table_name, r.entity_id, true); n := n + 1;
  end loop;
  -- rows whose entity is no longer searchable (removed, deactivated source, unknown) are dropped; rows of entities created meanwhile are untouched (they are in the registry)
  delete from search_index i
   where not exists (select 1 from entity_registry e join search_sources s on s.entity_type = e.entity_type and s.is_active where e.institutional_id = i.institutional_id and e.table_name = i.table_name and e.entity_id = i.entity_id and e.entity_type = i.entity_type and e.status is distinct from 'removed');
  -- the queue is only a to-do list: rows another session is working on right now are skipped, not waited for (waiting is what could deadlock); they stay queued and are refreshed next time
  delete from search_refresh_queue where ctid in (select q.ctid from search_refresh_queue q for update skip locked);
  return n;
end $$;
revoke execute on function search_rebuild() from public, anon, authenticated;
grant execute on function search_rebuild() to service_role;

-- Defect 2: search_flag_stale() is called from search() / search_suggest(), possibly several times inside ONE transaction, and inserts stale ids into
-- search_refresh_queue. Two sessions that flag overlapping ids across several calls each hold part of what the other needs, so PostgreSQL aborts one search
-- with "deadlock detected ... while inserting index tuple ... search_refresh_queue". (Sorting the ids inside one call is not enough: the order across calls
-- cannot be fixed.)
-- Fix 2: flagging is best-effort bookkeeping (a stale row is never returned whether or not it is flagged: every candidate is re-read from the authoritative
-- record, and the next search flags it again), so only one transaction flags at a time: it takes a try-lock and, if another transaction is flagging, simply
-- skips. A search can therefore never wait on, or deadlock with, another search over the queue. Same rows when it does flag, same grants.
create or replace function search_flag_stale(p_ids text[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_staff_id() is null then return; end if;
  if not pg_try_advisory_xact_lock(hashtext('ada.search_flag_stale')) then return; end if;
  insert into search_refresh_queue (institutional_id, reason)
  select e.institutional_id, 'stale' from entity_registry e where e.institutional_id = any (p_ids)
  order by e.institutional_id
  on conflict (institutional_id) do nothing;
end $$;
revoke execute on function search_flag_stale(text[]) from public, anon;
grant execute on function search_flag_stale(text[]) to authenticated;
