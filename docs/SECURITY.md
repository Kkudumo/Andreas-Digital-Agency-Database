# Security model

## Principles
Deny by default · least privilege · enforce in the database · public data is projected, never exposed ·
every important change is attributable · secrets are references, never values.

## Layers
1. **Authentication** — Supabase Auth today. A login (`auth.users`) is not a staff member: access requires a
   `staff` row with `account_status = 'active'` linked via `staff.user_id`. Suspending, terminating or soft-deleting
   staff removes all access immediately (every check goes through `current_staff_id()`).
2. **Authorization** — `has_permission(key[, division])` is the only check. Roles bundle permissions; a role
   assignment is organization-wide or scoped to one division. Record-level rules add: division relationship,
   personal assignment, classification (`public/internal/restricted/confidential`), soft-delete visibility.
3. **Row-level security** on every table (tested). `anon` has no table privileges; `authenticated` has only the
   grants each migration states; default privileges are revoked in `0001`.
4. **Workflow functions** — statuses of vacancies, applications and profiles change only through SECURITY DEFINER
   functions that check permissions, validate transitions, write history and emit events. Triggers reject direct updates.
5. **Anti-escalation** — nobody can change their own roles; nobody can grant/revoke a role carrying a permission
   they do not hold in that scope; ADA always keeps at least one active organization-wide administrator.
6. **Audit** — `audit_log` is written by triggers (cannot be skipped by application code), append-only (update, delete
   and truncate raise), readable only with `audit.view`. Sensitive columns are redacted from audit payloads.
7. **Public boundary** — role `ada_public_api` has **no table privileges**; it may execute six `public_api` functions.
   Each authenticates the website by key *hash*, checks the site's capability, and returns an explicitly built JSON DTO.
8. **Relationship-based privacy** — a person is one record, but who may see it follows the *relationship* (client contact, applicant, staff). Seeing someone as a client contact never reveals recruitment data and vice versa.
9. **Invoker views** — the 360° functions are SECURITY INVOKER, so they inherit row-level security instead of re-implementing it.
10. **Immutable history** — approved prices, status histories, review notes and the audit log reject updates and deletes at the database level, for every caller.
11. **Events** carry identifiers and states only (a test asserts no `@`, names or phone numbers ever appear).

## Restricted records must look like missing records
A restricted or confidential client may exist without its existence being knowable to people who are not authorised. This is enforced everywhere a caller could observe it:
- **errors and messages** - claiming, qualifying against, quoting or editing a hidden client fails with the same message as for an id that does not exist;
- **lookups and counts** - `client_lookup` returns nothing for a hidden client; counts and lists never include it; no helper function answers "is this id a restricted client?" (any such boolean would be probe-able);
- **uniqueness** - duplicate detection covers discoverable clients only, so a colliding name does not fail for the creator; management gets a silent review item instead (`matching_reviews`);
- **dependents** - projects, leads and enquiries of a restricted client inherit its classification (`effective_classification`, maintained by trigger), so their `client_id` never points at a client the viewer cannot see;
- **matching** - enquiry matching never auto-links or lists a hidden client; the handler-visible explanation is deliberately neutral;
- **API responses** - the website's response is independent of anything already held.
`85_existence_leakage.sql` runs the same probe against a restricted id and a random id and requires identical outcomes, with control checks proving the probes can tell visible from hidden.

**Accepted limits (documented, not hidden):** response *timing* is not equalised; adding a contact by an email that already belongs to a person reuses that person, so the relationship holder then sees the stored name for that email; `client_lookup` intentionally lets people with `clients.create` discover non-restricted clients in other divisions (that is how duplicates are avoided).

## Lessons encoded as tests
- Postgres `AFTER UPDATE OF col` triggers do not fire when a BEFORE trigger (not the statement) changes `col`: event/queue triggers fire on any update.
- `pg_dump` records grants relative to the target's default privileges: restores neutralise permissive defaults and verify a security fingerprint.
- Row-security helpers called by policies are executable by every signed-in user, so each must only describe the caller's own access (an allow-list test reviews every executable function).
- `INSERT … RETURNING` re-checks the SELECT policy against the new row, so visibility predicates evaluate the row's own columns.

## Data classification
| Class | Examples | Who |
|---|---|---|
| public | published vacancies, published team profiles, public divisions | anyone via the public API |
| internal | clients, projects, staff directory | active staff per permission/scope |
| restricted | roles, audit, website registry, onboarding | specific permissions |
| confidential | applicant data, interview notes, offers, HR, finance | named permissions only |

## Secrets
Never stored as values. `event_subscriptions.secret_ref` and future credential records hold a *reference* to a
secret manager entry. Website API keys are shown once and stored as SHA-256 hashes. Database credentials,
JWT secrets and the service-role key live in environment configuration only — never in this repository, never in the web app.

## Operational requirements (not provided by the database)
Rate limiting and request validation in the public API handlers · MFA at the identity provider · TLS everywhere ·
encrypted off-site backups · rotating the website keys on compromise (`issue_website_key`) · separate dev/staging/production databases.

## Reporting
Run `./scripts/test-db.sh` after any change to a migration, policy, grant or function. A rule that is not covered by a failing test when broken is not yet protected.
