# Domains

One record per domain name, identified by a permanent institutional ID (type `domain`, code `KF`) minted only through `attach_entity`. The record holds what is true of the domain itself; everything it relates to (organizations, clients, projects, websites/apps, divisions) is a reference, never a copy.

## Model
| Table | Purpose |
|---|---|
| `domains` | name (normalised, case-insensitive), purpose, status, `expires_on` (a mirror of the ledger), classification (own + inherited `effective_classification`) |
| `domain_relations` | registrant / client / registrar / project / website links (the division is a column on the domain; applications reach a domain through their website relation) with `valid_from` / `valid_to`; changing a single-valued relation closes the previous one — history is kept |
| `domain_registrations` | append-only ledger of registration/renewal periods (contiguous, ≤10-year horizon, 28–3660 days, idempotent by order reference). It drives lifecycle and `expires_on` |
| `domain_transfers` | append-only controlled transfers (registrar / ownership / out); one open transfer per domain; decided through the approval engine |
| `domain_events` | append-only event history |
| `domain_reviews` | silent review queue for hidden-name collisions (`matching.review`) |

Views: `domain_expiry_status`, `website_hostname_domains` (existing websites/applications keep working; the domain is the authority for the hostname).

## Lifecycle
`requested → active | expired | retired`; `active → suspended | transfer_pending | expired | retired`; `suspended → active | transfer_pending | expired | retired`; `transfer_pending → active | suspended | retired`; `expired → active | retired`; `retired → requested` (re-registration). Status changes happen only through commands; the expiry sweep (service role) only marks lapsed domains expired — it never deletes or retires. Nothing is ever deleted; a retired name keeps its ID, relations and ledger.

## Commands
Permissions: `domains.view/create/update/renew/suspend/transfer/approve/retire`. Registration, renewal, relation changes, transfer request/decision, suspend/reinstate, retire/re-register, expiry sweep. Renewals are never automatic.

## Security
* Classification is inherited from the strictest currently-related entity (restricted client/project/registrant organization → restricted domain); soft-deleting the client does not expose it.
* Hidden domains are invisible to lookup, search, counts, registry, 360 views, audit log (`audit_domain_visible`) and relationship listings. Hidden and missing answer identically ("not found"). Denials are logged.
* A hidden name never blocks or reveals through name uniqueness: the unique index covers visible classifications only; collisions are flagged silently in `domain_reviews`.
* Validation that would depend on hidden data runs in AFTER triggers (BEFORE triggers fire before RLS and would leak through their errors).
* Not publishable: `entity_types.publishable = false`. Any public exposure must come through the publication layer.

## Not built
Automatic renewal, registrar API sync, DNS record management, pricing/billing of renewals, bulk import, public projection.
