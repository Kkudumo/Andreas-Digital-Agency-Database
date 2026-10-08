-- Structural guarantees: RLS everywhere, least-privilege grants, hardened functions,
-- and the database matches the reviewed permission matrix CSV.
begin;

select tests.check('every public table has RLS enabled',
  (select coalesce(string_agg(relname, ','), 'none') from pg_class
   where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity), 'none');
select tests.check('anon has no table privileges at all',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
       or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete'))), 'none');
select tests.check('authenticated may DELETE only from link tables',
  (select string_agg(c.relname, ',' order by c.relname) from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'delete')),
  'client_staff,project_divisions,project_members,role_permissions,staff_roles');
select tests.check('authenticated has no write access to audit_log or service tables',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relname in ('audit_log', 'id_sequences', 'entity_registry', 'entity_types', 'permissions', 'events', 'event_deliveries', 'notifications', 'application_status_history', 'applications')
     and (has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update')
       or has_table_privilege('authenticated', c.oid, 'delete'))), 'none');
select tests.check('every SECURITY DEFINER function pins its search_path',
  (select coalesce(string_agg(proname, ','), 'none') from pg_proc
   where pronamespace = 'public'::regnamespace and prosecdef and not coalesce(proconfig::text like '%search_path%', false)), 'none');
select tests.check('anon can execute no callable function in public',
  (select coalesce(string_agg(proname, ','), 'none') from pg_proc
   where pronamespace = 'public'::regnamespace and prorettype <> 'trigger'::regtype and has_function_privilege('anon', oid, 'execute')), 'none');
select tests.check('anon and authenticated cannot use or execute anything in public_api',
  (select coalesce(string_agg(proname, ','), 'none') from pg_proc
   where pronamespace = 'public_api'::regnamespace
     and (has_function_privilege('anon', oid, 'execute') or has_function_privilege('authenticated', oid, 'execute'))), 'none');
select tests.check('ada_public_api has no privileges on any table',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace in ('public'::regnamespace, 'public_api'::regnamespace) and c.relkind in ('r', 'v', 'm')
     and (has_table_privilege('ada_public_api', c.oid, 'select') or has_table_privilege('ada_public_api', c.oid, 'insert')
       or has_table_privilege('ada_public_api', c.oid, 'update') or has_table_privilege('ada_public_api', c.oid, 'delete'))), 'none');
select tests.check('ada_public_api can execute only the six entry points',
  (select string_agg(proname, ',' order by proname) from pg_proc
   where pronamespace = 'public_api'::regnamespace and has_function_privilege('ada_public_api', oid, 'execute')),
  'divisions,statistics,submit_application,team,vacancies,vacancy');
select tests.check('ada_public_api cannot execute private helpers in public',
  (select coalesce(string_agg(proname, ','), 'none') from pg_proc
   where pronamespace = 'public'::regnamespace and prorettype <> 'trigger'::regtype
     and proname in ('site_from_key_hash', 'create_application_internal', 'emit_event', 'notify_holders', 'next_ada_id', 'has_permission')
     and has_function_privilege('ada_public_api', oid, 'execute')), 'none');
select tests.check('every table that is not a link table has an updated_at trigger or is append-only',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'updated_at' and not a.attisdropped)
     and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgfoid = 'set_updated_at'::regproc)), 'none');
select tests.check('every business table is audited',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and c.relname not in ('audit_log', 'id_sequences', 'entity_registry', 'entity_types', 'permissions', 'events', 'event_deliveries', 'notifications', 'application_status_history')
     and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'zz_audit')), 'none');

-- Permission matrix: CSV (reviewed design document) must equal the database.
create temp table m (permission text, sensitivity text, description text, ceo text, administration_officer text,
                     finance_officer text, division_lead text, division_staff text, auditor text, recruiter text);
\copy m from 'supabase/seed_data/permission_matrix.csv' csv header
create temp table expected as
  select r.role_key, m.permission
  from m, lateral (values ('ceo', m.ceo), ('administration_officer', m.administration_officer), ('finance_officer', m.finance_officer),
                          ('division_lead', m.division_lead), ('division_staff', m.division_staff), ('auditor', m.auditor), ('recruiter', m.recruiter)) r(role_key, mark)
  where r.mark = 'x';
create temp table actual as
  select r.key role_key, p.key permission from role_permissions rp join roles r on r.id = rp.role_id join permissions p on p.id = rp.permission_id
  where r.is_system;
select tests.check('matrix CSV == database (missing from DB)',
  (select coalesce(string_agg(role_key || ':' || permission, ','), 'none') from (select * from expected except select * from actual) x), 'none');
select tests.check('matrix CSV == database (extra in DB)',
  (select coalesce(string_agg(role_key || ':' || permission, ','), 'none') from (select * from actual except select * from expected) x), 'none');
select tests.check('permission catalogue == CSV rows',
  (select (count(*) filter (where p.id is null) + count(*) filter (where m.permission is null))::text
   from m full join permissions p on p.key = m.permission), '0');
select tests.check('CEO holds every permission',
  (select count(*)::text from permissions p where not exists (
     select 1 from role_permissions rp join roles r on r.id = rp.role_id where r.key = 'ceo' and rp.permission_id = p.id)), '0');
select tests.check('finance is not granted to division roles',
  (select count(*)::text from actual where role_key in ('division_lead', 'division_staff') and permission like 'finance.%'), '0');
select tests.check('HR is not granted to finance or division roles',
  (select count(*)::text from actual where role_key in ('finance_officer', 'division_lead', 'division_staff') and permission like 'hr.%'), '0');

select tests.check('ADA is seeded with the nine divisions',
  (select string_agg(key, ',' order by sort_order) from divisions),
  'management,administration,finance,web,tech,marketing,academy,software,consulting');
select tests.check('exactly the six service divisions are public',
  (select string_agg(key, ',' order by sort_order) from divisions where public_state = 'published'), 'web,tech,marketing,academy,software,consulting');
select tests.check('recruiter has no finance, HR, roles or audit access',
  (select count(*)::text from actual where role_key = 'recruiter' and (permission ~ '^(finance|hr|roles|audit|staff)\.')), '0');
select tests.check('divisions have ADA IDs', (select count(*)::text from divisions where ada_id ~ '^ADA-DIV-\d{4}-\d{4}$'), '9');

select tests.finish();
rollback;
