-- 0014_permissions_graph: permissions for the service catalogue, pricing, quotes and portfolio.
-- Generated from the matrix CSV diff (scripts/build-rbac-delta.mjs).

insert into permissions (key, module, action, description, sensitivity) values
  ('services.create', 'services', 'create', 'Create services in the catalogue', 'internal'::data_classification),
  ('services.update', 'services', 'update', 'Edit services in the catalogue', 'internal'::data_classification),
  ('services.publish', 'services', 'publish', 'Approve, publish and unpublish services on public websites', 'restricted'::data_classification),
  ('pricing.propose', 'pricing', 'propose', 'Propose a new price version for a service', 'restricted'::data_classification),
  ('pricing.approve', 'pricing', 'approve', 'Approve or reject proposed prices', 'restricted'::data_classification),
  ('pricing.approve_own', 'pricing', 'approve_own', 'Approve a price change you proposed yourself', 'restricted'::data_classification),
  ('quotes.view', 'quotes', 'view', 'View quotes', 'restricted'::data_classification),
  ('quotes.create', 'quotes', 'create', 'Create quotes', 'restricted'::data_classification),
  ('quotes.update', 'quotes', 'update', 'Edit quotes and record the client decision', 'restricted'::data_classification),
  ('quotes.approve', 'quotes', 'approve', 'Approve quotes before they are sent', 'restricted'::data_classification),
  ('quotes.approve_own', 'quotes', 'approve_own', 'Approve a quote you prepared yourself', 'restricted'::data_classification),
  ('portfolio.edit', 'portfolio', 'edit', 'Prepare portfolio entries from completed projects', 'internal'::data_classification),
  ('portfolio.publish', 'portfolio', 'publish', 'Approve, publish and unpublish portfolio entries', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'services.create'),
  ('division_lead', 'services.create'),
  ('ceo', 'services.update'),
  ('division_lead', 'services.update'),
  ('ceo', 'services.publish'),
  ('ceo', 'pricing.propose'),
  ('finance_officer', 'pricing.propose'),
  ('division_lead', 'pricing.propose'),
  ('ceo', 'pricing.approve'),
  ('ceo', 'pricing.approve_own'),
  ('ceo', 'quotes.view'),
  ('administration_officer', 'quotes.view'),
  ('finance_officer', 'quotes.view'),
  ('division_lead', 'quotes.view'),
  ('division_staff', 'quotes.view'),
  ('ceo', 'quotes.create'),
  ('division_lead', 'quotes.create'),
  ('ceo', 'quotes.update'),
  ('division_lead', 'quotes.update'),
  ('ceo', 'quotes.approve'),
  ('ceo', 'quotes.approve_own'),
  ('ceo', 'portfolio.edit'),
  ('administration_officer', 'portfolio.edit'),
  ('division_lead', 'portfolio.edit'),
  ('ceo', 'portfolio.publish')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;
