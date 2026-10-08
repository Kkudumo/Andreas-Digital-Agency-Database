# Development setup

## Prerequisites
PostgreSQL 16 server + client tools (`psql`, `pg_dump`, `pg_restore`), Node 20+, bash.

## Run the whole verification
```bash
# one-time: a local Postgres you can create databases in
export ADA_TEST_PG_URL=postgresql://postgres:postgres@localhost:5432/postgres
./scripts/test-db.sh            # builds a scratch DB from migrations only, runs every suite, then the parallel-ID test
./scripts/rehearse-migration.sh # backup -> restore into a new DB -> prove identical security posture and behaviour
./scripts/gen-docs.sh           # regenerate DATA_DICTIONARY.md, ERD.md, PERMISSION_MATRIX.md
```
`test-db.sh` applies `supabase/tests/00_supabase_shim.sql` first (a stand-in for Supabase's `auth` schema and API roles, with Supabase's
permissive default grants so the tests prove our explicit revokes). The shim is never applied to a real project.

## Adding a module
Follow [MODULE_CHECKLIST.md](../MODULE_CHECKLIST.md). It states the central-record rule, how snapshots must be documented, the privacy and existence-leakage requirements, and the tests every module must include. `supabase/tests/PROTECTED.txt` lists regression checks that CI refuses to lose.

## Changing the schema
1. Add a new numbered migration in `supabase/migrations/` (never edit one that has been applied to staging or production).
2. Changing permissions? Edit `supabase/seed_data/permission_matrix.csv`, generate the SQL with `node scripts/build-rbac-delta.mjs <old.csv>`, review it, ship it as a migration.
3. Write the test first for any new rule (who can, who must not, what is recorded). `supabase/tests/01_helpers.sql` has `tests.try`, `tests.scalar`, `tests.pub` and fixtures.
4. Run `./scripts/test-db.sh`. Break your own rule on purpose once to confirm a test fails.
5. Run `./scripts/gen-docs.sh` and commit the regenerated docs.

Test conventions: `tests.try(user, sql)` returns `ok`, `ok0` (ran but affected zero rows — usually a silent RLS block, so a success expectation fails on it) or `ERR:<sqlstate>`.
`tests.scalar(user, sql)` returns one value as the user. `tests.pub(site, fn, args)` calls the public API as the website role.

## Environments
Development (local / disposable), Staging (a separate Supabase project or server; run the full suite + rehearsal here before production), Production.
Configuration comes only from environment variables (`DATABASE_URL`, API credentials); nothing is hard-coded and no secret is committed.
