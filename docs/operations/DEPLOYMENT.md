# Deployment

## Order of operations for any environment
1. Create the database (PostgreSQL 16; on Supabase, a new project). Required extensions: `pgcrypto` and `pg_trgm`, both in schema `extensions` (the migrations create them; on a self-managed server the contrib package must be installed). Never point development at production.
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
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | IRM | browser-safe values only |
| website API key | each website's server | stored by the website's host as a secret; only its hash is in ADA Core |

The Supabase **service-role key** must never be placed in a website, in IRM's browser code, or in this repository.

## First staging check on real Supabase (partly done, 12 October 2026)
**Done.** (Since then migrations `0053`–`0056` have been added and are NOT yet applied to the live project.) All 52 migrations (`0001`–`0052`, commit `b0ac525`) were applied to a new, empty Supabase project, **ADA Core** (organization "ADA Core", account hello@andreasdigitalagency.com, region eu-central-1, ref `uyhwcbjfvfkqsixthxkn`, "automatically expose new tables" switched off). Each file ran in the dashboard SQL editor as one transaction with its row in `supabase_migrations.schema_migrations`, exactly as `scripts/supabase-apply.mjs` does (the files were fetched from GitHub at that commit; no access token was used). Every migration succeeded on the first attempt.

Posture checked on the real project straight afterwards:

| Check | Result |
|---|---|
| Tables in `public` | 139 |
| Tables without row-level security | 0 |
| Table privileges held by `anon` | 0 |
| `public_api` functions executable by `anon` / `authenticated` | 0 |
| `public` functions `anon` can execute | 143, all trigger functions (cannot be called as RPC) |
| Seed data | 9 divisions, 7 roles, 155 permissions |
| Migrations recorded | 52 |

**Still to do:** create two test logins with different roles and confirm through the REST/RPC endpoints that `anon` receives nothing and a division lead sees only their division; link the real CEO account with `link_staff_account()`.

### Original plan
Apply the migrations to a fresh Supabase project, run the structure checks, create two test logins with different roles, and confirm through the REST/RPC endpoints that `anon` receives nothing, a division lead sees only their division, and `public_api` functions are unreachable to `anon`/`authenticated`. Record the result in this file.

**Tools ready for that check (not yet run against a real project):**
- `SUPABASE_ACCESS_TOKEN=... node scripts/supabase-apply.mjs <project-ref> [--dry-run]` applies every migration to a hosted project through the Management API (no database password), recording each in `supabase_migrations.schema_migrations` like the Supabase CLI does.
- `scripts/pilot-live/run.sh` runs the Zeta engagement through the real interface against a real migrated database, with a local stand-in for Supabase Auth (see the header of that script). Against a real project, point `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` at it, link real staff with `link_staff_account()`, and walk through section F of `docs/workflows/ADA_HUB_PILOT_V0_1.md` by hand.
