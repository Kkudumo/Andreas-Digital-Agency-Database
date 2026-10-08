-- 0020_leads_permissions: permissions for leads, duplicate-match review and approval configuration;
-- reserves the asset ID prefix (ADA-AST). Generated from the matrix CSV diff.

insert into permissions (key, module, action, description, sensitivity) values
  ('leads.view', 'leads', 'view', 'View enquiries and leads of a division', 'confidential'::data_classification),
  ('leads.create', 'leads', 'create', 'Record enquiries received by phone, email or in person', 'internal'::data_classification),
  ('leads.update', 'leads', 'update', 'Triage, assign, qualify and update leads', 'internal'::data_classification),
  ('matching.review', 'matching', 'review', 'Review possible duplicate clients, including restricted ones', 'restricted'::data_classification),
  ('approvals.configure', 'approvals', 'configure', 'Configure approval policies (who approves, thresholds, self-approval)', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'leads.view'),
  ('administration_officer', 'leads.view'),
  ('division_lead', 'leads.view'),
  ('division_staff', 'leads.view'),
  ('ceo', 'leads.create'),
  ('administration_officer', 'leads.create'),
  ('division_lead', 'leads.create'),
  ('ceo', 'leads.update'),
  ('administration_officer', 'leads.update'),
  ('division_lead', 'leads.update'),
  ('division_staff', 'leads.update'),
  ('ceo', 'matching.review'),
  ('administration_officer', 'matching.review'),
  ('ceo', 'approvals.configure')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

insert into entity_types (key, prefix, description) values
  ('enquiry', 'ENQ', 'Inbound enquiry from a website, phone, email or walk-in'),
  ('lead',    'LED', 'Sales lead tracked from enquiry to quote'),
  ('asset',   'AST', 'Physical or technical asset (reserved; module not built yet)');
