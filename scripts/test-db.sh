#!/usr/bin/env bash
# Builds a scratch database from migrations only, then runs the authorization and
# integrity suite. This doubles as proof that a fresh server can be rebuilt from migrations.
#   ADA_TEST_PG_URL   admin connection URL (default postgresql://postgres:postgres@localhost:5432/postgres)
set -euo pipefail
cd "$(dirname "$0")/.."
ADMIN_URL="${ADA_TEST_PG_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
DB="ada_test_$$"
BASE="${ADMIN_URL%/*}"
URL="$BASE/$DB"
psql_() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

psql_ "$ADMIN_URL" -c "create database $DB"
trap 'psql_ "$ADMIN_URL" -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT

node scripts/check-migrations.mjs
psql_ "$URL" -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do
  echo "migrate  $(basename "$f")"
  psql_ "$URL" -f "$f" >/dev/null
done
psql_ "$URL" -f supabase/tests/01_helpers.sql >/dev/null

status=0
for f in supabase/tests/[1-9][0-9]_*.sql; do
  echo "== $(basename "$f")"
  if out=$(psql_ "$URL" -f "$f" 2>&1 >/dev/null); then rc=0; else rc=$?; fi
  # keep failures, errors and the summary line; drop passing checks
  printf '%s\n' "$out" | sed -E 's/^psql:[^:]+:[0-9]+: //' | grep -vE '^(NOTICE:  ok  |CONTEXT:|PL/pgSQL|LINE|HINT)' | sed 's/^/  /' || true
  [ "$rc" -eq 0 ] || status=1
done
[ "$status" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $status
