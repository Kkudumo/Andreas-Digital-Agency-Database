-- 0024_quote_lead_integration: the chain enquiry -> lead -> client/contact -> quote -> project, as references.
--  * a quote may originate from a qualified lead and must belong to the SAME client (and uses the same contact);
--  * accepting the quote converts the lead; the lead, enquiries, quote and project stay linked;
--  * client_360 / project_360 show the lead trail.

alter table quotes add column lead_id uuid references leads (id);
create index quotes_lead_idx on quotes (lead_id) where lead_id is not null;
comment on column quotes.lead_id is 'The lead this quote answers (reference, not a copy). Must belong to the same client.';

create or replace function quotes_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    return new;
  end if;
  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.total is distinct from old.total or new.requested_by is distinct from old.requested_by
       or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at or new.sent_at is distinct from old.sent_at
       or new.decided_at is distinct from old.decided_at or new.decision_note is distinct from old.decision_note
       or new.status_reason is distinct from old.status_reason or new.converted_at is distinct from old.converted_at
       or new.client_id is distinct from old.client_id or new.division_id is distinct from old.division_id or new.currency is distinct from old.currency
       or new.lead_id is distinct from old.lead_id then
      raise exception 'quote status, totals, client, division and lead are managed through the quote functions' using errcode = '42501';
    end if;
    if old.status <> 'draft' and (new.title, new.intro, new.terms, new.valid_until, new.contact_id, new.project_id)
       is distinct from (old.title, old.intro, old.terms, old.valid_until, old.contact_id, old.project_id) then
      raise exception 'a quote can only be edited while it is a draft' using errcode = '42501';
    end if;
  end if;
  if new.contact_id is distinct from (case when tg_op = 'UPDATE' then old.contact_id end) and new.contact_id is not null
     and not exists (select 1 from client_contacts cc where cc.id = new.contact_id and cc.client_id = new.client_id and cc.is_active) then
    raise exception 'the contact must be an active contact of the quote''s client' using errcode = '23514';
  end if;
  if new.project_id is not null and not exists (select 1 from projects p where p.id = new.project_id and p.client_id = new.client_id) then
    raise exception 'the project must belong to the quote''s client' using errcode = '23514';
  end if;
  if new.lead_id is not null and not exists (select 1 from leads l where l.id = new.lead_id and l.client_id = new.client_id) then
    raise exception 'the lead must belong to the quote''s client' using errcode = '23514';
  end if;
  return new;
end $$;

-- quote_create gains an optional lead; the old signature is replaced.
drop function quote_create(uuid, uuid, text, uuid, uuid, date, text, text);
create function quote_create(p_client uuid, p_division uuid, p_title text, p_contact uuid default null, p_project uuid default null,
                             p_valid_until date default null, p_intro text default null, p_terms text default null, p_lead uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; c clients%rowtype; l leads%rowtype;
begin
  if not has_permission('quotes.create', p_division) then
    raise exception 'quotes.create is required in that division' using errcode = '42501';
  end if;
  select * into c from clients where id = p_client and deleted_at is null;
  if not found or not can_view_client(p_client) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if c.status = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
  if p_lead is not null then
    select * into l from leads where id = p_lead;
    if not found or not has_permission('leads.view', l.division_id) then raise exception 'lead not found' using errcode = 'P0002'; end if;
    if l.status <> 'qualified' then raise exception 'only a qualified lead can be quoted (currently %)', l.status using errcode = '23514'; end if;
    if l.client_id is distinct from p_client then raise exception 'the lead belongs to a different client' using errcode = '23514'; end if;
  end if;
  insert into quotes (client_id, contact_id, division_id, project_id, lead_id, title, intro, terms, valid_until, assigned_staff_id)
  values (p_client, p_contact, p_division, p_project, p_lead, p_title, p_intro, p_terms, coalesce(p_valid_until, current_date + 30), current_staff_id())
  returning id into v_id;
  return v_id;
end $$;

-- Convenience: quote a qualified lead using the lead's own client, contact and requested service.
create function quote_create_from_lead(p_lead uuid, p_division uuid default null, p_title text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare l leads%rowtype; v_quote uuid;
begin
  select * into l from leads where id = p_lead;
  if not found or not has_permission('leads.view', l.division_id) then raise exception 'lead not found' using errcode = 'P0002'; end if;
  if l.status <> 'qualified' or l.client_id is null then raise exception 'qualify the lead first' using errcode = '23514'; end if;
  v_quote := quote_create(l.client_id, coalesce(p_division, l.division_id), coalesce(nullif(btrim(p_title), ''), l.title), l.contact_id, null, null, null, null, p_lead);
  if l.requested_service_id is not null and (price_on(l.requested_service_id)).id is not null then
    perform quote_add_line(v_quote, l.requested_service_id);
  end if;
  return v_quote;
end $$;

create or replace function quote_transition(p_id uuid, p_to quote_status, p_note text default null) returns quote_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  q quotes%rowtype;
  v_edit boolean;
  v_appr boolean;
  v_lines integer;
  v_gate text;
begin
  select * into q from quotes where id = p_id for update;
  if not found or not can_view_quote(p_id) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  v_edit := has_permission('quotes.update', q.division_id);
  v_appr := has_permission('quotes.approve');

  case
    when q.status = 'draft' and p_to = 'pending_approval' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      select count(*) into v_lines from quote_lines where quote_id = p_id;
      if v_lines = 0 then raise exception 'add at least one line before submitting' using errcode = '23514'; end if;
      if q.valid_until < current_date then raise exception 'the validity date is in the past' using errcode = '23514'; end if;
      if (select status from clients where id = q.client_id) = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
      update quotes set status = p_to, requested_by = current_staff_id(), status_reason = null where id = p_id;
      perform notify_holders('quotes.approve', null, 'approval.required', 'Quote awaiting approval: ' || q.title, null, 'quotes', q.id, q.ada_id);
    when q.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_appr) then raise exception 'not permitted' using errcode = '42501'; end if;
      update quotes set status = p_to, status_reason = p_note where id = p_id;
    when q.status = 'pending_approval' and p_to = 'approved' then
      v_gate := approval_gate('quote', 'quotes', q.id, q.division_id, q.total, q.requested_by, 'quotes.approve', true, p_note);
      if v_gate = 'pending' then return 'pending_approval'; end if;       -- more approvers needed
      update quotes set status = p_to, approved_by = current_staff_id(), approved_at = now(), status_reason = null where id = p_id;
    when q.status = 'approved' and p_to = 'sent' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if q.valid_until < current_date then raise exception 'the quote has expired' using errcode = '23514'; end if;
      update quotes set status = p_to, sent_at = now() where id = p_id;
    when q.status = 'sent' and p_to = 'accepted' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if q.valid_until < current_date then raise exception 'the quote expired on %', q.valid_until using errcode = '23514'; end if;
      update quotes set status = p_to, decided_at = now(), decision_note = p_note where id = p_id;
      perform emit_event('quote.accepted', 'quotes', q.id, q.ada_id, jsonb_build_object('status', 'accepted'));
      if q.lead_id is not null then                                    -- the lead has done its job
        update leads set status = 'converted', converted_at = now() where id = q.lead_id and status <> 'converted';
        perform emit_event('lead.converted', 'leads', q.lead_id, (select ada_id from leads where id = q.lead_id), jsonb_build_object('status', 'converted'));
      end if;
      perform notify_holders('projects.create', q.division_id, 'quote.accepted', 'Quote accepted: ' || q.title, 'Convert it into a project.', 'quotes', q.id, q.ada_id);
    when q.status = 'sent' and p_to = 'rejected' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'record why the client declined' using errcode = '23514'; end if;
      update quotes set status = p_to, decided_at = now(), decision_note = p_note where id = p_id;
    when q.status in ('draft', 'pending_approval', 'approved', 'sent') and p_to = 'cancelled' then
      if not (v_edit or v_appr) then raise exception 'not permitted' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
      update quotes set status = p_to, status_reason = p_note where id = p_id;
    else
      raise exception 'invalid quote transition % -> %', q.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;

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
    'pending', jsonb_build_array('invoices', 'payments', 'contracts', 'tickets', 'assets', 'documents', 'domains', 'communications'));
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
    'pending', jsonb_build_array('contracts', 'invoices', 'payments', 'expenses', 'assets', 'tickets', 'documents', 'domains', 'websites', 'deliverables'));
end $$;

revoke execute on function quote_create(uuid, uuid, text, uuid, uuid, date, text, text, uuid), quote_create_from_lead(uuid, uuid, text) from public, anon;
grant execute on function quote_create(uuid, uuid, text, uuid, uuid, date, text, text, uuid), quote_create_from_lead(uuid, uuid, text) to authenticated;
