# ADA Core / ADA IRM — Architecture Report (historical)

> **Superseded.** This is the pre-approval audit and gap report. The decisions it asked for were made and Phase 1 completion + Phase 2 (recruitment) + the public API layer were built afterwards — see [docs/README.md](../README.md) for current status. Kept for the record of what was found in `ada-core-foundation`.

Date: 2026-10-08 · Branch: `claude/pensive-planck-k9zod1`

Everything below is verified against the repositories as they exist. Where something has not been
executed, it says so.

## 1. What already exists

| Location | Contents |
|---|---|
| `Kkudumo/ada-core-foundation` (untouched, read-only reference) | 5 SQL migrations, a small Next.js 15 + Supabase scaffold, an admin UI for organizations, `docs/ada-irm/ADA_IRM_V0_Build_Specification.md` (2,441 lines, 48 sections), verification scripts. |
| `Kkudumo/Andreas-Digital-Agency-Database` (this repo) | Was empty. This session added the schema, tests and docs described in §6–§9. |
| Other repos (`ada-main-website`, `ada-web-division`, `ada-tech-division`, `ada-marketing-division`, `ada-consulting-division`, `ada-academy-mvp`) | **Not inspected.** They are the future consumers of the public API; their current content/data duplication is unknown. |

## 2. Implemented correctly (in `ada-core-foundation`)

Useful patterns, carried over in concept: a role-grant hierarchy that blocks self-promotion, final-owner
lockout, controlled SECURITY DEFINER functions for sensitive mutations, schema-qualified definer functions,
and a migration-sequence check.

## 3. Incomplete / unproven in `ada-core-foundation`

Its own `SECURITY_REVIEW.md` states nothing has ever been executed against a real database: migrations,
RLS, role-grant triggers and the verification scripts are all "statically reviewed" only. It has no
staff, clients, projects, positions/vacancies, services, finance, documents, ID sequences, or entity
registry. The spec describes them; the SQL does not contain them.

## 4. What should change

The foundation models **multi-tenant CMS hosting** (organizations as tenants, `org_owner`/`editor`/`viewer`,
domain→tenant resolution, theme tables). ADA is **one organization with divisions**. That model cannot be
extended into this one without distorting it, which is why the schema was re-based in this repo rather than
modified in place. Nothing in `ada-core-foundation` was changed or deleted.

## 5. What should NOT change

The ADA IRM V0 spec's intent (one source of truth, deny-by-default, publication-safe views, AI extraction
only with human verification) and the `ada-core-foundation` repo itself, which stays as a reference.

## 6. Current database structure (this repo, migrations 0001–0007)

`entity_types`, `id_sequences`, `entity_registry` · `organization`, `divisions`, `positions` ·
`staff`, `staff_private`, `roles`, `permissions`, `role_permissions`, `staff_roles` · `audit_log` ·
`clients`, `client_contacts`, `client_divisions`, `client_staff` · `projects`, `project_divisions`,
`project_members`, `project_financials`, `tasks`.
Seeded: 1 organization, 9 divisions, 9 positions, 33 permissions, 6 system roles (matrix in
`supabase/seed_data/permission_matrix.csv`).

## 7. Current authentication / authorization

- Login = `auth.users` (Supabase Auth). A login is **not** staff: `staff.user_id` is nullable and unique;
  `account_status` must be `active` for any access. `link_staff_account()` links a login to a staff record
  (requires `staff.manage_accounts`); `bootstrap_first_admin()` creates the first administrator (service role only).
- Permissions are `module.action` keys (e.g. `clients.update`). A role assignment is organization-wide or
  scoped to one division (`staff_roles.division_id`). `has_permission(key[, division])` is the single check used
  by every RLS policy; no `if role == ...` anywhere.
- Anti-escalation: nobody may change their own roles; nobody may grant/revoke a role carrying a permission they
  don't hold in the same scope; at least one active org-wide administrator must always exist.
- Record-level rules: division relationship, personal assignment, classification
  (`public/internal/restricted/confidential`), soft-delete visibility. Finance and HR are in separate tables behind
  their own permissions.
- Default privileges are revoked for `anon`/`authenticated`; every grant is explicit; every SECURITY DEFINER function
  pins `search_path`.
- **Not yet built:** MFA, rate limiting, API-key identity for websites, per-request IP/metadata in audit.

## 8. ADA Core architecture (current)

PostgreSQL schema + RLS + triggers (business rules live in the database). Only Supabase dependencies: `auth.uid()`
and `auth.users`. Test harness (`scripts/test-db.sh`) builds a scratch database from migrations alone and runs
**183 checks** (authorization, integrity, audit immutability, structure, matrix-equals-CSV). Mutation testing
confirmed the suite catches deliberately broken finance, anti-escalation and soft-delete rules. This ran on plain
PostgreSQL 16 with a shim for Supabase's `auth` schema and roles — **it has not run on a real Supabase project.**

## 9. ADA IRM architecture (current)

Partially written Next.js 15 app in `web/` (login, shell with permission-aware navigation, dashboard,
organization, staff). Uses only the user's own session — no service-role key. **Not yet installed, built, type-checked
or run**; clients, projects, access and audit pages are not written. Committed as WIP.

## 10. Gaps against the master specification

| Spec area | State |
|---|---|
| Organization, divisions, positions, staff, roles, permissions, central IDs, audit, soft delete, clients, projects/tasks | Built, tested |
| **People** (applicants/candidates distinct from staff) | Missing |
| **Vacancies, applications, recruitment pipeline, onboarding, controlled hire** | Missing (positions exist; vacancy is a separate concept still to build) |
| **Public profiles / publication states / approval workflow** | Missing (only classification exists) |
| **Website registry, source tracking (UTM/page), public API, public DTOs/views, statistics** | Missing |
| **Events/outbox, webhooks, cache revalidation** | Missing |
| **Notifications, global search** | Missing |
| **Services catalogue + price history, leads, quotes** | Missing |
| **Invoices, payments, expenses (only `project_financials`)** | Missing |
| **Assets, tickets, documents/storage, domains/digital assets, secrets references** | Missing |
| **History tables** (staff division/title, project status) | Missing; audit exists but is not queryable history |
| ID prefixes VAC, APP, TKT, AST, DOC, QUO, INV, SVC, … | Only ORG/DIV/POS/STF/CLI/CON/PRJ/TSK registered |
| Backup/restore scripts, deployment docs, environments | Missing (migrations are reproducible; nothing else) |
| ERD, data dictionary | Not yet produced (the report you asked for first) |

## 11. Recommended implementation order

1. **Phase 1 completion:** `people`, website registry (+ API identity), vacancies, extend ID prefixes, history tables
   (`staff_assignments`), outbox `events` table, status/publication enums, core `public` schema of views.
2. **Phase 2 Recruitment** (module by module, tested each): vacancy lifecycle → applications with source tracking →
   offer → `accept_application()` as one auditable, idempotent, duplicate-safe transaction → onboarding tasks → public
   profile approval → departure.
3. Public API (read-only, route handlers over `public_api` views) as soon as vacancies publish, so the first end-to-end
   website scenario (§54 steps 1–20) is provable early.
4. CRM/leads/quotes → services + price history → projects/portfolio → finance → assets/tickets/documents/domains →
   hardening, backup/restore rehearsal, migration to the ADA server.
5. Finish the IRM per module as each backend module passes tests, not before.

## 12. Risks and architectural issues

1. **Divisions: 6 vs 9.** Your prompt lists six divisions. The earlier foundation/spec also treats Management,
   Administration and Finance as organizational units, and I seeded all nine (`kind = corporate|service`). Public
   division data should expose only the six service divisions. Needs your decision.
2. **Public API access path.** Exposing Supabase's auto-generated REST API to `anon` would put table access one
   misconfigured policy from a leak. Recommended: the website-facing API is our own route handlers reading dedicated
   `public_api` views through a separate least-privilege database role; `anon` keeps zero access (already enforced
   and tested). This is also the more portable design.
3. **Supabase portability.** Real dependencies today are `auth.users`/`auth.uid()` and Supabase Auth itself, plus
   Storage once documents land. Moving to a private server means self-hosting Supabase's stack or replacing auth —
   a decision to make before Phase 6, not at migration time. Business rules are plain SQL either way.
4. **Business rules in triggers/SQL vs. services.** Chosen deliberately so no client can bypass them; the cost is
   SQL-heavy workflows (hire, quote→project). Acceptable for a modular monolith, but each workflow needs
   state-machine tests.
5. **Unverified on real Supabase.** Local PostgreSQL with a shim is good evidence, not proof. First deployment to a
   staging Supabase project must run the same suite.
6. **Websites not inspected.** The six site repos may carry hard-coded data (services, team, prices) that the public API
   will replace; scope of that migration is unknown.
7. **Secrets, MFA, rate limiting** are not designed yet; documents and domains/credentials phases depend on that.

## Decisions requested

1. Divisions: six public service divisions **plus** three corporate units (my recommendation), or exactly six?
2. Public API via own route handlers over `public_api` views (recommended), or PostgREST views?
3. Approve proceeding with Phase 1 completion → Phase 2 Recruitment in the order above?
4. Does the WIP `web/` scaffold stay (continue it after Phase 2 backend), or pause until the backend modules exist?
