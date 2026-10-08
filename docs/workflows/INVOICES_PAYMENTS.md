# Invoices and payments

Finance is not its own mini-database. The chain is **One Client → One Person → One Quote → One Contract → One Project → One Invoice → Many Payments**, linked by ids. Nothing here re-types who the client is.

## Billable items → invoice
`billable_items` are the staging area. They are created from
* an agreed **contract line** (`billable_from_contract`) — at the contracted price; partial quantities carry their share of the line discount, and the last portion takes the remainder so billed discounts always equal the contract's;
* a **project service line**, but only when no signed/active contract covers the project (`billable_from_project`);
* a **manual charge** with a stated reason (`billable_manual`).

Billed quantity is tracked per line (including across contract amendments), so a line can never be billed twice or beyond its quantity. Items are immutable snapshots (open → invoiced / void).

`invoice_create(items…)` produces a draft: client, billing contact (contract's authorised contact, else the client's billing/primary contact), contract/project, division, currency, VAT rate in force, payment terms (from the contract). Line values are **copied** (quantity, price, discount, tax rate): an invoice is never recomputed from today's price.

## Lifecycle (`invoice_transition`)
`draft → pending_approval → approved → issued → partially_paid → paid` (+ `cancelled`).
* Approval uses the shared engine (kind `invoice`; amount = total; discount = total line discounts). Sending back needs a note and is recorded as a rejection; the requester can withdraw.
* **Issue** (`invoices.issue`) sets issue/due dates and takes the legal **snapshot** (`*_snapshot` columns: client name/address/registration, billing contact name/email, ADA's legal name and VAT number). These are the only copies of identity in finance, documented as `SNAPSHOT:` in the schema, taken once and then immutable. Renaming the client later does not alter an issued invoice.
* After draft nothing about the invoice's content can change for any caller. `invoice_void` cancels (reason; `invoices.void` once approved/issued; refused while valid payments are allocated) and releases the billable items; the cancelled invoice and its lines stay on record.
* `partially_paid` / `paid` are never set by hand: they follow the payment allocations.

## Payments
`payments` (ADA-PAY-…) reference the client and the receiving `bank_accounts` row; they are immutable once recorded. A payment may settle several invoices and an invoice may be settled by several payments (`payment_allocations`). The caps — payment credit, invoice balance, same client, same currency, invoice issued and unpaid — are enforced by a **locking trigger**, so concurrent allocations cannot double-spend a payment (a parallel test in `scripts/test-db.sh` races 22 sessions behind a barrier).

**Nothing is stored that can be derived.** `invoice_balance(id)` = invoice total − valid allocated payments; `payment_balances.credit` = amount − approved refunds − active allocations (overpayments are simply unallocated credit). Views `invoice_balances` / `payment_balances` expose them (with an overdue flag) under the caller's own row visibility.

Same bank reference twice on one client is a hard duplicate; across clients `payment_record` refuses a reference already used on that account **among payments the caller can see** — an index would let a restricted client's payment block someone else (and reveal itself), or make un-restricting a client fail.

### Reversal and refund
`payment_request_reversal(payment, 'reversal'|'refund', …)` opens an approval request (kind `payment_reversal` / `refund`; default policy `finance.approve`, **no self-approval**). On approval (`payment_reversal_decide`) a reversal releases every allocation (invoices fall back to `issued` / `partially_paid` with the correct outstanding balance) and marks the payment `reversed`; a refund consumes unallocated credit. History is kept (released allocations, decided requests). `payment_reconcile` records the bank-statement reference and who reconciled.

## Financial approvals
One engine, no finance-specific permission system. `approval_gate(kind, table, id, division, amount, requested_by, fallback_permission, approve, note, discount)`:
1. policy for (`kind`, division, amount) → required permission, quorum, self-approval flag;
2. if a discount is present, the policy for kind `discount` (by discount amount) is also resolved: the decider must hold **both** permissions, the quorum is the larger, self-approval needs both to allow it;
3. self-approval only where the policy allows, and (default) only while the requester is the sole qualified approver — recorded on the request and decision.

Example configuration (all through `approval_policies`, `approvals.configure`): invoices from N$50,000 → `finance.approve`, 2 approvers; Tech invoices from N$10,000 → `finance.approve`; discounts from N$400 → `discounts.approve`; refunds → `finance.approve`, no self-approval. Defaults reproduce today's one-manager reality and tighten automatically when a second qualified approver exists.

## Client lifecycle effects
Restricting a client hides its contracts, billable items, invoices, payments and approval history from everyone without access; un-restricting restores them. Soft-deleting a client hides them from anyone without `records.view_deleted`; a client with open commercial records (live contracts, unpaid invoices, unallocated credit) cannot be deleted.

## Not built
Credit notes, expenses, recurring invoicing, PDF/e-mail delivery (documents/communications modules), multi-currency conversion, tax reporting, bank-feed import.
