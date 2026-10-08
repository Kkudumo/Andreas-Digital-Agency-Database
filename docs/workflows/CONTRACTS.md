# Contracts

`Client → Contact → Quote → Contract → Project`. A contract is the **commercial terms actually agreed** with one existing client. It references the client, the authorised contact (a `client_contacts` row), the originating quote, the projects it covers, the services and the price versions. It stores no client name, email or phone.

## The one rule: what was agreed stays agreed
Line prices (`contract_lines.unit_price`, `discount_amount`) are **snapshots** of what was agreed — copied from the accepted quote (`contract_create_from_quote`) or stated with a reason. They never follow the catalogue. `price_id` records which catalogue version they came from. Later price changes cannot touch a contract (tested).

## Versions: amendments never rewrite history
Terms live in `contract_versions` (v1, v2, …). A version is editable only while `draft`; once it leaves draft, **no caller — not even the database owner —** can change its lines or terms (trigger guards, tested). An amendment (`contract_amend`) creates a new draft version copied from the signed one (at the agreed prices); when it is signed, the previous version becomes `superseded` with an `effective_to` date. The header keeps its status (e.g. `active`) throughout. `contract_terms(id)` returns the version in force. Lines carry `origin_line_id`, so billing continues across versions.

## Lifecycle (`contract_transition`)
```
draft → internal_review → approved → sent → signed → active → expired | terminated
              ↘ draft (sent back)      ↘ rejected (client declined)         ↘ renewed (when the renewal activates)
 draft…sent → cancelled (reason required)           rejected by approver (note required)
```
* `internal_review` opens a request in the shared approvals queue (kind `contract`; amount = contract total, discount = total line discounts). `approved` is decided by `approval_gate` — thresholds, extra approvers, discount policy and the self-approval rule all come from `approval_policies`. Default policy: `contracts.approve`, one approver, self-approval only while the requester is the sole qualified approver.
* `signed` records the signature date (not in the future). `active` needs the start date to have arrived (or the scheduled job `activate_contracts`). `expire_contracts` marks active contracts past their end date as `expired`. Both jobs are service-role only.
* `terminated` needs `contracts.terminate` and a reason; any amendment in flight is cancelled.
* `contract_renew` creates a **new** contract (`renewed_from_id`) at the agreed prices; the old one becomes `renewed` when the new one is activated. `contracts_due_for_renewal(days)` lists contracts in their renewal window (nothing renews itself).
* Every header and version status change is appended to `contract_status_history` (append-only). Row changes are in `audit_log`.

## Visibility
`contracts.view` in the contract's division **and** the client's classification (inherited into `effective_classification`, plus `client_deleted`). A restricted client's contracts are indistinguishable from non-existent ones — errors, counts, helper functions and notifications included (`92_finance_restricted_clients.sql`, permanent). Approval requests carry the classification too, so the queue cannot reveal a restricted record.

## Not built
Document storage (a `document_ref` is held until the documents module), e-signature, automatic renewal creation, recurring billing schedules.
