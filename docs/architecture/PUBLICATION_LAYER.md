# Publication layer — design contract (not yet implemented)

> **ADA Hub is the institutional source of truth. The website is not.** A public projection is a controlled, approved representation of an authoritative record; it is never a second record. **One authoritative record → many controlled representations.**

Naming: *ADA Hub* = the platform; *ADA Core Architecture* = identity, registry, data, rules, authorization, audit, routing and integration beneath it; *ADA IRM* = the internal management interface; *ADA Website / public websites* = controlled public interfaces over approved projections.

## What exists today (so the layer attaches without rewrites)
* **Entity Registry** — maps every institutional ID to its entity type and authoritative record, with origin, current division, status and classification.
* **`entity_types.publishable`** — the capability flag: may instances of this type EVER have a public projection? True for: staff profiles, services, portfolio entries, vacancies, divisions, programmes, courses, modules, documents, cohorts. False for everything else (tickets, assets, finance, clients, contracts, people, students …), and tested for tickets.
* **Existing public pattern** — `public_api` functions called by the `ada_public_api` role (no table privileges), website keys by hash and capability, events/outbox for cache revalidation. Staff profiles, services, portfolio entries and vacancies already have `status` workflows with `published` states and approval requests.
* **Events** — `emit_event` writes identifiers-only events to an outbox; websites subscribe for revalidation.

## The contract new modules must follow
1. **Publication is explicit.** Existence in the Hub never implies visibility. A publishable entity gets a publication state — `draft → pending_approval → approved → published → (updated) → unpublished/archived` — through the existing approval engine (`approval_gate`), not through a flag on the authoritative row.
2. **A projection is its own approved object, pointing at the record.** Conceptually `public_projections(institutional_id → registry, version, approved_fields, approved_by, published_at, state)`. It references the authoritative record by registry ID; it never stores identity attributes of the entity beyond the approved presentation fields, and it is rebuilt/superseded, never edited in place after approval.
3. **Field-level allow-lists.** A projection exposes only fields approved for the public (e.g. a staff profile: approved name, position, division, biography, image, public contact — never Staff ID, HR data, permissions, salary, notes). Related entities are not traversed: a public project does not expose its client; a public profile does not expose the staff record.
4. **Routing uses the registry.** Request → resolve entity → registry → check `publishable` → publication state → approved projection → field allow-list → response. No second public registry, no table queries from the website, no enumeration of internal records, no discovery of restricted entities, no arbitrary relationship traversal.
5. **The website is untrusted.** Knowing an ID grants nothing; visibility and authorization stay separate concepts. A record can be internally visible, publicly publishable, and publicly published — each independently — without exposing its authoritative record.
6. **Events drive freshness.** Authoritative change → audit → publication event → projection update (only if currently published and approved) → cache revalidation → website. Caches never override the Hub; a changed published entity falls back to *pending approval* when its public fields change.
7. **Routes are conceptual** (`/public/people`, `/public/divisions`, `/public/services`, `/public/projects`, `/public/vacancies`, `/public/portfolio`, `/public/programmes`, `/public/events`, `/public/publications`) — each a `public_api` function returning an explicit DTO, never a table.

## Applying it to the modules being built now
* **Tickets** — never publishable (`publishable = false`; no public columns).
* **Documents (built)** — the first module on this contract: `document_types.publishable` + `entity_types.publishable` say what may ever be public; `document_publications` is the projection (points at the document and ONE approved/signed version, allow-listed `public_title`/`public_description`, random `public_ref`, frozen once created); request → approval (`approval_gate` kind `document_publication`, no self-approval by default) → explicit publish; withdrawn automatically when the document is reclassified, archived, becomes critical or loses the version; re-checked on every read through the registry; `public_api.documents`/`document` with capability `documents.read`. Original design intent follows. `publishable = true` in the type map, but **no document is public by default**; a document becomes public only through a publication state; restricted/confidential documents can never be published; a published document exposes the file and approved metadata, not its links to clients, contracts or staff.
* **Organization Unification** (after Documents) — an organization will carry the public-facing identity only via an approved projection (e.g. a client logo on a portfolio entry requires the client's consent and approval), never by exposing the organization record.

## Not decided yet (deliberately)
Event/queue/cache technology; the projection table's exact shape; per-type field allow-lists; the public API transport. These are chosen when the publication layer is built, after Search, Dashboards and Reporting.
