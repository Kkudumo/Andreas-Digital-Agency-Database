#!/usr/bin/env bash
# Restore an ADA Core backup into an EMPTY target database that already has the platform prerequisites
# (roles anon/authenticated/service_role/ada_public_api and the auth.users table; on Supabase these exist).
#   TARGET_URL=postgresql://... scripts/restore.sh path/to/ada-core-....dump
set -euo pipefail
: "${TARGET_URL:?set TARGET_URL}"
dump="${1:?usage: restore.sh <dump file>}"
[ -f "$dump.sha256" ] && sha256sum -c "$dump.sha256"
n=$(psql -X -Atq "$TARGET_URL" -c "select count(*) from information_schema.tables where table_schema in ('public','public_api')")
[ "$n" = "0" ] || { echo "refusing to restore: target already has $n tables in public/public_api" >&2; exit 1; }
# Prerequisite extension (idempotent), then restore everything except the pre-existing public schema object itself.
psql -X -q -v ON_ERROR_STOP=1 "$TARGET_URL" -c "create schema if not exists extensions" -c "create extension if not exists pgcrypto with schema extensions" -c "create extension if not exists pg_trgm with schema extensions"
list=$(mktemp); trap 'rm -f "$list"' EXIT
# pg_dump records grants as a difference from the target's defaults. Neutralise any permissive default
# privileges in the target first, otherwise restored tables could be MORE open than the source.
psql -X -q -v ON_ERROR_STOP=1 "$TARGET_URL" \
  -c "alter default privileges in schema public revoke all on tables from anon, authenticated" \
  -c "alter default privileges in schema public revoke all on sequences from anon, authenticated" \
  -c "alter default privileges in schema public revoke execute on functions from anon, authenticated"
pg_restore -l "$dump" | grep -vE '^[0-9]+; [0-9]+ [0-9]+ (SCHEMA - public |COMMENT - SCHEMA public )' > "$list"
pg_restore --no-owner --exit-on-error --use-list="$list" --dbname="$TARGET_URL" "$dump"
if [ -f "$dump.fingerprint" ]; then
  got=$(psql -X -Atq "$TARGET_URL" -f "$(dirname "$0")/security-fingerprint.sql")
  if [ "$got" != "$(cat "$dump.fingerprint")" ]; then
    echo "SECURITY FINGERPRINT MISMATCH: the restored database does not have the same grants/RLS/policies as the backup." >&2
    echo "Do NOT put this database into service. Inspect with scripts/security-fingerprint.sql." >&2
    exit 2
  fi
  echo "security fingerprint verified"
fi
echo "restored $dump"
