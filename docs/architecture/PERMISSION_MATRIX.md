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
