# ADA Core — architecture overview

> ADA Core is the company's digital brain, ADA IRM is the control room, public websites are windows onto
> approved parts of the organization. The database is the source of truth; permissions are the security
> boundary; the audit log is the memory; workflows are the business rules; public data is a controlled
> projection of internal data.

## Shape

```
 Public websites ──► Public API (own route handlers, to be built) ──► role ada_public_api ──► public_api.* functions ┐
                                                                                                                      ├─► PostgreSQL
 ADA IRM (paused) ─► signed-in user's own session ─────────────────► tables, RLS, workflow functions ────────────────┘
```

A modular monolith. All business rules live in the database (constraints, triggers, SECURITY DEFINER workflow
functions), so no client — IRM, a website, or a person with API access — can bypass them.

| Module | Tables / functions | Status |
|---|---|---|
| Foundation | ADA IDs (`next_ada_id`), `entity_registry`, `audit_log`, `events`, `notifications` | built, tested |
| Organization | `organization`, `divisions`, `positions` (+ headcount) | built, tested |
| Identity & access | `staff`, `roles`, `permissions`, `role_permissions`, `staff_roles`, `staff_assignments` | built, tested |
| Recruitment | `vacancies`, `people`, `applications`, `application_*`, `onboarding_tasks`, `staff_profiles` | built, tested |
| Websites & public API | `websites`, `event_subscriptions`, `public_api.*` | built, tested (HTTP layer not yet) |
| People & clients | `people`, `clients` (full profile), `client_contacts`, `client_divisions`, `client_staff`, duplicate prevention | built, tested |
| Services & pricing | `services`, `service_prices` (immutable versions), approvals queue | built, tested |
| Quotes | `quotes`, `quote_lines` (price snapshots), conversion to project | built, tested |
| Projects | `projects`, `project_services`, `project_contacts`, `project_divisions`, `project_members`, `milestones`, `tasks`, `portfolio_entries` | built, tested |
| 360° views | `client_360`, `project_360`, `staff_360` | built, tested (sections for unbuilt modules are declared `pending`) |
| Enquiries & leads | `enquiries`, `leads`, `enquiry_candidates`, `matching_reviews`, `client_create`/`client_lookup`/`claim_client_for_division`, `public_api.submit_enquiry` | built, tested |
| Approvals | `approval_requests`, `approval_policies`, `approval_decisions`, `approval_gate` (with discount policies) | built, tested (prices, quotes, contracts, invoices, reversals/refunds) |
| Contracts | `contracts`, `contract_versions`, `contract_lines`, `contract_projects`, `contract_status_history` | built, tested |
| Invoices | `billable_items`, `invoices`, `invoice_lines`, `finance_settings` | built, tested |
| Payments | `payments`, `payment_allocations`, `payment_reversals`, `bank_accounts`, `invoice_balances`, `payment_balances` | built, tested |
| Assets | `assets`, `asset_assignments`, `asset_history`, `asset_retirements`, `asset_maintenance`, `asset_warranties`, `asset_documents` (interim), `asset_finance_links`, `asset_duplicate_flags`, `suppliers` | built, tested |
| Tickets | `tickets` (foundation: lifecycle, assignment, inheritance) | foundation built; full module next |
| Expenses, credit notes | — | not started |
| Documents, domains, communications | — | not started |
| Search, reports, dashboards | — | not started |

Documents: [Module checklist](MODULE_CHECKLIST.md) · [Entity graph](architecture/ENTITY_GRAPH.md) · [Data dictionary](architecture/DATA_DICTIONARY.md) · [ERD](architecture/ERD.md) ·
[Permission matrix](architecture/PERMISSION_MATRIX.md) · [Security](SECURITY.md) · [Public API](api/PUBLIC_API.md) ·
[Recruitment workflow](workflows/RECRUITMENT.md) · [Services, pricing & quotes](workflows/QUOTES_PRICING.md) · [Leads & enquiries](workflows/LEADS_ENQUIRIES.md) · [Contracts](workflows/CONTRACTS.md) · [Invoices & payments](workflows/INVOICES_PAYMENTS.md) · [Assets](workflows/ASSETS.md) · [Approvals](workflows/APPROVALS.md) · [Development](operations/DEVELOPMENT.md) ·
[Backup, restore & migration](operations/BACKUP_RESTORE_MIGRATION.md) · [Deployment](operations/DEPLOYMENT.md) ·
[Original audit/gap report](architecture/ARCHITECTURE_REPORT.md)

## Decisions (recorded)

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
| Regression checks are protected | `PROTECTED.txt` + a CI guard prevent silently deleting the checks that guard leakage, privacy, prices, approvals and restore integrity. |
| One approvals queue | Every pending approval is visible to the right approvers in one place, with history. |
| 360° views are SECURITY INVOKER | They inherit row-level security; nothing to keep in sync. |
| Supabase is today's host, not the architecture | The only provider-specific dependencies are `auth.users`/`auth.uid()` and (later) Storage. |

## What is verified, and what is not

Verified by `./scripts/test-db.sh` on plain PostgreSQL 16 with a stand-in for Supabase's auth schema/roles:
**1,348 checks** — authorization, integrity, audit immutability, public/private exposure, the full hire-to-departure
scenario, structural guarantees (RLS everywhere, least-privilege grants, matrix == CSV), 320 parallel ID inserts and a 22-session allocation race
allocations. Rules were validated with mutation tests (deliberately breaking a rule makes the suite fail).
`./scripts/rehearse-migration.sh` proves dump → restore → identical security posture → working system.

**Not yet verified:** a run against a real Supabase project (do this first in staging); the HTTP public API
(not written); MFA, rate limiting; anything in modules marked "not started".

## Known limitations

- Client **merge** is not built: a review marked "same entity" is recorded, but combining two client records (re-pointing all references) is a future, carefully-tested operation.
- Timing side channels are not equalised; the similarity threshold for "possible duplicate" (0.55) is a constant in `client_candidates`.
- The approval gate covers prices, quotes, contracts, invoices, reversals/refunds and discounts; other kinds (vacancies, profiles, expenses, hiring) adopt it as their modules need thresholds.
- Enquiries carry no registration number, so an exact normalised-name match to an existing client is treated as the same organization (a person who is a contact elsewhere is only ever a candidate).
- Expenses, credit notes, recurring invoicing, documents, domains and communications are not built; tickets exist as a foundation only (SLA, comments, categories, escalation pending); `asset_documents` is an interim link until the Documents module. Search is not built, so assets are findable by direct query only. The 360° views list them under `pending`. `project_financials.revenue_to_date` was removed (revenue is derived from invoices/payments); `cost_to_date` stays an interim planning field until expenses exist.
- Historical `audit_log` rows keep the old `ADA-CON-…` text for contacts renamed to `ADA-CTC-…` in migration 0026 (the audit log is immutable); the registry and tables were rewritten.
- Contracts keep a `document_ref` text until the documents module links real files; contract renewals are created explicitly, never automatically.

- Editing a *published* staff profile, service or portfolio entry returns it to draft (it leaves the website until re-approved). A
  "pending changes" model that keeps the old version live needs a versions table — not built.
- Divisions' public state is changed by `settings.update` holders directly (no approval step yet).
- Applicant CVs are referenced (`cv_ref`) but file storage/documents are not built.
- Auth users are not created from SQL; a login is invited at the identity provider, then linked with `link_staff_account()`.
