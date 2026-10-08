-- Fixture for the concurrent document-version test: one staff member (CEO) and one document owned by them.
insert into auth.users (id, email) values (md5('conc-doc-user')::uuid, 'concdoc@ada.test');
insert into staff (user_id, full_name, email, account_status) values (md5('conc-doc-user')::uuid, 'Conc Doc', 'concdoc@ada.test', 'active');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'concdoc@ada.test' and r.key = 'ceo';
insert into documents (title, document_type_id, division_id, retention_class_id, retention_months, owner_staff_id)
select 'Concurrent versions', (select id from document_types where key = 'report'), (select id from divisions where key = 'web'), (select id from retention_classes where key = 'general_5y'), 60,
       (select id from staff where email = 'concdoc@ada.test');
