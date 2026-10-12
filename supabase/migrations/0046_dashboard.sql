-- 0046_dashboard: the operational dashboard's numbers, in one read-only function.
-- Every figure is DERIVED at read time from the authoritative records (quotes, leads, projects, contracts, invoices, payments, tickets, approvals, assets,
-- domains); nothing is stored, cached or denormalised, and no table, column or policy is added. The function is SECURITY INVOKER, so the caller's own
-- row-level security decides which rows are counted: a record the caller may not see contributes nothing to any total, count or list (a person without
-- finance rights simply sees no receivables; restricted clients' quotes, invoices, tickets and assets are not in anyone else's numbers). It never returns
-- a record's identity or content, only counts and sums. A caller who is not active staff gets null.
-- Money is grouped by currency and never added across currencies.
create function dashboard_summary() returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare me uuid := current_staff_id();
begin
  if me is null then return null; end if;
  return jsonb_build_object(
    'as_of', current_date,

    'pipeline', jsonb_build_object(
      'open_quotes', coalesce((select jsonb_agg(jsonb_build_object('status', status, 'currency', currency, 'count', n, 'value', v) order by case status when 'draft' then 1 when 'pending_approval' then 2 when 'approved' then 3 else 4 end, currency)
                                 from (select q.status::text as status, q.currency, count(*) as n, sum(q.total) as v from quotes q where q.status in ('draft', 'pending_approval', 'approved', 'sent') group by 1, 2) x), '[]'),
      'accepted_30d', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'count', n, 'value', v) order by currency)
                                  from (select q.currency, count(*) as n, sum(q.total) as v from quotes q where q.status = 'accepted' and q.decided_at >= now() - interval '30 days' group by 1) x), '[]'),
      'quotes_expiring_14d', (select count(*) from quotes q where q.status = 'sent' and q.valid_until between current_date and current_date + 14),
      'open_leads', coalesce((select jsonb_object_agg(status, n) from (select l.status::text as status, count(*) as n from leads l where l.status in ('new', 'contacted', 'qualified') group by 1) x), '{}')),

    'projects', jsonb_build_object(
      'by_status', coalesce((select jsonb_object_agg(status, n) from (select p.status::text as status, count(*) as n from projects p where p.deleted_at is null and p.status in ('proposed', 'approved', 'active', 'on_hold') group by 1) x), '{}'),
      'overdue', (select count(*) from projects p where p.deleted_at is null and p.status in ('approved', 'active', 'on_hold') and p.due_date < current_date),
      'due_14d', (select count(*) from projects p where p.deleted_at is null and p.status in ('approved', 'active', 'on_hold') and p.due_date between current_date and current_date + 14),
      'active_by_division', coalesce((select jsonb_agg(jsonb_build_object('division', name, 'count', n) order by n desc, name)
                                        from (select d.name, count(*) as n from projects p join divisions d on d.id = p.lead_division_id where p.deleted_at is null and p.status = 'active' group by d.name) x), '[]')),

    'contracts', jsonb_build_object(
      'active', (select count(*) from contracts c where c.status = 'active'),
      'ending_60d', (select count(*) from contracts c where c.status = 'active' and exists (select 1 from contract_terms(c.id) t where t.end_date between current_date and current_date + 60))),

    'receivables', jsonb_build_object(
      'outstanding', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'count', n, 'value', v) order by currency)
                                 from (select i.currency, count(*) as n, sum(invoice_balance(i.id)) as v from invoices i where i.status in ('issued', 'partially_paid') group by 1) x), '[]'),
      'overdue', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'count', n, 'value', v) order by currency)
                             from (select i.currency, count(*) as n, sum(invoice_balance(i.id)) as v from invoices i where i.status in ('issued', 'partially_paid') and i.due_date < current_date group by 1) x), '[]'),
      'invoiced_30d', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'value', v) order by currency)
                                  from (select i.currency, sum(i.total) as v from invoices i where i.status in ('issued', 'partially_paid', 'paid') and i.issue_date >= current_date - 30 group by 1) x), '[]'),
      'received_30d', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'value', v) order by currency)
                                  from (select p.currency, sum(p.amount) as v from payments p where p.status = 'received' and p.received_on >= current_date - 30 group by 1) x), '[]'),
      'unallocated_credit', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'value', v) order by currency)
                                        from (select b.currency, sum(b.credit) as v from payment_balances b where b.status = 'received' and b.credit > 0 group by 1) x), '[]'),
      'invoices_awaiting_approval', (select count(*) from invoices i where i.status = 'pending_approval')),

    'tickets', jsonb_build_object(
      'open_by_priority', coalesce((select jsonb_object_agg(priority, n) from (select t.priority::text as priority, count(*) as n from tickets t where t.status in ('open', 'in_progress', 'waiting') group by 1) x), '{}'),
      'sla_breached', (select count(*) from tickets t join ticket_sla_status s on s.ticket_id = t.id where t.status in ('open', 'in_progress', 'waiting') and (s.first_response_breached or s.resolution_breached)),
      'assigned_to_me', (select count(*) from tickets t where t.status in ('open', 'in_progress', 'waiting') and t.assignee_staff_id = me)),

    'approvals', jsonb_build_object(
      'awaiting_decision', (select count(*) from approval_requests a where a.status = 'pending' and a.requested_by is distinct from me),
      'my_requests_pending', (select count(*) from approval_requests a where a.status = 'pending' and a.requested_by = me)),

    'watch', jsonb_build_object(
      'assets_by_status', coalesce((select jsonb_object_agg(status, n) from (select a.status::text as status, count(*) as n from assets a where a.status in ('acquired', 'in_stock', 'assigned', 'in_maintenance') group by 1) x), '{}'),
      'warranties_ending_30d', (select count(*) from assets a join asset_warranty_status w on w.asset_id = a.id where w.warranty_ends_on between current_date and current_date + 30),
      'domains_due', coalesce((select jsonb_object_agg(state, n) from (select e.expiry_state::text as state, count(*) as n from domains d join domain_expiry_status e on e.domain_id = d.id where e.expiry_state in ('due_soon', 'lapsed') group by 1) x), '{}')));
end $$;
revoke execute on function dashboard_summary() from public, anon;
grant execute on function dashboard_summary() to authenticated;
