# ADA public API

Thin HTTP service over the `public_api.*` functions (contract: `docs/api/PUBLIC_API.md`).

- Runs as Postgres role `ada_public_api` (functions only, no table access). Set `PUBLIC_API_DATABASE_URL`.
- Callers send `X-API-Key`; the key is SHA-256 hashed here and the database decides what that website may read.
- Per-key and per-IP rate limits, 32 KB body limit, ETag + `Cache-Control`, database errors never echoed.
- `GET /health`, `GET /api/public/{divisions,services,vacancies,vacancies/:id,portfolio,team,statistics,documents,documents/:ref}`,
  `POST /api/public/{enquiries,applications}`.

Not done yet (needs the owner): give `ada_public_api` a login password, deploy this service, register the six websites
in `websites` with key hashes and capabilities, and the event dispatcher. CV upload is not handled yet.

`npm install && npm run build && npm test && npm start`
