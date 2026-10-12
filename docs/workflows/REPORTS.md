# Reports

Migration `0050_reports.sql`, suite `117_reports.sql`.

Five read-only report functions. Each is **`SECURITY INVOKER`**: it runs with the caller's own row-level security, so a report can only add up what the caller can already read. A restricted client's invoices, another division's expenses or an unreadable project are simply not in the figures (never partly counted). No permission row was added: seeing a number needs exactly the rights that reading its records needs. Nothing is stored; every figure is derived from the authoritative modules, and amounts are never mixed across currencies (every row carries its currency).

| Function | Returns | Rules |
|---|---|---|
| `report_receivables_aging(as_of=today)` | per client and currency: not due, 1-30, 31-60, 61-90, over 90 days late, total, number of invoices | Open balance of issued / partially paid invoices, **net of valid payments and applied credit notes** (`invoice_balance`). Buckets use `as_of - due_date`; the balance itself is the current one. |
| `report_revenue(from, to)` | per month and currency: invoiced, credited, net invoiced, received | Invoiced = issued, partially paid and paid invoices by issue date (cancelled are not revenue); credited = issued credit notes; received = payments in status received (visible only to those with the payments permission). |
| `report_expenses(from, to)` | per month, category and currency: bills, total, paid, unpaid | Approved and paid expenses by expense date; drafts, pending and rejected bills are not costs. |
| `report_project_profitability()` | per project and currency: invoiced (net of tax), credited, cost, margin | Revenue is attributed by invoice line: the invoice's own project, otherwise the project of the line's billable item. Invoices billed through a contract that carries no project are not split across projects. Credit notes are attributed the same way; cost = approved + paid expenses (`project_costs`). |
| `report_pipeline(from, to)` | per stage (`lead`/`quote`), status, division, currency: count, value | Leads and quotes **created** in the period. Conversion rates are for the reader to derive. |

CSV export and a reports page are a UI concern (not built); the functions return plain tabular rows so any export is a straight serialisation.
