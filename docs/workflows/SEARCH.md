# Search

ADA Hub Search is a **retrieval layer**, not a source of truth. It finds *authorized* records through the Entity Registry and the modules' own relationship tables. Nothing it holds is authoritative: every structure is derived from the records, linked back to them by institutional ID, and can be thrown away and rebuilt.

## Architecture
```
text ──► search_parse ──► request (JSON) ──► search_request_validate ──► search_execute ──► result
          (deterministic)   the one contract       (strict, whitelisted)   (SECURITY INVOKER: the caller's own row security, at every step)
```
* **The request** is the only way in: `{q, ids, types, status, division, related_to, as_of, limit, offset, facets}`. `search('type:client status:active zeta')` parses into it; a UI builds it; a *future interpreter* would build it from natural language. The interpreter is a translator behind Search, never a product, never required, and it never sees data before authorization. There is no AI in this module.
* **Exact IDs** (institutional or legacy `ADA-…`) go straight through the registry (`entity_resolve`): no index, no scan. Unknown and hidden IDs answer identically and are recorded as lookups in the existing security model.
* **Text** uses the derived `search_index`: normalised prefix tokens (all words must match, as prefixes), a tsvector, and trigram similarity on the label for near-spellings. Ranking is per row (no corpus statistics, so a hidden row cannot influence a visible row's rank).
* **Relationships** (`related:ID`, optionally `type:document`, `asof:2026-01-01`): the anchor's family (projects, contracts, quotes, invoices, tickets, assets of a client / project) plus documents (`document_links`), domains (`domain_relations`), communications (links, attachments of linked documents, and - for readers only - participants), each with its own history. The index is not needed to find them.
* **Suggestions** (`search_suggest`): labels of records the caller may see, 2+ characters, at most 10, no counts, no scores, no popularity, never an ID.

## What is indexed (and what never is)
`search_sources` (configuration, owner-maintained): per entity type a label and a few metadata attributes - expressions over the record's own columns that every viewer of the row can read. Clients and organizations (name, legal / trading name, registration number, e-mail, city, industry), suppliers, partners, people and staff (name, e-mail), projects, tickets, assets (tag, serial, make, model), documents (**title and description - metadata; no content exists in the database**), domains, websites, services, contracts, quotes, leads, programmes, cohorts, vacancies, tasks, divisions, and communication threads (a fixed label and the status only).
**Never indexed:** document or communication content, subjects, participants, message bodies, notes, storage references, hashes, personal identifiers beyond the above. A check constraint refuses content-like column names in the configuration, and a permanent test proves every configured column is readable by API users.

## Authorization
1. The functions are SECURITY INVOKER; the index rows are visible exactly where `entity_visible()` - the caller's row security on the authoritative table - says the record is. Matching, ranking, totals, facets and suggestions are computed over those rows only: a record the caller cannot see contributes nothing, not even to a count.
2. No staff identity (anonymous, a signed-in non-staff user, a suspended account, the service role, the database owner) ⇒ nothing.
3. Every candidate is re-read from its authoritative record with the caller's rights and compared with the index; a stale or unreadable row is never returned (and is queued for repair).
4. Document and communication authorization stays authoritative: Search shows metadata only, and content is read through `document_open` / `communication_read`.

## Restricted records
Same answers with and without them: results, totals, ranking, facets, suggestions, ID lookups, relationship search, errors. Proven differentially (a snapshot before and after hidden records of every kind are created must be identical for an uncleared caller). Critical records are recorded in security events as "no such entity". Query text is never stored.

## Historical search
`as_of` filters to entities that existed then (registry creation) and, for relationship search, to the relationships in force then (link / relation histories of documents, domains and communications). Caveats: labels are the *current* labels, an entity's family membership is current, and historical visibility uses today's authorization and classification.

## Freshness, rebuild, recovery
* Triggers on every source table keep the index current in the same transaction (`zz_search_refresh`). Registration happens first, so new records are searchable at once.
* `search_drift()` (service role) reports `missing`, `stale` and `orphan` rows; `search_process_queue()` repairs the entities Search found stale; `search_rebuild()` rebuilds everything from the authoritative records, safely beside live writes (it leaves correct rows alone and removes rows of unsearchable entities). `search_backup_manifest()` supports restore verification: after a restore the index is identical, and an emptied index rebuilds byte-for-byte the same.

## Cost and scale
The caller's row security is the authorization, so its cost is paid for every row that *matches*: the match is stated first (through four transaction-local settings read by `search_ctx_match`, a cost-1 half of the index policy that can only narrow what the caller sees), then authorization runs on the matches. Measured on a 400-client database: a query matching nothing ≈ 6 ms, a query matching 500 rows that the caller may see ≈ 70 ms (the first page is verified against the records; the rest is counted from the index), and a query matching 400 rows that the caller may NOT see ≈ 1.8 s (the platform's own client policy costs ~2 ms per denied row for a division lead). This is inherent to authorization-first retrieval; a leakproof pre-filter would need superuser-only `LEAKPROOF`, which hosted Postgres does not offer. Near spellings are tried only when nothing matches exactly. Candidates are capped at 500 (`capped` says so).

## Not built
Public search (waits for the Publication Layer and the Public API), full-text over documents or communications, semantic / vector indexes (the derived-index design admits one later, behind the same authorization), saved searches, search analytics, spelling suggestions beyond near-label similarity, any AI interpreter or assistant.
