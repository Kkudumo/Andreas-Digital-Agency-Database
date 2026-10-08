-- Fixture for the concurrent search tests: one staff member (CEO) and one client whose name the sessions will keep changing.
insert into auth.users (id, email) values (md5('conc-search-user')::uuid, 'concsearch@ada.test');
insert into staff (user_id, full_name, email, account_status) values (md5('conc-search-user')::uuid, 'Conc Search', 'concsearch@ada.test', 'active');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'concsearch@ada.test' and r.key = 'ceo';
insert into clients (name) values ('cs-target');
