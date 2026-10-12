-- 0050_reports: read-only reports over the authoritative modules.
--  * Every report is a SECURITY INVOKER function: it runs with the CALLER's row-level security, so a report can only ever add up what the caller can already
--    read. A restricted client's invoices, a division's expenses or an unreadable project simply are not in the numbers (the same as for the dashboard).
--  * Nothing is stored. Balances come from the same derived functions the invoice screens use (invoice_balance already nets payments AND credit notes).
--  * Amounts are never mixed across currencies: every row carries its currency.
--  * Money amounts: "invoiced" is what issued invoices say (issued, partially_paid, paid; cancelled ones are not revenue); "credited" is issued credit notes;
--    "received" is payments in status received; expenses count when approved or paid (a draft or rejected bill is not a cost).
--  * No permission row is added: seeing a number needs exactly the rights that reading its records needs.

-- 1. Receivables aging ------------------------------------------------------------------------------------------------------------------------------
-- Open balance of every issued / partially paid invoice, bucketed by how far past its due date it is on p_as_of. The balance itself is the current derived balance.
create function report_receivables_aging(p_as_of date default current_date)
returns table (client_id uuid, client_name text, currency char(3), not_due numeric, days_1_30 numeric, days_31_60 numeric, days_61_90 numeric, days_over_90 numeric, total numeric, invoices integer)
language sql stable set search_path = public, pg_temp as $$
  with open as (
    select i.client_id, coalesce(i.client_name_snapshot, '(client)') as client_name, i.currency, invoice_balance(i.id) as bal,
           coalesce(p_as_of - i.due_date, 0) as late
      from invoices i
     where current_staff_id() is not null and i.status in ('issued', 'partially_paid')
  )
  select o.client_id, max(o.client_name), o.currency,
         coalesce(sum(o.bal) filter (where o.late <= 0), 0), coalesce(sum(o.bal) filter (where o.late between 1 and 30), 0),
         coalesce(sum(o.bal) filter (where o.late between 31 and 60), 0), coalesce(sum(o.bal) filter (where o.late between 61 and 90), 0),
         coalesce(sum(o.bal) filter (where o.late > 90), 0), coalesce(sum(o.bal), 0), count(*)::integer
    from open o where o.bal > 0
   group by o.client_id, o.currency
   order by sum(o.bal) desc, 2
$$;

-- 2. Revenue by month -------------------------------------------------------------------------------------------------------------------------------
create function report_revenue(p_from date, p_to date)
returns table (month date, currency char(3), invoiced numeric, credited numeric, net_invoiced numeric, received numeric)
language sql stable set search_path = public, pg_temp as $$
  with inv as (
    select date_trunc('month', i.issue_date)::date as m, i.currency, sum(i.total) as v
      from invoices i where i.status in ('issued', 'partially_paid', 'paid') and i.issue_date between p_from and p_to group by 1, 2
  ), cre as (
    select date_trunc('month', c.issue_date)::date as m, c.currency, sum(c.total) as v
      from credit_notes c where c.status = 'issued' and c.issue_date between p_from and p_to group by 1, 2
  ), rec as (
    select date_trunc('month', p.received_on)::date as m, p.currency, sum(p.amount) as v
      from payments p where p.status = 'received' and p.received_on between p_from and p_to group by 1, 2
  ), keys as (
    select m, currency from inv union select m, currency from cre union select m, currency from rec
  )
  select k.m, k.currency, coalesce(inv.v, 0), coalesce(cre.v, 0), coalesce(inv.v, 0) - coalesce(cre.v, 0), coalesce(rec.v, 0)
    from keys k
    left join inv on inv.m = k.m and inv.currency = k.currency
    left join cre on cre.m = k.m and cre.currency = k.currency
    left join rec on rec.m = k.m and rec.currency = k.currency
   where current_staff_id() is not null
   order by k.m, k.currency
$$;

-- 3. Expenses by month and category ------------------------------------------------------------------------------------------------------------------
create function report_expenses(p_from date, p_to date)
returns table (month date, category text, currency char(3), bills integer, total numeric, paid numeric, unpaid numeric)
language sql stable set search_path = public, pg_temp as $$
  select date_trunc('month', e.expense_date)::date, ec.name, e.currency, count(*)::integer, sum(e.total),
         coalesce(sum(e.total) filter (where e.status = 'paid'), 0), coalesce(sum(e.total) filter (where e.status = 'approved'), 0)
    from expenses e join expense_categories ec on ec.id = e.category_id
   where current_staff_id() is not null and e.status in ('approved', 'paid') and e.expense_date between p_from and p_to
   group by 1, 2, 3
   order by 1, 2, 3
$$;

-- 4. Project profitability -------------------------------------------------------------------------------------------------------------------------
-- Revenue is attributed to a project by invoice line: the invoice's own project, otherwise the project of the line's billable item. Invoices billed through a
-- contract that carries no project of its own are NOT split across projects (they appear under no project, never twice). Revenue is net of tax and of
-- issued credit notes (credited the same way); cost is approved + paid expenses (project_costs).
create function report_project_profitability()
returns table (project_id uuid, project_ada_id text, project_name text, currency char(3), invoiced numeric, credited numeric, cost numeric, margin numeric)
language sql stable set search_path = public, pg_temp as $$
  with inv as (
    select coalesce(i.project_id, b.project_id) as pid, i.currency, sum(il.net_amount) as v
      from invoice_lines il join invoices i on i.id = il.invoice_id join billable_items b on b.id = il.billable_item_id
     where il.active and i.status in ('issued', 'partially_paid', 'paid') and coalesce(i.project_id, b.project_id) is not null
     group by 1, 2
  ), cre as (
    select coalesce(i.project_id, b.project_id) as pid, c.currency, sum(cl.net_amount) as v
      from credit_note_lines cl join credit_notes c on c.id = cl.credit_note_id join invoices i on i.id = c.invoice_id
      left join invoice_lines il on il.id = cl.invoice_line_id left join billable_items b on b.id = il.billable_item_id
     where c.status = 'issued' and coalesce(i.project_id, b.project_id) is not null
     group by 1, 2
  ), cost as (
    select pc.project_id as pid, pc.currency, pc.cost as v from project_costs pc
  ), keys as (
    select pid, currency from inv union select pid, currency from cre union select pid, currency from cost
  )
  select p.id, p.ada_id, p.name, k.currency, coalesce(inv.v, 0), coalesce(cre.v, 0), coalesce(cost.v, 0), coalesce(inv.v, 0) - coalesce(cre.v, 0) - coalesce(cost.v, 0)
    from keys k join projects p on p.id = k.pid
    left join inv on inv.pid = k.pid and inv.currency = k.currency
    left join cre on cre.pid = k.pid and cre.currency = k.currency
    left join cost on cost.pid = k.pid and cost.currency = k.currency
   where current_staff_id() is not null
   order by 8 desc, p.ada_id
$$;

-- 5. Pipeline ---------------------------------------------------------------------------------------------------------------------------------------
-- Leads and quotes CREATED in the period, by division and status. Conversion is for the reader to derive (e.g. accepted / sent); it is not stored.
create function report_pipeline(p_from date, p_to date)
returns table (stage text, status text, division text, currency char(3), n integer, value numeric)
language sql stable set search_path = public, pg_temp as $$
  select 'lead', l.status::text, d.name, l.currency, count(*)::integer, coalesce(sum(l.estimated_value), 0)
    from leads l join divisions d on d.id = l.division_id
   where current_staff_id() is not null and l.created_at::date between p_from and p_to group by 1, 2, 3, 4
  union all
  select 'quote', q.status::text, d.name, q.currency, count(*)::integer, coalesce(sum(q.total), 0)
    from quotes q join divisions d on d.id = q.division_id
   where current_staff_id() is not null and q.created_at::date between p_from and p_to group by 1, 2, 3, 4
  order by 1, 2, 3, 4
$$;

revoke execute on function report_receivables_aging(date), report_revenue(date, date), report_expenses(date, date), report_project_profitability(), report_pipeline(date, date) from public, anon;
grant execute on function report_receivables_aging(date), report_revenue(date, date), report_expenses(date, date), report_project_profitability(), report_pipeline(date, date) to authenticated;
