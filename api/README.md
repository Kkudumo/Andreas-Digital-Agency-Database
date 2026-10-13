# ADA public API

Thin HTTP service over the `public_api.*` functions (contract: `docs/api/PUBLIC_API.md`).

- Runs as Postgres role `ada_public_api` (functions only, no table access). Set `PUBLIC_API_DATABASE_URL`.
- Callers send `X-API-Key`; the key is SHA-256 hashed here and the database decides what that website may read.
- Per-key and per-IP rate limits, 32 KB body limit, ETag + `Cache-Control`, database errors never echoed.
- `GET /health`, `GET /api/public/{divisions,services,vacancies,vacancies/:id,portfolio,team,statistics,documents,documents/:ref}`,
  `POST /api/public/{enquiries,applications}`.

Not done yet (needs the owner): give `ada_public_api` a login password, deploy this service, register the six websites
in `websites` with key hashes and capabilities, and the event dispatcher. CV upload is not handled yet.

`npm install && npm run build && npm test && npm start` (long-running server on `PORT`, default 8080).

## On Vercel

The same handler (`src/app.ts`) runs as one Vercel function, `api/[...route].js`; `vercel.json` builds it and maps `/health`.
Create a Vercel project with **root directory `api`**, region `fra1` (next to the database), and one environment variable:

- `PUBLIC_API_DATABASE_URL` (sensitive): Supabase **transaction pooler** connection string (port 6543) for user
  `ada_public_api.<project-ref>` with the password set by `alter role ada_public_api with login password '…'`. The owner sets
  the password and pastes the string into Vercel himself; it is never committed or sent anywhere else.

On Vercel each instance keeps one connection and turns off prepared statements (the pooler does not support them).
Rate limits are per instance, so they are a soft limit there.

Checked locally against a database built from all migrations (Vercel mode): `/health` 200; no key or wrong key 403;
divisions and statistics returned; a read without its capability 403; an enquiry returns only `{"reference":"ADA-ENQ-…"}` (201).

Website capabilities in use: `divisions.read`, `services.read`, `vacancies.read`, `portfolio.read`, `team.read`,
`statistics.read`, `documents.read`, `enquiries.submit`, `applications.submit`.
