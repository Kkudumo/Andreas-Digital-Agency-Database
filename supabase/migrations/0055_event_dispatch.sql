-- 0055_event_dispatch: the sender behind the events outbox.
-- Changes already write rows to `events` and, for every active subscription, a pending row in `event_deliveries` (emit_event). This adds the two controlled
-- operations a delivery worker needs, and nothing else:
--   dispatch_claim(debounce)  -> hands the worker the due deliveries GROUPED PER SUBSCRIPTION (so a burst of changes is one webhook, not fifty rebuilds), and
--                                marks them in flight with a 5-minute visibility timeout so a crashed worker's deliveries come back by themselves;
--   dispatch_report(ids, ok)  -> records success, or schedules a retry with growing back-off (1, 2, 4 ... capped at 60 minutes) and gives up as 'failed' after 8 attempts.
-- Only the ada_dispatcher role can run them (ops gives it a login outside migrations, like ada_public_api). The worker sees event identifiers and states only
-- (never table contents) and the subscription's URL; it never reads a table.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'ada_dispatcher') then create role ada_dispatcher nologin; end if;
end $$;

create function dispatch_claim(p_max_subscriptions integer default 10, p_debounce_seconds integer default 20)
returns table (subscription_id uuid, url text, secret_ref text, domain text, delivery_ids bigint[], events jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record; v_ids bigint[];
begin
  for s in
    select sub.id, sub.url, sub.secret_ref, w.domain
      from event_subscriptions sub join websites w on w.id = sub.website_id
     where sub.is_active and w.status = 'active'
       and exists (select 1 from event_deliveries d join events e on e.id = d.event_id
                    where d.subscription_id = sub.id and d.status = 'pending' and d.next_attempt_at <= now()
                    having min(e.occurred_at) <= now() - make_interval(secs => greatest(coalesce(p_debounce_seconds, 0), 0)))
     order by sub.id
     limit greatest(coalesce(p_max_subscriptions, 10), 1)
  loop
    -- everything pending for this subscription that is due, taken together; rows another worker holds are skipped
    select array_agg(x.id order by x.id) into v_ids from (
      select d.id from event_deliveries d
       where d.subscription_id = s.id and d.status = 'pending' and d.next_attempt_at <= now()
       order by d.id limit 200 for update skip locked) x;
    continue when v_ids is null;
    update event_deliveries set attempts = attempts + 1, next_attempt_at = now() + interval '5 minutes' where id = any (v_ids);
    subscription_id := s.id; url := s.url; secret_ref := s.secret_ref; domain := s.domain; delivery_ids := v_ids;
    events := (select jsonb_agg(jsonb_build_object('id', e.id, 'type', e.event_type, 'occurred_at', e.occurred_at,
                      'entity', jsonb_strip_nulls(jsonb_build_object('table', e.entity_table, 'id', e.entity_id, 'ada_id', e.entity_ada_id)), 'payload', e.payload) order by e.id)
                 from event_deliveries d join events e on e.id = d.event_id where d.id = any (v_ids));
    return next;
  end loop;
end $$;

create function dispatch_report(p_delivery_ids bigint[], p_ok boolean, p_error text default null) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  if p_ok then
    update event_deliveries set status = 'delivered', delivered_at = now(), last_error = null where id = any (p_delivery_ids) and status = 'pending';
  else
    update event_deliveries
       set status = case when attempts >= 8 then 'failed' else 'pending' end,
           next_attempt_at = now() + least(power(2, greatest(attempts - 1, 0)) * interval '1 minute', interval '60 minutes'),
           last_error = left(coalesce(p_error, 'delivery failed'), 200)
     where id = any (p_delivery_ids) and status = 'pending';
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function dispatch_claim(integer, integer), dispatch_report(bigint[], boolean, text) from public, anon, authenticated;
grant execute on function dispatch_claim(integer, integer), dispatch_report(bigint[], boolean, text) to ada_dispatcher;
grant usage on schema public to ada_dispatcher;
