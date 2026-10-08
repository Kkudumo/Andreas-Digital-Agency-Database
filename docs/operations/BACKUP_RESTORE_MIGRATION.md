# Backup, restore and server migration

## What a backup contains
`scripts/backup.sh` writes a custom-format `pg_dump` of schemas `public` and `public_api` (data, constraints, RLS policies, functions, **grants**),
a SHA-256 checksum, and a **security fingerprint** (`scripts/security-fingerprint.sql`: grants, column grants, RLS flags, policies, function EXECUTE grants).
Optional GPG encryption: set `ADA_BACKUP_GPG_RECIPIENT`.

**Not included — handle separately:** Supabase Auth data (`auth.users`), uploaded files (Storage, once documents exist), secrets in the secret manager, environment configuration.

## Restore
Target prerequisites: empty database; roles `anon`, `authenticated`, `service_role`, `ada_public_api` (and the `auth.users` table with the login rows, because `staff.user_id` references it).
`scripts/restore.sh <dump>`: verifies the checksum, refuses a non-empty target, installs `pgcrypto` in schema `extensions`, **removes permissive default privileges first**, restores,
then recomputes the security fingerprint and **exits with code 2 if it differs** from the backup. A database that fails this must not be used.

Why: `pg_dump` stores grants as differences from the target's default privileges. Restored into a Supabase-style target that grants everything to `anon`/`authenticated` by default,
tables would silently come up open. The rehearsal found this; the restore script now neutralises it and proves the result.

## Schedule and retention (to be configured in production)
Daily logical backup + weekly restore test (run `rehearse-migration.sh` against the latest backup in staging) · retain 14 daily / 8 weekly / 12 monthly · store off-site and encrypted · restore authority: ADA administrators only.
Point-in-time recovery (WAL archiving) should be enabled on the production server; logical backups alone give a recovery point of up to 24 hours.

## Moving from Supabase to the ADA server
Rehearse first (`rehearse-migration.sh`), then:
1. **Freeze**: announce a window; stop writes (maintenance mode on IRM and the public API).
2. **Provision** PostgreSQL 16, TLS, firewall, backups. Create roles and the `auth.users` table (or the replacement identity store — see below).
3. **Backup** from Supabase (`DATABASE_URL`), **copy** logins, **restore** with `restore.sh`; confirm "security fingerprint verified".
4. **Verify**: run `supabase/tests/30_structure.sql` against the restored database; spot-check counts; call each `public_api` function with a test website key.
5. **Switch** environment variables (database URL, API credentials), start the services, update DNS/TLS, watch audit and error logs.
6. Keep Supabase read-only for a rollback period, then retire it.

**Authentication is the one real migration decision.** The schema depends on exactly two Supabase things: `auth.users` and `auth.uid()`.
Options: self-host Supabase Auth (GoTrue) against the new database, or replace it and provide `auth.uid()` from the new session (the database only needs a function returning the current user's id).
Decide before the production go-live, not at migration time.

## Disaster recovery
Lose the database → provision, restore the latest verified backup + the auth users export, run the structure suite, reconnect services. Recovery time is dominated by provisioning; practise it.
