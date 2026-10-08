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

## Finance (contracts, invoices, payments)
* **Same rules, no special cases.** Finance tables inherit the client's classification (`effective_classification`, `client_deleted`) by trigger, in both directions; visibility policies read only the row's own columns. `92_finance_restricted_clients.sql` (permanent) probes contracts, versions, lines, billable items, invoices, balances, payments, allocations, reversals and the approvals queue with a restricted id vs a random id, and checks propagation on restrict, un-restrict, delete and restore.
* **Uniqueness cannot leak.** Payment references are unique per client only; the cross-client duplicate check is made by `payment_record` against payments the caller can see. Not-found errors for child ids (lines, allocations, reversal requests) are identical to the parent's, so a hidden record cannot be told from a missing one by which message appears.
* **The queue is classification-aware.** `approval_requests.classification` (decided requests included) gates who sees a request; notifications for restricted records are not broadcast.
* **Immutability is enforced for every caller**, including the database owner: signed contract versions, issued invoices (content and snapshots), recorded payments, billable items, status trails.
* **Money is derived.** Invoice balances and payment credit are computed from allocations; locks serialise allocation so racing sessions cannot overspend a payment (parallel test).
* **Approvals** use the one engine (`approval_gate`); reversal and refund default to no self-approval.

## Assets
Same model as finance (see above), plus: no unique index on serial or tag (existence oracle) — duplicates are flagged, and a flag is readable only by someone who can see both assets; a holder sees the asset they hold but classification still wins; a project must be visible, its client visible and its classification visible before anything can attach to it (membership alone is not enough); tickets and every attached record inherit; `96_asset_restricted.sql` is permanent.

## Identity, routing and investigation
* The registry is readable only through the caller's own row security on the authoritative table (`entity_visible`, SECURITY INVOKER): a restricted entity and a non-existent one are indistinguishable from `entity_resolve`, `entity_get`, `search_route`, the registry, the directory and the search index. `98_institutional_identity.sql` is permanent.
* Denied or unresolved lookups are recorded (actor, action, internal exists-flag, classification, session, source) and escalate by policy: flag → case → critical. The actor never sees the log. A command that raises rolls back its own log row; gateways report with `security_report_denial`.
* IDs encode only immutable facts and are opaque; the scramble key is permanent; `ada_mint_id` is not executable by API roles.

## Lessons encoded as tests
- Postgres `AFTER UPDATE OF col` triggers do not fire when a BEFORE trigger (not the statement) changes `col`: event/queue triggers fire on any update.
- `pg_dump` records grants relative to the target's default privileges: restores neutralise permissive defaults and verify a security fingerprint.
- Row-security helpers called by policies are executable by every signed-in user, so each must only describe the caller's own access (an allow-list test reviews every executable function).
- `INSERT … RETURNING` re-checks the SELECT policy against the new row, so visibility predicates evaluate the row's own columns.
- A global unique index over records of differing visibility is an existence oracle (and can make un-restricting fail): uniqueness is per visible scope, with the cross-scope check made in the command against what the caller can see.
- A parent-lookup error that differs from the child-lookup error is an oracle too: lookups of line/allocation/request ids report the same 'not found' as the parent.
- A history table that is not reclassified with its subject leaks: decided approval requests follow the client's classification.
- `AFTER UPDATE OF col` triggers silently skip changes made by a BEFORE trigger: classification propagation (assets, tickets) fires on any update and compares inside the function.
- A migration that wires triggers by looking at existing ROWS leaves a fresh database unwired: wire from the type map, not from data.
- A test file that never calls `tests.finish()` silently reports nothing: the runner fails such files.

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
