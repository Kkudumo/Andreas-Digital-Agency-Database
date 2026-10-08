-- 0019_views_360: the organizational graph, read as one picture per entity.
-- These functions are SECURITY INVOKER on purpose: every section is an ordinary query against the same tables,
-- so row-level security decides what each viewer sees. There is no second copy of the access rules to drift:
-- a section a viewer may not read simply comes back empty. Sections for modules not built yet are listed in
-- "pending" so the shape of the 360 view is stable as the graph grows.

create function client_360(p_client uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  c record;
begin
  select cl.*, d.name as owner_division_name into c
    from clients cl left join divisions d on d.id = cl.owner_division_id where cl.id = p_client;
  if not found then return null; end if;                         -- RLS: also null when the caller may not see it

  return jsonb_build_object(
    'overview', jsonb_build_object(
      'id', c.ada_id, 'name', c.name, 'legal_name', c.legal_name, 'trading_name', c.trading_name, 'type', c.client_type, 'status', c.status,
      'industry', c.industry, 'registration_number', c.registration_number, 'email', c.email, 'phone', c.phone, 'website', c.website,
      'address', c.address, 'city', c.city, 'country', c.country, 'billing_address', c.billing_address, 'social_links', c.social_links,
      'classification', c.classification, 'created_at', c.created_at,
      'owner', (select jsonb_build_object('id', s.ada_id, 'name', s.full_name) from client_staff cs join staff s on s.id = cs.staff_id
                 where cs.client_id = p_client and cs.assignment_role = 'owner')),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('contact', cc.ada_id, 'person', pe.ada_id, 'name', pe.full_name, 'email', pe.email,
                 'phone', pe.phone, 'role', cc.role_title, 'primary', cc.is_primary, 'billing', cc.is_billing, 'active', cc.is_active) order by cc.is_primary desc, pe.full_name)
               from client_contacts cc join people pe on pe.id = cc.person_id where cc.client_id = p_client), '[]'),
    'relationship', jsonb_build_object(
      'divisions', coalesce((select jsonb_agg(jsonb_build_object('code', d.key, 'name', d.name, 'status', cd.relationship_status, 'since', cd.since) order by d.sort_order)
                  from client_divisions cd join divisions d on d.id = cd.division_id where cd.client_id = p_client), '[]'),
      'services_purchased', coalesce((select jsonb_agg(x order by x ->> 'service') from (
                  select jsonb_build_object('service', s.name, 'service_id', s.ada_id, 'division', dv.key, 'quantity', sum(ps.quantity), 'spent', sum(ps.line_total), 'currency', ps.currency) x
                  from project_services ps join projects p on p.id = ps.project_id join services s on s.id = ps.service_id join divisions dv on dv.id = s.division_id
                  where p.client_id = p_client and p.status <> 'cancelled' group by s.id, s.name, s.ada_id, dv.key, ps.currency) q), '[]')),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.ada_id, 'name', p.name, 'status', p.status, 'priority', p.priority, 'division', d.key,
                 'start_date', p.start_date, 'due_date', p.due_date, 'completed_at', p.completed_at) order by p.created_at)
               from projects p join divisions d on d.id = p.lead_division_id where p.client_id = p_client and p.deleted_at is null), '[]'),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total, 'currency', q.currency,
                 'valid_until', q.valid_until, 'project', (select ada_id from projects where id = q.project_id)) order by q.created_at)
               from quotes q where q.client_id = p_client), '[]'),
    'quote_summary', (select jsonb_build_object('pending', count(*) filter (where status in ('draft', 'pending_approval', 'approved', 'sent')),
                 'accepted', count(*) filter (where status = 'accepted'), 'rejected', count(*) filter (where status = 'rejected'),
                 'accepted_value', coalesce(sum(total) filter (where status = 'accepted'), 0)) from quotes where client_id = p_client),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'record', a.record_ada_id, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'clients' and record_id = p_client)
                        or (table_name = 'client_contacts' and (new_data ->> 'client_id')::uuid = p_client)
                        or (table_name = 'client_divisions' and (new_data ->> 'client_id')::uuid = p_client)
                     order by id desc limit 25) a), '[]'),
    'pending', jsonb_build_array('invoices', 'payments', 'contracts', 'tickets', 'assets', 'documents', 'domains', 'communications'));
end $$;

create function project_360(p_project uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare p record;
begin
  select pr.*, cl.name as client_name, cl.ada_id as client_ada_id, d.name as division_name, d.key as division_key into p
    from projects pr join clients cl on cl.id = pr.client_id join divisions d on d.id = pr.lead_division_id where pr.id = p_project;
  if not found then return null; end if;
  return jsonb_build_object(
    'overview', jsonb_build_object('id', p.ada_id, 'name', p.name, 'description', p.description, 'status', p.status, 'priority', p.priority,
                 'type', p.project_type, 'start_date', p.start_date, 'due_date', p.due_date, 'completed_at', p.completed_at, 'division', p.division_key),
    'client', jsonb_build_object('id', p.client_ada_id, 'name', p.client_name),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('contact', cc.ada_id, 'name', pe.full_name, 'email', pe.email, 'role', pc.role))
               from project_contacts pc join client_contacts cc on cc.id = pc.contact_id join people pe on pe.id = cc.person_id where pc.project_id = p_project), '[]'),
    'divisions', coalesce((select jsonb_agg(d.key order by d.sort_order) from project_divisions pd join divisions d on d.id = pd.division_id where pd.project_id = p_project), '[]'),
    'services', coalesce((select jsonb_agg(jsonb_build_object('service', s.name, 'service_id', s.ada_id, 'quantity', ps.quantity, 'unit_price', ps.unit_price,
                 'discount', ps.discount_amount, 'total', ps.line_total, 'currency', ps.currency, 'catalogue_price_used', ps.price_id is not null,
                 'override_reason', ps.price_override_reason, 'quote', (select q.ada_id from quote_lines l join quotes q on q.id = l.quote_id where l.id = ps.quote_line_id)) order by s.name)
               from project_services ps join services s on s.id = ps.service_id where ps.project_id = p_project), '[]'),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total)) from quotes q where q.project_id = p_project), '[]'),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'role', pm.member_role)) from project_members pm join staff s on s.id = pm.staff_id where pm.project_id = p_project), '[]'),
    'milestones', coalesce((select jsonb_agg(jsonb_build_object('title', m.title, 'due_date', m.due_date, 'status', m.status) order by m.sort_order, m.due_date) from milestones m where m.project_id = p_project), '[]'),
    'tasks', jsonb_build_object(
      'open', (select count(*) from tasks where project_id = p_project and status in ('todo', 'in_progress', 'blocked')),
      'done', (select count(*) from tasks where project_id = p_project and status = 'done'),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', t.ada_id, 'title', t.title, 'status', t.status, 'due_date', t.due_date, 'assignee', (select full_name from staff where id = t.assignee_id)) order by t.created_at)
                 from tasks t where t.project_id = p_project), '[]')),
    'budget', (select to_jsonb(f) - 'project_id' from project_financials f where f.project_id = p_project),     -- empty unless finance.view
    'portfolio', (select jsonb_build_object('id', e.ada_id, 'status', e.status, 'consent', e.client_consent) from portfolio_entries e where e.project_id = p_project),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'projects' and record_id = p_project) order by id desc limit 25) a), '[]'),
    'pending', jsonb_build_array('contracts', 'invoices', 'payments', 'expenses', 'assets', 'tickets', 'documents', 'domains', 'websites', 'deliverables'));
end $$;

create function staff_360(p_staff uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare s record;
begin
  select st.*, pos.title as position_title, d.name as division_name into s
    from staff st left join positions pos on pos.id = st.position_id left join divisions d on d.id = st.primary_division_id where st.id = p_staff;
  if not found then return null; end if;
  return jsonb_build_object(
    'profile', jsonb_build_object('id', s.ada_id, 'name', s.full_name, 'email', s.email, 'work_phone', s.work_phone, 'position', s.position_title,
                 'division', s.division_name, 'employment_status', s.employment_status, 'account_status', s.account_status, 'start_date', s.start_date, 'end_date', s.end_date),
    'assignments', coalesce((select jsonb_agg(jsonb_build_object('position', pos.title, 'division', d.name, 'from', a.started_on, 'to', a.ended_on, 'reason', a.reason) order by a.started_on desc)
               from staff_assignments a left join positions pos on pos.id = a.position_id left join divisions d on d.id = a.division_id where a.staff_id = p_staff), '[]'),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('role', r.name, 'scope', coalesce(d.name, 'organization-wide')))
               from staff_roles sr join roles r on r.id = sr.role_id left join divisions d on d.id = sr.division_id where sr.staff_id = p_staff), '[]'),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.ada_id, 'name', p.name, 'status', p.status, 'role', pm.member_role))
               from project_members pm join projects p on p.id = pm.project_id where pm.staff_id = p_staff), '[]'),
    'clients_owned', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'name', c.name, 'role', cs.assignment_role))
               from client_staff cs join clients c on c.id = cs.client_id where cs.staff_id = p_staff), '[]'),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.ada_id, 'title', t.title, 'status', t.status, 'due_date', t.due_date) order by t.due_date nulls last)
               from tasks t where t.assignee_id = p_staff and t.status in ('todo', 'in_progress', 'blocked')), '[]'),
    'onboarding', coalesce((select jsonb_agg(jsonb_build_object('kind', o.kind, 'title', o.title, 'status', o.status, 'due_date', o.due_date) order by o.created_at)
               from onboarding_tasks o where o.staff_id = p_staff), '[]'),
    'public_profile', (select jsonb_build_object('id', sp.ada_id, 'status', sp.status) from staff_profiles sp where sp.staff_id = p_staff),
    'hr', (select jsonb_build_object('emergency_contact', sp.emergency_contact_name) from staff_private sp where sp.staff_id = p_staff),   -- only with hr.view or self
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where table_name = 'staff' and record_id = p_staff order by id desc limit 25) a), '[]'),
    'pending', jsonb_build_array('tickets', 'assets', 'documents', 'performance'));
end $$;

revoke execute on function client_360(uuid), project_360(uuid), staff_360(uuid) from public, anon;
grant execute on function client_360(uuid), project_360(uuid), staff_360(uuid) to authenticated;
