# Expenses

What ADA spends. One record per cost, on the same foundation as everything else: a permanent institutional ID and an `ADA-EXP-YYYY-####` number, references instead of copies, one approval engine, derived totals, nothing deleted. Migration `0047_expenses.sql`; tests `114_expenses.sql`.

## The record
`expenses` holds: division, category, description, date, currency, **net amount, tax and the derived total**, status, and the supplier's own bill number. The supplier, project, division, category and bank account are **references**; the **client is derived from the project**, and the expense inherits the classification of that project and client. An expense needs no project (overheads) and no supplier (petty cash).

## Lifecycle (`expense_transition` and friends — the table cannot be written any other way)
`draft → pending_approval → approved → paid`, plus `rejected` and `cancelled`.

| Step | Command | Who |
|---|---|---|
| record, edit while draft | `expense_create`, `expense_update` | `expenses.create` / `expenses.update` in the division |
| submit, withdraw | `expense_transition(→ pending_approval / draft)` | the requester |
| approve, reject, send back | `expense_transition(→ approved / rejected / draft)` | `expenses.approve`; **a note is required to reject or send back** |
| pay | `expense_pay(account, date, reference)` | `expenses.pay`; the account must be in the expense's currency; not in the future |
| cancel | draft / pending: `expense_transition(→ cancelled)` with a reason; approved and unpaid: `expense_void` | `expenses.void` for the approved one |

* Approval is the shared engine (kind `expense`, amount = total): policy-driven, **no self-approval** unless the policy allows it and the requester is the only qualified approver. The request appears in the one approvals queue and carries the expense's classification.
* After submission the content is locked for every caller; a **paid expense is final**. History is the append-only `expense_events` (and the audit log).
* The same supplier bill (supplier + their bill number) cannot be recorded twice among the expenses you can see; a cancelled or rejected one frees the number.

## Derived, never stored
* `project_costs` — per project and currency: paid, approved-unpaid, awaiting approval, and **cost = approved + paid**. Project 360 shows the expenses and these totals (`expenses`, `costs`).
* `expense_payables` — approved and unpaid, per supplier and currency.
The interim `project_financials.cost_to_date` planning field is left as it was.

## Privacy
A restricted (or confidential) client's project makes its expenses invisible to everyone without access: row counts, search, the derived views and the approvals queue included. Restricting or un-restricting a client re-derives its expenses and their approval history at once. Asking about a hidden expense answers exactly like asking about one that never existed.

## Search, documents, relationships
Search finds expenses by type, ADA number and the supplier's bill number (metadata only: no amounts, no descriptions). `related:<project>` / `related:<client>` include them. Receipts attach through the Documents module (a link by institutional ID); only someone who can see the expense can attach.

## Permissions
`expenses.view`, `.create`, `.update`, `.approve`, `.pay`, `.void` (matrix in `PERMISSION_MATRIX.md`). Management and finance approve and pay; division leads record and submit for their division; the auditor views.

## Not built
Reimbursement runs and bank-feed matching for expense payments, supplier statements, recurring expenses, multi-currency conversion, re-billing an expense to a client (a billable item can still be raised by hand with a stated reason).
