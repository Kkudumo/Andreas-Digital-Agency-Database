#!/usr/bin/env bash
# Builds a DEVELOPMENT database for the pilot console: schema + the pilot seed.
# usage: pilot/build-db.sh [dbname]     (PGURL = server URL without the database, default postgresql://postgres:postgres@localhost:5432)
# On Supabase, run the migrations with the CLI instead and create the staff through the bootstrap path; seed.sql is dev-only.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${1:-ada_pilot}; A=${PGURL:-postgresql://postgres:postgres@localhost:5432}
psql -X -q $A/postgres -c "drop database if exists $DB" -c "create database $DB"
psql -X -q -v ON_ERROR_STOP=1 $A/$DB -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do psql -X -q -v ON_ERROR_STOP=1 $A/$DB -f "$f" >/dev/null; done
psql -X -q -v ON_ERROR_STOP=1 $A/$DB -f pilot/seed.sql >/dev/null
echo "built $DB"
