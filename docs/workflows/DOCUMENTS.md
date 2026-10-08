# Documents

Documents are an **institutional records layer**, not "upload → filename → download". Three things are kept apart:

| | What | Where |
|---|---|---|
| **Identity** | the permanent institutional ID (9 characters, opaque, issued centrally through `attach_entity`; no document-specific generator, no user-chosen ID). Never changes when the document moves division, project, folder, storage or owner. | `entity_registry` (type `document`, family operations) |
| **Record** | type, title, classification, **origin** division (fixed) and **current** division, owner, creator, dates, status, retention, critical flag | `documents` |
| **Content** | the file, held **by reference** (provider + opaque key) with its SHA-256; never part of the identity, never exposed to metadata viewers or the public | `document_versions` |

Relationships live in `document_links` (institutional ID → registered entity: organization/client/supplier/person/staff/project/ticket/asset/contract/invoice/…). Nothing about the target is copied: no client name, e-mail or project title columns exist (a structure test enforces it). Contacts follow the People architecture (person → organization → contact); a signed version is itself the historical evidence of who signed.

## Access is a decision, not a label
`document_can(document, action)` — one definite boolean per action: **view/discover** (one gate: the right to know the document exists and read its metadata), **read** (content), **download**, **upload**, **edit**, **comment**, **share**, **approve**, **publish**, **archive/restore**, **request_disposal**, **dispose**. The decision combines staff identity (active session), the permission in the owning division (`documents.*`), ownership (view/read/download/upload/edit/comment only), explicit grants, classification (`classification_visible`), soft-deleted client/project state, relationships and document status (archived: read/download/restore/disposal only; disposed: metadata only). **Classification alone grants nothing**; a grant never overrides it. Every non-view action also requires view.

Entity visibility ≠ metadata visibility ≠ content access ≠ modification rights: the auditor can see a document and its version list yet is refused the download and every change; division staff can read but not edit documents they do not own.

### Classification
The platform's four levels plus an explicit critical flag. Policy mapping of the L0–L5 examples: L0 public → `public`; L1 → `internal`; L2 → `restricted`; L3 → `confidential`; **L4/L5 critical → `is_critical`**. A document inherits the **highest classification of what it is linked to** (a restricted client makes its documents restricted; un-restricting lowers them again), and follows client/project soft-deletion.

### Critical documents
Visible only to the owner, to explicit grantees (expiring, with a reason) and to `documents.view_critical` holders. They are absent from search, counts, relationship lookups, Client/Project 360, `entity_resolve`/`entity_get`, the registry and directory, `document_events`, the audit log (`audit_select` is filtered by `audit_document_visible`), and the security records (a probe of a critical document is recorded exactly like a probe of an ID that was never issued; an integrity event names no critical document). Approval requests for them are filed under `confidential`.

### Explicit grants
`document_share` (needs `documents.share`): named person or division, actions limited to view/read/download/comment, optional expiry (required for critical), reason required; `document_unshare` revokes at once.

## Versions
`draft → review → approved → signed`, or `withdrawn`. Enforced for every caller, the database owner included:
* the **content columns** of a version (hash, size, type, file name, uploader, upload time, which version it amends) are permanent; a metadata edit is never a content change (`document_update` changes title/description/dates/owner only);
* an **approved** version is frozen; a **signed** or **withdrawn** version is immutable;
* approval goes through the approval engine (`document_version` kind): the submitter cannot approve; signing needs a date (not in the future) and a note naming who signed;
* an **amendment is a new version** that records the signed version it amends (`amends_version_id`); identical bytes are refused;
* drafts and versions under review are private to people who can upload or approve; viewers get approved/signed (and withdrawn, as history).

`document_open(document, 'read'|'download', [version])` authorises, **logs every read and download**, and returns the storage reference for the storage service to turn into a short-lived delivery; entitled-looking-but-denied callers get `NULL` plus a lookup security event (hidden and missing behave identically). The reference changes only through `document_relocate_content` (`documents.configure`, or the storage service) — the hash, state and identity stay.

## Integrity
`document_record_integrity_check(version, observed_hash)` (documents.configure) and `document_service_integrity_check` (service role) compare the storage layer's hash with the recorded one and append a `document_integrity_checks` row. A mismatch or missing file is a **security event of kind `integrity`** (policy: immediate `open`/`high` case in the existing investigation model) and the content is withheld until a later check matches.

## Historical review and Project 360
Requests resolve **Request → time interpretation (`period_resolve`) → registry → entity (→ its family) → authorization → documents**. `documents_for_entity(entity, from, to, as_of, include_children, signed_only)` finds documents by institutional ID in `document_links` (client → its projects, contracts, quotes, invoices, tickets, assets; project → the same), applies the caller's row security, and answers "as of" a moment from the link, version and state history (`document_version_as_of`): "the signed contract", "what was attached then". No table or blob scan. `client_360`, `project_360`, `staff_360` and `asset_360` carry a `documents` section (asset_360 keeps the interim `documents` list and adds `document_records`), each independently authorised by the documents' own row security.

## Search
Titles reach `search_index` through the entity map (`label_col = 'title'`); the index is derived, rebuildable (`search_rebuild()`), visible only for documents the caller may see, and never the only place a relationship exists.

## Retention, legal holds, disposal
* `retention_classes` (permanent, 10-year contract, 7-year financial/personnel, 5-year general, 1-year transient) + a **snapshot** of the period on each document (changing a class never silently shortens a held record); retention changes only through `document_set_retention` (`documents.configure`, reason).
* `document_retention_status` (derived view): end date, review due, legal hold, disposal eligibility, disposition — nothing stored.
* **Legal holds** (`documents.legal_hold`) override disposal at every layer, including a direct database update.
* **Disposal**: archive → request (retention elapsed, no hold, not permanent) → a **different** person with `documents.dispose` approves → storage references are detached into `document_disposals.purge_manifest` for the storage service, which confirms (`document_disposal_confirm`). Identity, metadata, hashes and history remain. Nothing is ever disposed or deleted automatically; documents, versions, links and events are never deleted.

## Publication
`document_types.publishable` and `entity_types.publishable` say what may ever be public; **publishable ≠ published**. The flow is request (`documents.publish`; document must be active, **public**-classified, non-critical, of a publishable type, with an approved/signed version; an explicit public title is required — the internal title is never published) → approval by someone else (`documents.approve`, kind `document_publication`) → explicit `document_publish`. The projection (`document_publications`) points at the authoritative document and one version, uses a random `public_ref` (not the institutional ID), is frozen once created, and is **withdrawn automatically** when the document is reclassified, archived, critical, or its version withdrawn; the public view re-checks eligibility and the registry entry on every read. `public_api.documents` / `public_api.document` (capability `documents.read`) return `ref, title, description, type, document_date, published_at, file{mime_type, size_bytes, sha256}` and nothing else. `document_public_content_ref` (service role only) is how the delivery service turns a public ref into a storage reference. Events `document.published`/`document.unpublished` carry only the public ref.

## Audit and security
Every change is in `audit_log` (with actor and institutional ID) and in the document's own append-only `document_events` (creation, metadata, version added/state, classification, link added/removed, shares, publication, archive/restore, transfer, retention, holds, disposal, integrity, relocation, **opens and downloads**) — always with the staff identity; opens/downloads are visible to auditors and approvers only. Repeated denied access raises flags/cases through the **existing** `security_events`/`security_cases` model (no documents-only alarm). Denials that raise (commands) are reported by the gateway with `security_report_denial`.

## Recovery
`document_backup_manifest()` (service role) fingerprints records, versions (hashes and references), links, history and registry entries. `scripts/rehearse-migration.sh` builds documents (signed version, amendment, hold, restricted and critical files), backs up, restores into a new database, and proves the manifest is identical, registry entries survive, immutability and append-only history still hold, access is unchanged and new document IDs keep being minted without collision.

## Not built
No upload/preview service (the storage layer supplies provider, key and hash), no OCR/full-text content search, no e-signature capture (a signed version records who and when), no per-document retention-review reminders, no document templates or generation, no external sharing links. Organization Unification will let `document_links` point at the unified organization entity.
