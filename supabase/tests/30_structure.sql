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
  'client_staff,project_contacts,project_divisions,project_members,role_permissions,staff_roles');
select tests.check('authenticated has no write access to audit_log or service tables',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relname in ('audit_log', 'id_sequences', 'entity_registry', 'entity_types', 'permissions', 'events', 'event_deliveries', 'notifications', 'application_status_history', 'applications', 'approval_requests', 'approval_decisions', 'service_prices', 'enquiries', 'enquiry_candidates', 'matching_reviews', 'client_distinct_pairs')
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
select tests.check('ada_public_api can execute only the reviewed entry points',
  (select string_agg(proname, ',' order by proname) from pg_proc
   where pronamespace = 'public_api'::regnamespace and has_function_privilege('ada_public_api', oid, 'execute')),
  'divisions,document,documents,portfolio,services,statistics,submit_application,submit_enquiry,team,vacancies,vacancy');
select tests.check('ada_public_api cannot execute private helpers in public',
  (select coalesce(string_agg(proname, ','), 'none') from pg_proc
   where pronamespace = 'public'::regnamespace and prorettype <> 'trigger'::regtype
     and proname in ('site_from_key_hash', 'create_application_internal', 'emit_event', 'notify_holders', 'next_ada_id', 'has_permission')
     and has_function_privilege('ada_public_api', oid, 'execute')), 'none');
select tests.check('authenticated can execute only the reviewed functions',
  (select coalesce(string_agg(proname, ',' order by proname), 'none') from pg_proc
   where pronamespace = 'public'::regnamespace and prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', oid, 'execute')
     and proname not in (
       -- authorization helpers (RLS policies call them as the invoker; they only describe the caller's own access)
       'current_staff_id', 'is_active_staff', 'is_untrusted_caller', 'has_permission', 'has_permission_anywhere', 'my_access',
       'can_view_client', 'can_edit_client', 'can_view_client_row', 'can_edit_client_row', 'can_view_person', 'can_edit_person',
       'can_view_project', 'can_edit_project', 'can_view_project_row', 'can_edit_project_row', 'has_project_permission', 'has_project_permission_row',
       'can_view_vacancy_row', 'can_view_application_row', 'application_division', 'can_view_service', 'can_view_service_row', 'service_division',
       'position_open_capacity', 'client_duplicate_message', 'client_name_key', 'price_on',
       -- workflow / command functions (each checks its own permission inside)
       'link_staff_account', 'issue_website_key', 'vacancy_transition', 'staff_record_application', 'application_transition', 'make_offer',
       'accept_application', 'profile_transition', 'terminate_staff', 'client_lookup', 'claim_client_for_division', 'set_client_owner',
       'add_client_contact', 'price_propose', 'price_decide', 'price_withdraw', 'service_transition', 'project_transition', 'project_add_service',
       'project_lead_division', 'portfolio_transition', 'can_view_quote', 'can_view_quote_row', 'quote_create',
       'quote_add_line', 'quote_remove_line', 'quote_transition', 'quote_convert_to_project',
       -- 360 views: SECURITY INVOKER, so they add no access beyond ordinary row-level security
       'client_360', 'project_360', 'staff_360', 'client_create', 'matching_resolve', 'enquiry_record', 'enquiry_resolve_candidate',
       'lead_assign', 'lead_transition', 'lead_set_person', 'lead_qualify', 'quote_create_from_lead', 'classification_visible',
       -- contracts (each checks its own permission inside; visibility helpers read only the row's own columns)
       'can_view_contract', 'can_view_contract_row', 'can_view_contract_version', 'contract_create', 'contract_create_from_quote', 'contract_add_line',
       'contract_remove_line', 'contract_set_terms', 'contract_set_owner', 'contract_link_project', 'contract_transition', 'contract_amend',
       'contract_renew', 'contracts_due_for_renewal', 'contract_terms',
       -- invoices
       'can_view_invoice_row', 'can_view_invoice', 'billable_from_contract', 'billable_from_project', 'billable_manual', 'billable_void', 'invoice_add_lines',
       'invoice_create', 'invoice_remove_line', 'invoice_set_terms', 'invoice_transition', 'invoice_void',
       -- payments
       'can_view_payment_row', 'can_view_payment', 'invoice_balance', 'invoice_paid', 'payment_allocate', 'payment_record', 'payment_unallocate',
       'payment_request_reversal', 'payment_reversal_decide', 'payment_reconcile',
       -- assets, tickets, maintenance (each checks its own permission inside; visibility helpers read only the row's own columns)
       'can_view_asset_row', 'can_view_asset', 'can_edit_asset', 'asset_create', 'asset_update', 'asset_set_parent', 'asset_flag_resolve', 'asset_transition', 'asset_assign',
       'asset_unassign', 'asset_retire', 'asset_dispose', 'asset_add_warranty', 'asset_void_warranty', 'asset_add_document', 'asset_void_document', 'asset_link_finance',
       'asset_360', 'can_view_ticket_row', 'can_view_ticket', 'ticket_create', 'ticket_assign', 'ticket_transition',
       'maintenance_schedule', 'maintenance_start', 'maintenance_complete', 'maintenance_cancel',
       -- institutional skeleton: validation, routing and the caller's own security reporting (all describe only the caller's own access)
       'ada_id_valid', 'entity_visible', 'entity_resolve', 'entity_get', 'entity_view_fn', 'search_route', 'security_note_lookup', 'security_report_denial', 'security_case_update',
       -- academy identity core
       'can_view_student_row', 'can_view_student', 'programme_create', 'cohort_create', 'student_admit', 'student_enrol', 'student_set_status', 'person_relationships', 'asset_register',
       -- tickets module
       'can_work_ticket_row', 'can_work_ticket', 'ticket_comment_add', 'ticket_set_priority', 'ticket_transfer',
       -- documents module
       'document_can_row', 'document_can', 'document_on_hold', 'document_note_denied', 'audit_document_visible', 'document_register', 'document_add_version', 'document_version_transition',
       'document_open', 'document_update', 'document_set_classification', 'document_set_retention', 'document_transfer', 'document_archive', 'document_restore', 'document_link_add',
       'document_link_remove', 'document_share', 'document_unshare', 'document_comment_add', 'document_hold_place', 'document_hold_release', 'document_record_integrity_check',
       'document_relocate_content', 'document_request_disposal', 'document_disposal_decide', 'document_publication_request', 'document_publication_decide', 'document_publish',
       'document_unpublish', 'document_version_as_of', 'documents_of', 'document_family_ids', 'documents_for_entity', 'period_resolve', 'document_360',
       -- organizations (one identity, many roles)
       'can_view_organization_row', 'can_view_organization', 'partner_visible', 'organization_note_denied', 'organization_create', 'organization_update', 'organization_add_role',
       'organization_set_classification', 'organization_merge', 'organization_review_resolve', 'organization_360')), 'none');
-- "Does this information already exist in ADA Core? Then REFERENCE it." Identity/contact columns may live only in
-- these reviewed places; a new module that adds its own name/email/phone column fails here and must reference
-- people / clients / staff instead.
select tests.check('contact and identity columns exist only where reviewed',
  (select string_agg(table_name || '.' || column_name, ', ' order by table_name, column_name) from information_schema.columns
   where table_schema = 'public' and (column_name ~ '(email|phone)' or column_name in ('full_name', 'first_name', 'last_name'))),
  'clients.email, clients.phone, enquiries.submitted_email, enquiries.submitted_phone, invoices.billing_contact_email_snapshot, organization.email, organization.phone, organizations.email, organizations.phone, people.email, people.full_name, people.phone, staff.email, staff.full_name, staff.work_phone, staff_private.emergency_contact_phone, staff_private.personal_email, staff_private.personal_phone, staff_profiles.public_email');
select tests.check('any identity-like column outside the core tables is explicitly documented as a SNAPSHOT of what was submitted',
  (select coalesce(string_agg(c.table_name || '.' || c.column_name, ', ' order by 1), 'none') from information_schema.columns c
   where c.table_schema = 'public' and (c.column_name ~ '(email|phone|name)' and c.column_name ~ '^(submitted|customer|client|contact|staff|person|applicant)_')
     and coalesce(col_description((c.table_schema || '.' || c.table_name)::regclass, c.ordinal_position), '') not like 'SNAPSHOT:%'), 'none');
select tests.check('submitted_* columns are all documented snapshots',
  (select coalesce(string_agg(c.table_name || '.' || c.column_name, ', '), 'none') from information_schema.columns c
   where c.table_schema = 'public' and c.column_name like 'submitted\_%' and c.column_name not in ('submitted_at')
     and coalesce(col_description((c.table_schema || '.' || c.table_name)::regclass, c.ordinal_position), '') not like 'SNAPSHOT:%'), 'none');
select tests.check('every business table that points at a client points at clients(id), never at a copy',
  (select coalesce(string_agg(c.conrelid::regclass::text || '.' || a.attname, ',' order by 1), 'none') from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.contype = 'f' and c.conrelid::regclass::text in ('projects', 'quotes', 'client_contacts', 'client_divisions', 'client_staff')
     and a.attname = 'client_id' and c.confrelid <> 'clients'::regclass), 'none');
select tests.check('every table that is not a link table has an updated_at trigger or is append-only',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'updated_at' and not a.attisdropped)
     and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgfoid = 'set_updated_at'::regproc)), 'none');
select tests.check('every business table is audited',
  (select coalesce(string_agg(c.relname, ','), 'none') from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and c.relname not in ('audit_log', 'id_sequences', 'entity_registry', 'entity_types', 'permissions', 'events', 'event_deliveries', 'notifications', 'application_status_history', 'approval_requests', 'approval_decisions', 'contract_status_history', 'asset_history', 'id_settings', 'id_codebook', 'id_counters', 'entity_location_history', 'security_events', 'security_case_events', 'search_index', 'ticket_events', 'document_events', 'organization_mirror_columns')
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
