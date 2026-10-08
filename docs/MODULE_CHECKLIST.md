# Adding a module to ADA Core: the checklist

> **The central record rule (non-negotiable).** A business entity gets ONE authoritative record in ADA Core.
> Other modules **reference** that record; they do not copy its identity fields.
> Entities under this rule: people, clients, contacts, staff, services, pricing, projects, assets, domains, websites.

Before writing a migration, answer these in the pull request.

## 1. Does it already exist?
- [ ] I searched [ENTITY_GRAPH.md](architecture/ENTITY_GRAPH.md) and the [data dictionary](architecture/DATA_DICTIONARY.md) for the thing I am about to store.
- [ ] Every link to a client / person / contact / staff / service / project / asset / domain / website is a **foreign key** to its central table.
- [ ] I did **not** add columns such as `client_name`, `client_email`, `client_phone`, `staff_name`, `contact_name`.
- [ ] **Identity comes from the skeleton** ([INSTITUTIONAL_SKELETON.md](architecture/INSTITUTIONAL_SKELETON.md)): add the entity type to the codebook (`entity_types` row with its family, routing map and ID code), then register the table with `attach_entity(table, type)` (or `attach_ada_id` if it also needs a legacy-style identifier). Never write an ID generator, never accept an ID from a form, never encode mutable facts (division, status, owner, location) in an ID.
- [ ] The registration function returns the generated institutional ID (and origin/status) to the caller.
- [ ] Division, status, classification and location are declared in the type's routing map so the registry mirrors them; origin is taken at creation.

## 2. Snapshots are explicit
A copy of a value is allowed only when history or law requires it (a price on an invoice, what a stranger typed into a form).
- [ ] The column name says so (`submitted_*`, `*_snapshot`) and its column comment **starts with `SNAPSHOT:`** and says what it is a snapshot of.
- [ ] Nothing reads the snapshot as the live value once the central record is resolved.
- [ ] The identity-columns allow-list in `30_structure.sql` was updated, with a reviewer's explicit approval.

## 3. Privacy is by relationship, never by identity
Two modules referencing the same person or client do **not** share each other's private data.
- [ ] Visibility policies read only the row's own columns plus permission helpers. No helper answers "does record X exist / is it restricted?" for an arbitrary id.
- [ ] Records that belong to a restricted client inherit its classification (`effective_classification`).
- [ ] Errors, counts, lookups and API responses are **identical** for "does not exist" and "exists but you may not know" (see `85_existence_leakage.sql`; add probes for your entity).

## 4. Controlled paths
- [ ] Creation of anything that could duplicate a central entity goes through a function that searches first (`client_create`, `add_client_contact`, ...), and direct `INSERT` is not granted.
- [ ] Status changes go through a transition function; direct updates of status columns are rejected for every caller.
- [ ] Anything needing approval calls `approval_gate()` ([APPROVALS.md](workflows/APPROVALS.md)); no new `*_own` permissions.
- [ ] Public exposure is a `public_api` function returning an explicit DTO of published data, and the website capability is declared.

## 5. Tests that must exist for the module
- [ ] **No duplication:** create the entity through one division/website, reach it through another, and prove the same record is resolved (e.g. client created in Web, enquiry through Tech).
- [ ] **No duplicate people:** person + contact + applicant/lead resolve to one `people` row, and each relationship stays blind to the others' private data.
- [ ] Authorization (who can, who must not), RLS, direct-table access, anon/authenticated/website roles.
- [ ] Workflow transitions (valid and invalid), locking after submission, history, audit, events (without personal data).
- [ ] **Every access predicate returns a definite boolean** (wrap with `coalesce(..., false)`; add the helper to the NULL-safety list in `100_tickets.sql`): in plpgsql, NULL fails an `IF` and silently grants access.
- [ ] Soft-delete/archive visibility, institutional ID format and registry membership (`tests.unregistered_tables()` covers every built entity type), restricted-vs-nonexistent through `entity_resolve`.
- [ ] Immutability of anything historical (prices, financial amounts, decisions).
- [ ] Mutation check: break your main rule on purpose and confirm a test fails.

## 6. Regression protection
- [ ] `./scripts/test-db.sh` passes in full, including every earlier suite. **Do not delete or weaken an existing check to make work easier.**
- [ ] `supabase/tests/PROTECTED.txt` lists the checks that must never disappear; `scripts/check-protected-tests.mjs` fails the build if one does. Replacing a protected check with a stronger one requires updating that file in the same commit and explaining why.
- [ ] `./scripts/rehearse-migration.sh` passes (new extensions are added to `scripts/restore.sh` and the deployment docs).
- [ ] `./scripts/gen-docs.sh` was run and the regenerated docs committed.

## 6b. Publication readiness
- [ ] Decide `entity_types.publishable` for the new type. If true, public exposure will be a separate, approved **projection** with a field allow-list ([PUBLICATION_LAYER.md](architecture/PUBLICATION_LAYER.md)); do NOT add public/visible flags or public copies of fields to the authoritative table.
- [ ] Nothing in the module is reachable by the website role except through an explicit `public_api` function.

## 7. Documentation
- [ ] ENTITY_GRAPH.md row(s), the module's workflow doc, PUBLIC_API.md (if public), SECURITY.md (if it adds a rule), `client_360` / `project_360` / `staff_360` sections.
