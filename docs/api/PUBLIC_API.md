# Public API contract

**Status: built** (`public-api/`, build step 3). The HTTP layer described below exists, is tested against the real database as the `ada_public_api` role, and is not yet deployed (see "Deploying" at the end).

Websites never touch tables. The (future) HTTP layer is a thin server that holds the database credentials of
role `ada_public_api`, hashes the caller's API key (SHA-256 hex) and calls one `public_api` function. Nothing else
is reachable by that role (tested: no table privileges; only these six functions).

Caller identity = the website registered in `websites` (status `active`) whose key hash matches. Each function also
requires a **capability** on that website. Source attribution (which website an application came from) comes from this identity, never from the request body.

| HTTP | Function | Capability | Returns |
|---|---|---|---|
| `GET /api/public/divisions` | `public_api.divisions(hash)` | `divisions.read` | published divisions: `code, name, description` |
| `GET /api/public/vacancies?division=` | `public_api.vacancies(hash, division)` | `vacancies.read` | published, open vacancies |
| `GET /api/public/vacancies/{id}` | `public_api.vacancy(hash, ada_id)` | `vacancies.read` | one vacancy or `null` |
| `GET /api/public/services?division=` | `public_api.services(hash, division)` | `services.read` | published, active services with the price currently in force |
| `GET /api/public/portfolio?division=` | `public_api.portfolio(hash, division)` | `portfolio.read` | published, consented portfolio entries of finished projects |
| `GET /api/public/team` | `public_api.team(hash)` | `team.read` | published profiles of current staff |
| `GET /api/public/statistics` | `public_api.statistics(hash)` | `statistics.read` | `staff, team_members, open_vacancies, divisions, services, portfolio_projects` (derived live) |
| `GET /api/public/posts?type=&division=&limit=` | `public_api.posts(hash, type, division, limit)` | `content.read` | published news / announcements / updates (featured first); agency-wide posts appear for every division |
| `GET /api/public/posts/{slug}` | `public_api.post(hash, slug)` | `content.read` | one published post or `null` |
| `GET /api/public/testimonials?division=` | `public_api.testimonials(hash, division)` | `content.read` | published testimonials whose consent is recorded |
| `GET /api/public/faqs?division=` | `public_api.faqs(hash, division)` | `content.read` | published FAQs in their set order |
| `GET /api/public/settings?division=` | `public_api.settings(hash, division)` | `settings.read` | public settings: company facts, division email, planner rules (agency-wide plus the division's) |
| `POST /api/public/enquiries` | `public_api.submit_enquiry(hash, name, email, phone, organization, service, message, page, referrer, utm, budget, currency)` | `enquiries.submit` | `{ "reference": "ADA-ENQ-…" }` only |
| `POST /api/public/applications` | `public_api.submit_application(hash, vacancy, name, email, phone, cover, page, referrer, utm)` | `applications.submit` | `{ "reference": "ADA-APP-…" }` only |

## DTOs (the complete field lists — anything else is a bug)
- **division**: `code, name, description`
- **vacancy**: `id, title, summary, description, requirements, employment_type, closing_date, published_at, division{code,name}`, and `salary{min,max,currency}` only when the vacancy is marked `salary_public`
- **service**: `id, name, category, summary, description, pricing_model, billing_unit, division{code,name}`, and `price{amount,currency,effective_from,starting_price}` (`starting_price: true` means the website must show "from") only when the service shows its price and one is in force (never for quote-based services or hidden prices)
- **portfolio entry**: `id, title, summary, description, technologies, images, completed_on, division{code,name}, services[] (names)`, and `client` (name) only when the client consented to being named — never prices, contacts, project or client IDs
- **team member**: `id, name, title, bio, photo, email (only if the person approved a public email), division{code,name}`
- Divisions that are not published (Management, Administration, Finance) never appear, even as a vacancy's or person's division.

- **post**: `id, type, title, slug, summary, content, cover_image_url, image_alt_text, author_name, source_label, featured, published_at, division{code,name}` (division absent = whole agency)
- **testimonial**: `id, quote, person_name, person_role, organization_name, service (name), division{code,name}` — never the consent note
- **faq**: `id, question, answer, category, service (name), division{code,name}`
- **setting**: `key, label, value, type, group, division{code,name}` — only settings marked public

## Documents (capability `documents.read`)
| Function | Returns |
|---|---|
| `public_api.documents(key_hash, [type])` | the published documents: `ref, title, description, type, document_date, published_at, file{mime_type, size_bytes, sha256}` |
| `public_api.document(key_hash, ref)` | one published document by its random public reference (`pd_…`), or `null` |

Only documents with an approved, live publication whose document is still eligible (public classification, active, not critical, publishable type, approved/signed version) and whose registry entry is active are returned. The institutional ID, storage reference, internal title, uploader, classification, notes and other versions are never exposed; the institutional ID does not resolve here. To serve the bytes, the handler asks the **delivery service** (service role) for `document_public_content_ref(ref)` and issues a short-lived signed URL; that reference never goes to the browser. Events: `document.published|unpublished` carry only the public ref.

## Error mapping (SQLSTATE → HTTP)
| SQLSTATE | Meaning | HTTP |
|---|---|---|
| `42501` | unknown key / suspended site / missing capability | 403 |
| `P0002` | vacancy not open or not found | 404 |
| `22023` | invalid name, email, or nothing to contact (no email, phone or message) | 422 |
| `23514` | constraint (e.g. over-long text) | 422 |
| `23505` | already applied | 409 |

## What the handlers must still do (outside the database)
Rate-limit per key and per IP · validate/size-limit request bodies · accept CV files via object storage and pass a reference ·
return `Cache-Control` and an ETag · expose a `POST /api/internal/revalidate` consumer for event deliveries.

## Enquiries: what the website sends and gets back
The website sends what the visitor typed plus `page`, `referrer` and `utm` (`utm_source/medium/campaign/term/content`). It never sends its own identity - ADA derives the source website from the API key. The response is always just a reference, whether or not the person or organization is already known, so a website can never learn who or what ADA already holds.

## Cache invalidation
Changes emit rows in `events` and, for sites with an active `event_subscriptions` row matching the event type, a pending `event_deliveries` row.
A dispatcher (to be built) POSTs a signed webhook, e.g. `vacancy.published`, and the website revalidates the affected page. No redeploy is involved.
Event types: `vacancy.published|unpublished|closed`, `service.published|unpublished`, `price.changed`, `portfolio.published|unpublished`, `project.completed`, `application.submitted|status_changed|offer_made|accepted`, `staff.created|deactivated`, `profile.published|unpublished`, `website.registered`, `enquiry.received`, `lead.created|qualified|converted`, `quote.accepted` (identifiers and states only; the last five are internal and not meant for websites).


## The service (`public-api/`)
* **Callers** send the key as `Authorization: Bearer <key>` (or `X-API-Key`). The service hashes it (SHA-256 hex) and passes only the hash to the database; the key is never logged, stored or forwarded. Websites get their key from **ADA Hub → Websites** (shown once; rotating stops the old key at once).
* **Routes** are exactly the table above, under `/api/public/...` (vacancy and document single records are `GET /vacancies/{id}` and `GET /documents/{ref}`). Nothing else is reachable.
* **Responses:** `GET` carries `Cache-Control: public, max-age=…, stale-while-revalidate`, an `ETag` (and answers `If-None-Match` with 304) and `Vary: Authorization, X-API-Key`. `POST` returns `201` with the reference only and `no-store`.
* **Errors** use the mapping above plus `401` (no key), `405`, `413` (body over 16 KB), `415` (not JSON), `422` (invalid field or unknown field), `429` (rate limit, with `Retry-After`). Database error text is never returned.
* **Validation:** bodies are JSON only, size-limited, and every field is type- and length-checked; unknown fields are refused; query parameters (`division`, `type`) are restricted to `[a-z0-9-]`. The database function names come from a fixed table, arguments are bound parameters.
* **Rate limits:** per key (600/min) and per address (120/min) inside each instance. Because serverless instances do not share memory, also set a platform firewall rule; this is a second line, not the only one.
* **Not in this service:** CV file upload (applications take text only; a file reference can be added when object storage is chosen), and the website-side `POST /api/internal/revalidate` consumer for event deliveries (each website owns that).

## Deploying (owner steps; no secret is ever typed by an assistant)
1. In the Supabase SQL editor, give the role a login: `alter role ada_public_api login password '<a long random password you generate>';`
2. Create the connection string for that role (Supabase project settings → Database → connection pooler, user `ada_public_api.<project-ref>`).
3. Create a host (a new Vercel project from this repository, **root directory `public-api/`**, e.g. `api.andreasdigitalagency.com`) and set `ADA_PUBLIC_API_DATABASE_URL` to that string. Leave TLS verification on (do not set `ADA_PUBLIC_API_SSL=off` outside local tests). `public-api/src/server.mjs` also runs anywhere Node 20+ runs (`npm start`, `/healthz` for health checks; set `ADA_PUBLIC_API_TRUST_PROXY=on` behind a proxy so the rate limit sees real client addresses).
4. In ADA Hub → Websites register each of the six websites with the capabilities it needs, issue its key, and put the key in that website's own environment.
5. Check: `curl -H "Authorization: Bearer <key>" https://api.andreasdigitalagency.com/api/public/divisions`.

The Vercel entry (`public-api/api/index.mjs`) has been written to Vercel's documented Web-handler form but could only be exercised locally through `src/server.mjs`; check the first deployment.
