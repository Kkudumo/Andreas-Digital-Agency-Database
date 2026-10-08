-- Fixture for the concurrent communications tests: one staff member (CEO) and two open threads (the first message of each is recorded by the test).
insert into auth.users (id, email) values (md5('conc-com-user')::uuid, 'conccom@ada.test');
insert into staff (user_id, full_name, email, account_status) values (md5('conc-com-user')::uuid, 'Conc Com', 'conccom@ada.test', 'active');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'conccom@ada.test' and r.key = 'ceo';
select set_config('request.jwt.claim.sub', md5('conc-com-user'), false);
set role authenticated;
select communication_start((select id from divisions where key = 'web'), 'race-numbering');
select communication_start((select id from divisions where key = 'web'), 'race-source');
reset role;
