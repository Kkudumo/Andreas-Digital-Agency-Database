# Assets (and the ticket / maintenance links)

`ADA-AST-YYYY-####` is one record per physical or technical asset. Everything else about it — who holds it, where it has been, what was done to it, which tickets and documents concern it, what it cost — hangs off that record by id.

## What the asset record is (and is not)
`assets` holds identity and state: name, category, manufacturer, model, serial number, asset tag, condition, lifecycle status, acquisition method/date, current location, responsible division, and *references* to supplier, client, project and parent asset.

* **Not on the asset:** who holds it (history in `asset_assignments`), client or supplier names, invoice or payment identity, maintenance, documents, warranty. A structural test fails the build if the asset tables grow holder/name/amount columns.
* **Acquisition cost** is the one financial figure and is a labelled `SNAPSHOT:` (with its currency) until the expenses module links the authoritative record. Sales-side money — a laptop billed to a client — is linked, not copied: `asset_finance_links` holds only `invoice_id` / `payment_id`, and a link is visible only to someone who can also see that invoice/payment. Finance stays the source of truth.
* **Suppliers** are one record each (`ADA-SUP-…`, normalised name), referenced by assets, warranties and maintenance, and later by expenses.

## Lifecycle (controlled for every caller, owner included)
```
proposed → acquired → in_stock ⇄ assigned ⇄ in_maintenance → returned → retired → disposed
   ↘ cancelled (a proposal that never happened)
```
* `asset_assign` / `asset_unassign` (assignment), `maintenance_start` / `maintenance_complete` (maintenance), `asset_retire`, `asset_dispose` are the only doors to those states; `asset_transition` covers the rest.
* **Retired ≠ deleted.** Assets are never deleted. A retired asset's record is frozen (only notes may be added), it keeps its assignments, history and retirement record, and it can only be *disposed* — never silently reactivated. Disposal records the method and date; any sale value belongs on a linked sales invoice, not on the asset.
* Retiring needs a reason, no open assignment, no maintenance in progress and no live components.

## Assignment is history, not a field
`asset_assignments` — one row per period an asset was held by a staff member and/or division. At most one is open (unique index) and periods cannot overlap; ending one sets `ended_at` and a reason once; rows are never edited or deleted. "Assigned to" is derived (`asset_current_assignments`). Moving the laptop from Tech to Web ends the Tech assignment and opens a Web one; responsibility (`assets.division_id`) moves with it and the move is logged. A holder can see the asset they hold even outside their division — but never beyond the classification rules.

## Maintenance, tickets, warranty, documents
* `asset_maintenance`: scheduled → in progress → completed/cancelled, optionally linked to a ticket and a vendor. Starting puts the asset in maintenance; completing returns it to its holder (`assigned`) or to stock and can update its condition. Never deleted.
* `tickets` (**foundation only**: lifecycle, assignment, classification — SLAs, comments, categories and escalation belong to the Tickets module). A ticket raised against an asset takes client, project and division from it; a conflicting client/project is refused.
* `asset_warranties` (append-only, voided with a reason; `asset_warranty_status` is derived) and `asset_documents` (an **interim** document link — a reference plus kind; the Documents module will replace it with real document links). Both are visible exactly as the asset is.

## Duplicates are flagged, never merged
There is deliberately **no unique index** on serial number or tag: a global unique index would reveal hidden assets. Instead `asset_detect_duplicates` raises `asset_duplicate_flags` (`same_serial` — same normalised maker and serial; `same_serial_unknown_maker`; `same_tag`), for people to review (`dismissed` / `confirmed_duplicate`, note required). Same serial from different manufacturers is *not* flagged. A flag is visible only to someone who can see **both** assets, so flagging cannot reveal a hidden one. A tag that collides with an asset the caller can *see* is refused; a collision with a hidden asset behaves like a fresh tag.

## Restricted clients and projects
An asset's `effective_classification` is the strictest of its own, its client's, its project's and its parent's, kept current by triggers when any of them change (fired on any update, because a `BEFORE` trigger sets the column — the lesson from earlier). Tickets inherit from their asset, client and project. Attached records (assignments, history, maintenance, warranties, documents, links, flags) follow the asset. A restricted record is invisible to the holder and to project members too; lookups by id, client, project, serial or tag, helper functions, 360 views, duplicate detection, command errors and notifications are indistinguishable from "does not exist" (`96_asset_restricted.sql`, permanent). A project must be visible *and* its client visible *and* its classification visible before anything can be attached to it. Removing a client hides its retired assets and closed tickets from ordinary users (management keeps them); a client with live assets or open tickets cannot be removed.

## Views
`asset_360(id)` (overview, holder, assignment history, client, project, parent/components, warranties, maintenance, tickets, documents, finance links, retirement, possible duplicates, history) is a security-invoker function — each slice is empty unless the viewer may read it. `client_360`, `project_360` and `staff_360` list assets and tickets. `asset_assignment_exceptions` lists assets still held by people who are no longer active.

## Not built
Search (assets are findable by direct query only until the Search module), asset depreciation, barcode/QR labels, bulk import, disposal approval (the gate can be adopted with one call), the full Tickets module, the Documents module.
