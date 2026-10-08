# Organizations

```
organizations   ← the ONE identity record of an external organization
   ├── clients     role / context   (client IDs, ADA-CLI aliases, every downstream FK unchanged)
   ├── suppliers   role
   └── partners    role (new)
```

An organization exists independently of any role. A company that is a client **and** a supplier **and** a partner is **one** `organizations` row with up to three role rows; a different relationship never creates a second organization. Organizations are registered entities (type `external_organization`, own permanent institutional ID, never public); each role keeps the identity it always had (client: ADA-CLI alias + institutional ID; supplier: ADA-SUP; partner: institutional ID).

## What lives where
| `organizations` (authoritative) | role tables |
|---|---|
| name, legal name, trading name, registration number, website, e-mail, phone, address, city, country, industry, social links; own classification floor; status | `clients`: account status, type, owner division, billing address, notes, classification, divisions, contacts, staff … `suppliers`: status, notes. `partners`: kind, status, since |

Downstream modules (projects, quotes, contracts, invoices, payments, tickets, assets, documents, finance links) keep referencing `clients(id)` / `suppliers(id)`. Nothing outside the role tables and the two review tables references `organizations` (a test pins this).

## Mirrors (compatibility, not copies)
`clients.name`, `registration_number` and the other identity columns, and `suppliers.name` / `registration_number` / `website`, and `partners.name`, are **trigger-maintained, readable mirrors** (`organization_mirror_columns` says which).
* A **direct write** to a mirror (any caller, the database owner included) is not stored on the role: it is **redirected** to `organization_apply`, the organization changes (uniqueness, normalisation and audit apply), every other role is re-synchronised, and the written row carries the organization's values.
* Recursion is prevented with transaction-local flags (`ada.org_sync`, `ada.org_skip`); a role's organization changes only through `organization_merge` (`ada.org_relink`).
* `organization_mirror_drift()` proves the absence of inconsistent states (tests, monitoring, the rehearsal and the concurrency test all assert zero). Client 360 reads identity from the organization (falling back to the mirror only if the organization is not visible to the caller), so even a tampered mirror never shows.
* `name_key` on clients stays a generated column over the mirror; the client-level uniqueness, duplicate-guard and hidden-duplicate behaviour of earlier migrations is unchanged.

## Creating and linking
`insert into clients|suppliers|partners` (or `client_create`, `organization_add_role`) finds-or-creates the organization (`org_attach`): the roles of **one** company meet the **same** organization, even when two sessions race (advisory locks on the name and registration keys). An organization is **reused only if** it is discoverable (public/internal), the new role is discoverable, exactly one organization matches **strongly**, and it does not already hold that role (one live client, one supplier, one partner per organization — database-enforced). A **hidden** (restricted/confidential) organization is never reused, never named and never errors: the new role gets its own organization and a silent review item.
`organization_create` (organizations.create) makes a roleless organization after the same checks; `organization_add_role(org, 'client'|'supplier'|'partner')` adds a role to an organization that exists; `organization_update` edits identity (organizations.update).

## Evidence (`org_match`)
* **strong** (same organization): registration numbers equal *and* names equal-or-similar (≥ 0.5); or normalised names equal with no contradicting registration number; or the same website host with a similar name (≥ 0.4).
* **ambiguous** (a human must decide): registration equal but names dissimilar; same name but **different** registration numbers; similar names (≥ 0.55) without deciding evidence; same website host alone; a strong match whose organization already holds the role.
* Strong matches link; ambiguous ones stay **separate organizations** with a row in `organization_reviews`. **Nothing ambiguous is ever merged by the system.**

## Reconciliation of existing data
`organization_reconcile()` (run once by migration 0038 itself; idempotent; service role) processes clients first (oldest first), then suppliers, applying the rules above: it links, creates (keeping the role's original `created_at`/`created_by`, origin_kind `migrated`), marks look-alike organizations `uniqueness_exempt` so ambiguity can coexist, and leaves review items. A closed (deleted) client of the same company joins the same organization as history. Role IDs, ADA aliases, relationships and audit rows are untouched; only `organization_id` (and mirrors) change, `updated_at` of re-linked rows is not bumped. `test-db.sh` upgrades a database that already holds clients and suppliers and checks all of this.

## Human review and merging
`organization_reviews` (open / resolved_same / resolved_distinct / dismissed) is readable by `matching.review` holders only. `organization_review_resolve(review, 'distinct'|'same'|'dismissed', note, [survivor])`: *distinct* records `organization_distinct_pairs` (never flagged again); *same* calls `organization_merge`. A merge is a human act: roles are re-pointed to the survivor (IDs unchanged), the survivor keeps its own facts and gains only the ones it lacked, the absorbed organization becomes a **tombstone** (`status = merged`, `merged_into_id`; its institutional ID keeps resolving and never changes or returns), open reviews about it move to the survivor. Merges are **refused** while both sides hold a live client, a supplier or a partner (resolve the duplicate role first) — a duplicate role is a business decision, not an automatic one.

## Visibility
A role's own rules still decide who sees the role. An organization is visible to those who can see one of its client roles, to supplier/partner viewers **who are cleared for its effective classification**, and to `organizations.view` holders (cleared). `effective_classification` = the strictest of the organization's own floor and its live client roles; raising the floor raises its clients (it never lowers them); a restricted client therefore hides its organization from everyone not entitled to it, and every probe (360, resolve, add role, update, merge) answers exactly like a random ID. Un-restricting a client whose organization now collides with a discoverable look-alike is refused until a human settles the review (the same rule clients always had).

## Lifecycle
`active` (has a live role, or none yet) → `dormant` (every role ended) → reactivated when a new role of the same company arrives (the same organization, never a duplicate) → `merged` (tombstone). Organizations are never deleted.

## Other integration
* `client_360` — `organization` section (institutional ID, status, which other roles exist) and identity read from the organization; all client-facing compatibility fields kept. `organization_360(org)` shows identity, the roles the viewer may see, and documents of the organization and its clients' families. `search` finds organizations by name. Documents can link to organizations directly.
* Permissions: `organizations.view|create|update`, `partners.view|manage`; reviews and merges use `matching.review`.

## Not built
Client/supplier record merging (a duplicate role is resolved by archiving one), organization hierarchies (parent/subsidiary, branches), contact points that are people (still `client_contacts` → `people`), an organization portal, auto-detected rebrands.
