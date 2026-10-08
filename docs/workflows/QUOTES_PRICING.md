# Services, pricing, quotes and projects

## Service catalogue (`service_transition`)
`draft → pending_approval → approved → published → unpublished → archived`. Created by `services.create` in the owning division, approved/published by `services.publish` (management).
A published service with a visible price must have an approved price in force; a service can instead set `show_price = false` ("contact us") or be `quote_based`.
Editing a published service's public wording returns it to draft (re-approval); price changes do **not** touch the service.

## Price versions (`price_propose`, `price_decide`, `price_withdraw`)
```
propose (pricing.propose, effective today or later) ─► pending_approval ─► approved (pricing.approve; not your own unless pricing.approve_own)
                                                         │                        └─ previous version's effective_to := new effective_from − 1
                                                         └─► rejected (note required) / withdrawn
```
- one pending proposal per service; a new version must start after the latest approved one; no back-dating;
- **an approved version is immutable** (the database refuses edits and deletes even by the owner); only `effective_to` is set when the next version takes over;
- `price_on(service, date)` answers "what was the price on that day?" — the basis for quotes today and invoices later;
- approval emits `price.changed` so subscribed websites refresh. No code change, no redeploy.

## Quote (`quote_create`, `quote_add_line`, `quote_transition`, `quote_convert_to_project`)
```
draft ─► pending_approval ─► approved ─► sent ─► accepted ─► (convert) project
   ▲           │                           ├──► rejected (reason)
   └───────────┘ return                    └──► expired (job)           any open state ─► cancelled (reason)
```
- A quote belongs to an **existing, visible client**, a division, optionally a contact and a project of that client.
- Lines: a catalogue service snapshots the price in force (`unit_price`) and records the version (`price_id`); a different price needs a reason; custom lines need a description and price.
- Lines are editable only in draft (also enforced by a database trigger for any write path). The total is maintained from the lines.
- Approval needs `quotes.approve` and someone other than the preparer (unless `quotes.approve_own`). Accepting after `valid_until` is refused; `expire_quotes()` (service role) marks overdue quotes.
- **Conversion** (once, idempotent): creates the project for the same client and division (status `approved`), copies the service lines with their price snapshots and discounts into `project_services`,
  attaches the quote's contact (the shared contact record) and makes the preparer a project member. Later catalogue price changes never alter any of this.

## Project (`project_transition`)
`proposed → approved → active ⇄ on_hold → completed → archived`; `cancelled → archived`. Reasons required for hold/cancel; archiving needs `projects.archive`; completion emits `project.completed`.
A project holds: client, shared contacts, participating divisions, services bought (snapshots), staff, tasks, milestones, and (finance only) planning budget. Quoted/invoiced/received amounts are derived, not stored.

## Portfolio (`portfolio_transition`)
A finished project can have one portfolio entry. It needs the client's consent to appear at all and a second flag to show the client's name; it goes through approval; the public API returns only title, summary,
description, technologies, images, completion date, division and the *names* of published services. Editing it after approval returns it to draft.

## Approvals inbox
Vacancies, profiles, services, price changes, quotes and portfolio entries all appear in `approval_requests` while pending (visible to those holding the approving permission) and keep their decision history.
