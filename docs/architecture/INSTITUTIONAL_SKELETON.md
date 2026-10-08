# ADA Core Institutional Skeleton

> **One organization → one core → one institutional skeleton → one source of truth → many controlled interfaces.**
> The skeleton is the institutional *map* of the relational database. It is not a second source of truth.

| Layer | Purpose | Where |
|---|---|---|
| Authoritative record | the actual business data | the domain table (`assets`, `clients`, `students`, …) |
| Entity Registry | what is this, where does it belong, where is its authoritative record | `entity_registry` |
| Search index | fast retrieval, rebuildable | `search_index` (derived) |
| Codebook | the formal meaning of every code in an ID | `id_codebook` (versioned) |
| ID service | the one generator of permanent IDs | `ada_mint_id()` |
| Security | denied/unresolved lookups, escalation | `security_events`, `security_cases`, `security_policies` |

## The permanent institutional ID
**9 characters, `A–Z 0–9` only** (the 32-symbol alphabet drops `I L O U` so IDs survive printing, scanning and phone dictation). No hyphens, spaces or punctuation.

```
 T T  C  S S S S S  K
 │ │  │  └───────┘  └─ check character (odd weights mod 32: any single wrong character is detected)
 │ │  └─ issue cycle (codebook: the year of issue)
 └─┴─ entity type code (codebook: asset, student, staff, invoice, …)
      scrambled serial: a keyed 4-round Feistel permutation of a gap-free counter per (type, cycle)
```
* **Opaque:** the type and cycle codes are random-looking codebook entries (not letters of the name); the serial is scrambled with a per-database secret key, so neighbours are unrelated and cannot be guessed.
* **Collision-free by construction:** the scramble is a bijection of the counter; the counter is incremented inside the registering transaction (row-locked upsert). A rolled-back registration leaves no gap and consumes nothing; an ID is never reused (registry rows are never deleted; a removed record's entry is marked `removed`).
* **Capacity:** 33,554,432 IDs per entity type per issue cycle. The codebook seeds cycles for 2024–2055; extending it is a new codebook version.
* **Only immutable facts are encoded.** What kind of thing it is and when it was issued. Never division, owner, location, status, job, programme, assignment or project state. Those are registry attributes that change without touching the ID.
* **Users never choose or type an ID.** `ada_mint_id` is not executable by API roles; registration functions return the generated ID (`asset_register`, `student_admit` return `institutional_id` and the origin card).

The scramble key lives in `id_settings` and **must never change** once IDs exist (it would break uniqueness); it travels with backups. A database rebuilt from migrations alone gets a fresh key — IDs are meaningful only together with their database's data.

## The codebook (`id_codebook`, versioned)
`kind` = `type` (2-char entity type code → entity type, family), `cycle` (1-char → year), `division` (2-char → division, for internal templates; **not** embedded in IDs), `family`. Entries are retired, never edited or reused (guarded for every caller). `entity_types` carries the routing map for each type: family, domain table, which column holds division, status, classification and physical location, label column, and the 360 function.

Documents are now a built type (`document`, code `DOC`): see [DOCUMENTS](../workflows/DOCUMENTS.md).

Families and reserved types (47 types, all codes allocated now; tables attach later with one call): **people_org** organization, person, staff, position, vacancy, student, client, contact, supplier, partner, division, profile · **commercial** lead, enquiry, quote, contract, invoice, payment, credit note, expense, service · **operations** project, task, milestone, asset, ticket, document, domain, website, application, portfolio, communication · **academy** programme, course, module, cohort, enrollment, assessment, result, attendance, certificate, academic record · **governance** approval, investigation case, audit event, notification, policy, authorization record.

## The Entity Registry (`entity_registry`)
Per authoritative record: `institutional_id` (primary key) · `entity_family`, `entity_type` · **origin** (`origin_division_id`, `origin_year`, `origin_cycle`, `origin_kind`: created / admitted / hired / detected / migrated — immutable) · **current** (`current_division_id`, `current_location`, `status`, `classification`, `authorization_scope`, `routing_version` — mirrored from the authoritative record by trigger, so it cannot drift) · **pointer** (`table_name` + `entity_id` = authoritative domain + record key) · `created_by`, `created_at` · `ada_id` = **legacy identifier**. Nothing else: a structural test fails if a business column appears. Movement is kept in `entity_location_history` (registered → moved …). `entity_directory` presents the same data under the institutional field names.

### Legacy identifiers (migration strategy)
`ADA-AST-2026-0001`-style identifiers stay: immutable `audit_log` rows, events and documents already refer to them. Each became the **alias** of its new permanent ID (`ada_id` / `legacy_identifier`, unique, resolvable). Existing rows were backfilled with institutional IDs in creation order (`origin_kind = migrated`, cycle from `created_at`). New audit rows also carry `record_institutional_id`; older ones join through the registry on `record_id`. Contacts' earlier `ADA-CON`→`ADA-CTC` rename is unaffected. New tables need no legacy identifier: `attach_entity(table, type)` registers with an institutional ID only (programmes, cohorts, students, enrolments and security cases do this); `attach_ada_id` keeps legacy-plus-institutional for the earlier modules.

### Registration (one path)
`BEFORE`/`AFTER INSERT` on the authoritative table → validate (the table's own constraints) → `ada_mint_id` → registry row (origin from the record's division column) → location history. All in the caller's transaction: **atomic**. `registry_sync_trigger` keeps current division/location/status/classification in step and records movement; a deleted record is marked `removed` and keeps its ID.

## Routing and retrieval (registry first)
`entity_resolve(id)` → registry only (the primary key / legacy alias, never a table scan; verified by plan) · `entity_get(id)` → resolve, then the authoritative record through the type's 360 function · `search_route(q)` → an ID goes straight to the registry; free text goes to the derived `search_index`. A search index row exists only to find an entity; it is rebuilt from the authoritative records by `search_rebuild()` (tested: delete and rebuild reproduces it) and is never consulted for identity.

## Authorization hooks
Registry and index rows are filtered by `entity_visible(table, id)` — a SECURITY INVOKER check that runs the caller's own row-level security against the authoritative table. So the registry **cannot reveal** an entity the caller cannot read: a restricted entity and a non-existent one give identical results (`null`) from `entity_resolve`, `entity_get`, `search_route`, direct registry/index queries and the directory view. Classification alone never grants access; the authoritative domain's policy (role, division scope, relationship, classification) decides. Every request carries the authenticated actor (`current_staff_id()` / `auth.uid()`).

## Security investigation
A denied or unresolved lookup is recorded in `security_events` (actor staff/user, action, input, whether the entity exists *internally*, its classification, session, source address). Escalation is data (`security_policies`): 5 within 10 minutes → **flag**; 15 within an hour → **investigation case**; a bypass attempt (`security_report_bypass`, service/gateway) → **critical case at once**. Each case is itself an institutional entity (`investigation_case`), references the whole pattern, notifies `security.view` holders without naming any entity, and is worked with `security_case_update` (`security.manage`, resolution required). The actor can never see the log, and the answer they receive never depends on whether the entity exists. **Limit:** an error raised by a command rolls back its own transaction, so in-database logging covers functions that *return* (the resolve/get/search family); gateways report observed failures with `security_report_denial`.

## Academy and people
`students` is a **role of a person** (`person_id` unique → `people`; no name/email/phone). `student_admit` creates the Student entity and its permanent ID; programme and cohort changes are rows in `student_enrolments` (history), never identity changes. Staff follow the same rule: the Staff ID is minted when the staff record is created and survives position, role, division and even departure. `person_relationships(person)` shows one person through every role the viewer may see (staff, student, contact, applicant), each with its own institutional ID.

## Publication readiness
`entity_types.publishable` marks the types that may ever have a public projection; everything else never crosses the public boundary. The registry is the router the future publication layer will use (entity → authoritative record → publication state → approved projection). See [PUBLICATION_LAYER.md](PUBLICATION_LAYER.md).

## Open decision: external organizations
Today the external organization is the `clients` record, and `suppliers` is a separate table. The directive's ideal — one `organizations` record that clients, suppliers and partners reference, so a company that is both client and supplier is one record — requires moving name, registration number and address out of `clients` into that record, which touches `client_create`, matching, the 360 views and a large part of the test suite. It is deliberately **not** done inside this foundation. Recommendation: do it as its own migration right after Tickets/Documents are attached, using this registry (`organization` type is already reserved with a code).
