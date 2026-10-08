# Permission matrix

_Generated from `supabase/seed_data/permission_matrix.csv`, which the test suite requires to equal the database. To change it, edit the CSV and ship a migration (`scripts/build-rbac-delta.mjs`)._

A role assignment is organization-wide or scoped to one division. **Division Lead** and **Division Staff** are assigned per division; every other role is normally organization-wide. "x" = permission held.

| Permission | Class | ceo | administration officer | finance officer | division lead | division staff | auditor | recruiter |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `staff.create` — Create staff records | internal | x | x |  |  |  |  |  |
| `staff.update` — Edit staff records | internal | x | x |  |  |  |  |  |
| `staff.delete` — Soft-delete or restore staff records | restricted | x |  |  |  |  |  |  |
| `staff.manage_accounts` — Link logins and change account or employment status | restricted | x |  |  |  |  |  |  |
| `hr.view` — Read sensitive HR information | confidential | x | x |  |  |  |  |  |
| `hr.update` — Edit sensitive HR information | confidential | x | x |  |  |  |  |  |
| `clients.view` — View clients | internal | x | x | x | x | x |  |  |
| `clients.create` — Create clients | internal | x | x |  | x |  |  |  |
| `clients.update` — Edit clients and link them to divisions | internal | x | x |  | x |  |  |  |
| `clients.delete` — Soft-delete or restore clients | restricted | x |  |  |  |  |  |  |
| `clients.export` — Export client data | restricted | x |  |  |  |  |  |  |
| `projects.view` — View projects | internal | x | x | x | x | x |  |  |
| `projects.create` — Create projects | internal | x | x |  | x |  |  |  |
| `projects.update` — Edit projects and add participating divisions | internal | x | x |  | x |  |  |  |
| `projects.archive` — Archive projects | internal | x |  |  | x |  |  |  |
| `projects.delete` — Soft-delete or restore projects | restricted | x |  |  |  |  |  |  |
| `tasks.create` — Create project tasks | internal | x | x |  | x | x |  |  |
| `tasks.update` — Update project tasks | internal | x | x |  | x | x |  |  |
| `finance.view` — View financial records including project financials | confidential | x |  | x |  |  |  |  |
| `finance.create` — Create and edit financial records | confidential | x |  | x |  |  |  |  |
| `finance.approve` — Approve financial records and workflows | confidential | x |  |  |  |  |  |  |
| `finance.export` — Export financial data | confidential | x |  | x |  |  |  |  |
| `roles.view` — View roles and the permission matrix | restricted | x | x |  |  |  | x |  |
| `roles.administer` — Create roles and assign or revoke permissions and role assignments | restricted | x |  |  |  |  |  |  |
| `audit.view` — Read the audit log | restricted | x |  |  |  |  | x |  |
| `reports.view` — View reports | internal | x | x | x | x |  | x |  |
| `reports.generate` — Generate reports | internal | x |  | x |  |  |  |  |
| `reports.export` — Export reports | restricted | x |  | x |  |  |  |  |
| `settings.update` — Edit organization settings divisions and positions | restricted | x |  |  |  |  |  |  |
| `records.classify` — Mark records restricted or confidential | restricted | x | x |  |  |  |  |  |
| `records.view_restricted` — See records classified restricted | restricted | x | x |  |  |  | x |  |
| `records.view_confidential` — See records classified confidential | confidential | x |  |  |  |  |  |  |
| `records.view_deleted` — See soft-deleted records | restricted | x |  |  |  |  | x |  |
| `positions.manage` — Create and edit positions and headcount | restricted | x | x |  |  |  |  |  |
| `vacancies.view` — View vacancies including drafts | internal | x | x |  | x |  | x | x |
| `vacancies.create` — Create draft vacancies | internal | x | x |  | x |  |  | x |
| `vacancies.update` — Edit vacancies and submit them for approval | internal | x | x |  | x |  |  | x |
| `vacancies.publish` — Approve, publish, unpublish and close vacancies | restricted | x |  |  |  |  |  |  |
| `applications.view` — View applications and applicant details | confidential | x | x |  | x |  |  | x |
| `applications.review` — Screen, shortlist, interview and record review notes | confidential | x | x |  | x |  |  | x |
| `applications.decide` — Make offers and reject at final stages | confidential | x |  |  |  |  |  |  |
| `applications.hire` — Accept an offer and trigger controlled onboarding | confidential | x |  |  |  |  |  |  |
| `onboarding.manage` — Manage onboarding and offboarding tasks | restricted | x | x |  |  |  |  |  |
| `staff.offboard` — Record staff departure and revoke access | restricted | x |  |  |  |  |  |  |
| `profiles.view` — View all public staff profiles including drafts | internal | x | x |  |  |  |  |  |
| `profiles.edit` — Edit other staff members public profile drafts | internal | x | x |  |  |  |  |  |
| `profiles.publish` — Approve, publish and unpublish public staff profiles | restricted | x |  |  |  |  |  |  |
| `websites.view` — View the registry of connected websites | restricted | x | x |  |  |  | x |  |
| `websites.manage` — Register websites and issue or rotate their API keys | restricted | x |  |  |  |  |  |  |
| `services.create` — Create services in the catalogue | internal | x |  |  | x |  |  |  |
| `services.update` — Edit services in the catalogue | internal | x |  |  | x |  |  |  |
| `services.publish` — Approve, publish and unpublish services on public websites | restricted | x |  |  |  |  |  |  |
| `pricing.propose` — Propose a new price version for a service | restricted | x |  | x | x |  |  |  |
| `pricing.approve` — Approve or reject proposed prices | restricted | x |  |  |  |  |  |  |
| `quotes.view` — View quotes | restricted | x | x | x | x | x |  |  |
| `quotes.create` — Create quotes | restricted | x |  |  | x |  |  |  |
| `quotes.update` — Edit quotes and record the client decision | restricted | x |  |  | x |  |  |  |
| `quotes.approve` — Approve quotes before they are sent | restricted | x |  |  |  |  |  |  |
| `portfolio.edit` — Prepare portfolio entries from completed projects | internal | x | x |  | x |  |  |  |
| `portfolio.publish` — Approve, publish and unpublish portfolio entries | restricted | x |  |  |  |  |  |  |
| `leads.view` — View enquiries and leads of a division | confidential | x | x |  | x | x |  |  |
| `leads.create` — Record enquiries received by phone, email or in person | internal | x | x |  | x |  |  |  |
| `leads.update` — Triage, assign, qualify and update leads | internal | x | x |  | x | x |  |  |
| `matching.review` — Review possible duplicate clients, including restricted ones | restricted | x | x |  |  |  |  |  |
| `approvals.configure` — Configure approval policies (who approves, thresholds, self-approval) | restricted | x |  |  |  |  |  |  |
| `contracts.view` — View contracts and their versions | confidential | x | x | x | x |  |  |  |
| `contracts.create` — Draft contracts and amendments | confidential | x |  |  | x |  |  |  |
| `contracts.update` — Edit draft contracts and link projects | confidential | x |  |  | x |  |  |  |
| `contracts.approve` — Approve contracts before they are sent | confidential | x |  |  |  |  |  |  |
| `contracts.terminate` — Terminate or cancel contracts | confidential | x |  |  |  |  |  |  |
| `invoices.view` — View invoices and billable items | confidential | x |  | x | x |  |  |  |
| `invoices.create` — Raise invoices and billable items | confidential | x |  | x |  |  |  |  |
| `invoices.update` — Edit draft invoices | confidential | x |  | x |  |  |  |  |
| `invoices.approve` — Approve invoices before they are issued | confidential | x |  | x |  |  |  |  |
| `invoices.issue` — Issue approved invoices to the client | confidential | x |  | x |  |  |  |  |
| `invoices.void` — Void or cancel invoices | confidential | x |  |  |  |  |  |  |
| `payments.view` — View payments and allocations | confidential | x |  | x |  |  |  |  |
| `payments.record` — Record received payments | confidential | x |  | x |  |  |  |  |
| `payments.allocate` — Allocate payments to invoices | confidential | x |  | x |  |  |  |  |
| `payments.reconcile` — Reconcile payments against bank statements | confidential | x |  | x |  |  |  |  |
| `payments.reverse` — Request reversal or refund of a payment | confidential | x |  | x |  |  |  |  |
| `finance.configure` — Configure finance settings (VAT, payment terms, bank accounts) | confidential | x |  |  |  |  |  |  |
| `discounts.approve` — Approve discounts above the policy threshold | confidential | x |  |  |  |  |  |  |
| `assets.view` — View the asset register (own division; assignees see their own assets) | internal | x | x | x | x | x | x |  |
| `assets.create` — Register assets and report duplicates | internal | x | x |  | x |  |  |  |
| `assets.update` — Edit asset details and record locations / condition / documents / warranties | internal | x | x |  | x |  |  |  |
| `assets.assign` — Assign and return assets | internal | x | x |  | x |  |  |  |
| `assets.maintain` — Schedule and record maintenance | internal | x | x |  | x | x |  |  |
| `assets.retire` — Retire assets | restricted | x | x |  | x |  |  |  |
| `assets.dispose` — Dispose of retired assets | restricted | x |  |  |  |  |  |  |
| `assets.configure` — Manage asset categories | restricted | x | x |  |  |  |  |  |
| `suppliers.view` — View suppliers and vendors | internal | x | x | x | x |  |  |  |
| `suppliers.manage` — Create and edit suppliers and vendors | internal | x | x | x |  |  |  |  |
| `tickets.view` — View tickets (own division; reporters and assignees see their own) | internal | x | x | x | x | x | x |  |
| `tickets.create` — Open tickets | internal | x | x |  | x | x |  |  |
| `tickets.update` — Work and resolve tickets | internal | x | x |  | x | x |  |  |
| `tickets.assign` — Assign tickets to staff | internal | x | x |  | x |  |  |  |
| `security.view` — View security events and investigation cases | restricted | x |  |  |  |  | x |  |
| `security.manage` — Manage security policies and investigation cases | restricted | x |  |  |  |  |  |  |
| `students.view` — View students and their enrolments (own division) | restricted | x | x |  | x | x | x |  |
| `students.admit` — Admit students and record enrolments | restricted | x | x |  | x |  |  |  |
| `students.manage` — Change student status and academic structure | restricted | x | x |  | x |  |  |  |
| `programmes.manage` — Manage programmes and cohorts | internal | x | x |  | x |  |  |  |
| `tickets.configure` — Manage ticket categories and SLA policies | restricted | x | x |  |  |  |  |  |
| `documents.view` — Discover documents and read their metadata (own division; no content access) | internal | x | x | x | x | x | x |  |
| `documents.read` — Read the content of documents (separate from metadata and from download) | restricted | x | x | x | x | x | x |  |
| `documents.download` — Download documents | restricted | x | x | x | x | x |  |  |
| `documents.create` — Register documents and upload new versions | internal | x | x | x | x | x |  |  |
| `documents.update` — Edit document metadata and relationships | internal | x | x | x | x |  |  |  |
| `documents.comment` — Comment on documents | internal | x | x | x | x | x |  |  |
| `documents.share` — Share a document with named people or divisions | restricted | x | x |  | x |  |  |  |
| `documents.approve` — Approve and sign off document versions | restricted | x |  |  | x |  |  |  |
| `documents.publish` — Publish documents publicly (after approval) | restricted | x |  |  |  |  |  |  |
| `documents.archive` — Archive and restore documents | restricted | x | x |  | x |  |  |  |
| `documents.dispose` — Approve disposal of documents after retention | confidential | x |  |  |  |  |  |  |
| `documents.view_critical` — Open critical documents without an explicit grant | confidential | x |  |  |  |  |  |  |
| `documents.legal_hold` — Place and release legal holds on documents | confidential | x |  |  |  |  |  |  |
| `documents.configure` — Manage document types and retention classes and run integrity checks | restricted | x | x |  |  |  |  |  |
| `organizations.view` — View organizations (the single identity record behind client, supplier and partner roles) | internal | x | x |  |  |  | x |  |
| `organizations.create` — Create organizations that have no client / supplier / partner role yet | internal | x | x |  |  |  |  |  |
| `organizations.update` — Edit organization identity (legal name, registration number, address) | internal | x | x |  |  |  |  |  |
| `partners.view` — View partners | internal | x | x | x | x |  | x |  |
| `partners.manage` — Create and edit partners | internal | x | x |  |  |  |  |  |
| `domains.view` — View domains (own division) | internal | x | x | x | x | x | x |  |
| `domains.create` — Create domain records and bring existing domains under management | internal | x | x |  | x |  |  |  |
| `domains.update` — Edit domain details and relationships | internal | x | x |  | x |  |  |  |
| `domains.renew` — Record registrations and renewals | internal | x | x | x | x |  |  |  |
| `domains.suspend` — Suspend and restore domains | restricted | x | x |  | x |  |  |  |
| `domains.transfer` — Request complete and cancel transfers | restricted | x | x |  | x |  |  |  |
| `domains.approve` — Approve domain transfers | restricted | x |  |  |  |  |  |  |
| `domains.retire` — Retire domains and re-register retired ones | restricted | x | x |  |  |  |  |  |
