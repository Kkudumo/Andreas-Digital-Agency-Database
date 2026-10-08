-- Who can see and do what. Every check goes through the same table/RPC surface the
-- Supabase API exposes, as the `authenticated` or `anon` role, so a hidden button is never trusted.
begin;
select tests.setup();

-- helper: rows visible to a persona
create function pg_temp.n(p_user text, p_table text, p_where text default 'true') returns text
language sql as $$ select tests.scalar(p_user, format('select count(*)::text from %s where %s', p_table, p_where)) $$;
-- helper: rows affected by a statement given as "<cte-able dml> returning 1"
create function pg_temp.affected(p_user text, p_dml text) returns text
language sql as $$ select tests.scalar(p_user, format('with u as (%s returning 1) select count(*)::text from u', p_dml)) $$;

-- Clients: one record, visibility derived from division relationships ---------
select tests.check('CEO sees all 3 clients',                         pg_temp.n('ceo', 'clients'), '3');
select tests.check('Admin sees clients except confidential',         pg_temp.n('admin', 'clients'), '2');
select tests.check('Finance sees clients except confidential',       pg_temp.n('fin', 'clients'), '2');
select tests.check('Web lead sees only Web''s client',               pg_temp.n('web_lead', 'clients'), '1');
select tests.check('Web staff sees only Web''s client',              pg_temp.n('web_staff', 'clients'), '1');
select tests.check('Tech staff sees only Tech''s client',            tests.scalar('tech_staff', $q$ select string_agg(name, ',') from clients $q$), 'C_tech');
select tests.check('Web staff cannot see Tech''s client by name',    pg_temp.n('web_staff', 'clients', $q$ name = 'C_tech' $q$), '0');
select tests.check('Auditor has no client access',                   pg_temp.n('audit', 'clients'), '0');
select tests.check('Confidential client visible only with records.view_confidential',
  tests.scalar('admin', $q$ select count(*)::text from clients where name = 'C_conf' $q$) || tests.scalar('ceo', $q$ select count(*)::text from clients where name = 'C_conf' $q$), '01');
select tests.check('Contacts follow client visibility', pg_temp.n('web_staff', 'client_contacts'), '0');

-- Projects ------------------------------------------------------------------
select tests.check('CEO sees all projects',            pg_temp.n('ceo', 'projects'), '2');
select tests.check('Finance sees all projects',        pg_temp.n('fin', 'projects'), '2');
select tests.check('Web lead sees only Web project',   tests.scalar('web_lead', $q$ select string_agg(name, ',') from projects $q$), 'P_web');
select tests.check('Tech staff sees only Tech project', tests.scalar('tech_staff', $q$ select string_agg(name, ',') from projects $q$), 'P_tech');
select tests.check('Auditor sees no projects',         pg_temp.n('audit', 'projects'), '0');
select tests.check('Tasks follow project visibility (web)',  tests.scalar('web_staff', $q$ select string_agg(title, ',') from tasks $q$), 'T_web');
select tests.check('Tasks follow project visibility (tech)', tests.scalar('tech_staff', $q$ select string_agg(title, ',') from tasks $q$), 'T_tech');

-- Finance isolation: seeing a project never implies seeing its money ----------
select tests.check('Web lead cannot read project financials',  pg_temp.n('web_lead', 'project_financials'), '0');
select tests.check('Web staff cannot read project financials', pg_temp.n('web_staff', 'project_financials'), '0');
select tests.check('Admin cannot read project financials',     pg_temp.n('admin', 'project_financials'), '0');
select tests.check('Auditor cannot read project financials',   pg_temp.n('audit', 'project_financials'), '0');
select tests.check('Finance reads project financials',         pg_temp.n('fin', 'project_financials'), '2');
select tests.check('CEO reads project financials',             pg_temp.n('ceo', 'project_financials'), '2');
select tests.check('Web lead cannot write project financials',
  tests.try('web_lead', $q$ insert into project_financials (project_id, budget) select id, 1 from projects where name = 'P_web' on conflict (project_id) do update set budget = 1 $q$), 'ERR:42501');
select tests.check('Web lead cannot update project financials',
  pg_temp.affected('web_lead', $q$ update project_financials set budget = 1 $q$), '0');
select tests.check('Finance can update project financials',
  pg_temp.affected('fin', $q$ update project_financials set cost_to_date = 100 where project_id = (select id from projects where name = 'P_web') $q$), '1');

-- HR confidentiality --------------------------------------------------------
select tests.check('Staff can read their own private HR record', pg_temp.n('web_staff', 'staff_private'), '1');
select tests.check('Finance cannot read confidential HR',        pg_temp.n('fin', 'staff_private'), '0');
select tests.check('Web lead cannot read a colleague''s HR',     pg_temp.n('web_lead', 'staff_private'), '0');
select tests.check('Auditor cannot read HR',                     pg_temp.n('audit', 'staff_private'), '0');
select tests.check('Administration (hr.view) can read HR',       pg_temp.n('admin', 'staff_private'), '1');
select tests.check('Staff cannot edit their own HR record',
  pg_temp.affected('web_staff', $q$ update staff_private set national_id = '0' $q$), '0');
select tests.check('hr.update holder can edit HR',
  pg_temp.affected('admin', $q$ update staff_private set hr_notes = 'checked' $q$), '1');

-- Staff directory & account state -------------------------------------------
select tests.check('Active staff see the whole directory (limited columns)', pg_temp.n('web_staff', 'staff'), '8');
select tests.check('Suspended account sees nothing',        pg_temp.n('suspended', 'staff'), '0');
select tests.check('Suspended CEO sees no clients',         pg_temp.n('suspended', 'clients'), '0');
select tests.check('Suspended CEO has no permissions',      tests.scalar('suspended', $q$ select has_permission('roles.administer')::text $q$), 'false');
select tests.check('Login without staff record sees nothing', pg_temp.n('outsider', 'staff'), '0');
select tests.check('Login without staff record gets no identity', tests.scalar('outsider', $q$ select (my_access() is null)::text $q$), 'true');
select tests.check('Admin can edit directory fields',
  pg_temp.affected('admin', $q$ update staff set work_phone = '+264' where email = 'web_staff@ada.test' $q$), '1');
select tests.check('Admin cannot change account status without staff.manage_accounts',
  tests.try('admin', $q$ update staff set account_status = 'suspended' where email = 'web_staff@ada.test' $q$), 'ERR:42501');
select tests.check('Admin cannot create an already-active account',
  tests.try('admin', $q$ insert into staff (full_name, email, account_status) values ('N', 'n@ada.test', 'active') $q$), 'ERR:42501');
select tests.check('Admin can create an invited staff record',
  tests.try('admin', $q$ insert into staff (full_name, email) values ('Newbie', 'newbie@ada.test') $q$), 'ok');
select tests.check('Staff cannot change their own account status',
  pg_temp.affected('web_staff', $q$ update staff set account_status = 'active' where email = 'web_staff@ada.test' $q$), '0');
select tests.check('Admin cannot link logins', tests.try('admin', $q$ select link_staff_account((select id from staff where email = 'newbie@ada.test'), 'outsider@ada.test') $q$), 'ERR:42501');
select tests.check('CEO can link a login to a staff record',
  tests.try('ceo', $q$ select link_staff_account((select id from staff where email = 'newbie@ada.test'), 'outsider@ada.test') $q$), 'ok');
select tests.check('A linked login can now use the system', pg_temp.n('outsider', 'staff'), '9');
select tests.check('Linking an unknown login fails cleanly',
  tests.try('ceo', $q$ select link_staff_account((select id from staff where email = 'newbie@ada.test'), 'nobody@ada.test') $q$), 'ERR:P0002');

-- Permission administration: no escalation -----------------------------------
select tests.check('Web lead cannot grant themselves a role',
  tests.try('web_lead', $q$ insert into staff_roles (staff_id, role_id) values ((select id from tests.ids where key = 'staff:web_lead'), (select id from tests.ids where key = 'role:ceo')) $q$), 'ERR:42501');
select tests.check('Web lead cannot grant someone else a role',
  tests.try('web_lead', $q$ insert into staff_roles (staff_id, role_id) values ((select id from tests.ids where key = 'staff:web_staff'), (select id from tests.ids where key = 'role:division_staff')) $q$), 'ERR:42501');
select tests.check('Admin (no roles.administer) cannot grant roles',
  tests.try('admin', $q$ insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'web_staff@ada.test' and r.key = 'auditor' $q$), 'ERR:42501');
select tests.check('Ordinary staff cannot add role permissions',
  tests.try('web_lead', $q$ insert into role_permissions (role_id, permission_id) values ((select id from tests.ids where key = 'role:division_lead'), (select id from tests.ids where key = 'perm:finance.view')) $q$), 'ERR:42501');
select tests.check('Ordinary staff cannot remove role permissions',
  pg_temp.affected('web_lead', $q$ delete from role_permissions where role_id = (select id from roles where key = 'division_staff') $q$), '0');
select tests.check('Ordinary staff cannot edit roles',
  pg_temp.affected('web_lead', $q$ update roles set name = 'hacked' $q$), '0');
select tests.check('Nobody can edit the permission catalogue through the API',
  tests.try('ceo', $q$ insert into permissions (key, module, action, description) values ('x.y', 'x', 'y', 'z') $q$), 'ERR:42501');
select tests.check('Ordinary staff cannot see the access model', pg_temp.n('web_staff', 'role_permissions'), '0');
select tests.check('CEO cannot change their own role assignments',
  tests.try('ceo', $q$ insert into staff_roles (staff_id, role_id, division_id) select s.id, r.id, d.id from staff s, roles r, divisions d where s.email = 'ceo@ada.test' and r.key = 'division_staff' and d.key = 'web' $q$), 'ERR:42501');
select tests.check('CEO can assign a scoped role to someone else',
  tests.try('ceo', $q$ insert into staff_roles (staff_id, role_id, division_id) select s.id, r.id, d.id from staff s, roles r, divisions d where s.email = 'tech_staff@ada.test' and r.key = 'division_staff' and d.key = 'marketing' $q$), 'ok');

-- A delegated administrator cannot hand out more than they hold.
insert into roles (key, name) values ('role_admin', 'Role Administrator');
insert into role_permissions (role_id, permission_id)
  select r.id, p.id from roles r, permissions p where r.key = 'role_admin' and p.key in ('roles.administer', 'roles.view');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'admin@ada.test' and r.key = 'role_admin';
select tests.check('Delegated admin cannot grant the CEO role',
  tests.try('admin', $q$ insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'web_staff@ada.test' and r.key = 'ceo' $q$), 'ERR:42501');
select tests.check('Delegated admin cannot grant a role carrying permissions they lack (auditor)',
  tests.try('admin', $q$ insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'web_staff@ada.test' and r.key = 'auditor' $q$), 'ERR:42501');
select tests.check('Delegated admin cannot grant org-wide a role they hold only in part (finance)',
  tests.try('admin', $q$ insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'web_staff@ada.test' and r.key = 'finance_officer' $q$), 'ERR:42501');
select tests.check('Delegated admin cannot add a permission they lack to a role',
  tests.try('admin', $q$ insert into role_permissions (role_id, permission_id) select r.id, p.id from roles r, permissions p where r.key = 'role_admin' and p.key = 'finance.view' $q$), 'ERR:42501');
select tests.check('Delegated admin can grant what they hold',
  tests.try('admin', $q$ insert into staff_roles (staff_id, role_id, division_id) select s.id, r.id, d.id from staff s, roles r, divisions d where s.email = 'web_staff@ada.test' and r.key = 'division_staff' and d.key = 'consulting' $q$), 'ok');

-- Write scoping ---------------------------------------------------------------
select tests.check('Web lead can create a client owned by Web',
  tests.try('web_lead', $q$ insert into clients (name, owner_division_id) select 'New Web client', id from divisions where key = 'web' $q$), 'ok');
select tests.check('Creating a client records the creator',
  (select (created_by = (select id from staff where email = 'web_lead@ada.test'))::text from clients where name = 'New Web client'), 'true');
select tests.check('New client is linked to its owner division',
  (select count(*)::text from client_divisions cd join clients c on c.id = cd.client_id join divisions d on d.id = cd.division_id where c.name = 'New Web client' and d.key = 'web'), '1');
select tests.check('Web lead cannot create a client owned by Tech',
  tests.try('web_lead', $q$ insert into clients (name, owner_division_id) select 'Sneaky', id from divisions where key = 'tech' $q$), 'ERR:42501');
select tests.check('Web lead cannot create an unowned (org-level) client',
  tests.try('web_lead', $q$ insert into clients (name) values ('Unowned') $q$), 'ERR:42501');
select tests.check('Web staff (no clients.create) cannot create clients',
  tests.try('web_staff', $q$ insert into clients (name, owner_division_id) select 'X', id from divisions where key = 'web' $q$), 'ERR:42501');
select tests.check('Web lead cannot edit Tech''s client',
  pg_temp.affected('web_lead', $q$ update clients set notes = 'x' where name = 'C_tech' $q$), '0');
select tests.check('Web lead can edit Web''s client',
  pg_temp.affected('web_lead', $q$ update clients set notes = 'x' where name = 'C_web' $q$), '1');
select tests.check('Web staff (read-only on clients) cannot edit',
  pg_temp.affected('web_staff', $q$ update clients set notes = 'x' where name = 'C_web' $q$), '0');
select tests.check('Web lead cannot mark records confidential',
  tests.try('web_lead', $q$ update clients set classification = 'confidential' where name = 'C_web' $q$), 'ERR:42501');
select tests.check('Web lead cannot hand a client to another owner division',
  tests.try('web_lead', $q$ update clients set owner_division_id = (select id from divisions where key = 'tech') where name = 'C_web' $q$), 'ERR:42501');
select tests.check('Web lead cannot link their client to another division',
  tests.try('web_lead', $q$ insert into client_divisions (client_id, division_id) select c.id, d.id from clients c, divisions d where c.name = 'C_web' and d.key = 'tech' $q$), 'ERR:42501');
select tests.check('Web lead cannot soft-delete a client',
  tests.try('web_lead', $q$ update clients set deleted_at = now(), deletion_reason = 'no' where name = 'C_web' $q$), 'ERR:42501');
select tests.check('Web lead cannot add a contact to Tech''s client',
  tests.try('web_lead', $q$ insert into client_contacts (client_id, full_name) values ((select id from tests.ids where key = 'client:C_tech'), 'Spy') $q$), 'ERR:42501');
select tests.check('Web lead can add a contact to Web''s client',
  tests.try('web_lead', $q$ insert into client_contacts (client_id, full_name) select id, 'Pat' from clients where name = 'C_web' $q$), 'ok');

select tests.check('Web lead can create a Web project for a Web client',
  tests.try('web_lead', $q$ insert into projects (client_id, lead_division_id, name) select c.id, d.id, 'P_new' from clients c, divisions d where c.name = 'C_web' and d.key = 'web' $q$), 'ok');
select tests.check('Web lead cannot create a project for a client they cannot see',
  tests.try('web_lead', $q$ insert into projects (client_id, lead_division_id, name) values ((select id from tests.ids where key = 'client:C_tech'), (select id from tests.ids where key = 'div:web'), 'P_bad') $q$), 'ERR:42501');
select tests.check('Web lead cannot create a project led by another division',
  tests.try('web_lead', $q$ insert into projects (client_id, lead_division_id, name) select c.id, d.id, 'P_bad2' from clients c, divisions d where c.name = 'C_web' and d.key = 'tech' $q$), 'ERR:42501');
select tests.check('Web staff cannot create projects',
  tests.try('web_staff', $q$ insert into projects (client_id, lead_division_id, name) select c.id, d.id, 'P_bad3' from clients c, divisions d where c.name = 'C_web' and d.key = 'web' $q$), 'ERR:42501');
select tests.check('Lead division is added to the project automatically',
  (select count(*)::text from project_divisions pd join projects p on p.id = pd.project_id where p.name = 'P_new'), '1');
select tests.check('Web lead can edit a Web project',
  pg_temp.affected('web_lead', $q$ update projects set description = 'x' where name = 'P_web' $q$), '1');
select tests.check('Web lead cannot edit a Tech project',
  pg_temp.affected('web_lead', $q$ update projects set description = 'x' where name = 'P_tech' $q$), '0');
select tests.check('Web staff cannot edit projects',
  pg_temp.affected('web_staff', $q$ update projects set description = 'x' where name = 'P_web' $q$), '0');
select tests.check('Web lead cannot move a project to another client',
  tests.try('web_lead', $q$ update projects set client_id = (select id from clients where name = 'C_tech') where name = 'P_web' $q$), 'ERR:42501');
select tests.check('Web staff can create tasks in their division''s project',
  tests.try('web_staff', $q$ insert into tasks (project_id, title) select id, 'T2' from projects where name = 'P_web' $q$), 'ok');
select tests.check('Web staff cannot create tasks in another division''s project',
  tests.try('web_staff', $q$ insert into tasks (project_id, title) values ((select id from tests.ids where key = 'project:P_tech'), 'T3') $q$), 'ERR:42501');
select tests.check('Web staff can update tasks in their project',
  pg_temp.affected('web_staff', $q$ update tasks set status = 'done' where title = 'T_web' $q$), '1');
select tests.check('Completing a task stamps completed_at',
  (select (completed_at is not null)::text from tasks where title = 'T_web'), 'true');
select tests.check('Web staff cannot update another division''s tasks',
  pg_temp.affected('web_staff', $q$ update tasks set status = 'done' where title = 'T_tech' $q$), '0');
select tests.check('Web lead can archive a Web project',
  tests.try('web_lead', $q$ update projects set status = 'archived' where name = 'P_new' $q$), 'ok');
select tests.check('Web lead cannot soft-delete a project',
  tests.try('web_lead', $q$ update projects set deleted_at = now(), deletion_reason = 'x' where name = 'P_new' $q$), 'ERR:42501');

-- Cross-division collaboration is deliberate and needs management ---------------
select tests.check('Web lead cannot pull another division into a project',
  tests.try('web_lead', $q$ insert into project_divisions (project_id, division_id) select p.id, d.id from projects p, divisions d where p.name = 'P_web' and d.key = 'tech' $q$), 'ERR:42501');
select tests.check('Tech staff cannot yet see the Web project', pg_temp.n('tech_staff', 'projects', $q$ name = 'P_web' $q$), '0');
select tests.check('Admin (org-wide projects.update) can add a participating division',
  tests.try('admin', $q$ insert into project_divisions (project_id, division_id) select p.id, d.id from projects p, divisions d where p.name = 'P_web' and d.key = 'tech' $q$), 'ok');
select tests.check('Tech staff now sees the shared project', pg_temp.n('tech_staff', 'projects', $q$ name = 'P_web' $q$), '1');
select tests.check('...and its client via the new division relationship', pg_temp.n('tech_staff', 'clients', $q$ name = 'C_web' $q$), '1');
select tests.check('...but still not the project''s finances', pg_temp.n('tech_staff', 'project_financials'), '0');
select tests.check('Personal assignment grants visibility (client)',
  tests.try('ceo', $q$ insert into client_staff (client_id, staff_id) select c.id, s.id from clients c, staff s where c.name = 'C_web' and s.email = 'web_staff@ada.test' $q$), 'ok');

-- Restricted classification ---------------------------------------------------
update clients set classification = 'restricted' where name = 'C_web';
select tests.check('Restricted client hidden from unassigned division staff', pg_temp.n('web_lead', 'clients', $q$ name = 'C_web' $q$), '0');
select tests.check('Restricted client visible to assigned staff', pg_temp.n('web_staff', 'clients', $q$ name = 'C_web' $q$), '1');
select tests.check('Restricted client visible with records.view_restricted', pg_temp.n('admin', 'clients', $q$ name = 'C_web' $q$), '1');

-- INSERT ... RETURNING (what supabase-js .insert().select() does) must work under RLS.
select tests.check('Division lead can insert a client and read it back in one statement',
  tests.scalar('web_lead', $q$ with i as (insert into clients (name, owner_division_id) select 'Returned', id from divisions where key = 'web' returning id, ada_id)
                             select (ada_id ~ '^ADA-CLI-')::text from i $q$), 'true');
select tests.check('Division lead can insert a project and read it back in one statement',
  tests.scalar('web_lead', $q$ with i as (insert into projects (client_id, lead_division_id, name)
                                           select c.id, c.owner_division_id, 'Returned P' from clients c where c.name = 'Returned' returning ada_id)
                             select (ada_id ~ '^ADA-PRJ-')::text from i $q$), 'true');

-- Direct API surface ------------------------------------------------------------
select tests.check('Anonymous users cannot read clients',       tests.scalar_anon('select count(*)::text from clients'), 'ERR:42501');
select tests.check('Anonymous users cannot read staff',         tests.scalar_anon('select count(*)::text from staff'), 'ERR:42501');
select tests.check('Anonymous users cannot read divisions',     tests.scalar_anon('select count(*)::text from divisions'), 'ERR:42501');
select tests.check('Anonymous users cannot call my_access',     tests.scalar_anon('select my_access()::text'), 'ERR:42501');
select tests.check('Anonymous users cannot call has_permission', tests.scalar_anon($q$ select has_permission('clients.view')::text $q$), 'ERR:42501');
select tests.check('Signed-in users cannot call bootstrap_first_admin',
  tests.try('ceo', $q$ select bootstrap_first_admin(gen_random_uuid(), 'X', 'x@x.x') $q$), 'ERR:42501');
select tests.check('Signed-in users cannot write audit events',
  tests.try('ceo', $q$ select record_audit_event('X', 'clients', null) $q$), 'ERR:42501');
select tests.check('Signed-in users cannot hard-delete core records',
  tests.try('ceo', $q$ delete from projects $q$) || tests.try('ceo', $q$ delete from staff $q$) || tests.try('ceo', $q$ delete from audit_log $q$), 'ERR:42501ERR:42501ERR:42501');
select tests.check('Staff directory only exposes directory columns (no HR data on staff)',
  (select count(*)::text from information_schema.columns where table_name = 'staff' and column_name in ('national_id', 'date_of_birth', 'personal_email')), '0');
select tests.check('my_access reports scoped permissions for a division lead',
  tests.scalar('web_lead', $q$ select (my_access() -> 'permissions' @> '[{"key":"clients.update"}]'::jsonb
                                    and not (my_access() -> 'permissions' @> '[{"key":"finance.view"}]'::jsonb))::text $q$), 'true');
select tests.check('Organization settings are read-only to ordinary staff',
  pg_temp.affected('web_staff', $q$ update divisions set name = 'hacked' $q$), '0');
select tests.check('CEO can manage divisions (add a new division without schema change)',
  tests.try('ceo', $q$ insert into divisions (key, name, kind) values ('research', 'ADA Research', 'service') $q$), 'ok');

select tests.finish();
rollback;
