# The ADA organizational graph

> **One organization → one core → one source of truth → many controlled interfaces.**
> Before adding anything, ask: *does this information already exist in ADA Core?* If yes, **reference it**.
> If not, design it as a central entity or relationship, then let internal and public views consume that record.

## What each thing is, and where it lives (exactly once)

| Thing | The one place | Everything else… |
|---|---|---|
| A human (applicant, hire, client contact) | `people` (`ADA-PER-…`) | references `person_id`; **relationship tables** decide who may see it |
| A client company | `clients` (`ADA-CLI-…`) | references `client_id`; divisions join it via `client_divisions`; duplicates are blocked |
| A client's contact | `client_contacts` (`ADA-CON-…`) = person + role at a client | projects and quotes reference this row |
| Staff | `staff` (`ADA-STF-…`), one per person ever (`staff.person_id`) | roles, assignments, projects reference `staff_id`; history in `staff_assignments` |
| A service | `services` (`ADA-SVC-…`) | quotes, projects, websites, reports reference `service_id` |
| A price | `service_prices` (immutable versions) | quote lines and project services copy the amount **and** point at the version used |
| A quote | `quotes` (`ADA-QUO-…`) + `quote_lines` | references client, contact, division, project, services, price versions |
| A project | `projects` (`ADA-PRJ-…`) | the container: client, contacts, services, quote(s), staff, tasks, milestones, portfolio |
| Public view of a finished project | `portfolio_entries` (`ADA-PFO-…`) | a consent-gated projection, not a copy of the project |
| Public view of a person on staff | `staff_profiles` (`ADA-PRF-…`) | an approved projection, not the staff record |
| An opening / an applicant's application | `vacancies` / `applications` | position ≠ vacancy; person reused |
| A connected website | `websites` (`ADA-WEB-…`) | is the *identity* of incoming requests |
| Anything awaiting approval | `approval_requests` | uniform queue + history across all modules |
| Everything that happened | `audit_log`, `events` | append-only memory; outbox for websites |

```text
                         ORGANIZATION
                              │
      ┌───────────────────────┼────────────────────────┐
   DIVISIONS ──┬─── POSITIONS ─── VACANCIES ─── APPLICATIONS ─┐
      │        │                                              │
      │      STAFF ◄──────────────── (hired) ◄──────── PEOPLE ◄── CLIENT CONTACTS
      │     (assignments, roles)                         ▲            │
      │        │                                         │            │
   SERVICES ───┼───────────────┐                         │         CLIENTS ◄── (claimed by divisions)
      │        │               │                         │            │
   PRICE      PROJECT ◄── QUOTE (lines snapshot price versions)  ◄──┘
  VERSIONS   (members, tasks,   │
      │       milestones,       └── accepted ⇒ converts, once, into the project
      │       contacts,
      │       services bought) ──► PORTFOLIO (consent + approval) ──► PUBLIC API ──► websites
      │
      └──────────────────────────► PUBLIC API (approved services + current price) ──► websites

  Still to be attached to the SAME records: contracts, invoices, payments, expenses, assets, tickets,
  documents, domains, communications. Each will reference client / project / staff / person, never copy them.
```

## Relationships carry privacy, not the record
A person may be an applicant, a client contact and a staff member at once; that is **one** `people` row.
What each viewer may see follows the *relationship*:

- a client team sees a contact's name/email/phone (through `client_contacts`) but **not** that the person applied for a job;
- a recruiter sees the applicant but **not** their client-contact relationships;
- none of it is public: public data is projected only through `staff_profiles`, `portfolio_entries`, services, vacancies and divisions, each with its own approval.

## Duplicate prevention without leaking
Row-level security hides other divisions' clients, which would normally *cause* duplicates. ADA avoids that:
`client_lookup()` finds matches (by normalised name, registration number, contact email) revealing only what the caller may know;
`claim_client_for_division()` makes your division a participant in the existing record (the owner is notified);
creating a second record with a matching name or registration number is refused with a message pointing at the existing one;
restricted/confidential matches are refused with a generic message and are never claimable.

## Prices and history
`services` → `service_prices` (version 1, 2, 3 … with `effective_from/to`). A change is *proposed*, approved by someone other than the proposer
(unless they hold `pricing.approve_own`), and never edits an approved version. Quote lines and project services copy the amount used and keep `price_id`.
A July 2026 invoice therefore still shows N$5,000 when the catalogue price later becomes N$6,000.

## The 360° views
`client_360`, `project_360`, `staff_360` are **SECURITY INVOKER** functions made of ordinary queries: they inherit row-level security, so a section a viewer
may not read is simply empty and a record they may not see returns `null`. There is no second copy of the access rules. Sections for modules not built yet are listed under `pending`.

## Guards that enforce "reference, don't duplicate"
The structure suite fails the build if a new module adds its own name/email/phone column (it must reference `people`/`clients`/`staff`), if a table points at anything but `clients(id)` for a client,
if a record with an ADA ID is not in `entity_registry`, or if a new executable function is not reviewed.

## Open decisions for the next modules
| Question | Recommendation |
|---|---|
| ID prefix for assets: your master prompt says `ADA-AST-…`, your latest note says `ADA-ASM-…` | pick one before the assets module; the prefix is a one-row change in `entity_types` |
| Documents link to many entity types (client, project, staff, vacancy, application, quote, invoice, asset, ticket, domain, website) | one `documents` table + `document_links(document_id, ada_id → entity_registry)`; access resolved per linked entity |
| Invoices | reference client, project, quote, division and *copy* the quote/project line snapshots; payments reference invoices; a client's lifetime value becomes a query |
| `project_financials.revenue_to_date / cost_to_date` | remove when invoices, payments and expenses exist (derived, not stored) |
