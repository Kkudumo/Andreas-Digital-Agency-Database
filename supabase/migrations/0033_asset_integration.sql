-- 0033_asset_integration: maintenance, the client-delete guard, assets/tickets in the 360 views, asset_360.

-- ---------------------------------------------------------------------------
-- Maintenance history (needs tickets, so it lives here)
-- ---------------------------------------------------------------------------
create type maintenance_kind as enum ('preventive', 'repair', 'inspection', 'upgrade', 'calibration');
create type maintenance_status as enum ('scheduled', 'in_progress', 'completed', 'cancelled');

create table asset_maintenance (
  id               uuid primary key default gen_random_uuid(),
  asset_id         uuid not null references assets (id) on delete restrict,
  kind             maintenance_kind not null,
  status           maintenance_status not null default 'scheduled',
  description      text not null check (btrim(description) <> ''),
  scheduled_for    date,
  started_at       timestamptz,
  completed_at     timestamptz,
  performed_by     uuid references staff (id),
  vendor_id        uuid references suppliers (id),
  ticket_id        uuid references tickets (id),
  outcome          text,
  cancel_reason    text,
  created_by       uuid references staff (id),
  created_at       timestamptz not null default now(),
  check (status <> 'completed' or (completed_at is not null and coalesce(btrim(outcome), '') <> ''))
);
create unique index asset_maintenance_one_in_progress on asset_maintenance (asset_id) where status = 'in_progress';
create index asset_maintenance_asset_idx on asset_maintenance (asset_id, created_at);
create index asset_maintenance_ticket_idx on asset_maintenance (ticket_id) where ticket_id is not null;
comment on table asset_maintenance is 'Purpose: maintenance history of an asset. Rows move forward (scheduled -> in_progress -> completed/cancelled) and are never deleted. The cost of the work is NOT stored here: it belongs to the expense / supplier invoice. [class: internal]';
create function asset_maintenance_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'maintenance history cannot be deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then new.created_by := current_staff_id(); return new; end if;
  if (new.asset_id, new.kind, new.description, new.created_by) is distinct from (old.asset_id, old.kind, old.description, old.created_by) then
    raise exception 'maintenance records cannot be rewritten' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not ((old.status = 'scheduled' and new.status in ('in_progress', 'cancelled')) or (old.status = 'in_progress' and new.status in ('completed', 'cancelled'))) then
    raise exception 'invalid maintenance status change % -> %', old.status, new.status using errcode = '23514';
  end if;
  if old.status in ('completed', 'cancelled') then raise exception 'a % maintenance record is final', old.status using errcode = '42501'; end if;
  return new;
end $$;
create trigger asset_maintenance_guard_trg before insert or update or delete on asset_maintenance for each row execute function asset_maintenance_guard();

create function maintenance_schedule(p_asset uuid, p_kind maintenance_kind, p_description text, p_scheduled_for date default null, p_ticket uuid default null, p_vendor uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype; t tickets%rowtype; v_id uuid;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.maintain', a.division_id) then raise exception 'assets.maintain is required' using errcode = '42501'; end if;
  if a.status in ('proposed', 'retired', 'disposed', 'cancelled') then raise exception 'an asset that is % cannot be maintained', a.status using errcode = '23514'; end if;
  if p_ticket is not null then
    select * into t from tickets where id = p_ticket;
    if not found or not can_view_ticket(p_ticket) then raise exception 'ticket not found' using errcode = 'P0002'; end if;
    if t.asset_id is distinct from a.id then raise exception 'the ticket is about a different asset' using errcode = '23514'; end if;
  end if;
  if p_vendor is not null and not exists (select 1 from suppliers where id = p_vendor) then raise exception 'supplier not found' using errcode = 'P0002'; end if;
  insert into asset_maintenance (asset_id, kind, description, scheduled_for, ticket_id, vendor_id) values (a.id, p_kind, p_description, p_scheduled_for, p_ticket, p_vendor) returning id into v_id;
  perform asset_log(a.id, 'maintenance', p_kind::text, null, 'scheduled', p_description);
  return v_id;
end $$;

create function maintenance_start(p_maintenance uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m asset_maintenance%rowtype; a assets%rowtype;
begin
  select * into m from asset_maintenance where id = p_maintenance;
  if not found or not can_view_asset(m.asset_id) then raise exception 'maintenance record not found' using errcode = 'P0002'; end if;
  a := asset_load(m.asset_id);
  if not has_permission('assets.maintain', a.division_id) then raise exception 'assets.maintain is required' using errcode = '42501'; end if;
  if m.status <> 'scheduled' then raise exception 'this maintenance is already %', m.status using errcode = '23514'; end if;
  if a.status not in ('in_stock', 'assigned', 'returned') then raise exception 'an asset that is % cannot go into maintenance', a.status using errcode = '23514'; end if;
  update asset_maintenance set status = 'in_progress', started_at = now(), performed_by = current_staff_id() where id = m.id;
  update assets set status = 'in_maintenance' where id = a.id;
  perform asset_log(a.id, 'status', 'status', a.status::text, 'in_maintenance', m.description);
end $$;

create function maintenance_complete(p_maintenance uuid, p_outcome text, p_condition asset_condition default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m asset_maintenance%rowtype; a assets%rowtype; v_to asset_status;
begin
  select * into m from asset_maintenance where id = p_maintenance;
  if not found or not can_view_asset(m.asset_id) then raise exception 'maintenance record not found' using errcode = 'P0002'; end if;
  a := asset_load(m.asset_id);
  if not has_permission('assets.maintain', a.division_id) then raise exception 'assets.maintain is required' using errcode = '42501'; end if;
  if m.status <> 'in_progress' then raise exception 'only maintenance in progress can be completed (currently %)', m.status using errcode = '23514'; end if;
  if coalesce(btrim(p_outcome), '') = '' then raise exception 'record the outcome' using errcode = '23514'; end if;
  v_to := case when exists (select 1 from asset_assignments where asset_id = a.id and ended_at is null) then 'assigned' else 'in_stock' end;
  update asset_maintenance set status = 'completed', completed_at = now(), outcome = p_outcome where id = m.id;
  update assets set status = v_to where id = a.id;
  perform asset_log(a.id, 'status', 'status', 'in_maintenance', v_to::text, p_outcome);
  if p_condition is not null and p_condition is distinct from a.condition then
    update assets set condition = p_condition where id = a.id;
    perform asset_log(a.id, 'field', 'condition', a.condition::text, p_condition::text, 'after maintenance');
  end if;
end $$;

create function maintenance_cancel(p_maintenance uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m asset_maintenance%rowtype; a assets%rowtype; v_to asset_status;
begin
  select * into m from asset_maintenance where id = p_maintenance;
  if not found or not can_view_asset(m.asset_id) then raise exception 'maintenance record not found' using errcode = 'P0002'; end if;
  a := asset_load(m.asset_id);
  if not has_permission('assets.maintain', a.division_id) then raise exception 'assets.maintain is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if m.status not in ('scheduled', 'in_progress') then raise exception 'this maintenance is already %', m.status using errcode = '23514'; end if;
  update asset_maintenance set status = 'cancelled', cancel_reason = p_reason where id = m.id;
  if m.status = 'in_progress' then
    v_to := case when exists (select 1 from asset_assignments where asset_id = a.id and ended_at is null) then 'assigned' else 'in_stock' end;
    update assets set status = v_to where id = a.id;
    perform asset_log(a.id, 'status', 'status', 'in_maintenance', v_to::text, p_reason);
  end if;
end $$;

-- Retiring (defined here because it needs the maintenance table): cancels scheduled maintenance, refuses while work is in progress
create function asset_retire(p_asset uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a assets%rowtype;
begin
  a := asset_load(p_asset);
  if not has_permission('assets.retire', a.division_id) then raise exception 'assets.retire is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if a.status not in ('in_stock', 'returned', 'in_maintenance') then raise exception 'an asset that is % cannot be retired (return it to stock first)', a.status using errcode = '23514'; end if;
  if exists (select 1 from asset_assignments where asset_id = a.id and ended_at is null) then raise exception 'end the open assignment first' using errcode = '23514'; end if;
  if exists (select 1 from asset_maintenance where asset_id = a.id and status = 'in_progress') then raise exception 'complete or cancel the maintenance in progress first' using errcode = '23514'; end if;
  if exists (select 1 from assets c where c.parent_asset_id = a.id and c.status not in ('retired', 'disposed', 'cancelled')) then
    raise exception 'retire or detach the components of this asset first' using errcode = '23514';
  end if;
  update asset_maintenance set status = 'cancelled', cancel_reason = 'asset retired' where asset_id = a.id and status = 'scheduled';
  update assets set status = 'retired' where id = a.id;
  insert into asset_retirements (asset_id, reason, retired_by) values (a.id, p_reason, current_staff_id());
  perform asset_log(a.id, 'status', 'status', a.status::text, 'retired', p_reason);
  perform emit_event('asset.retired', 'assets', a.id, a.ada_id, '{}');
end $$;

revoke execute on function asset_retire(uuid, text) from public, anon, authenticated;
grant execute on function asset_retire(uuid, text) to authenticated;
alter table asset_maintenance enable row level security;
revoke all on asset_maintenance from anon, authenticated;
grant select on asset_maintenance to authenticated;
create policy asset_maintenance_select on asset_maintenance for select to authenticated using (can_view_asset(asset_id));
revoke execute on function maintenance_schedule(uuid, maintenance_kind, text, date, uuid, uuid), maintenance_start(uuid), maintenance_complete(uuid, text, asset_condition),
  maintenance_cancel(uuid, text) from public, anon, authenticated;
grant execute on function maintenance_schedule(uuid, maintenance_kind, text, date, uuid, uuid), maintenance_start(uuid), maintenance_complete(uuid, text, asset_condition),
  maintenance_cancel(uuid, text) to authenticated;
do $$ begin perform attach_audit('asset_maintenance'); end $$;

-- ---------------------------------------------------------------------------
-- A client with live assets or open tickets cannot be removed
-- ---------------------------------------------------------------------------
create function clients_block_delete_with_assets() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.deleted_at is not null and old.deleted_at is null and (
       exists (select 1 from assets where client_id = new.id and status not in ('retired', 'disposed', 'cancelled'))
    or exists (select 1 from tickets where client_id = new.id and status not in ('closed', 'cancelled'))) then
    raise exception 'the client has live assets or open tickets; retire or close them before removing the client' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger clients_block_delete_with_assets_trg before update of deleted_at on clients for each row execute function clients_block_delete_with_assets();

-- Open assignments whose holder has left (for the asset manager to chase)
create view asset_assignment_exceptions with (security_invoker = true) as
  select g.asset_id, g.id as assignment_id, g.staff_id, g.started_at
  from asset_assignments g join staff s on s.id = g.staff_id
  where g.ended_at is null and (s.account_status <> 'active' or s.deleted_at is not null or s.employment_status in ('terminated', 'suspended'));
comment on view asset_assignment_exceptions is 'Purpose: assets still held by staff who are no longer active. Derived.';
grant select on asset_assignment_exceptions to authenticated;

-- ---------------------------------------------------------------------------
-- 360 views
-- ---------------------------------------------------------------------------
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
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition, 'category', (select name from asset_categories where id = ast.category_id),
                 'project', (select ada_id from projects where id = ast.project_id)) order by ast.created_at) from assets ast where ast.client_id = p_client), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority, 'asset', (select ada_id from assets where id = tk.asset_id)) order by tk.created_at)
               from tickets tk where tk.client_id = p_client), '[]'),
    'pending', jsonb_build_array('documents', 'domains', 'communications'));
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
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition) order by ast.created_at) from assets ast where ast.project_id = p_project), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.project_id = p_project), '[]'),
    'pending', jsonb_build_array('expenses', 'documents', 'domains', 'websites', 'deliverables'));
end $$;


create or replace function staff_360(p_staff uuid) returns jsonb
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
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'condition', ast.condition, 'since', asg.started_at) order by asg.started_at)
               from asset_assignments asg join assets ast on ast.id = asg.asset_id where asg.staff_id = p_staff and asg.ended_at is null), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at)
               from tickets tk where tk.assignee_staff_id = p_staff and tk.status in ('open', 'in_progress', 'waiting')), '[]'),
    'pending', jsonb_build_array('documents', 'performance'));
end $$;


-- The asset 360: one record, every slice (invoker rights - row security decides what each viewer sees)
create function asset_360(p_asset uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare a record;
begin
  select ast.*, cat.name as category_name, d.name as division_name, d.key as division_key, sp.name as supplier_name into a
    from assets ast join asset_categories cat on cat.id = ast.category_id join divisions d on d.id = ast.division_id left join suppliers sp on sp.id = ast.supplier_id where ast.id = p_asset;
  if not found then return null; end if;
  return jsonb_build_object(
    'overview', jsonb_build_object('id', a.ada_id, 'name', a.name, 'category', a.category_name, 'manufacturer', a.manufacturer, 'model', a.model, 'serial_number', a.serial_number,
                 'asset_tag', a.asset_tag, 'condition', a.condition, 'status', a.status, 'location', a.current_location, 'division', a.division_key, 'classification', a.classification,
                 'supplier', a.supplier_name, 'acquisition', jsonb_build_object('method', a.acquisition_method, 'date', a.acquisition_date, 'cost', a.acquisition_cost, 'currency', a.acquisition_currency)),
    'holder', (select jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'division', dv.key, 'since', g.started_at)
                 from asset_assignments g left join staff s on s.id = g.staff_id join divisions dv on dv.id = g.division_id where g.asset_id = p_asset and g.ended_at is null),
    'assignment_history', coalesce((select jsonb_agg(jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'division', dv.key, 'from', g.started_at, 'to', g.ended_at, 'reason', g.end_reason) order by g.started_at)
                 from asset_assignments g left join staff s on s.id = g.staff_id join divisions dv on dv.id = g.division_id where g.asset_id = p_asset), '[]'),
    'client', (select jsonb_build_object('id', cl.ada_id, 'name', cl.name) from clients cl where cl.id = a.client_id),
    'project', (select jsonb_build_object('id', pr.ada_id, 'name', pr.name) from projects pr where pr.id = a.project_id),
    'parent', (select jsonb_build_object('id', pa.ada_id, 'name', pa.name) from assets pa where pa.id = a.parent_asset_id),
    'components', coalesce((select jsonb_agg(jsonb_build_object('id', ch.ada_id, 'name', ch.name, 'status', ch.status) order by ch.created_at) from assets ch where ch.parent_asset_id = p_asset), '[]'),
    'warranties', coalesce((select jsonb_agg(jsonb_build_object('from', w.starts_on, 'to', w.ends_on, 'provider', (select name from suppliers where id = w.provider_id), 'reference', w.reference, 'voided', w.voided_at is not null) order by w.ends_on) from asset_warranties w where w.asset_id = p_asset), '[]'),
    'maintenance', coalesce((select jsonb_agg(jsonb_build_object('kind', m.kind, 'status', m.status, 'scheduled_for', m.scheduled_for, 'completed_at', m.completed_at, 'description', m.description, 'outcome', m.outcome, 'ticket', (select ada_id from tickets where id = m.ticket_id)) order by m.created_at) from asset_maintenance m where m.asset_id = p_asset), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.asset_id = p_asset), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('kind', dc.kind, 'title', dc.title, 'ref', dc.document_ref) order by dc.added_at) from asset_documents dc where dc.asset_id = p_asset and dc.voided_at is null), '[]'),
    'finance', coalesce((select jsonb_agg(jsonb_build_object('relation', f.relation, 'invoice', (select ada_id from invoices where id = f.invoice_id), 'payment', (select ada_id from payments where id = f.payment_id))) from asset_finance_links f where f.asset_id = p_asset), '[]'),
    'retirement', (select to_jsonb(r) - 'asset_id' from asset_retirements r where r.asset_id = p_asset),
    'possible_duplicates', coalesce((select jsonb_agg(jsonb_build_object('reason', fl.reason, 'status', fl.status, 'other', (select ada_id from assets where id = case when fl.asset_id = p_asset then fl.other_asset_id else fl.asset_id end)))
                 from asset_duplicate_flags fl where p_asset in (fl.asset_id, fl.other_asset_id)), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', h.created_at, 'kind', h.kind, 'field', h.field, 'from', h.from_value, 'to', h.to_value, 'note', h.note) order by h.id desc)
                 from (select * from asset_history where asset_id = p_asset order by id desc limit 50) h), '[]'));
end $$;
revoke execute on function asset_360(uuid) from public, anon;
grant execute on function asset_360(uuid) to authenticated;
