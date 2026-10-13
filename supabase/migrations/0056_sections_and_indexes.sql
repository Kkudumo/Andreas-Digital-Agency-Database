-- 0056_sections_and_indexes: arrange the database into sections, and index it for search and lists.
-- NOTHING IS MOVED OR RENAMED. Every table stays where it is; the sections are a CATALOGUE (db_sections / db_section_tables) that the Hub's menu, the data
-- dictionary and the documentation share, and a structure test makes sure every table belongs to exactly one section (a new table without a section fails the suite).
-- Indexes: every foreign-key column that a person or a page looks things up by (127 of them had none), and the sort orders the Hub's lists use.
-- Actor columns (created_by, decided_by, ...) are deliberately not indexed: they are written on every row and almost never searched.
-- (Search itself was already indexed: full-text and trigram indexes on search_index.)

create table db_sections (
  key      text primary key check (key ~ '^[a-z_]+$'),
  position integer not null unique,
  title    text not null,
  summary  text not null
);
create table db_section_tables (
  table_name  text primary key,
  section_key text not null references db_sections (key)
);
create index ix_db_section_tables_section on db_section_tables (section_key);
alter table db_sections enable row level security;
alter table db_section_tables enable row level security;
create policy db_sections_read on db_sections for select to authenticated using (true);
create policy db_section_tables_read on db_section_tables for select to authenticated using (true);
revoke all on db_sections, db_section_tables from public, anon, authenticated;
grant select on db_sections, db_section_tables to authenticated;
comment on table db_sections is 'Purpose: the sections the database is arranged into (people & careers, services & prices, finance ...). A catalogue for navigation and documentation; moves nothing. Changed only by migration. [class: internal]';
comment on table db_section_tables is 'Purpose: which section each table of the public schema belongs to (exactly one). A test fails if a table has no section. Holds table names only, no business data. [class: internal]';

insert into db_sections (key, position, title, summary) values
  ('identity_access', 1, 'Identity, access & audit', 'Who someone is, what they may do, and the record of what they did.'),
  ('organization', 2, 'Organization & divisions', 'The agency, its divisions and positions, and every external organization (client, partner and supplier are roles of one record).'),
  ('people_careers', 3, 'People, careers & hiring', 'One record per human; vacancies, applications and hiring steps; staff public profiles.'),
  ('academy', 4, 'Academy', 'Programmes, intakes and students.'),
  ('clients_leads', 5, 'Clients, leads & matching', 'Clients, their contacts and divisions, enquiries and leads, duplicate review.'),
  ('services_prices', 6, 'Services, prices & catalogue', 'The one service catalogue, immutable price versions and the approval queue behind price changes.'),
  ('projects', 7, 'Projects & delivery', 'Projects, participating divisions, members, tasks, milestones and portfolio entries.'),
  ('sales_contracts', 8, 'Sales & contracts', 'Quotes and contracts with their versions.'),
  ('finance', 9, 'Finance', 'Billable items, invoices, payments, credit notes, expenses, billing schedules and bank accounts.'),
  ('assets_support', 10, 'Assets & support', 'Equipment and the support tickets raised against it.'),
  ('documents_comms', 11, 'Documents & communications', 'Document records, versions, links and holds; recorded communications.'),
  ('domains', 12, 'Domains', 'Domain names under management, their registrations, transfers and relations.'),
  ('search', 13, 'Search', 'The derived search index and its configuration (rebuildable; not a source of truth).');

insert into db_section_tables (table_name, section_key) values
  ('db_sections', 'organization'),
  ('db_section_tables', 'organization'),
  ('application_offers', 'people_careers'),
  ('application_reviews', 'people_careers'),
  ('application_status_history', 'people_careers'),
  ('applications', 'people_careers'),
  ('approval_decisions', 'services_prices'),
  ('approval_policies', 'services_prices'),
  ('approval_requests', 'services_prices'),
  ('asset_assignments', 'assets_support'),
  ('asset_categories', 'assets_support'),
  ('asset_documents', 'assets_support'),
  ('asset_duplicate_flags', 'assets_support'),
  ('asset_finance_links', 'assets_support'),
  ('asset_history', 'assets_support'),
  ('asset_maintenance', 'assets_support'),
  ('asset_retirements', 'assets_support'),
  ('asset_warranties', 'assets_support'),
  ('assets', 'assets_support'),
  ('audit_log', 'identity_access'),
  ('bank_accounts', 'finance'),
  ('billable_items', 'finance'),
  ('billing_schedule_runs', 'finance'),
  ('billing_schedules', 'finance'),
  ('client_contacts', 'clients_leads'),
  ('client_distinct_pairs', 'clients_leads'),
  ('client_divisions', 'clients_leads'),
  ('client_staff', 'clients_leads'),
  ('clients', 'clients_leads'),
  ('cohorts', 'academy'),
  ('communication_access', 'documents_comms'),
  ('communication_attachments', 'documents_comms'),
  ('communication_comments', 'documents_comms'),
  ('communication_disposals', 'documents_comms'),
  ('communication_events', 'documents_comms'),
  ('communication_holds', 'documents_comms'),
  ('communication_links', 'documents_comms'),
  ('communication_messages', 'documents_comms'),
  ('communication_participants', 'documents_comms'),
  ('communication_threads', 'documents_comms'),
  ('communication_types', 'documents_comms'),
  ('contract_lines', 'sales_contracts'),
  ('contract_projects', 'sales_contracts'),
  ('contract_status_history', 'sales_contracts'),
  ('contract_versions', 'sales_contracts'),
  ('contracts', 'sales_contracts'),
  ('credit_note_allocations', 'finance'),
  ('credit_note_lines', 'finance'),
  ('credit_notes', 'finance'),
  ('divisions', 'organization'),
  ('document_access', 'documents_comms'),
  ('document_comments', 'documents_comms'),
  ('document_disposals', 'documents_comms'),
  ('document_events', 'documents_comms'),
  ('document_holds', 'documents_comms'),
  ('document_integrity_checks', 'documents_comms'),
  ('document_links', 'documents_comms'),
  ('document_publications', 'documents_comms'),
  ('document_types', 'documents_comms'),
  ('document_versions', 'documents_comms'),
  ('documents', 'documents_comms'),
  ('domain_events', 'domains'),
  ('domain_registrations', 'domains'),
  ('domain_relations', 'domains'),
  ('domain_reviews', 'domains'),
  ('domain_transfers', 'domains'),
  ('domains', 'domains'),
  ('enquiries', 'clients_leads'),
  ('enquiry_candidates', 'clients_leads'),
  ('entity_location_history', 'organization'),
  ('entity_registry', 'organization'),
  ('entity_types', 'organization'),
  ('event_deliveries', 'identity_access'),
  ('event_subscriptions', 'identity_access'),
  ('events', 'identity_access'),
  ('expense_categories', 'finance'),
  ('expense_events', 'finance'),
  ('expenses', 'finance'),
  ('finance_settings', 'finance'),
  ('id_codebook', 'organization'),
  ('id_codebook_versions', 'organization'),
  ('id_counters', 'organization'),
  ('id_sequences', 'organization'),
  ('id_settings', 'organization'),
  ('invoice_lines', 'finance'),
  ('invoices', 'finance'),
  ('leads', 'clients_leads'),
  ('matching_reviews', 'clients_leads'),
  ('milestones', 'projects'),
  ('notifications', 'identity_access'),
  ('onboarding_tasks', 'people_careers'),
  ('organization', 'organization'),
  ('organization_distinct_pairs', 'organization'),
  ('organization_mirror_columns', 'organization'),
  ('organization_reviews', 'organization'),
  ('organizations', 'organization'),
  ('partners', 'organization'),
  ('payment_allocations', 'finance'),
  ('payment_reversals', 'finance'),
  ('payments', 'finance'),
  ('people', 'people_careers'),
  ('permissions', 'identity_access'),
  ('portfolio_entries', 'projects'),
  ('positions', 'organization'),
  ('programmes', 'academy'),
  ('project_contacts', 'projects'),
  ('project_divisions', 'projects'),
  ('project_financials', 'projects'),
  ('project_members', 'projects'),
  ('project_services', 'projects'),
  ('projects', 'projects'),
  ('quote_lines', 'sales_contracts'),
  ('quotes', 'sales_contracts'),
  ('retention_classes', 'documents_comms'),
  ('role_permissions', 'identity_access'),
  ('roles', 'identity_access'),
  ('search_index', 'search'),
  ('search_refresh_queue', 'search'),
  ('search_sources', 'search'),
  ('security_case_events', 'identity_access'),
  ('security_cases', 'identity_access'),
  ('security_events', 'identity_access'),
  ('security_policies', 'identity_access'),
  ('service_prices', 'services_prices'),
  ('services', 'services_prices'),
  ('staff', 'identity_access'),
  ('staff_assignments', 'identity_access'),
  ('staff_private', 'identity_access'),
  ('staff_profiles', 'people_careers'),
  ('staff_roles', 'identity_access'),
  ('student_enrolments', 'academy'),
  ('students', 'academy'),
  ('suppliers', 'organization'),
  ('tasks', 'projects'),
  ('ticket_categories', 'assets_support'),
  ('ticket_comments', 'assets_support'),
  ('ticket_events', 'assets_support'),
  ('ticket_sla_policies', 'assets_support'),
  ('tickets', 'assets_support'),
  ('vacancies', 'people_careers'),
  ('websites', 'identity_access');

-- The arrangement as one read: sections with their tables and table counts (names only).
create function database_sections() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'position', s.position, 'title', s.title, 'summary', s.summary,
           'tables', (select coalesce(jsonb_agg(t.table_name order by t.table_name), '[]') from db_section_tables t where t.section_key = s.key)) order by s.position), '[]')
    from db_sections s
$$;
revoke execute on function database_sections() from public, anon;
grant execute on function database_sections() to authenticated;
comment on function database_sections() is 'The arrangement of the database into sections, with the tables of each (names only).';

-- ---------------------------------------------------------------------------
-- Indexes on foreign-key columns that were looked up without one
-- ---------------------------------------------------------------------------
create index if not exists ix_applications_source_website_id on applications (source_website_id);
create index if not exists ix_applications_staff_id on applications (staff_id);
create index if not exists ix_approval_policies_division_id on approval_policies (division_id);
create index if not exists ix_approval_requests_division_id on approval_requests (division_id);
create index if not exists ix_asset_assignments_division_id on asset_assignments (division_id);
create index if not exists ix_asset_assignments_project_id on asset_assignments (project_id);
create index if not exists ix_asset_duplicate_flags_other_asset_id on asset_duplicate_flags (other_asset_id);
create index if not exists ix_asset_finance_links_invoice_id on asset_finance_links (invoice_id);
create index if not exists ix_asset_finance_links_payment_id on asset_finance_links (payment_id);
create index if not exists ix_asset_maintenance_vendor_id on asset_maintenance (vendor_id);
create index if not exists ix_asset_warranties_provider_id on asset_warranties (provider_id);
create index if not exists ix_assets_category_id on assets (category_id);
create index if not exists ix_assets_supplier_id on assets (supplier_id);
create index if not exists ix_billable_items_contract_id on billable_items (contract_id);
create index if not exists ix_billable_items_division_id on billable_items (division_id);
create index if not exists ix_billable_items_price_id on billable_items (price_id);
create index if not exists ix_billable_items_project_id on billable_items (project_id);
create index if not exists ix_billable_items_service_id on billable_items (service_id);
create index if not exists ix_billing_schedule_runs_invoice_id on billing_schedule_runs (invoice_id);
create index if not exists ix_billing_schedules_origin_line_id on billing_schedules (origin_line_id);
create index if not exists ix_client_distinct_pairs_client_b on client_distinct_pairs (client_b);
create index if not exists ix_client_divisions_division_id on client_divisions (division_id);
create index if not exists ix_client_staff_staff_id on client_staff (staff_id);
create index if not exists ix_cohorts_division_id on cohorts (division_id);
create index if not exists ix_communication_access_division_id on communication_access (division_id);
create index if not exists ix_communication_access_staff_id on communication_access (staff_id);
create index if not exists ix_communication_attachments_thread_id on communication_attachments (thread_id);
create index if not exists ix_communication_comments_message_id on communication_comments (message_id);
create index if not exists ix_communication_events_message_id on communication_events (message_id);
create index if not exists ix_communication_messages_division_id on communication_messages (division_id);
create index if not exists ix_communication_messages_in_reply_to_message_id on communication_messages (in_reply_to_message_id);
create index if not exists ix_communication_messages_type_key on communication_messages (type_key);
create index if not exists ix_communication_participants_thread_id on communication_participants (thread_id);
create index if not exists ix_communication_threads_owner_staff_id on communication_threads (owner_staff_id);
create index if not exists ix_communication_threads_retention_class_id on communication_threads (retention_class_id);
create index if not exists ix_contract_lines_price_id on contract_lines (price_id);
create index if not exists ix_contract_lines_quote_line_id on contract_lines (quote_line_id);
create index if not exists ix_contract_lines_service_id on contract_lines (service_id);
create index if not exists ix_contract_versions_contact_id on contract_versions (contact_id);
create index if not exists ix_contracts_division_id on contracts (division_id);
create index if not exists ix_contracts_owner_staff_id on contracts (owner_staff_id);
create index if not exists ix_credit_notes_division_id on credit_notes (division_id);
create index if not exists ix_divisions_parent_id on divisions (parent_id);
create index if not exists ix_document_access_division_id on document_access (division_id);
create index if not exists ix_document_access_staff_id on document_access (staff_id);
create index if not exists ix_document_comments_version_id on document_comments (version_id);
create index if not exists ix_document_integrity_checks_document_id on document_integrity_checks (document_id);
create index if not exists ix_document_publications_version_id on document_publications (version_id);
create index if not exists ix_document_types_retention_class_id on document_types (retention_class_id);
create index if not exists ix_document_versions_amends_version_id on document_versions (amends_version_id);
create index if not exists ix_documents_owner_staff_id on documents (owner_staff_id);
create index if not exists ix_documents_retention_class_id on documents (retention_class_id);
create index if not exists ix_domain_registrations_registrar_institutional_id on domain_registrations (registrar_institutional_id);
create index if not exists ix_domain_reviews_left_domain_id on domain_reviews (left_domain_id);
create index if not exists ix_domain_reviews_right_domain_id on domain_reviews (right_domain_id);
create index if not exists ix_domain_transfers_to_client_institutional_id on domain_transfers (to_client_institutional_id);
create index if not exists ix_domain_transfers_to_entity_institutional_id on domain_transfers (to_entity_institutional_id);
create index if not exists ix_enquiries_assigned_staff_id on enquiries (assigned_staff_id);
create index if not exists ix_enquiries_client_id on enquiries (client_id);
create index if not exists ix_enquiries_person_id on enquiries (person_id);
create index if not exists ix_enquiries_requested_service_id on enquiries (requested_service_id);
create index if not exists ix_enquiries_source_division_id on enquiries (source_division_id);
create index if not exists ix_enquiries_source_website_id on enquiries (source_website_id);
create index if not exists ix_enquiry_candidates_client_id on enquiry_candidates (client_id);
create index if not exists ix_entity_location_history_from_division_id on entity_location_history (from_division_id);
create index if not exists ix_entity_location_history_to_division_id on entity_location_history (to_division_id);
create index if not exists ix_entity_registry_current_division_id on entity_registry (current_division_id);
create index if not exists ix_entity_registry_origin_division_id on entity_registry (origin_division_id);
create index if not exists ix_event_deliveries_subscription_id on event_deliveries (subscription_id);
create index if not exists ix_event_subscriptions_website_id on event_subscriptions (website_id);
create index if not exists ix_expense_events_actor_id on expense_events (actor_id);
create index if not exists ix_expenses_category_id on expenses (category_id);
create index if not exists ix_expenses_paid_from_account_id on expenses (paid_from_account_id);
create index if not exists ix_finance_settings_billing_runner_id on finance_settings (billing_runner_id);
create index if not exists ix_invoice_lines_price_id on invoice_lines (price_id);
create index if not exists ix_invoice_lines_service_id on invoice_lines (service_id);
create index if not exists ix_invoices_billing_contact_id on invoices (billing_contact_id);
create index if not exists ix_invoices_division_id on invoices (division_id);
create index if not exists ix_leads_assigned_staff_id on leads (assigned_staff_id);
create index if not exists ix_leads_contact_id on leads (contact_id);
create index if not exists ix_leads_requested_service_id on leads (requested_service_id);
create index if not exists ix_matching_reviews_left_client_id on matching_reviews (left_client_id);
create index if not exists ix_matching_reviews_right_client_id on matching_reviews (right_client_id);
create index if not exists ix_onboarding_tasks_application_id on onboarding_tasks (application_id);
create index if not exists ix_onboarding_tasks_assignee_id on onboarding_tasks (assignee_id);
create index if not exists ix_organization_distinct_pairs_org_b on organization_distinct_pairs (org_b);
create index if not exists ix_organization_reviews_left_org_id on organization_reviews (left_org_id);
create index if not exists ix_organization_reviews_right_org_id on organization_reviews (right_org_id);
create index if not exists ix_organizations_merged_into_id on organizations (merged_into_id);
create index if not exists ix_payments_received_account_id on payments (received_account_id);
create index if not exists ix_positions_division_id on positions (division_id);
create index if not exists ix_programmes_division_id on programmes (division_id);
create index if not exists ix_project_contacts_contact_id on project_contacts (contact_id);
create index if not exists ix_project_divisions_division_id on project_divisions (division_id);
create index if not exists ix_project_members_staff_id on project_members (staff_id);
create index if not exists ix_project_services_price_id on project_services (price_id);
create index if not exists ix_project_services_quote_line_id on project_services (quote_line_id);
create index if not exists ix_quote_lines_price_id on quote_lines (price_id);
create index if not exists ix_quote_lines_service_id on quote_lines (service_id);
create index if not exists ix_quotes_assigned_staff_id on quotes (assigned_staff_id);
create index if not exists ix_quotes_contact_id on quotes (contact_id);
create index if not exists ix_quotes_division_id on quotes (division_id);
create index if not exists ix_quotes_project_id on quotes (project_id);
create index if not exists ix_role_permissions_permission_id on role_permissions (permission_id);
create index if not exists ix_security_case_events_event_id on security_case_events (event_id);
create index if not exists ix_staff_position_id on staff (position_id);
create index if not exists ix_staff_primary_division_id on staff (primary_division_id);
create index if not exists ix_staff_assignments_division_id on staff_assignments (division_id);
create index if not exists ix_staff_assignments_position_id on staff_assignments (position_id);
create index if not exists ix_staff_roles_division_id on staff_roles (division_id);
create index if not exists ix_staff_roles_role_id on staff_roles (role_id);
create index if not exists ix_student_enrolments_cohort_id on student_enrolments (cohort_id);
create index if not exists ix_student_enrolments_division_id on student_enrolments (division_id);
create index if not exists ix_student_enrolments_programme_id on student_enrolments (programme_id);
create index if not exists ix_students_division_id on students (division_id);
create index if not exists ix_tasks_milestone_id on tasks (milestone_id);
create index if not exists ix_ticket_categories_division_id on ticket_categories (division_id);
create index if not exists ix_ticket_events_actor_id on ticket_events (actor_id);
create index if not exists ix_ticket_sla_policies_division_id on ticket_sla_policies (division_id);
create index if not exists ix_tickets_category_id on tickets (category_id);
create index if not exists ix_tickets_contact_id on tickets (contact_id);
create index if not exists ix_tickets_division_id on tickets (division_id);
create index if not exists ix_tickets_reporter_staff_id on tickets (reporter_staff_id);
create index if not exists ix_tickets_sla_policy_id on tickets (sla_policy_id);
create index if not exists ix_vacancies_division_id on vacancies (division_id);
create index if not exists ix_websites_division_id on websites (division_id);

-- ---------------------------------------------------------------------------
-- Sort orders and filters the Hub lists use (newest first; one division and a status)
-- ---------------------------------------------------------------------------
create index if not exists ix_quotes_created on quotes (created_at desc);
create index if not exists ix_contracts_created on contracts (created_at desc);
create index if not exists ix_invoices_created on invoices (created_at desc);
create index if not exists ix_projects_created on projects (created_at desc) where deleted_at is null;
create index if not exists ix_clients_created on clients (created_at desc) where deleted_at is null;
create index if not exists ix_documents_updated on documents (updated_at desc) where status <> 'disposed';
create index if not exists ix_tickets_created on tickets (created_at desc);
create index if not exists ix_quotes_division_status on quotes (division_id, status);
create index if not exists ix_invoices_division_status on invoices (division_id, status);
create index if not exists ix_tickets_division_status on tickets (division_id, status);
create index if not exists ix_documents_division_status on documents (division_id, status);
create index if not exists ix_projects_lead_status on projects (lead_division_id, status) where deleted_at is null;
create index if not exists ix_vacancies_division_status on vacancies (division_id, status);
