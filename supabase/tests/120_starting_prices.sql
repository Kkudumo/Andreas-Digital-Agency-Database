-- PERMANENT: Starting prices - a price version can be a "from" price; the flag is part of the immutable version, defaults to a fixed price, and is passed on
-- to the public catalogue.
begin;
select tests.setup();
select tests.setup_hr();
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.remember('svc:a', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description, billing_unit) select id, 'Fixed thing', 's', 'd', 'job' from divisions where key = 'web' returning id::text $q$));
select tests.remember('svc:b', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description, billing_unit) select id, 'From thing', 's', 'd', 'job' from divisions where key = 'web' returning id::text $q$));
select tests.remember('p:a', tests.scalar('web_lead', format($q$ select price_propose(%L, 500, 'NAD', current_date, 'fixed list price')::text $q$, tests.id('svc:a'))));
select tests.remember('p:b', tests.scalar('web_lead', format($q$ select price_propose(%L, 800, 'NAD', current_date, 'starting price', true)::text $q$, tests.id('svc:b'))));
select tests.scalar('ceo', format($q$ select (price_decide(%L, true)).status::text $q$, tests.id('p:a')));
select tests.scalar('ceo', format($q$ select (price_decide(%L, true)).status::text $q$, tests.id('p:b')));
select tests.check('1. the existing five-argument call still works and means a fixed price; the sixth argument makes it a starting price; the approved version carries the flag',
  (select string_agg(is_starting_price::text, ',' order by amount) from service_prices where service_id in (tests.id('svc:a'), tests.id('svc:b'))), 'false,true');
select tests.check('2. the flag is part of the immutable version: not even the owner can change it once approved',
  tests.try_owner(format('update service_prices set is_starting_price = not is_starting_price where id = %L', tests.id('p:b'))), 'ERR:42501');
select tests.check('3. the price in force reports the flag (price_on)', (select (price_on(tests.id('svc:b'))).is_starting_price::text || (price_on(tests.id('svc:a'))).is_starting_price::text), 'truefalse');
select tests.scalar('ceo', format($q$ select service_transition(%L, 'pending_approval')::text $q$, tests.id('svc:a')));
select tests.scalar('ceo', format($q$ select service_transition(%L, 'pending_approval')::text $q$, tests.id('svc:b')));
select tests.scalar('ceo', format($q$ select service_transition(%L, 'approved')::text $q$, tests.id('svc:a')));
select tests.scalar('ceo', format($q$ select service_transition(%L, 'approved')::text $q$, tests.id('svc:b')));
select tests.scalar('ceo', format($q$ select service_transition(%L, 'published')::text $q$, tests.id('svc:a')));
select tests.scalar('ceo', format($q$ select service_transition(%L, 'published')::text $q$, tests.id('svc:b')));
select tests.check('4. the public catalogue says which price is a starting price (and a website that may not read services learns nothing)',
  coalesce((select string_agg(e ->> 'name' || '=' || (e #>> '{price,amount}') || '/' || coalesce(e #>> '{price,starting_price}', 'null'), ',' order by e ->> 'name')
              from jsonb_array_elements(tests.pub('main', 'services')::jsonb) e where e ->> 'name' in ('Fixed thing', 'From thing')), 'none') || '|' || coalesce(tests.pub('limited', 'services'), 'null'),
  'Fixed thing=500.00/false,From thing=800.00/true|ERR:42501');
select tests.finish();
rollback;
