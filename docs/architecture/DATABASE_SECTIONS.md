# ADA Core — how the database is arranged (sections), and where the website admin data goes

_Status: PROPOSAL for the owner's approval. Nothing in the database has been changed by this document. Written 13 October 2026 from the live ADA Core project (139 tables, migrations 0001–0055) and the website repository `ada-main-website` (`/admin`)._

## 1. What you asked for

* One place for everything, but **arranged by section** — careers and staff in one place, each **division** in its own workspace — instead of one long mixed list.
* Pick a division, pick what to edit (services, prices, packages, team, news …), change it, **save**, and it is saved.
* **Live facts** on the websites (prices, positions, staff names, news) follow the database: change a price in ADA Core and the website shows it, with no redeploy.
* Move what the current Administrator system holds into ADA Core, and retire its separate database.

## 2. The arrangement (13 sections, every one of today's 139 tables placed)

The tables stay in one PostgreSQL database and one schema (`public`). That is deliberate (§6): the sections are a **catalogue** that the Hub's navigation, the data dictionary and the documentation all share, not 13 databases and not 13 schemas.

### 1 Identity, access & audit
Who someone is, what they may do, and the record of what they did.

`audit_log`, `event_deliveries`, `event_subscriptions`, `events`, `notifications`, `permissions`, `role_permissions`, `roles`, `security_case_events`, `security_cases`, `security_events`, `security_policies`, `staff`, `staff_assignments`, `staff_private`, `staff_roles`, `websites` (17 tables)

### 2 Organization & divisions
The agency itself, its divisions and positions, and every external organization (clients, partners, suppliers are roles of one record).

`divisions`, `entity_location_history`, `entity_registry`, `entity_types`, `id_codebook`, `id_codebook_versions`, `id_counters`, `id_sequences`, `id_settings`, `organization`, `organization_distinct_pairs`, `organization_mirror_columns`, `organization_reviews`, `organizations`, `partners`, `positions`, `suppliers` (17 tables)

### 3 People, careers & hiring
One record per human; vacancies, applications and hiring steps; staff public profiles.

`application_offers`, `application_reviews`, `application_status_history`, `applications`, `onboarding_tasks`, `people`, `staff_profiles`, `vacancies` (8 tables)

### 4 Academy
Programmes, intakes and students (academic identity, separate from the person).

`cohorts`, `programmes`, `student_enrolments`, `students` (4 tables)

### 5 Clients, leads & matching
Clients, their contacts and divisions, enquiries and leads, duplicate review.

`client_contacts`, `client_distinct_pairs`, `client_divisions`, `client_staff`, `clients`, `enquiries`, `enquiry_candidates`, `leads`, `matching_reviews` (9 tables)

### 6 Services, prices & catalogue
The ONE service catalogue, immutable price versions, and the approval queue behind price changes.

`approval_decisions`, `approval_policies`, `approval_requests`, `service_prices`, `services` (5 tables)

### 7 Projects & delivery
Projects, participating divisions, members, tasks, milestones, portfolio entries.

`milestones`, `portfolio_entries`, `project_contacts`, `project_divisions`, `project_financials`, `project_members`, `project_services`, `projects`, `tasks` (9 tables)

### 8 Sales & contracts
Quotes and contracts (with versions).

`contract_lines`, `contract_projects`, `contract_status_history`, `contract_versions`, `contracts`, `quote_lines`, `quotes` (7 tables)

### 9 Finance
Billable items, invoices, payments, credit notes, expenses, billing schedules, bank accounts.

`bank_accounts`, `billable_items`, `billing_schedule_runs`, `billing_schedules`, `credit_note_allocations`, `credit_note_lines`, `credit_notes`, `expense_categories`, `expense_events`, `expenses`, `finance_settings`, `invoice_lines`, `invoices`, `payment_allocations`, `payment_reversals`, `payments` (16 tables)

### 10 Assets & support (tickets)
Equipment and the support tickets raised against it.

`asset_assignments`, `asset_categories`, `asset_documents`, `asset_duplicate_flags`, `asset_finance_links`, `asset_history`, `asset_maintenance`, `asset_retirements`, `asset_warranties`, `assets`, `ticket_categories`, `ticket_comments`, `ticket_events`, `ticket_sla_policies`, `tickets` (15 tables)

### 11 Documents & communications
Document records, versions, links, holds; recorded communications.

`communication_access`, `communication_attachments`, `communication_comments`, `communication_disposals`, `communication_events`, `communication_holds`, `communication_links`, `communication_messages`, `communication_participants`, `communication_threads`, `communication_types`, `document_access`, `document_comments`, `document_disposals`, `document_events`, `document_holds`, `document_integrity_checks`, `document_links`, `document_publications`, `document_types`, `document_versions`, `documents`, `retention_classes` (23 tables)

### 12 Domains
Domain names under management, their registrations, transfers and relations.

`domain_events`, `domain_registrations`, `domain_relations`, `domain_reviews`, `domain_transfers`, `domains` (6 tables)

### 13 Search
Derived search index and its configuration (rebuildable, not a source of truth).

`search_index`, `search_refresh_queue`, `search_sources` (3 tables)


## 3. Divisions: one workspace per division

A division is not a copy of the data; it is a **lens** over the one set of tables (almost every table already carries `division_id`, and access is already scoped by division). The Hub gets one entry per division (ADA Web, ADA Tech, ADA Marketing, ADA Academy, ADA Software, ADA Consulting; Management, Administration and Finance are internal and never public):

**Divisions → ADA Web → [Services & prices · Packages · Projects · Clients · Quotes · Team & positions · Vacancies · Portfolio · News & events · Documents]**

| Division page | Reads / writes (today) | Status |
|---|---|---|
| Services & prices | `services`, `service_prices` (a change is a new price version; the approval queue applies) | in the database; **screen to build** |
| Packages | — | **new table(s) needed** (the website has packages; ADA Core has none) |
| Projects, clients, quotes | `projects`, `clients`, `quotes` | in the database and the Hub |
| Team & positions | `staff`, `positions`, `staff_profiles` | in the database; division screen to build |
| Vacancies, applications | `vacancies`, `applications` | in the database; screens to build |
| Portfolio | `portfolio_entries` | in the database; screen to build |
| News & events, testimonials, FAQs | — | **new Content section needed** (§5) |
| Documents | `documents` | built (Hub → Documents) |

Saving anywhere goes through the existing controlled functions and row-level security, so the audit trail, approvals and "who may edit which division" rules stay exactly as they are.

## 4. Careers and staff

Already in ADA Core and covered by section 3: `people`, `vacancies`, `applications` (+ history, reviews, offers), `onboarding_tasks`, `staff`, `staff_profiles`, `positions`. The website's `career_opportunities` and `career_applications` map onto `vacancies` and `applications`; the website's CV files move into the Documents bucket (migration 0055) and are referenced, not copied.

## 5. What the current Administrator system holds, and where it goes

The `/admin` of `ada-main-website` uses a **separate** Supabase project. Only the pages below read or write it; all other admin pages (CRM, finance, operations, people, system — about 40 of them) are 28-line placeholders that read no data, which is why their links "lead nowhere".

| Old table | What it is | Goes to | Notes |
|---|---|---|---|
| `admin_profiles` | who may use `/admin` and their role | `staff` + `staff_roles` | ADA Core already has the people and the roles; the old admin logins are retired |
| `admin_activity_logs` | admin actions | `audit_log` | the history is old; keep as an archive export, do not re-create |
| `career_opportunities` | published vacancies | `vacancies` | field mapping to confirm; no vacancies exist in ADA Core yet |
| `career_applications` | applications + notes + status | `applications` (+ history, reviews) | personal data: migrate only with the owner's go-ahead; CVs to the Documents bucket |
| `content_posts` | news, announcements, updates | **new Content section** | not in ADA Core |
| events, packages, testimonials, team, services, website settings (pages exist, data location unconfirmed) | public site content | services/team → existing tables; events, packages, testimonials, settings → **new Content section** | needs a look at the old project's tables |
| `cookie_consent_events`, `site_events` | visitor consent and anonymous analytics | stay with the website (not business records) | the handover already says so; they may keep a small database of their own |

I cannot read the old Supabase project from this session (it is on a different Supabase account from ADA Core). Before any data moves I need either an export of its tables or access to it.

## 6. Why sections are a catalogue, not separate schemas

Splitting 139 tables into several PostgreSQL schemas (or databases) would mean rewriting every function, policy, trigger, test and API call that names a table, and Supabase's API only exposes `public` by default. It would also not make anything easier to find for a person. The same goal is reached without risk by: (a) a **section registry** in the database (a small table mapping each table to its section and division relevance), generated into the data dictionary and used by the Hub's navigation; (b) the **division workspace** screens above; (c) clear naming. If you later want hard separation, it can be done section by section, behind this catalogue, after the screens exist.

## 6a. Live data on the websites (prices, positions, staff names, news)

Already designed and built in ADA Core (`docs/api/PUBLIC_API.md`): the websites never touch tables; they call `public_api` functions — `divisions`, `services` (with the price currently in force), `team`, `vacancies`, `statistics`, `portfolio`, `documents` — and only what is **published** is returned. A price change writes a new `service_prices` version and emits a `price.changed` event; a website subscribed to events revalidates the page, so the new price (for example the minimum price changing to 1,199.99) appears without a redeploy. Not yet built: the small HTTP layer that exposes these functions (the doc says "to be built"), the event dispatcher, and the websites actually reading from it. News/events need the new Content section first.

## 7. Proposed order (nothing starts until you say so)

1. **Approve this arrangement** (sections, division workspace, catalogue-not-schemas).
2. **Section registry**: add the registry table and generate the sectioned data dictionary; group the Hub menu by section. No existing table changes.
3. **Content section** (news/posts, events, testimonials, FAQs, packages, website/company settings) as new tables with the same rules (division, status, publish approval, audit, events).
4. **Services & prices division screens** (the first thing you named): pick a division → edit a service or price → save; approvals apply.
5. **Public API HTTP layer + event dispatcher**, then the main website reads services/prices/team/vacancies/news from ADA Core.
6. **Migrate the old admin data** (vacancies, applications, news, then the rest), after an export/inspection of the old project; retire `/admin` and point "Administrator Login" at ADA Hub.

## 8. Decisions I need from you

* Is the 13-section arrangement and the division workspace what you meant?
* Sections as a **catalogue** (recommended), or hard separation into schemas?
* Which division first for step 4 (suggested: ADA Web, since you are pricing its services now)?
* How can I see the old admin database: a table export, or access to that Supabase project?
