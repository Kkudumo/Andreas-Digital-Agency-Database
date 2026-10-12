-- ADA Hub Pilot V0.1 - DEVELOPMENT seed: pilot staff accounts, ONE service with an approved price, ONE bank account.
-- Not part of the schema migrations. It creates NO clients, projects, quotes or any engagement: the workflow creates those.
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000001', 'ceo@pilot.test'),
  ('00000000-0000-4000-8000-000000000002', 'weblead@pilot.test'),
  ('00000000-0000-4000-8000-000000000003', 'webstaff@pilot.test'),
  ('00000000-0000-4000-8000-000000000004', 'finance@pilot.test'),
  ('00000000-0000-4000-8000-000000000005', 'techlead@pilot.test'),
  ('00000000-0000-4000-8000-000000000006', 'techstaff@pilot.test'),
  ('00000000-0000-4000-8000-000000000007', 'suspended@pilot.test'),
  ('00000000-0000-4000-8000-000000000008', 'outsider@pilot.test');
insert into staff (user_id, full_name, email, account_status)
  select u.id, v.n, u.email, v.s::account_status from auth.users u join (values
    ('ceo@pilot.test', 'Naomi Nangolo (CEO)', 'active'), ('weblead@pilot.test', 'Wanda Web (Web lead)', 'active'), ('webstaff@pilot.test', 'Wesley Web (Web staff)', 'active'),
    ('finance@pilot.test', 'Fiona Finance (Finance)', 'active'), ('techlead@pilot.test', 'Tobias Tech (Tech lead)', 'active'),
    ('techstaff@pilot.test', 'Tina Tech (Tech staff)', 'active'), ('suspended@pilot.test', 'Sam Suspended', 'suspended')) v(e, n, s) on u.email = v.e;
insert into staff_roles (staff_id, role_id, division_id)
  select s.id, r.id, d.id from staff s join (values
    ('ceo@pilot.test', 'ceo', null), ('weblead@pilot.test', 'division_lead', 'web'), ('webstaff@pilot.test', 'division_staff', 'web'), ('finance@pilot.test', 'finance_officer', null),
    ('techlead@pilot.test', 'division_lead', 'tech'), ('techstaff@pilot.test', 'division_staff', 'tech'), ('suspended@pilot.test', 'ceo', null)) v(e, rk, dk) on s.email = v.e
  join roles r on r.key = v.rk left join divisions d on d.key = v.dk;

insert into bank_accounts (name, bank_name, account_hint, currency) values ('ADA operating account', 'FNB Namibia', '****1234', 'NAD');

-- The catalogue: a service and its approved price, entered through the controlled operations (the web lead proposes, the CEO approves).
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', false);
set role authenticated;
insert into services (division_id, name, summary, description) select id, 'Website Development', 'Design and build of a business website', 'Pilot catalogue entry' from divisions where key = 'web';
select price_propose((select id from services where name = 'Website Development'), 5000, 'NAD', current_date, 'pilot launch price');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', false);
set role authenticated;
select (price_decide((select id from service_prices order by created_at desc limit 1), true)).status;
reset role;
