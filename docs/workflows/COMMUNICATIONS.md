# Communications

An institutional **records layer** for communication: it records that an email arrived, a call took place, a meeting was held, a message was exchanged - against the entities it concerns - and keeps that record permanently, under the same identity, authorization and retention rules as the rest of ADA Hub. It is **not** a mail server or messaging platform: nothing here sends, receives or synchronises anything (no SMTP, IMAP, WhatsApp, SMS gateway, mailbox sync, delivery tracking, templates or notifications).

## Identity
* A **thread** (entity type `communication`, code `C9`) and each **message** in it (type `communication_message`, code `CM`) are separate registered entities, minted only through `attach_entity`. IDs are never chosen by a user, never change when the thread moves division, never reused. Nothing is deleted.
* The registry carries **no label**: a subject is content. Search finds communications by ID and metadata; content is read only after `communication_read` has authorised the caller.

## Structure
| Table | Purpose |
|---|---|
| `communication_threads` | the record: owning division, owner, classification (own + inherited), status, retention snapshot; the **subject** (content) |
| `communication_messages` | append-only: gap-free `seq` (assigned under the thread lock), type, direction, `occurred_at` vs `recorded_at`, reply-to, optional `source_system`/`source_reference` (idempotent, for a future connector), the **body** (content) and its SHA-256 |
| `communication_participants` | who took part, by **reference** to a registered person / contact / organization / staff; only for a party that is not yet a registered entity, the address *as typed* (`address_snapshot`). Added only in the transaction that recorded the message |
| `communication_links` | which entities a thread concerns (client, project, ticket, domain, contract, ...), with linked / removed history |
| `communication_attachments` | **an attachment is a Document**: this row only references it. File, hash, versions, retention and holds stay in the Documents module |
| `communication_access`, `communication_holds`, `communication_comments`, `communication_disposals`, `communication_events` | explicit grants, legal holds, internal notes (content), two-person disposal, append-only history |
| `communication_types` | approved kinds (email, phone_call, meeting, video_call, sms, instant_message, letter, other) - data, extended with `communications.configure` |

## Metadata vs content (the central rule)
* `communications.view` = **metadata**: that a thread exists, its type/direction/time of messages, status, classification label, linked entities, counts.
* `communications.read` = **content**: subject, participants, bodies, hashes, notes. Never granted to table readers (column privileges); the only way out is `communication_read`, which authorises, **logs every read**, and returns attachments only if the caller can also see the document.
* `communications.attachments` + the document's own right = opening an attachment (through `document_open`, which logs it as well).
* Separate again: `create`, `append`, `update` (details, links, close/reopen), `comment`, `share`, `archive`, `dispose`, `legal_hold`, `view_critical`, `configure`.
* Participation is content: finding "threads that involved this person" works only for threads the caller may **read**.

## Classification
A thread takes the strictest classification of everything it is linked to: linked entities, participants, and attached documents (a critical attached document makes the thread critical). Soft-deleted clients hide their correspondence. Classification applies **in addition to** authorization, never instead. Effective classification changes are recorded in the thread's history; historical queries are authorised against the *current* rules.

## Lifecycle
`open → closed ↔ open`, `open|closed → archived → closed`, `archived → disposed` (only through an approved disposal). Messages are recorded only while open. Reasons are required for status changes.

## Retention, holds, disposal
Reuses the Documents framework: `retention_classes` (new data rows `communications_standard` 5y, `communications_contractual_10y`), the same hold semantics, the same approval engine (kind `communication_disposal`, no self-approval). A hold on the thread **or on any attached document** blocks disposal. Disposal removes content only (subject, bodies, notes, address snapshots); identity, metadata, relationships, hashes and the event history remain. Nothing is destroyed automatically.

## Retrieval
`communications_for_entity(entity, from, to, as_of, include_children)` - request → registry → entity (→ its family) → authorization → communications, found by institutional ID through links, attachments (document → "what was sent about this") and, for readers, participants. `as_of` answers "as it stood then" from link/attachment history and message recording times. `communication_lookup`, `communication_360` (metadata only), `communication_retention_status`. Sections in Client, Project, Organization, Domain and Document 360.

## Security notes
Hidden threads answer exactly like missing ones (errors, counts, lookups, registry, audit log, security records); critical threads are recorded in security events as "no such entity". Validation that depends on hidden data lives in AFTER triggers or behind row security. The audit log carries redacted content columns (a disposed body must not survive in a permanent log). Not publishable; no public API.

## Not built
Sending/receiving/syncing of any kind, templates, notifications, delivery tracking, external share links, full-text search over content, resolving a participant address to a registered entity after the fact, AI of any kind.
