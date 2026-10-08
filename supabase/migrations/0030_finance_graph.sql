-- 0030_finance_graph: finance joins the central graph, it does not stand beside it.
--  * a client's classification and soft-delete state propagate to its contracts, billable items, invoices, payments
--    and pending approvals (restricting or removing a client hides all of them from people who may not know it exists);
--  * a client with open commercial records cannot be soft-deleted;
--  * converting an accepted quote into a project links the quote's contract(s) to that project;
--  * client_360 / project_360 show contracts, invoices, payments and derived finance totals - authorisation slices of
--    the same records;
--  * project_financials.revenue_to_date is removed: revenue is derived from invoices and payments, never typed in.

-- 1. propagation ---------------------------------------------------------------------------------------------------------------------------
create or replace function clients_propagate_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.classification is distinct from old.classification then
    update projects  set effective_classification = greatest(classification, new.classification) where client_id = new.id;
    update leads     set effective_classification = new.classification where client_id = new.id;
    update enquiries set effective_classification = new.classification where client_id = new.id;
  end if;
  if new.classification is distinct from old.classification or (new.deleted_at is not null) is distinct from (old.deleted_at is not null) then
    update contracts       set effective_classification = new.classification, client_deleted = new.deleted_at is not null where client_id = new.id;
    update billable_items  set effective_classification = new.classification, client_deleted = new.deleted_at is not null where client_id = new.id;
    update invoices        set effective_classification = new.classification, client_deleted = new.deleted_at is not null where client_id = new.id;
    update payments        set effective_classification = new.classification, client_deleted = new.deleted_at is not null where client_id = new.id;
    update approval_requests set classification = greatest(new.classification, 'internal'::data_classification)
     where status = 'pending' and (
           (entity_table = 'contract_versions' and entity_id in (select v.id from contract_versions v join contracts c on c.id = v.contract_id where c.client_id = new.id))
        or (entity_table = 'invoices' and entity_id in (select id from invoices where client_id = new.id))
        or (entity_table = 'payment_reversals' and entity_id in (select r.id from payment_reversals r join payments p on p.id = r.payment_id where p.client_id = new.id))
        or (entity_table = 'quotes' and entity_id in (select id from quotes where client_id = new.id)));
  end if;
  return null;
end $$;
drop trigger clients_propagate_classification_trg on clients;
create trigger clients_propagate_classification_trg after update of classification, deleted_at on clients
  for each row execute function clients_propagate_classification();

-- 2. a client with open commercial records cannot be deleted ------------------------------------------------------------------------------------
create function clients_block_delete_with_finance() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.deleted_at is not null and old.deleted_at is null and (
       exists (select 1 from contracts where client_id = new.id and status in ('draft', 'internal_review', 'approved', 'sent', 'signed', 'active'))
    or exists (select 1 from invoices where client_id = new.id and status not in ('cancelled', 'paid'))
    or exists (select 1 from payment_balances where client_id = new.id and status = 'received' and credit > 0)) then
    raise exception 'the client has open commercial records; close them before removing the client' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger clients_block_delete_with_finance_trg before update of deleted_at on clients
  for each row execute function clients_block_delete_with_finance();

-- 3. quote -> project links the quote's contracts -----------------------------------------------------------------------------------------------
create or replace function quote_convert_to_project(p_quote uuid, p_project_name text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  q quotes%rowtype;
  v_project uuid;
begin
  select * into q from quotes where id = p_quote for update;
  if not found or not can_view_quote(p_quote) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  if q.status <> 'accepted' then raise exception 'only an accepted quote can be converted (currently %)', q.status using errcode = '23514'; end if;
  if q.converted_at is not null then return q.project_id; end if;               -- idempotent

  if q.project_id is not null then
    v_project := q.project_id;
    if not has_project_permission('projects.update', v_project) then raise exception 'projects.update is required' using errcode = '42501'; end if;
  else
    if not has_permission('projects.create', q.division_id) then raise exception 'projects.create is required in that division' using errcode = '42501'; end if;
    insert into projects (client_id, lead_division_id, name, description, status)
    values (q.client_id, q.division_id, coalesce(nullif(btrim(p_project_name), ''), q.title), q.intro, 'approved')
    returning id into v_project;
  end if;

  insert into project_services (project_id, service_id, quote_line_id, price_id, description, quantity, unit_price, discount_amount, currency, price_override_reason, created_by)
  select v_project, l.service_id, l.id, l.price_id, l.description, l.quantity, l.unit_price, l.discount_amount, q.currency, l.price_override_reason, current_staff_id()
  from quote_lines l where l.quote_id = p_quote and l.service_id is not null;
  if q.contact_id is not null then
    insert into project_contacts (project_id, contact_id, role) values (v_project, q.contact_id, 'quote contact') on conflict do nothing;
  end if;
  if q.assigned_staff_id is not null then
    insert into project_members (project_id, staff_id, member_role) values (v_project, q.assigned_staff_id, 'account manager') on conflict do nothing;
  end if;
  update quotes set project_id = v_project, converted_at = now() where id = p_quote;
  insert into contract_projects (contract_id, project_id, linked_by)
  select c.id, v_project, current_staff_id() from contracts c where c.quote_id = p_quote and c.status not in ('rejected', 'cancelled') on conflict do nothing;
  return v_project;
end $$;


-- 4. 360 views -----------------------------------------------------------------------------------------------------------------------------------
create or replace function client_360(p_client uuid) returns jsonb
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
    'leads', coalesce((select jsonb_agg(jsonb_build_object('id', l.ada_id, 'title', l.title, 'status', l.status, 'division', d.key,
                 'service', (select name from services where id = l.requested_service_id), 'enquiries', (select count(*) from enquiries e where e.lead_id = l.id),
                 'created_at', l.created_at) order by l.created_at)
               from leads l join divisions d on d.id = l.division_id where l.client_id = p_client), '[]'),
    'quote_summary', (select jsonb_build_object('pending', count(*) filter (where status in ('draft', 'pending_approval', 'approved', 'sent')),
                 'accepted', count(*) filter (where status = 'accepted'), 'rejected', count(*) filter (where status = 'rejected'),
                 'accepted_value', coalesce(sum(total) filter (where status = 'accepted'), 0)) from quotes where client_id = p_client),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'record', a.record_ada_id, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'clients' and record_id = p_client)
                        or (table_name = 'client_contacts' and (new_data ->> 'client_id')::uuid = p_client)
                        or (table_name = 'client_divisions' and (new_data ->> 'client_id')::uuid = p_client)
                     order by id desc limit 25) a), '[]'),
    -- finance: authorisation slices of the SAME records (empty unless the viewer holds contracts.view / invoices.view / payments.view)
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', ct.ada_id, 'title', ct.title, 'status', ct.status, 'version', ct.current_version_no, 'currency', ct.currency,
                 'total', ctt.total, 'start_date', ctt.start_date, 'end_date', ctt.end_date, 'auto_renew', ctt.auto_renew, 'quote', (select ada_id from quotes where id = ct.quote_id)) order by ct.created_at)
               from contracts ct left join lateral contract_terms(ct.id) ctt on true where ct.client_id = p_client), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.ada_id, 'status', i.status, 'currency', i.currency, 'total', i.total, 'issue_date', i.issue_date,
                 'due_date', i.due_date, 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id), 'contract', (select ada_id from contracts where id = i.contract_id)) order by i.created_at)
               from invoices i where i.client_id = p_client), '[]'),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', py.ada_id, 'status', py.status, 'currency', py.currency, 'amount', py.amount, 'received_on', py.received_on,
                 'method', py.method, 'reconciliation', py.reconciliation, 'credit', b.credit) order by py.received_on, py.created_at)
               from payments py join payment_balances b on b.payment_id = py.id where py.client_id = p_client), '[]'),
    'finance_summary', (select jsonb_build_object(
                 'invoiced', coalesce(sum(i.total) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'paid', coalesce(sum(invoice_paid(i.id)) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'outstanding', coalesce(sum(invoice_balance(i.id)) filter (where i.status in ('issued', 'partially_paid')), 0),
                 'overdue', coalesce(sum(invoice_balance(i.id)) filter (where i.status in ('issued', 'partially_paid') and i.due_date < current_date), 0),
                 'unallocated_credit', (select coalesce(sum(credit), 0) from payment_balances where client_id = p_client and status = 'received'))
               from invoices i where i.client_id = p_client),
    'pending', jsonb_build_array('tickets', 'assets', 'documents', 'domains', 'communications'));
end $$;

create or replace function project_360(p_project uuid) returns jsonb
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
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total, 'lead', (select ada_id from leads where id = q.lead_id))) from quotes q where q.project_id = p_project), '[]'),
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
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'title', c.title, 'status', c.status, 'total', t.total, 'currency', c.currency) order by c.created_at)
               from contract_projects cp join contracts c on c.id = cp.contract_id left join lateral contract_terms(c.id) t on true where cp.project_id = p_project), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.ada_id, 'status', i.status, 'total', i.total, 'currency', i.currency, 'due_date', i.due_date,
                 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id)) order by i.created_at)
               from invoices i where i.project_id = p_project
                  or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)), '[]'),
    'pending', jsonb_build_array('expenses', 'assets', 'tickets', 'documents', 'domains', 'websites', 'deliverables'));
end $$;


-- 5. revenue is derived, not typed ---------------------------------------------------------------------------------------------------------------
alter table project_financials drop column revenue_to_date;
comment on column project_financials.cost_to_date is 'Interim planning field until expenses exist (then derived). Revenue is NOT stored: it is derived from invoices and payments.';
