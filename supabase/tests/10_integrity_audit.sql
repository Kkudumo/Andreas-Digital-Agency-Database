-- IDs, registry, audit trail, soft delete, referential integrity, admin invariant.
begin;
select tests.setup();

-- ADA IDs -------------------------------------------------------------------
select tests.check('staff ADA ID format', (select ada_id ~ '^ADA-STF-\d{4}-\d{4}$' from staff where email = 'ceo@ada.test')::text, 'true');
select tests.check('client ADA ID format', (select ada_id ~ '^ADA-CLI-\d{4}-\d{4}$' from clients where name = 'C_web')::text, 'true');
select tests.check('ADA IDs are unique and sequential per prefix',
  (select (count(*) = count(distinct ada_id))::text from staff), 'true');
select tests.check('forged ada_id on insert is overridden',
  tests.scalar('admin', $q$ with i as (insert into staff (full_name, email, ada_id) values ('Forge S', 'forge.s@ada.test', 'ADA-STF-1999-0001') returning ada_id)
                       select (ada_id <> 'ADA-STF-1999-0001')::text from i $q$), 'true');
select tests.check('ada_id is immutable for API users',
  tests.try('ceo', $q$ update clients set ada_id = 'ADA-CLI-2000-0001' where name = 'C_web' $q$), 'ERR:42501');
select tests.check('every identified record is in the entity registry',
  (select (count(*) = 0)::text from clients c where not exists (select 1 from entity_registry r where r.ada_id = c.ada_id)), 'true');
select tests.check('API users can never write the registry or its service tables', tests.try('ceo', $q$ insert into entity_registry (institutional_id) values ('AAAAAAAAA') $q$) || tests.try('ceo', 'update entity_registry set status = ''x''') || tests.try('ceo', 'select * from id_counters') || tests.try('ceo', 'select * from id_settings') || tests.try('ceo', 'select * from id_codebook'), 'ERR:42501ERR:42501ERR:42501ERR:42501ERR:42501');
select tests.check('API users read only the registry rows of entities they may read (their own authorisation, via the authoritative table)', tests.scalar('web_staff', 'select (count(*) > 0)::text from entity_registry') || tests.scalar('web_staff', 'select (count(*) filter (where entity_type = ''client''))::text from entity_registry'), 'true' || (select count(*)::text from clients where name = 'C_web'));
select tests.check('API users cannot read id_sequences',   tests.try('ceo', 'select * from id_sequences'),   'ERR:42501');
select tests.check('API users cannot call next_ada_id',     tests.try('ceo', $q$ select next_ada_id('client') $q$), 'ERR:42501');

-- Audit ---------------------------------------------------------------------
select tests.check('audit.view holder sees the log', (tests.scalar('ceo',   'select (count(*) > 0)::text from audit_log')), 'true');
select tests.check('auditor sees the log',           (tests.scalar('audit', 'select (count(*) > 0)::text from audit_log')), 'true');
select tests.check('web staff see no audit rows',     tests.scalar('web_staff', 'select count(*)::text from audit_log'), '0');
select tests.check('finance sees no audit rows',      tests.scalar('fin', 'select count(*)::text from audit_log'), '0');
select tests.try('ceo', $q$ update clients set notes = 'audited change' where name = 'C_web' $q$);
select tests.check('update is audited with actor, before and after',
  (select (actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test')
           and old_data ->> 'notes' is null and new_data ->> 'notes' = 'audited change'
           and changed_fields = array['notes'])::text
   from audit_log where table_name = 'clients' and action = 'UPDATE' order by id desc limit 1), 'true');
select tests.check('no-op update writes no audit row',
  (with before as (select count(*) c from audit_log),
        _u as (select tests.try('ceo', $q$ update clients set notes = 'audited change' where name = 'C_web' $q$))
   select ((select count(*) from audit_log) = (select c from before))::text), 'true');
select tests.check('sensitive HR columns never appear in audit data',
  (select (count(*) = 0)::text from audit_log
   where table_name = 'staff_private' and (new_data::text like '%123456789%' or new_data::text like '%Someone%')), 'true');
select tests.check('sensitive HR columns are marked redacted',
  (select (new_data ->> 'national_id' = '[redacted]')::text from audit_log where table_name = 'staff_private' limit 1), 'true');
select tests.check('API users cannot insert audit rows',
  tests.try('ceo', $q$ insert into audit_log (action, table_name) values ('FORGED', 'x') $q$), 'ERR:42501');
select tests.check('audit rows cannot be updated, even by the owner',
  (select tests.try_owner($q$ update audit_log set action = 'X' $q$)), 'ERR:42501');
select tests.check('audit rows cannot be deleted, even by the owner',
  (select tests.try_owner($q$ delete from audit_log $q$)), 'ERR:42501');
select tests.check('audit log cannot be truncated, even by the owner',
  (select tests.try_owner($q$ truncate audit_log $q$)), 'ERR:42501');
select tests.check('role assignment changes are audited',
  (select (count(*) > 0)::text from audit_log where table_name = 'staff_roles' and action = 'INSERT'), 'true');

-- Soft delete ---------------------------------------------------------------
select tests.check('hard delete of clients is not available to API users',
  tests.try('ceo', $q$ delete from clients where name = 'C_web' $q$), 'ERR:42501');
select tests.check('soft delete requires a reason',
  tests.try('ceo', $q$ update clients set deleted_at = now() where name = 'C_tech' $q$), 'ERR:23514');
select tests.check('soft delete with reason succeeds',
  tests.try('ceo', $q$ update clients set deleted_at = now(), deletion_reason = 'duplicate' where name = 'C_tech' $q$), 'ok');
select tests.check('soft delete stamps who deleted',
  (select (deleted_by = (select id from staff where email = 'ceo@ada.test'))::text from clients where name = 'C_tech'), 'true');
select tests.check('deleted client is hidden from division staff', tests.scalar('tech_staff', $q$ select count(*)::text from clients where name = 'C_tech' $q$), '0');
select tests.check('deleted client is still visible to records.view_deleted', tests.scalar('ceo', $q$ select count(*)::text from clients where name = 'C_tech' $q$), '1');
select tests.check('deleted client''s projects stay reachable only via project rules (still hidden client row)',
  tests.scalar('tech_staff', $q$ select count(*)::text from clients where name = 'C_tech' $q$), '0');
select tests.check('deletion fields cannot be forged',
  tests.try('web_lead', $q$ update clients set deletion_reason = 'forged' where name = 'C_web' $q$), 'ERR:42501');
select tests.check('non-deleter cannot soft-delete',
  tests.try('web_lead', $q$ update clients set deleted_at = now(), deletion_reason = 'nope' where name = 'C_web' $q$), 'ERR:42501');
select tests.check('deleted records cannot be restored by users who cannot even see them',
  tests.scalar('web_lead', $q$ with u as (update clients set deleted_at = null where name = 'C_tech' returning 1) select count(*)::text from u $q$), '0');
select tests.check('client is still deleted after the attempted restore',
  (select (deleted_at is not null)::text from clients where name = 'C_tech'), 'true');

-- Referential integrity & checks ---------------------------------------------
select tests.check('project cannot reference a missing client',
  tests.try_owner($q$ insert into projects (client_id, lead_division_id, name)
                      values (gen_random_uuid(), (select id from divisions where key = 'web'), 'Orphan') $q$), 'ERR:23503');
select tests.check('staff cannot reference a missing division',
  tests.try_owner($q$ insert into staff (full_name, email, primary_division_id) values ('X', 'x@x.x', gen_random_uuid()) $q$), 'ERR:23503');
select tests.check('task cannot reference a missing project',
  tests.try_owner($q$ insert into tasks (project_id, title) values (gen_random_uuid(), 'Orphan') $q$), 'ERR:23503');
select tests.check('project due date cannot precede start date',
  tests.try_owner($q$ insert into projects (client_id, lead_division_id, name, start_date, due_date)
                      select c.id, c.owner_division_id, 'Bad dates', '2026-06-01', '2026-05-01' from clients c where c.name = 'C_web' $q$), 'ERR:23514');
select tests.check('negative budget rejected',
  tests.try_owner($q$ update project_financials set budget = -1 $q$), 'ERR:23514');
select tests.check('duplicate staff email rejected',
  tests.try_owner($q$ insert into staff (full_name, email) values ('Dup', 'CEO@ada.test') $q$), 'ERR:23505');
select tests.check('only one organization row', tests.try_owner($q$ insert into organization (legal_name) values ('Second') $q$), 'ERR:23505');

-- Administrator invariant ------------------------------------------------------
select tests.check('last active administrator cannot lose their role',
  tests.try_owner($q$ delete from staff_roles where staff_id = (select id from staff where email = 'ceo@ada.test') $q$), 'ERR:23514');
select tests.check('last administrator cannot be suspended',
  tests.try_owner($q$ update staff set account_status = 'suspended' where email = 'ceo@ada.test' $q$), 'ERR:23514');
select tests.check('last administrator cannot be soft-deleted',
  tests.try_owner($q$ update staff set deleted_at = now(), deletion_reason = 'x' where email = 'ceo@ada.test' $q$), 'ERR:23514');
select tests.check('roles.administer cannot be stripped from the last role carrying it',
  tests.try('ceo', $q$ delete from role_permissions where role_id = (select id from roles where key = 'ceo')
                         and permission_id = (select id from permissions where key = 'roles.administer') $q$), 'ERR:23514');
select tests.check('administrators cannot suspend themselves',
  tests.try('ceo', $q$ update staff set account_status = 'suspended' where email = 'ceo@ada.test' $q$), 'ERR:42501');

select tests.finish();
rollback;
