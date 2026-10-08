# Public API contract

Websites never touch tables. The (future) HTTP layer is a thin server that holds the database credentials of
role `ada_public_api`, hashes the caller's API key (SHA-256 hex) and calls one `public_api` function. Nothing else
is reachable by that role (tested: no table privileges; only these six functions).

Caller identity = the website registered in `websites` (status `active`) whose key hash matches. Each function also
requires a **capability** on that website. Source attribution (which website an application came from) comes from this identity, never from the request body.

| HTTP (proposed) | Function | Capability | Returns |
|---|---|---|---|
| `GET /api/public/divisions` | `public_api.divisions(hash)` | `divisions.read` | published divisions: `code, name, description` |
| `GET /api/public/vacancies?division=` | `public_api.vacancies(hash, division)` | `vacancies.read` | published, open vacancies |
| `GET /api/public/vacancies/{id}` | `public_api.vacancy(hash, ada_id)` | `vacancies.read` | one vacancy or `null` |
| `GET /api/public/team` | `public_api.team(hash)` | `team.read` | published profiles of current staff |
| `GET /api/public/statistics` | `public_api.statistics(hash)` | `statistics.read` | `staff, team_members, open_vacancies, divisions` (derived live) |
| `POST /api/public/applications` | `public_api.submit_application(hash, vacancy, name, email, phone, cover, page, referrer, utm)` | `applications.submit` | `{ "reference": "ADA-APP-…" }` only |

## DTOs (the complete field lists — anything else is a bug)
- **division**: `code, name, description`
- **vacancy**: `id, title, summary, description, requirements, employment_type, closing_date, published_at, division{code,name}`, and `salary{min,max,currency}` only when the vacancy is marked `salary_public`
- **team member**: `id, name, title, bio, photo, email (only if the person approved a public email), division{code,name}`
- Divisions that are not published (Management, Administration, Finance) never appear, even as a vacancy's or person's division.

## Error mapping (SQLSTATE → HTTP)
| SQLSTATE | Meaning | HTTP |
|---|---|---|
| `42501` | unknown key / suspended site / missing capability | 403 |
| `P0002` | vacancy not open or not found | 404 |
| `22023` | invalid name or email | 422 |
| `23514` | constraint (e.g. over-long text) | 422 |
| `23505` | already applied | 409 |

## What the handlers must still do (outside the database)
Rate-limit per key and per IP · validate/size-limit request bodies · accept CV files via object storage and pass a reference ·
return `Cache-Control` and an ETag · expose a `POST /api/internal/revalidate` consumer for event deliveries.

## Cache invalidation
Changes emit rows in `events` and, for sites with an active `event_subscriptions` row matching the event type, a pending `event_deliveries` row.
A dispatcher (to be built) POSTs a signed webhook, e.g. `vacancy.published`, and the website revalidates the affected page. No redeploy is involved.
Event types: `vacancy.published|unpublished|closed`, `application.submitted|status_changed|offer_made|accepted`, `staff.created|deactivated`, `profile.published|unpublished`, `website.registered`.
