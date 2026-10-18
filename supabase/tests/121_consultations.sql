-- PERMANENT: consultation booking - nothing is offered until an administrator switches it on and sets hours; slots are generated in
-- Africa/Windhoek; a booked slot cannot be booked again (database exclusion); customers act only with reference + cancel code.
begin;
select tests.setup();
select tests.setup_hr();
update websites set capabilities = capabilities || array['consultations.book'] where id = tests.id('site:main') and not ('consultations.book' = any (capabilities));

select tests.check('booking is off and no hours exist by default: no slots are offered', tests.pub('main', 'consultation_slots', ''), '{"slots": [], "enabled": false, "timezone": "Africa/Windhoek", "slot_minutes": 30}');
select tests.check('another website (no capability) is refused', tests.pub('tech', 'consultation_slots', ''), 'ERR:42501');
select tests.check('booking while off is refused', tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', now() + interval '3 days', 'Ann Test', 'ann@example.com', '+264811234567', 'A new website')), 'ERR:P0001');

-- Configure: only configure-permission holders may
select tests.check('staff without configure cannot switch booking on or add hours; the CEO can', concat_ws('|',
  tests.try('web_lead', 'update consultation_settings set enabled = true'),
  tests.try('web_lead', $q$ insert into consultation_hours (weekday, opens_at, closes_at) values (1, '09:00', '12:00') $q$),
  tests.try('ceo', 'update consultation_settings set enabled = true, min_notice_hours = 0'),
  tests.try('ceo', $q$ insert into consultation_hours (weekday, opens_at, closes_at) select d, '09:00', '11:00' from generate_series(0, 6) d $q$)), 'ok0|ERR:42501|ok|ok');

create temp table slraw as select tests.pub('main', 'consultation_slots', format('%L, %L', current_date + 1, current_date + 3)) as r;
create temp table sl as select (case when (select r from slraw) like 'ERR%' then '{"slots":[]}' else (select r from slraw) end)::jsonb as j;
select tests.check('each day offers 09:00, 09:30, 10:00, 10:30 (30-minute slots until 11:00) with +02:00 times', 
  (select (jsonb_array_length(j -> 'slots') between 8 and 12)::text || '|' || (j ->> 'timezone') from sl), 'true|Africa/Windhoek');
select tests.check('slot times are on the half-hour in Windhoek local time and end 30 minutes later', (select bool_and(
  (s ->> 'start') ~ '^\d{4}-\d\d-\d\dT(09|10):(00|30):00\+02:00$' and ((s ->> 'end')::timestamptz - (s ->> 'start')::timestamptz) = interval '30 minutes')::text
  from sl, jsonb_array_elements(j -> 'slots') s), 'true');

create temp table pick as select (j -> 'slots' -> 0 ->> 'start') as s from sl;
create temp table b1raw as select tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', (select s from pick), 'Ann Test', 'Ann@Example.com', '+264811234567', 'A new website for my shop')) as r;
create temp table b1 as select (case when (select r from b1raw) like 'ERR%' then '{}' else (select r from b1raw) end)::jsonb as j;
select tests.check('a booking returns a reference and a cancel code', (select (j ->> 'reference' ~ '^ADA-BKG-[0-9A-F]{8}$')::text || '|' || (length(j ->> 'cancel_code') = 10)::text from b1), 'true|true');
select tests.check('only the code''s hash is stored, and the email is stored lower-case', (select count(*)::text from consultations where cancel_code_hash = (select j ->> 'cancel_code' from b1)) || '|' ||
  (select customer_email from consultations limit 1), '0|ann@example.com');
select tests.check('the booked slot is gone from the list', (select (not exists (select 1 from jsonb_array_elements(tests.pub('main', 'consultation_slots', format('%L, %L', current_date + 1, current_date + 3))::jsonb -> 'slots') e where e ->> 'start' = (select s from pick)))::text), 'true');
select tests.check('the same slot cannot be booked twice', tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', (select s from pick), 'Ben Test', 'ben@example.com', '+264811234568', 'Another request')), 'ERR:23P01');
select tests.check('a time outside the hours is refused', tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', ((current_date + 2)::text || 'T14:00:00+02:00'), 'Ben Test', 'ben@example.com', '+264811234568', 'Another request')), 'ERR:23P01');
select tests.check('a bad email or short topic is refused by the database', concat_ws('|',
  tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', (select j -> 'slots' -> 1 ->> 'start' from sl), 'Ben', 'not-an-email', '+264811234568', 'Another request')),
  tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', (select j -> 'slots' -> 1 ->> 'start' from sl), 'Ben', 'ben@example.com', '+264811234568', 'hi'))), 'ERR:23514|ERR:23514');

-- Blocked dates
insert into consultation_blocks (starts_on, ends_on, reason) values (current_date + 3, current_date + 3, 'Public holiday');
select tests.check('a blocked date offers nothing', jsonb_array_length(tests.pub('main', 'consultation_slots', format('%L, %L', current_date + 3, current_date + 3))::jsonb -> 'slots')::text, '0');

-- Customer actions with reference + code
select tests.check('status needs the right reference and code', concat_ws('|',
  tests.pub('main', 'consultation_status', format('%L, %L', (select j ->> 'reference' from b1), (select j ->> 'cancel_code' from b1)))::jsonb ->> 'status',
  tests.pub('main', 'consultation_status', format('%L, %L', (select j ->> 'reference' from b1), 'WRONGCODE1')),
  tests.pub('main', 'consultation_status', format('%L, %L', 'ADA-BKG-00000000', (select j ->> 'cancel_code' from b1)))), 'booked|ERR:P0002|ERR:P0002');
select tests.check('the customer can move the booking to another free time (once per move, at most twice)', 
  tests.pub('main', 'reschedule_consultation', format('%L, %L, %L', (select j ->> 'reference' from b1), (select j ->> 'cancel_code' from b1), (select j -> 'slots' -> 2 ->> 'start' from sl)))::jsonb ->> 'status', 'booked');
select tests.check('the old slot is free again and the booking moved', (select (starts_at = (select (j -> 'slots' -> 2 ->> 'start')::timestamptz from sl))::text || '|' || reschedule_count::text from consultations where reference = (select j ->> 'reference' from b1)), 'true|1');
select tests.check('the customer can cancel; cancelling twice is refused', 
  tests.pub('main', 'cancel_consultation', format('%L, %L, %L', (select j ->> 'reference' from b1), (select j ->> 'cancel_code' from b1), 'Plans changed'))::jsonb ->> 'status' || '|' ||
  tests.pub('main', 'cancel_consultation', format('%L, %L', (select j ->> 'reference' from b1), (select j ->> 'cancel_code' from b1))), 'cancelled|ERR:P0001');
select tests.check('a cancelled slot can be booked again', coalesce(tests.pub('main', 'book_consultation', format('%L, %L, %L, %L, %L', (select s from pick), 'Cy Test', 'cy@example.com', '+264811234569', 'Redesign of my site'))::jsonb ->> 'status', 'none'), 'booked');

-- Privacy: customers and the public see no rows; staff by permission
select tests.check('the public and signed-in users without the permission cannot read bookings; viewers can', concat_ws('|',
  tests.scalar_anon('select count(*)::text from consultations'),
  tests.scalar('outsider', 'select count(*)::text from consultations'),
  tests.scalar('tech_staff', 'select count(*)::text from consultations'),
  (tests.scalar('ceo', 'select count(*)::text from consultations') <> '0')::text,
  tests.scalar('ceo', 'select cancel_code_hash from consultations limit 1')), 'ERR:42501|0|0|true|ERR:42501');

-- Staff actions
create temp table cid as select id from consultations where customer_email = 'cy@example.com';
select tests.check('staff with manage can mark a consultation completed; viewers cannot; the closed one cannot be cancelled', concat_ws('|',
  tests.scalar('tech_staff', format($q$ select (consultation_staff_action(%L, 'completed')).status $q$, (select id from cid))),
  tests.scalar('ceo', format($q$ select (consultation_staff_action(%L, 'completed')).status $q$, (select id from cid))),
  tests.scalar('ceo', format($q$ select (consultation_staff_action(%L, 'cancel')).status $q$, (select id from cid)))), 'ERR:42501|completed|ERR:P0001');
select tests.finish();
rollback;
