# Deployment

## Order of operations for any environment
1. Create the database (PostgreSQL 16; on Supabase, a new project). Never point development at production.
2. Apply `supabase/migrations/*.sql` in order (Supabase CLI `db push`, or `psql -f` for a plain server). The migrations are the only schema source.
3. Bootstrap the first administrator once: invite the user in Authentication, then as the service role: `select bootstrap_first_admin('<auth user id>', 'Full Name', 'email');` (it refuses to run twice).
4. From IRM (when built) or SQL as an administrator: register websites (`websites`), choose their capabilities, issue keys (`issue_website_key`) and hand each key to its website's server-side configuration exactly once.
5. Give role `ada_public_api` a login and password (outside migrations) for the public API server only: `alter role ada_public_api login password '…'`.
6. Run `supabase/tests/30_structure.sql`-style checks and the website smoke tests in **staging first**.

## Configuration (environment variables — none are committed)
| Variable | Used by | Notes |
|---|---|---|
| `DATABASE_URL` | backup/restore, migrations | admin/owner role; never given to a browser |
| `PUBLIC_API_DATABASE_URL` | public API server | role `ada_public_api` only |
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | IRM (paused) | browser-safe values only |
| website API key | each website's server | stored by the website's host as a secret; only its hash is in ADA Core |

The Supabase **service-role key** must never be placed in a website, in IRM's browser code, or in this repository.

## First staging check on real Supabase (not yet done)
Apply the migrations to a fresh Supabase project, run the structure checks, create two test logins with different roles, and confirm through the REST/RPC endpoints that `anon` receives nothing, a division lead sees only their division, and `public_api` functions are unreachable to `anon`/`authenticated`. Record the result in this file.
