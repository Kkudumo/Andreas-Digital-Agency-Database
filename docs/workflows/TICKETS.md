# Tickets

A ticket is a **registered entity** (`tickets`, legacy alias `ADA-TKT-…`, permanent 9-character institutional ID in the registry) created through the one registration path. Tickets have no ID generator, no ID input and no copy of anything they refer to.

## References, not copies
`asset_id`, `client_id`, `project_id`, `contact_id`, `requester_person_id` (a `people` row), `service_id`, `website_id`, `category_id`, `reporter_staff_id`, `assignee_staff_id`. Raised against an asset, a ticket takes client, project and division from it (a conflicting client/project is refused) — the technician never retypes "Lenovo ThinkPad, serial XYZ, assigned to John". The requester's person record becomes visible to anyone who can see the ticket (the relationship carries the privacy); a requester the creator cannot see behaves exactly like a random id. Documents and communications will attach by reference when those modules arrive; organizations will be referenced after Organization Unification.

## Origin vs ownership
The registry records the **origin division** at creation (immutable) and the **current division** (follows `tickets.division_id`). `ticket_transfer(ticket, division, reason)` is the only way to change the division — enforced for every caller, owner included — requires `tickets.assign`, clears the assignee, and writes both `ticket_events` and the registry's `entity_location_history`. The permanent ID never changes.

## Lifecycle
`open → in_progress ⇄ waiting → resolved → closed`, `resolved → open` (reopen), `cancelled`. Resolve and cancel need a note; closed and cancelled tickets are final (no comments, priority changes or transfers). Every change is an append-only `ticket_events` row, in addition to `audit_log`.

## SLA (derived, configurable)
`ticket_sla_policies` (priority, optional division override — the division wins) set first-response and resolution targets in elapsed minutes. Due times are agreed at creation from the policy then in force and re-derived from the **creation time** when the priority changes. `ticket_sla_status` (a view) derives breach flags and time remaining; nothing "breached" is stored. The first **public staff** comment is the first response (an internal note or a reporter's own comment is not). Business-hours calendars and pausing while *waiting* are not modelled.

## Conversation
`ticket_comments` are append-only. **Internal** notes are visible only to people working the ticket (division ticket staff, the assignee); a reporter who is not in the handling division sees the non-internal conversation only and may add public comments but not internal ones.

## Priority and escalation
`ticket_set_priority(ticket, priority, reason)`: raising the priority is an **escalation** (event kind `escalation`, notification to the division's `tickets.assign` holders when the ticket is `internal`); lowering is a plain priority event.

## Classification and restricted clients
A ticket inherits the strictest classification of itself, its asset, its client and its project, and follows them when they change (triggers fire on any update). Restricted tickets are invisible to everyone without access; every command reports "ticket not found" identically for hidden and missing tickets (`100_tickets.sql`, permanent). Notifications are not sent for restricted tickets.

## A defect worth remembering
`can_view_ticket_row` once returned **NULL** for a ticket with no assignee when the caller was neither reporter nor handler; plpgsql `IF` treats NULL as false, so `ticket_load` did not raise and `ticket_comment_add` would have let any staff member comment on any ticket. Access predicates now return a definite boolean, and a permanent test asserts that no access predicate returns NULL for any row, for the owner and for four unprivileged personas.

## Publication
Tickets are never public: `entity_types.publishable = false`, and no ticket table has a public/publication column (tested). See [PUBLICATION_LAYER.md](../architecture/PUBLICATION_LAYER.md).

## Not built
E-mail/web intake, customer portal, business-hours SLA calendars, linked/duplicate tickets, bulk actions, documents and communications attachments (those modules), organization reference (after unification).
