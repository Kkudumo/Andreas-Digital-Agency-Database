# ADA Hub — Pilot V0.1: operational workflow map

> ONE ORGANIZATION → ONE INSTITUTIONAL PLATFORM → ONE SOURCE OF TRUTH → MANY CONTROLLED INTERFACES.

The pilot adds **no new source of truth**. Every step of the engagement workflow is performed with a controlled operation that already
belongs to a closed module. Pilot V0.1 added only: four small project/task operations, one read-only catalogue function, two search
sources (invoices, payments), one correctness fix (D1 below), and a minimal console that calls these operations.
Migration: `supabase/migrations/0042_pilot.sql`. Tests: `110_ada_hub_pilot.sql`, `111_ada_hub_pilot_access_restricted.sql`.
Console: `pilot/` (see "Console" below). AI is out of scope and absent.

## A. Authoritative modules that exist (and are reused)

| Concern | Table / entity | Institutional ID | Controlled operations (callable by `authenticated`) | Authorization | 360 view | Lifecycle | Audit |
|---|---|---|---|---|---|---|---|
| Organization | `organizations` (+ roles) | 9-char registry id (`external_organization`) | `organization_create`, `organization_add_role`, `organization_merge`, `organization_review_resolve` | RLS + `can_view_organization` | `organization_360` | active / merged | `audit_log` |
| Client (a *role* of an organization) | `clients` | registry id (`client`) + legacy alias | `client_lookup`, `client_create` (created / exists / similar / name_conflict), `claim_client_for_division` | RLS: division + classification | `client_360` | prospect → active → … | `audit_log` |
| Person / contact | `people`, `client_contacts` | registry id (`person`) | `add_client_contact` (reuses a person by email) | RLS via client | in Client 360 | active / ended | `audit_log` |
| Service catalogue & prices | `services`, `service_prices` | registry id (`service`) | `price_propose`, `price_decide`, `price_on` | `services.*`, `prices.*`; approval engine, no self-approval | – | price history (immutable rows, effective dating) | `audit_log`, `approvals` |
| Project (central container) | `projects`, `project_divisions/members/contacts/services`, `tasks` | registry id (`project`) | **new** `project_create`, `project_add_division`, `project_add_member`, `project_add_contact`, `task_create`; existing `project_transition`, `quote_convert_to_project`, `contract_link_project` | RLS (`can_view_project`, `can_edit_project`) | `project_360` | planned → active → … | `audit_log` |
| Quote | `quotes`, `quote_lines` | registry id (`quote`) | `quote_create`, `quote_add_line`, `quote_transition`, `quote_convert_to_project` | RLS; approval engine | in 360s | draft → pending_approval → approved → sent → accepted | `audit_log`, `approvals` |
| Contract | `contracts`, `contract_versions/lines/projects` | registry id (`contract`) | `contract_create_from_quote`, `contract_transition`, `contract_link_project` | RLS; approvals | in 360s | draft … active … | yes |
| Invoice | `invoices`, `invoice_lines` | registry id (`invoice`) | `billable_from_contract`, `billable_from_project`, `billable_manual`, `invoice_create`, `invoice_transition`, `invoice_balance` | finance permissions; approvals | in 360s | draft → approved → issued → partially_paid → paid | yes |
| Payment | `payments`, `payment_allocations` | registry id (`payment`) | `payment_record`, `payment_allocate` | finance only | in Client 360 (finance) | recorded / allocated | yes |
| Document | `documents`, `document_versions`, `document_links` | registry id (`document`) | `document_register`, `document_link_add`, `document_open`, holds, retention, publication | classification + division + links | `document_360` | draft … archived | yes |
| Communication | `communication_threads`, `communication_messages` | registry id (`communication_thread`, `communication_message`) | `communication_start`, `communication_message_add`, `communication_link_add`, … | metadata vs body are separate permissions (`communications.read`) | `communication_360` | open → closed → archived | yes |
| Ticket | `tickets` | registry id (`ticket`) | `ticket_create`, `ticket_assign`, `ticket_transition`, `ticket_comment_add` | RLS | in 360s | open … closed | yes |
| Asset | `assets` (+ assignments, warranty) | registry id (`asset`) | `asset_create`, `asset_transition`, `asset_assign`, … | RLS | `asset_360` | proposed → acquired → in_stock → assigned … | yes |
| Domain | `domains`, `domain_relations` | registry id (`domain`) | `domain_create`, relations by RLS-controlled insert | classification inherited from related entities | `domain_360` | pending … active … retired | yes |
| Search | `search_index` (derived, rebuildable) | – | `search`, `search_suggest`, `search_capabilities` | authorization before exposure | – | – | – |
| Identity / access | `entity_registry`, `staff`, roles, permissions | – | `entity_resolve`, `entity_get`, `my_access` | `has_permission`, RLS | – | – | yes |

The registry is a map, never the truth. Classification inherits from the client down through every record of an engagement.

## B. Gaps found

### REQUIRED FOR PILOT (built)
| # | Gap | Resolution (conservative) |
|---|---|---|
| G1 | No controlled way to create a project, add a division/member/contact, or create a task without SQL | `project_create` (idempotent per client+name, advisory-locked), `project_add_division`, `project_add_member`, `project_add_contact`, `task_create`: invoker functions under the existing policies |
| G2 | A UI cannot list divisions, services and their *current* price, bank accounts, staff | `pilot_catalogue()` read-only, invoker: RLS decides what each caller sees |
| G3 | Invoices and payments were not findable through Search | `search_sources` rows for `invoice` and `payment` (configuration only; no change to the Search architecture) |
| G4 | **Defect D1** — an invoice billed from a *contract* line (it has `contract_id`, not `project_id`) never appeared in Project 360 | `project_360` now also includes invoices of contracts linked to the project (`0042_pilot.sql`, documented with the migration; covered by suite 110) |
| G5 | No interface at all | Minimal console (`pilot/`) that calls only the controlled operations |

### NICE TO HAVE (not built)
* `related:` from a client does not list payments (payments are not in `document_family_ids`); reachable through `type:payment`, reference search and Client 360 for finance.
* Pretty printing / PDF of quotes and invoices; unit-of-work "wizard" screens; bulk entry.

### FUTURE (not built)
Dashboards, reporting, public API / public search, publication layer, email/WhatsApp/SMS, external document sharing, analytics, saved searches,
full-text document search, semantic/vector search, AI of any kind.

## C. Workflow map

| # | Step | Operation | Reads / writes | Guard |
|---|---|---|---|---|
| 1 | Authenticate | session (Supabase JWT in production; dev stand-in in console) | `staff` | suspended / non-staff get nothing |
| 2 | Search first | `search('Zeta')` | `search_index` (derived) | authorization before exposure |
| 3 | Find / create organization + client | `client_lookup`, `client_create` | `organizations`, `clients` | exists → reuse; similar / name_conflict → existing review mechanism; other division → `claim_client_for_division` keeps IDs |
| 4 | Contact | `add_client_contact` | `people`, `client_contacts` | reuses the person by email; no copies |
| 5 | Project | `project_create` | `projects` | idempotent; division permission; client must be visible |
| 6 | Division / service | `project_add_division`; service chosen on the quote line | `project_divisions`, `project_services` | org-wide `projects.update` for extra divisions |
| 7 | Quote | `quote_create`, `quote_add_line` (price from `price_on`, snapshot) | `quotes`, `quote_lines` | price never typed; override needs a reason |
| 8 | Approval | `quote_transition('pending_approval' …)`, approver decides | `approvals` | approval engine; no self-approval |
| 9 | Send / accept | `quote_transition('sent')`, `('accepted')` | `quotes` | quote frozen after send |
| 10 | Contract / project | `contract_create_from_quote`, `contract_transition`, `quote_convert_to_project`, `contract_link_project` | `contracts`, `projects` | approvals |
| 11 | Invoice | `billable_from_contract`, `invoice_create`, `invoice_transition` (prepare → approve → issue) | `invoices`, `invoice_lines` | line snapshots; immutable after issue |
| 12 | Payment | `payment_record`, `payment_allocate` | `payments`, `payment_allocations` | partial payments; balance derived by `invoice_balance` (no stored balance) |
| 13 | Document | `document_register`, `document_link_add` | `documents` | classification, retention, holds |
| 14 | Communication | `communication_start`, `communication_message_add`, `communication_link_add` | `communication_*` | metadata only unless `communications.read` |
| 15 | Ticket | `ticket_create` | `tickets` | references client / project / asset |
| 16 | Asset | `asset_create`, `asset_transition`, `asset_assign` | `assets` | stable identity |
| 17 | Client 360 / Project 360 | `client_360`, `project_360` | views over authoritative rows | per-section authorization; no denormalized copies |
| 18 | Search anywhere | `search('type:client Zeta')`, `related:<id>`, ID / legacy-ID lookup | `search_index` | deterministic; no AI |
| 19 | History | `audit_log` (visible per authorization) | | append-only |

## Console (`pilot/`)

See `pilot/README.md`. Dev server exposes `POST /rpc/<function>` (same contract as PostgREST) over an allow-list of functions executable by
`authenticated`, runs each call as the signed-in staff member inside a transaction (`set local role authenticated`, JWT subject set —
exactly what the test suites do) and the SPA only ever calls those functions. The dev log-in is a **stand-in** and must be replaced by
Supabase Auth in production; it grants nothing the database does not already grant.

## Security behaviour

Suite 111 proves, with a differential method, that a restricted client's whole engagement (project, quote, invoice, payment, document,
communication, ticket, asset, domain) contributes nothing to search results, totals, facets, suggestions, counts, 360 views, `related:`
traversal or error messages for a caller who may not see it, and that workflow operations on hidden ids answer exactly as on missing ids.
