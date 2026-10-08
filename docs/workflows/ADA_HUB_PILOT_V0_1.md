# ADA Hub Pilot — Overview & Operational Workflow (Phase 1 / V0.1)

> **Naming.** *ADA Hub* is the platform as a whole; *ADA Core Architecture* is the identity, registry, data, rules, authorization, audit, routing and integration layer beneath it; *ADA IRM* is the internal management interface; *ADA Website / public websites* are controlled public interfaces over approved projections. ADA Organization → ADA Hub → ADA Core Architecture → Domain Modules → Controlled Interfaces.

---

## 1. High-level codebase overview

ADA Core is the company's digital brain, ADA IRM is the control room, public websites are windows onto approved parts of the organization. **The database is the source of truth; permissions are the security boundary; the audit log is the memory; workflows are the business rules; public data is a controlled projection of internal data.**

### Shape

```
 Public websites ──► Public API (own route handlers, to be built) ──► role ada_public_api ──► public_api.* functions ┐
                                                                                                                  ├─► PostgreSQL
 ADA IRM (paused) ─► signed-in user's own session ─────────────────► tables, RLS, workflow functions ────────────────┘
```

A modular monolith. All business rules live in the database (constraints, triggers, `SECURITY DEFINER` workflow functions), so no client — IRM, a website, or a person with API access — can bypass them.

### Top-level layout

```
supabase/    the database: schema, tests, permission matrix
scripts/     test runner, backup/restore, migration rehearsal, doc generators
docs/        architecture, security, API, workflows, operations
web/         ADA IRM — the Next.js internal interface (PAUSED, scaffold stage)
```

### Layout detail

**`supabase/migrations/`** — 41 ordered SQL files; the schema, in order, and the *only* way the schema changes. Migrate in sequence: foundation → organization → RBAC → clients & projects → recruitment → services/pricing/quotes → approvals → contracts → invoices → payments → finance graph → assets → tickets → asset integration → institutional skeleton → academy identity → tickets module → documents → organization unification → domains → communications → search.

**`supabase/seed_data/permission_matrix.csv`** — the reviewed permission matrix. Tests require the database to grant exactly what the CSV says (`matrix == CSV`).

**`supabase/tests/`** — authorization, integrity, public-exposure and scenario tests, plus a `00_supabase_shim.sql` that stands in for Supabase's auth schema/roles so everything runs on plain PostgreSQL 16. Structure: helpers, integrity, authorization, structure, bootstrap, then test suites covering recruitment, public API, scenario hiring, central clients, services/pricing, project graph & quotes, approval policies, leads & enquiries, existence leakage, contracts, invoices, payments, financial approvals, graph scenario, enquiry-to-quote, finance-restricted clients, finance scenario, assets, asset integration, asset-restricted, asset scenario, institutional identity, people/academy/staff. A `concurrency/` subdirectory holds parallel-load scenarios (ID insertion, asset registration, allocation races). `PROTECTED.txt` flags regression checks CI will not silently delete.

**`scripts/`** — `test-db.sh` (main test runner, needs local PostgreSQL 16 + Node; see `docs/operations/DEVELOPMENT.md`), `backup.sh`/`restore.sh` (backup & restore), `rehearse-migration.sh` (rehearse a server move: dump → restore → identical security posture → working system), `check-migrations.mjs`, `check-protected-tests.mjs`, `build-rbac-delta.mjs`, `security-fingerprint.sql`, `gen-docs.sh`.

**`docs/`** — architecture, API, workflows, operations docs; see below for the file map.

**`web/`** — ADA IRM scaffold (PAUSED until backend modules finish). Next.js 15 + React 19 + TypeScript, `@supabase/ssr` + `@supabase/supabase-js`, `middleware.ts` for session/route protection, `lib/supabase/` server-side Supabase client, `lib/access.ts` (permission checks), `lib/format.ts`, `lib/flash.ts`, `app/(irm)/` authenticated routes (dashboard / organization / staff), `app/login/`, `app/no-access/`.

---

### Module map (built / tested / not started)

| Module | Tables / functions | Status |
|---|---|---|
| Institutional skeleton | `id_codebook`, `ada_mint_id` (9-char opaque IDs), `entity_registry`, `entity_location_history`, `entity_resolve` / `entity_get` / `search_route`, `search_index` (derived), `security_events` / `security_cases` | built, tested |
| Foundation | legacy ADA IDs (`next_ada_id`, now aliases), `audit_log`, `events`, `notifications` | built, tested |
| Academy identity | `programmes`, `cohorts`, `students`, `student_enrolments` (identity core only) | built, tested |
| Organization | `organization`, `divisions`, `positions` (+ headcount) | built, tested |
| Identity & access | `staff`, `roles`, `permissions`, `role_permissions`, `staff_roles`, `staff_assignments` | built, tested |
| Recruitment | `vacancies`, `people`, `applications`, `application_*`, `onboarding_tasks`, `staff_profiles` | built, tested |
| Websites & public API | `websites`, `event_subscriptions`, `public_api.*` | built, tested (HTTP layer not yet) |
| People & clients | `people`, `clients` (full profile), `client_contacts`, `client_divisions`, `client_staff`, duplicate prevention | built, tested |
| Services & pricing | `services`, `service_prices` (immutable versions), approvals queue | built, tested |
| Quotes | `quotes`, `quote_lines` (price snapshots), conversion to project | built, tested |
| Projects | `projects`, `project_services`, `project_contacts`, `project_divisions`, `project_members`, `milestones`, `tasks`, `portfolio_entries` | built, tested |
| 360° views | `client_360`, `project_360`, `staff_360`, `asset_360`, `document_360` | built, tested (sections for unbuilt modules declared `pending`) |
| Enquiries & leads | `enquiries`, `leads`, `enquiry_candidates`, `matching_reviews`, `client_create` / `client_lookup` / `claim_client_for_division`, `public_api.submit_enquiry` | built, tested |
| Approvals | `approval_requests`, `approval_policies`, `approval_decisions`, `approval_gate` (with discount policies) | built, tested (prices, quotes, contracts, invoices, reversals/refunds) |
| Contracts | `contracts`, `contract_versions`, `contract_lines`, `contract_projects`, `contract_status_history` | built, tested |
| Invoices | `billable_items`, `invoices`, `invoice_lines`, `finance_settings` | built, tested |
| Payments | `payments`, `payment_allocations`, `payment_reversals`, `bank_accounts`, `invoice_balances`, `payment_balances` | built, tested |
| Assets | `assets`, `asset_assignments`, `asset_history`, `asset_retirements`, `asset_maintenance`, `asset_warranties`, `asset_documents` (interim), `asset_finance_links`, `asset_duplicate_flags`, `suppliers` | built, tested |
| Tickets | `tickets`, `ticket_categories`, `ticket_sla_policies`, `ticket_comments`, `ticket_events`, `ticket_sla_status` | built, tested |
| Organizations | `organizations`, `partners`, `organization_reviews`, `organization_distinct_pairs` (+ clients / suppliers as roles) | built, tested |
| Expenses, credit notes | — | not started |
| Documents | `documents`, `document_versions`, `document_links`, `document_access`, `document_holds`, `document_comments`, `document_events`, `document_integrity_checks`, `document_disposals`, `document_publications`, `document_types`, `retention_classes`, `document_retention_status` | built, tested |
| Domains | `domains`, `domain_relations`, `domain_registrations`, `domain_transfers`, `domain_events`, `domain_reviews`, `domain_expiry_status`, `website_hostname_domains` | built, tested |
| Communications | `communication_threads`, `communication_messages`, `communication_participants`, `communication_links`, `communication_attachments`, `communication_access`, `communication_holds`, `communication_comments`, `communication_disposals`, `communication_events`, `communication_types`, `communication_retention_status` | built, tested (records only: no sending or synchronisation) |
| Search | `search_index` (derived), `search_sources`, `search_refresh_queue`; `search`, `search_execute`, `search_suggest`, `search_parse` | built, tested (staff only; derived, rebuildable, authorization-first) |
| Reports, dashboards | — | not started |

---

### Recorded decisions

| Decision | Why |
|---|---|
| One organization, many divisions — not multi-tenant | ADA is one company; the earlier tenant model (`ada-core-foundation`) solved a different problem. |
| Nine divisions: six public service divisions + Management, Administration, Finance | Internal units hold staff and permissions but are never published (`divisions.public_state`). |
| Position ≠ Vacancy | A position has a `headcount`; vacancies are openings over time. Filled/vacant is derived (`position_availability`), never stored. |
| Permissions are `module.action`, assigned by role, org-wide or scoped to a division | No role-name checks anywhere; new positions need no code. |
| Workflows are database functions with explicit transition tables | `vacancy_transition`, `application_transition`, `make_offer`, `accept_application`, `profile_transition`, `terminate_staff`. Direct status updates are rejected even for the CEO. |
| Public API = our own route handlers over `public_api` functions, called as a database role with no table access | Smaller blast radius than exposing the auto-generated REST API; also portable. |
| The API server hashes website keys; the database stores and sees only hashes | Keys never appear in query logs or backups. |
| Events are an outbox of identifiers and states only | Websites revalidate caches without redeploying, and events can never leak personal data (tested). |
| ONE client, ONE person, ONE catalogue | Contacts are relationships to a shared `people` record; clients are claimed by divisions, never re-created; every module references existing records. Enforced by tests that fail on new identity columns or unregistered IDs. |
| Prices are immutable versions; documents of commerce copy the version used | History is true by construction; changing a price never changes a quote, project or (later) invoice. |
| Restricted records look like missing records | Existence is not leaked through errors, lookups, counts, helper functions or API answers; dependents inherit the classification. A permanent probe suite compares a restricted id with a random id. |
| Self-approval is a configurable, recorded policy | Allowed only while the requester is the sole qualified approver (default), never hardcoded for a role; separation of duties then applies automatically. |
| Identity is generated, opaque and permanent | One central service mints 9-character IDs that encode only immutable facts; the registry maps IDs to their authoritative records and mirrors (never owns) division, location, status and classification; legacy identifiers remain as aliases. Search goes registry-first. |
| Regression checks are protected | `PROTECTED.txt` + a CI guard prevent silently deleting the checks that guard leakage, privacy, prices, approvals and restore integrity. |
| One approvals queue | Every pending approval is visible to the right approvers in one place, with history. |
| 360° views are SECURITY INVOKER | They inherit row-level security; nothing to keep in sync. |
| Supabase is today's host, not the architecture | The only provider-specific dependencies are `auth.users` / `auth.uid()` and (later) Storage. |

---

## 2. Phase 1 (ADA HUB PILOT V0.1) — what exists and what is ready

Phase 1 (V0.1 pilot) operates **over the already-built Core**. Nothing in the module list above must be implemented for the pilot to run. The pilot's job is to connect the ready modules to the right people, lock the security boundary, and run end-to-end scenarios before any public website or the IRM goes live.

**Ready-to-use modules for the pilot:**

- **Institutional skeleton** — opaque 9-char IDs, `entity_registry`, `entity_resolve`/`entity_get`/`search_route`, `search_index` (derived).
- **Foundation** — `audit_log`, `events`, `notifications`.
- **Organization** — `organization`, `divisions`, `positions`.
- **Identity & access** — `staff`, `roles`, `permissions`, `role_permissions`, `staff_roles`, `staff_assignments`.
- **Recruitment** — `vacancies`, `people`, `applications`, `application_*`, `onboarding_tasks`, `staff_profiles`.
- **People & clients** — `people`, `clients`, `client_contacts`, `client_divisions`, `client_staff`, client duplicate prevention.
- **Services & pricing** — `services`, `service_prices` (immutable versions), approvals queue.
- **Quotes** — `quotes`, `quote_lines`, conversion to project.
- **Projects** — `projects`, `project_services`, `project_contacts`, `project_divisions`, `project_members`, `milestones`, `tasks`, `portfolio_entries`.
- **Enquiries & leads** — `enquiries`, `leads`, `enquiry_candidates`, `matching_reviews`, `client_create` / `client_lookup` / `claim_client_for_division`, `public_api.submit_enquiry`.
- **Approvals** — `approval_requests`, `approval_policies`, `approval_decisions`, `approval_gate` (prices, quotes, contracts, invoices, reversals/refunds, discounts).
- **Contracts** — `contracts`, `contract_versions`, `contract_lines`, `contract_projects`, `contract_status_history`.
- **Invoices** — `billable_items`, `invoices`, `invoice_lines`, `finance_settings`.
- **Payments** — `payments`, `payment_allocations`, `payment_reversals`, `bank_accounts`, `invoice_balances`, `payment_balances`.
- **Assets** — `assets`, `asset_assignments`, `asset_history`, `asset_retirements`, `asset_maintenance`, `asset_warranties`, `asset_documents` (interim), `asset_finance_links`, `asset_duplicate_flags`, `suppliers`.
- **Docs**, **Domains**, **Communications** (records only), **Search** (staff only), and **360° views**.

**Not yet part of the pilot:**
- HTTP public API (not written — `public_api.*` functions exist but there are no route handlers yet).
- Expenses, credit notes, recurring invoicing, reports/dashboards.
- Client merge, MFA, rate limiting, real Supabase staging run (recommended first staging step).
- IRM fully built (paused scaffold) — pilot operations will use the database directly or a thin admin until the IRM is finished.

---

## 3. Operational workflow — Phase 1 (ADA HUB PILOT V0.1)

This is the operational sequence for standing up the pilot, readying the security boundary, validating scenarios, and deciding the hand-off to a real Supabase staging environment.

### 3.1 Pre-flight — environment and credentials

**Preconditions.**

1. Local PostgreSQL 16 is available (the test runners use plain PostgreSQL, not a live Supabase project).
2. Node is available (the concurrency scenarios and helpers run under Node).
3. Read `docs/operations/DEVELOPMENT.md` for the local setup steps.
4. `supabase/seed_data/permission_matrix.csv` reflects the role/permission grant intent for the pilot. Confirm with the stakeholders that the CSV is the reviewed source of truth before running tests.

**Entry point.** `docs/README.md` is the canonical entry point; `docs/workflows/*.md` hold per-module operational detail. The file map:
- Architecture: `architecture/INSTITUTIONAL_SKELETON.md`, `architecture/ENTITY_GRAPH.md`, `architecture/DATA_DICTIONARY.md`, `architecture/ERD.md`, `architecture/PERMISSION_MATRIX.md`, `architecture/ARCHITECTURE_REPORT.md`, `architecture/PUBLICATION_LAYER.md`.
- Workflows: `workflows/RECRUITMENT.md`, `workflows/QUOTES_PRICING.md`, `workflows/LEADS_ENQUIRIES.md`, `workflows/CONTRACTS.md`, `workflows/INVOICES_PAYMENTS.md`, `workflows/ASSETS.md`, `workflows/TICKETS.md`, `workflows/DOCUMENTS.md`, `workflows/ORGANIZATIONS.md`, `workflows/APPROVALS.md`.
- API / operations: `api/PUBLIC_API.md`, `operations/DEVELOPMENT.md`, `operations/BACKUP_RESTORE_MIGRATION.md`, `operations/DEPLOYMENT.md`.
- Security: `SECURITY.md`.
- Module checklist: `MODULE_CHECKLIST.md`.

### 3.2 Run the core test suite

**Command.** `./scripts/test-db.sh`

**What it validates (1,806 checks):**
- Authorization — every role sees only what it is allowed to see.
- Integrity — constraints, triggers, and workflow transitions hold.
- Audit immutability — `audit_log` cannot be altered by any client.
- Public/private exposure — restricted records look like missing records; a permanent probe suite compares a restricted id with a random id.
- Scenario coverage — full hire-to-departure, enquiry-to-quote, finance, and asset scenarios.
- Structural guarantees — RLS everywhere, least-privilege grants, `matrix == CSV` (permission matrix equals the seed CSV).
- Concurrency — 320 parallel ID inserts, 320 parallel asset registrations, a mixed-family parallel ID run, and a 22-session allocation race.

**Rule validation.** The suite was validated with mutation tests: deliberately breaking a rule must make the suite fail. If a test passes after an intentional break, the rule test is insufficient — raise it before proceeding.

**Exit criterion.** All checks pass on plain PostgreSQL 16 with the Supabase auth shim. If anything fails, the pilot does not advance to staging.

### 3.3 Verify the permission matrix

**Mechanism.** The seed CSV at `supabase/seed_data/permission_matrix.csv` is the reviewed permission matrix. The test suite asserts `matrix == CSV`: every grant the database makes is accounted for in the CSV, and vice versa.

**Operational rule.** Any change to roles or permissions must:
1. Be reflected in the CSV first (review the change).
2. Then be reflected in the migration that applies the change.
3. Then pass the `matrix == CSV` check.

No role-name checks appear anywhere in client code — positions need no new code when permissions change.

### 3.4 Rehearse a server move (migration integrity)

**Command.** `./scripts/rehearse-migration.sh`

**What it proves.** Dump → restore → identical security posture → working system. Use this before any staging migration, and any time the migration set changes materially. The rehearsal gives confidence that the dump/restore path preserves the security boundary and that the restored system passes the same checks.

**Timing.** Run it after the migration set changes and before promoting a dump to staging.

### 3.5 Prepare the staging Supabase project

**Status.** Nothing is yet verified against a real Supabase project (do this first in staging).

**Steps.**
1. Create a (non-production) Supabase project in staging.
2. Apply the migration set in order, exactly as it runs locally.
3. Seed the permission matrix.
4. Run the test suite against the staging project (with the Supabase auth schema real, not shimmed).
5. Confirm that `auth.users` / `auth.uid()` behave as the shim modelled.

**Known provider-specific dependency.** Only `auth.users` / `auth.uid()` (and later Storage) are provider-specific. Everything else is portable PostgreSQL.

### 3.6 Author the pilot's role & permission baseline

**Goal.** Define, in the CSV, the exact grant set the pilot will operate with. The pilot is a single organization with nine divisions (six public service divisions + Management, Administration, Finance). Internal units hold staff and permissions but are never published (`divisions.public_state`).

**Guidance from recorded decisions:**
- Permissions are `module.action`, assigned by role, org-wide or scoped to a division.
- Workflows are database functions with explicit transition tables — direct status updates are rejected even for the CEO. Pilot operators use the workflow functions, not direct `UPDATE`s.
- Self-approval is a configurable, recorded policy — allowed only while the requester is the sole qualified approver (default), never hardcoded for a role.
- One approvals queue — every pending approval is visible to the right approvers in one place, with history.

**Pilot baseline suggestion (to be reviewed against the CSV):**
- A pilot-admin role with read across ready modules + write in the modules needed for the pilot scenarios (enquiries, leads, clients, quotes, projects, service/pricing, approvals, contracts, invoices, payments, assets, docs, domains, tickets).
- Division-scoped roles where the pilot exercises division-level claims (`claim_client_for_division`) and division-scoped permission grants.

### 3.7 Run the pilot scenarios (end-to-end)

The pilot validates the system end-to-end through representative flows. Use the workflow functions in the database, not direct table writes. Approvals, prices (immutable versions), audit entries, and events are produced by the same functions live clients will use.

**Recommended pilot flows:**

1. **Lead / enquiry flow.** `public_api.submit_enquiry` equivalent (today: call the underlying functions with a signed-in session), `client_create` / `client_lookup` / `claim_client_for_division`, enquiry-to-quote scenario. Verify that an exact normalized-name match to an existing client is treated as the same organization and that a person who is a contact elsewhere is only ever a candidate.

2. **Quote / pricing / service flow.** Create a service, create an immutable price version, quote against it (price snapshots in `quote_lines`), convert a quote to a project. Verify that changing a price never changes an existing quote, project, or (later) invoice.

3. **Approvals flow.** Trigger approvals via the approval gate (prices, quotes, contracts, invoices, reversals/refunds, discounts). Verify separation of duties and that self-approval is only allowed when the requester is the sole qualified approver.

4. **Contracts / invoices / payments flow.** Create a contract, invoice billable items, allocate payments, handle reversals/refunds. Verify `invoice_balances` / `payment_balances` and that revenue is derived from invoices/payments (no separate revenue field).

5. **Assets flow.** Register assets, assign them, retire, maintain, warranty. Verify duplicate flags and `asset_360`.

6. **Recruitment flow.** Vacancy → application → offer (`make_offer`) → accept → onboarding. Verify `vacancy_transition`, `application_transition`, and that direct status updates are rejected.

7. **Restricted / existence-leakage probe.** Confirm restricted records look like missing records across errors, lookups, counts, helpers, and API answers. Confirm the permanent probe suite (restricted id vs random id) still passes.

### 3.8 Audit & observation during the pilot

- **Audit log is immutable.** All mutations the pilot makes should appear in `audit_log` via the workflow functions. Read it to confirm the trail; do not attempt to alter it.
- **Events are an outbox of identifiers and states only.** They carry no personal data. They exist so websites can revalidate caches without redeploying. Confirm the event stream matches the pilot's mutations.
- **Search (staff only).** `search_index` is derived and rebuildable, authorization-first. If the pilot needs search, confirm the index refresh and that results respect RLS.

### 3.9 Not in scope for the pilot (document the gap)

Explicitly note during the pilot that the following are **not** being built or validated yet, so nothing is claimed about them:

- HTTP public API (route handlers not written — `public_api.*` functions exist but are not exposed yet).
- Expenses, credit notes, recurring invoicing.
- Reports & dashboards.
- Client merge (a "same entity" review is recorded, but combining two client records is not built — references are not re-pointed).
- MFA, rate limiting.
- Real Supabase staging run (do this first in staging).
- Communications sending / receiving / synchronisation (records layer only).
- Tickets email/web intake, customer portal, business-hours SLA calendars, linked tickets.
- Approvals for kinds other than prices, quotes, contracts, invoices, reversals/refunds, discounts (vacancies, profiles, expenses, hiring adopt the gate as their modules need thresholds).
- Auth users are not created from SQL — a login is invited at the identity provider, then linked with `link_staff_account()`.

### 3.10 Hand-off criteria from pilot to staging/next phase

The pilot advances when **all** of the following hold:

1. `./scripts/test-db.sh` passes on plain PostgreSQL 16 (1,806 checks).
2. The permission matrix CSV is reviewed, committed, and the `matrix == CSV` check passes.
3. `./scripts/rehearse-migration.sh` passes (dump → restore → identical security posture → working system).
4. The pilot scenarios above run to completion using the database workflow functions, producing approvals, audit entries, immutable price snapshots, and events consistent with the rules.
5. The `docs/MODULE_CHECKLIST.md` reflects the pilot's read.
6. Any module still marked "not started" or "not yet verified" is explicitly documented as out of scope for the pilot.

Once the above hold, the next step is the real Supabase staging run. The HTTP public API and the IRM are separate work items that come after the backend modules are finalized and the security boundary is confirmed on staging.

---

## 4. How the pieces map to the pilot

| Pilot need | Where it lives |
|---|---|
| Source of truth | PostgreSQL (the database) — no client keeps its own copy |
| Security boundary | RLS + `module.action` permissions assigned by role + least-privilege grants (`matrix == CSV`) |
| Business rules | `SECURITY DEFINER` workflow functions + explicit transition tables |
| Memory | `audit_log` (immutable) |
| Notification / cache invalidation | `events` outbox (identifiers and states only) |
| Identity | `ada_mint_id` (9-char opaque IDs) + `entity_registry` (registry-first search) |
| Reviews & approvals | `approval_*` + `approval_gate` (prices, quotes, contracts, invoices, reversals/refunds, discounts) |
| Commerce history | Immutable price versions copied into `quote_lines` / contracts / invoices |
| Restricted data | Classified records look like missing records; dependents inherit classification; probe suite guards leakage |
| 360° views | SECURITY INVOKER views that inherit RLS |
| Public projection (future) | Own route handlers → `ada_public_api` role → `public_api.*` functions (not yet exposed) |
| Internal interface (paused) | `web/` IRM scaffold, Next.js + Supabase SSR, permission checks in `lib/access.ts` |

---

*This document is the Phase 1 (ADA HUB PILOT V0.1) overview and operational workflow. It references — and does not replace — the detailed per-module documents in `docs/architecture/`, `docs/workflows/`, `docs/api/`, and `docs/operations/`.*
