# Credit notes

Correcting an issued invoice **without rewriting it**. A credit note is issued against one invoice; the invoice stays exactly as issued, and its balance is derived from what was paid and what was credited. Migration `0048_credit_notes.sql`; tests `115_credit_notes.sql` and the `concurrent_credit_notes` race in `scripts/test-db.sh`.

## The record
`credit_notes` (`ADA-CRN-YYYY-####`, permanent institutional ID) references **one invoice**. Client, division and currency are taken from that invoice (never typed again) and so is the classification: a restricted client's credit notes are invisible to everyone without access. Lines (`credit_note_lines`) are snapshots, taken **from an invoice line** (a part or all of its quantity: price, tax rate and a pro-rata share of any discount are copied) or **free-form** with a description. A reason code is required (`billing_error`, `price_adjustment`, `service_not_delivered`, `goodwill`, `duplicate`, `other`; "other" needs a note).

## Caps (checked under the invoice's row lock)
* per invoice line: credited quantity ≤ invoiced quantity;
* per invoice: credit notes that are submitted, approved or issued never add up to more than the invoice total.
A cancelled credit note frees its share. Two credit notes racing for the last of an invoice cannot both succeed (tested in parallel).

## Lifecycle (`credit_note_transition`)
`draft → pending_approval → approved → issued`, or `cancelled` before issue (reason required; approving permission to cancel an approved one).
* Approval is the shared engine (kind `credit_note`, amount = total): **no self-approval** unless the policy allows it and the requester is the only qualified approver; sending back needs a note.
* **Issue** (`credit_notes.issue`) takes the one-time identity snapshot (client name / address / registration, ADA's legal name and VAT number) and then the credit note is a legal record: locked for every caller, never edited, never deleted.
* An invoice with a credit note in progress cannot be cancelled.

## Applying credit
On issue the credit is **applied to its own invoice**, up to what is still owed there. Whatever is left (for example credit on an invoice that was already paid in full) stays as **unapplied customer credit** and can be applied to another open invoice of the same client and currency with `credit_note_allocate`, or released again with `credit_note_unallocate` (reason required): the same mechanics and caps as payments. Applications are never edited or deleted, only released. A client with unapplied credit cannot be removed.

## Balances are derived
`invoice_balance = total − allocated payments − applied credit`. Payments can no longer be allocated beyond what is owed after credit. The invoice's status follows payments **plus** credit, so a fully credited invoice reads `paid` (meaning fully settled). `invoice_balances` and `credit_note_balances` are views; nothing about balances is stored. Client 360 and Project 360 show `credited` per invoice, a `credit_notes` slice, and `credited` in the client's finance summary; the dashboard's outstanding receivables already count credit.

## Privacy
Visibility is `credit_notes.view` in the division plus the classification inherited from the invoice. Asking about a hidden credit note, applying to it, or crediting a hidden invoice answers exactly like an id that never existed. Restricting or un-restricting a client re-derives its credit notes and the history of their approvals at once.

## Search and permissions
Search finds credit notes by type and ADA number (metadata only: no amounts); `related:<client>` includes them. Permissions: `credit_notes.view`, `.create` (draft, edit, submit, cancel), `.approve`, `.issue`, `.apply`. Management and finance hold them; division leads and the auditor view.

## Not built
Refunding unapplied credit as cash (record it as a payment reversal / refund through the payments module), debit notes, credit notes against several invoices at once, PDF / e-mail delivery (Documents / Communications).
