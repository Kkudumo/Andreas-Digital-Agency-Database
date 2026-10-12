-- PERMANENT: Event dispatch - deliveries are handed out grouped per subscription (bursts become one webhook), debounced, in flight with a visibility timeout,
-- retried with back-off and abandoned after 8 attempts; only the dispatcher role can claim or report; inactive subscriptions and suspended sites get nothing.
begin;
select tests.setup();
select tests.setup_hr();
create table tests.outs (k text primary key, v text);
create function tests.o(p_key text, p_val text) returns void language sql as $$ insert into tests.outs values (p_key, p_val) on conflict (k) do update set v = excluded.v $$;
create function tests.g(p_key text) returns text language sql stable as $$ select v from tests.outs where k = p_key $$;
-- run a statement as the dispatcher role and return its text result (or ERR:<sqlstate>)
create function tests.disp(p_role text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute format('set local role %I', p_role);
  begin execute p_sql into v; exception when others then reset role; return 'ERR:' || sqlstate; end;
  reset role; return v;
end $$;
-- two subscriptions: the main site wants everything; the tech site only price and service events
insert into event_subscriptions (website_id, url, secret_ref, event_types) values
  (tests.id('site:main'), 'https://hooks.example.test/main', 'MAIN_SITE_SECRET', array['*']),
  (tests.id('site:tech'), 'https://hooks.example.test/tech', null, array['price.changed', 'service.published']);
select emit_event('price.changed', 'service_prices', gen_random_uuid(), 'ADA-SVC-2026-0001', '{"service":"ADA-SVC-2026-0001"}');
select emit_event('price.changed', 'service_prices', gen_random_uuid(), 'ADA-SVC-2026-0002', '{}');
select emit_event('content_post.published', 'content_posts', gen_random_uuid(), 'ADA-NWS-2026-0001', '{}');
select emit_event('service.published', 'services', gen_random_uuid(), 'ADA-SVC-2026-0003', '{}');
select tests.check('1. the outbox has one delivery per matching subscription (main: all 4 events, tech: 3)',
  (select string_agg(w.domain || '=' || n, ',' order by w.domain) from (select s.website_id, count(*) n from event_deliveries d join event_subscriptions s on s.id = d.subscription_id group by 1) c join websites w on w.id = c.website_id),
  'main.ada.test=4,tech.ada.test=3');
select tests.check('2. only the dispatcher role can claim or report; every other role, including signed-in staff and the public API role, is refused',
  tests.scalar('ceo', 'select count(*)::text from dispatch_claim(10, 0)') || tests.disp('ada_public_api', 'select count(*)::text from dispatch_claim(10, 0)') || tests.disp('authenticated', 'select dispatch_report(array[1]::bigint[], true)::text'), 'ERR:42501ERR:42501ERR:42501');
select tests.check('3. the debounce holds a fresh burst back: nothing is due for 20 seconds', tests.disp('ada_dispatcher', 'select count(*)::text from dispatch_claim(10, 20)'), '0');
select tests.o('c1', tests.disp('ada_dispatcher', $q$ with c as (select * from dispatch_claim(10, 0))
  select (select string_agg(domain || ':' || cardinality(delivery_ids) || ':' || jsonb_array_length(events) || ':' || coalesce(secret_ref, '-'), ',' order by domain) from c) || '#' ||
         (select string_agg(distinct k, ',' order by k) from c, jsonb_array_elements(c.events) e, jsonb_object_keys(e) k) $q$));
select tests.check('4. a claim returns one batch per subscription with all its due events (main: 4 with its secret name, tech: 3 without); events carry identifiers and state only',
  tests.g('c1'), 'main.ada.test:4:4:MAIN_SITE_SECRET,tech.ada.test:3:3:-#entity,id,occurred_at,payload,type');
select tests.check('5. claimed deliveries are in flight (attempt 1, retry window 5 minutes): an immediate second claim finds nothing',
  tests.disp('ada_dispatcher', 'select count(*)::text from dispatch_claim(10, 0)') || '|' || (select min(attempts)::text || max(attempts)::text from event_deliveries), '0|11');
select tests.o('r1', tests.disp('ada_dispatcher', format('select dispatch_report(%L::bigint[], true)::text', (select array_agg(d.id) from event_deliveries d join event_subscriptions s on s.id = d.subscription_id where s.url like '%/tech'))));
select tests.o('r2', tests.disp('ada_dispatcher', format('select dispatch_report(%L::bigint[], false, ''HTTP 503'')::text', (select array_agg(d.id) from event_deliveries d join event_subscriptions s on s.id = d.subscription_id where s.url like '%/main'))));
select tests.check('6. success marks the batch delivered; failure keeps it pending with the error (no URL) and a back-off of about a minute',
  tests.g('r1') || '/' || tests.g('r2') || '|' ||
  (select string_agg((s.url like '%/tech')::text || ':' || d.status || ':' || coalesce(d.last_error, '-') || ':' || (d.next_attempt_at > now() and d.next_attempt_at <= now() + interval '70 seconds')::text, ',' order by d.id) from (select distinct on (d.subscription_id) d.* from event_deliveries d order by d.subscription_id, d.id) d join event_subscriptions s on s.id = d.subscription_id),
  '3/4|false:pending:HTTP 503:true,true:delivered:-:false');
-- pull the retry forward and fail it again and again: attempts grow, the wait doubles, and after 8 attempts it is abandoned
update event_deliveries set next_attempt_at = now() - interval '1 second' where status = 'pending';
select tests.o('c2', tests.disp('ada_dispatcher', $q$ select string_agg(cardinality(delivery_ids)::text, ',') from dispatch_claim(10, 0) $q$));
select tests.disp('ada_dispatcher', format('select dispatch_report(%L::bigint[], false, ''timeout'')::text', (select array_agg(id) from event_deliveries where status = 'pending')));
select tests.check('7. the second failure doubles the wait (about 2 minutes)', tests.g('c2') || '|' || (select (min(next_attempt_at) > now() + interval '100 seconds' and max(next_attempt_at) <= now() + interval '125 seconds')::text from event_deliveries where status = 'pending'), '4|true');
do $$ declare i integer; begin
  for i in 3..8 loop
    update event_deliveries set next_attempt_at = now() - interval '1 second' where status = 'pending';
    perform tests.disp('ada_dispatcher', 'select count(*)::text from dispatch_claim(10, 0)');
    perform tests.disp('ada_dispatcher', format('select dispatch_report(%L::bigint[], false, ''timeout'')::text', (select array_agg(id) from event_deliveries where status = 'pending')));
  end loop;
end $$;
select tests.check('8. after 8 failed attempts the deliveries are abandoned as failed and are never claimed again',
  (select string_agg(distinct status || attempts, ',') from event_deliveries where status <> 'delivered') || '|' ||
  (select count(*)::text from dispatch_claim(10, 0)), 'failed8|0');
-- inactive subscriptions and suspended sites get nothing
select emit_event('price.changed', 'service_prices', gen_random_uuid(), 'ADA-SVC-2026-0004', '{}');
update event_subscriptions set is_active = false where url like '%/main';
update websites set status = 'suspended' where id = tests.id('site:tech');
select tests.check('9. an inactive subscription or a suspended website is not delivered to', tests.disp('ada_dispatcher', 'select count(*)::text from dispatch_claim(10, 0)'), '0');
update websites set status = 'active' where id = tests.id('site:tech');
select tests.check('10. ...and a website that comes back gets what it missed', tests.disp('ada_dispatcher', 'select count(*)::text || cardinality(min(delivery_ids)) from dispatch_claim(10, 0)'), '11');
select tests.check('11. the dispatcher role can read no table', tests.disp('ada_dispatcher', 'select count(*)::text from events') || tests.disp('ada_dispatcher', 'select count(*)::text from websites'), 'ERR:42501ERR:42501');
select tests.finish();
rollback;
