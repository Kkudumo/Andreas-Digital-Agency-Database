-- 0042_pilot: Pilot V0.1 - the few CONTROLLED operations that the client-engagement workflow needed and the completed modules did not yet offer.
-- Nothing here is a new source of truth and nothing duplicates an entity: every function is a thin SECURITY INVOKER wrapper that runs under the CALLER's
-- row-level security and the table's own triggers (so authorization, classification, audit and the registry are exactly the existing ones).
--   * Projects had no controlled creation, no controlled way to add participating divisions, staff, shared contacts or tasks (the IRM wrote the tables
--     directly). These are now operations, so no interface needs to write a protected table.
--   * pilot_catalogue(): the reference lists a form needs (divisions, services with the price in force today, bank accounts, staff to assign), read
--     under the caller's rights.
--   * pilot_record(id): the authoritative row (and its lines / allocations / approvals) behind a quote, contract, invoice, payment, ticket or person, read under
--     the caller's rights, so a screen can inspect what it created. Nothing is stored or copied.
-- Everything else in the pilot reuses the existing operations unchanged.

-- A project of an existing, visible client. Idempotent per (client, name): a double submit or a race answers with the existing project.
create function project_create(p_client uuid, p_division uuid, p_name text, p_description text default null, p_type text default null,
                               p_start date default null, p_due date default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare v_name text := btrim(coalesce(p_name, '')); v_id uuid; v_ada text; v_ex record;
begin
  if not can_view_client(p_client) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if not has_permission('projects.create', p_division) then raise exception 'projects.create is required in that division' using errcode = '42501'; end if;
  if length(v_name) not between 2 and 200 then raise exception 'a project needs a name (2-200 characters)' using errcode = '22023'; end if;
  if p_start is not null and p_due is not null and p_due < p_start then raise exception 'the due date cannot precede the start date' using errcode = '23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended('project_create:' || p_client::text || ':' || lower(v_name), 0));
  select id, ada_id into v_ex from projects where client_id = p_client and lower(name) = lower(v_name) and deleted_at is null order by created_at limit 1;
  if found then
    return jsonb_build_object('status', 'exists', 'id', v_ex.id, 'ada_id', v_ex.ada_id,
                              'institutional_id', (select institutional_id from entity_registry where table_name = 'projects' and entity_id = v_ex.id));
  end if;
  insert into projects (client_id, lead_division_id, name, description, project_type, start_date, due_date)
  values (p_client, p_division, v_name, nullif(btrim(coalesce(p_description, '')), ''), nullif(btrim(coalesce(p_type, '')), ''), p_start, p_due)
  returning id, ada_id into v_id, v_ada;
  return jsonb_build_object('status', 'created', 'id', v_id, 'ada_id', v_ada, 'institutional_id', (select institutional_id from entity_registry where table_name = 'projects' and entity_id = v_id));
end $$;

create function project_add_division(p_project uuid, p_division uuid) returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  if not can_view_project(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  insert into project_divisions (project_id, division_id) values (p_project, p_division) on conflict do nothing;
end $$;

create function project_add_member(p_project uuid, p_staff uuid, p_role text default null) returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  if not can_view_project(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then raise exception 'the member must be an active staff member' using errcode = '23514'; end if;
  insert into project_members (project_id, staff_id, member_role) values (p_project, p_staff, nullif(btrim(coalesce(p_role, '')), '')) on conflict do nothing;
end $$;

-- A shared contact of the project's own client (the database refuses a contact of another client)
create function project_add_contact(p_project uuid, p_contact uuid, p_role text default null) returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  if not can_view_project(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  insert into project_contacts (project_id, contact_id, role) values (p_project, p_contact, nullif(btrim(coalesce(p_role, '')), '')) on conflict do nothing;
end $$;

create function task_create(p_project uuid, p_title text, p_description text default null, p_assignee uuid default null, p_due date default null,
                            p_priority priority_level default 'normal') returns uuid
language plpgsql set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not can_view_project(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if length(btrim(coalesce(p_title, ''))) < 2 then raise exception 'a task needs a title' using errcode = '22023'; end if;
  insert into tasks (project_id, title, description, assignee_id, due_date, priority, created_by)
  values (p_project, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''), p_assignee, p_due, p_priority, current_staff_id()) returning id into v_id;
  return v_id;
end $$;

-- Reference lists for forms, read under the caller's own rights (rows the caller cannot see are simply absent)
create function pilot_catalogue() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'divisions', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'key', d.key, 'name', d.name) order by d.name) from divisions d), '[]'),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'ada_id', s.ada_id, 'name', s.name, 'division_id', s.division_id, 'status', s.status, 'billing_unit', s.billing_unit,
                          'price', (select jsonb_build_object('id', p.id, 'amount', p.amount, 'currency', p.currency, 'effective_from', p.effective_from) from price_on(s.id, current_date) p)) order by s.name)
                          from services s where s.deleted_at is null), '[]'),
    'bank_accounts', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'currency', b.currency) order by b.name) from bank_accounts b where b.is_active), '[]'),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'ada_id', t.ada_id, 'name', t.full_name) order by t.full_name) from staff t where t.account_status = 'active' and t.deleted_at is null), '[]'))
$$;

-- Relating a domain to an entity (client, project, registrant ...). The Domains module's own mechanism is an RLS-checked insert into domain_relations; this is
-- the same insert as an operation, so a screen does not write the table. The trigger, the policy and the audit are the existing ones.
create function domain_relation_add(p_domain uuid, p_relation text, p_entity text, p_reason text default null) returns uuid
language plpgsql set search_path = public, pg_temp as $$
declare v_id uuid; v_inst text := entity_get(p_entity) ->> 'institutional_id';
begin
  -- a target the caller cannot see is refused exactly as a refused insert (the policy's own message): hidden and missing look alike
  if v_inst is null then raise exception 'new row violates row-level security policy for table "domain_relations"' using errcode = '42501'; end if;
  insert into domain_relations (domain_id, relation, entity_institutional_id, reason) values (p_domain, p_relation, v_inst, p_reason) returning id into v_id;
  return v_id;
end $$;

-- The record behind an institutional ID for the entity types that have no 360 of their own (quote, contract, invoice, payment, ticket, person), so a screen can
-- inspect what it just created. It reads the authoritative rows under the caller's own rights; nothing is copied or stored. A hidden id answers null, as a missing one.
create function pilot_record(p_id text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare e jsonb := entity_get(p_id); t text; k uuid; r jsonb; v_tab text;
begin
  if e is null then return null; end if;
  t := e ->> 'entity_type'; k := (e ->> 'authoritative_record_key')::uuid; v_tab := e ->> 'authoritative_domain';
  r := case t
    when 'quote' then (select to_jsonb(q) || jsonb_build_object('client_ref', (select ada_id from clients where id = q.client_id), 'project_ref', (select ada_id from projects where id = q.project_id),
         'lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('service', (select name from services where id = l.service_id)) order by l.position) from quote_lines l where l.quote_id = q.id), '[]'))
       from quotes q where q.id = k)
    when 'contract' then (select to_jsonb(c) || jsonb_build_object('client_ref', (select ada_id from clients where id = c.client_id), 'quote_ref', (select ada_id from quotes where id = c.quote_id),
         'projects', coalesce((select jsonb_agg(pr.ada_id) from contract_projects cp join projects pr on pr.id = cp.project_id where cp.contract_id = c.id), '[]'),
         'terms', (select to_jsonb(cv) from contract_versions cv where cv.contract_id = c.id and cv.version_no = c.current_version_no),
         'lines', coalesce((select jsonb_agg(to_jsonb(cl) || jsonb_build_object('service', (select name from services where id = cl.service_id)) order by cl.position)
                              from contract_lines cl join contract_versions cv on cv.id = cl.version_id where cv.contract_id = c.id and cv.version_no = c.current_version_no), '[]'))
       from contracts c where c.id = k)
    when 'invoice' then (select to_jsonb(i) || jsonb_build_object('client_ref', (select ada_id from clients where id = i.client_id), 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id),
         'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.position) from invoice_lines l where l.invoice_id = i.id and l.active), '[]'),
         'allocations', coalesce((select jsonb_agg(jsonb_build_object('payment', pm.ada_id, 'amount', a.amount, 'status', a.status, 'allocated_at', a.allocated_at) order by a.allocated_at)
                                    from payment_allocations a join payments pm on pm.id = a.payment_id where a.invoice_id = i.id), '[]'))
       from invoices i where i.id = k)
    when 'payment' then (select to_jsonb(pm) || jsonb_build_object('client_ref', (select ada_id from clients where id = pm.client_id),
         'allocations', coalesce((select jsonb_agg(jsonb_build_object('invoice', i.ada_id, 'invoice_uuid', i.id, 'amount', a.amount, 'status', a.status) order by a.allocated_at)
                                    from payment_allocations a join invoices i on i.id = a.invoice_id where a.payment_id = pm.id), '[]'))
       from payments pm where pm.id = k)
    when 'ticket' then (select to_jsonb(tk) || jsonb_build_object('client_ref', (select ada_id from clients where id = tk.client_id), 'project_ref', (select ada_id from projects where id = tk.project_id),
         'asset_ref', (select ada_id from assets where id = tk.asset_id)) from tickets tk where tk.id = k)
    when 'person' then (select to_jsonb(pe) from people pe where pe.id = k)
    else null end;
  if r is not null and t in ('quote', 'contract', 'invoice') then
    r := r || jsonb_build_object('approvals', coalesce((select jsonb_agg(jsonb_build_object('kind', ar.kind, 'status', ar.status, 'requested_at', ar.requested_at, 'decided_at', ar.decided_at, 'decision_note', ar.decision_note,
                 'requested_by', (select full_name from staff where id = ar.requested_by), 'decided_by', (select full_name from staff where id = ar.decided_by)) order by ar.requested_at)
                 from approval_requests ar where ar.entity_table = v_tab and ar.entity_id = k), '[]'));
  end if;
  return jsonb_build_object('entity', e, 'record', r);
end $$;

revoke execute on function project_create(uuid, uuid, text, text, text, date, date), project_add_division(uuid, uuid), project_add_member(uuid, uuid, text), project_add_contact(uuid, uuid, text),
  task_create(uuid, text, text, uuid, date, priority_level), pilot_catalogue(), pilot_record(text), domain_relation_add(uuid, text, text, text) from public, anon;
grant execute on function project_create(uuid, uuid, text, text, text, date, date), project_add_division(uuid, uuid), project_add_member(uuid, uuid, text), project_add_contact(uuid, uuid, text),
  task_create(uuid, text, text, uuid, date, priority_level), pilot_catalogue(), pilot_record(text), domain_relation_add(uuid, text, text, text) to authenticated;

-- Search sources for the finance records an engagement produces. Configuration only (Search itself is unchanged): invoices and payments become findable by their
-- number, the purchase-order / payment reference, and (invoices) the client name as issued. Both columns are readable by every viewer of the row.
insert into search_sources (entity_type, label_expr, attribute_exprs, note) values
  ('invoice', 'x.ada_id', array['x.po_reference', 'x.client_name_snapshot'], 'invoice number, PO reference, client name as issued'),
  ('payment', 'x.ada_id', array['x.reference'], 'payment number and the payer''s reference');
do $$ begin
  perform attach_search('public.invoices'::regclass);
  perform attach_search('public.payments'::regclass);
end $$;
select search_rebuild();

-- DEFECT D1 (found by the pilot): Project 360 listed only invoices whose own project_id is set. An invoice billed from a CONTRACT line that is linked to the project
-- (contract_projects) carries the contract, not the project, so a fully paid engagement showed no invoice on its project. Project 360 now lists the invoices of the
-- project OR of a contract linked to it. Nothing is copied or stored; only the read is corrected (the function is otherwise exactly the previous version).
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
               from invoices i where (i.project_id = p_project or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = p_project))
                  or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)), '[]'),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition) order by ast.created_at) from assets ast where ast.project_id = p_project), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.project_id = p_project), '[]'),
    'documents', documents_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'domains', domains_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'communications', communications_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'pending', jsonb_build_array('expenses', 'websites', 'deliverables'));
end $$;
