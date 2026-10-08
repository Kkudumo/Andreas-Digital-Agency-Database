# Approvals

Two layers, kept deliberately small.

**The queue.** `approval_requests` records everything awaiting or having received approval (vacancies, staff profiles, services, price changes, quotes, portfolio entries), is visible to those who hold the approving permission, and keeps the decision history. It is written by triggers when an entity enters `pending_approval` and when it leaves it.

**The policy.** `approval_policies` decide *how* a kind of request may be approved. `approval_gate()` is the single call a workflow makes to authorise a decision.

## Policy fields
| Field | Meaning |
|---|---|
| `kind` | what is being approved: `price_change`, `quote`, and later `invoice`, `expense`, `hire`, `publication` ... |
| `division_id` (optional) | the policy applies to that division only; a division row outranks a generic one |
| `min_amount` (optional) | applies from this amount upward (e.g. quotes from N$10,000 need two approvers); the highest threshold not above the amount wins |
| `required_permission` | who may approve (a permission, never a role name) |
| `min_approvers` (1-5) | how many distinct approvers are needed; the request stays `pending` until reached |
| `allow_self_approval` | may the requester also approve? **false = never** |
| `self_approval_only_if_sole_approver` | when true, self-approval works only while no other qualified approver exists |

No policy row means: one approver holding the caller's permission, and no self-approval.

## Self-approval is a recorded exception, not a privilege
ADA may begin with one manager. Today's default policies (`price_change`, `quote`) allow self-approval **only while the requester is the sole qualified approver**. The moment a second qualified approver exists, separation of duties applies automatically, with no configuration change, because the rule counts qualified approvers at decision time. Every self-approval is recorded (`approval_decisions.is_self`, `approval_requests.self_approved`) and is reviewable. Setting `allow_self_approval = false` removes the exception entirely. Nothing says "the CEO may always approve themselves": a role holds the approving permission and the policy decides the rest.

A policy that needs more approvers than exist (e.g. `min_approvers = 3` with two qualified people) is refused with a clear message rather than deadlocking.

## Configuring
Only holders of `approvals.configure` (management) can read or change policies. Policies cannot be deleted; deactivate them (`is_active = false`) so history stays explainable. Changes are audited.

## Where it is adopted
| Kind | Gate |
|---|---|
| price changes (`price_decide`) | `approval_gate` |
| quotes (`quote_transition` to approved; amount = quote total) | `approval_gate` |
| vacancies, staff profiles, services, portfolio entries | publish permission only (queue + history, no policy yet) |
| invoices, expenses, hiring, contracts | to adopt `approval_gate` when built |

Adopting the gate in another workflow is one call in its approve step: `approval_gate(kind, table, id, division, amount, requested_by, fallback_permission, approve?, note)` returns `approved`, `pending` (more approvers needed) or `rejected`.
