-- Fixture for the concurrent domain tests: one staff member (CEO), a registrar, and three active domains.
insert into auth.users (id, email) values (md5('conc-dom-user')::uuid, 'concdom@ada.test');
insert into staff (user_id, full_name, email, account_status) values (md5('conc-dom-user')::uuid, 'Conc Dom', 'concdom@ada.test', 'active');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'concdom@ada.test' and r.key = 'ceo';
insert into suppliers (name) values ('Conc Registrar');
insert into domains (name, division_id) select n, (select id from divisions where key = 'web') from unnest(array['race-distinct.example', 'race-same.example', 'race-transfer.example']) n;
insert into domain_relations (domain_id, relation, entity_institutional_id)
select d.id, 'registrar', (select institutional_id from entity_registry where table_name = 'suppliers' and entity_id = (select id from suppliers where name = 'Conc Registrar')) from domains d where d.name like 'race-%';
insert into domain_registrations (domain_id, kind, period_start, period_end, order_reference) select d.id, 'registration', current_date - 65, current_date + 300, 'INIT' from domains d where d.name like 'race-%';
