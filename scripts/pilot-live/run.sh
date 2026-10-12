#!/usr/bin/env bash
# Runs the Zeta Test Company engagement through the REAL interface against a REAL migrated database, with no Supabase account:
#   PostgreSQL 16 (migrations + test shim) <- PostgREST <- gateway.mjs (stands in for Supabase Auth + the /rest/v1 edge) <- Next.js (web/) <- headless Chromium
# This proves the interface works end to end; it is a development harness, not part of CI. Needs: local PostgreSQL 16 (as for scripts/test-db.sh), a PostgREST binary
# (https://github.com/PostgREST/postgrest/releases, v12) in $POSTGREST or on PATH, Node, and `npm i --no-save --prefix scripts/pilot-live playwright-core` and a Chromium (set CHROMIUM_PATH to its executable).
set -euo pipefail
cd "$(dirname "$0")/../.."
HERE=scripts/pilot-live; B=${ADA_TEST_PG_URL:-postgresql://postgres:postgres@localhost:5432/postgres}; BASE=${B%/*}; U=$BASE/ada_live
PGREST=${POSTGREST:-postgrest}
pkill -x postgrest 2>/dev/null || true
psql -X -q "$B" -c "drop database if exists ada_live" -c "create database ada_live"
psql -X -q -v ON_ERROR_STOP=1 "$U" -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do psql -X -q -v ON_ERROR_STOP=1 "$U" -f "$f" >/dev/null; done
psql -X -q -v ON_ERROR_STOP=1 "$U" -f supabase/tests/01_helpers.sql >/dev/null
psql -X -q "$B" -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login password 'x' noinherit; end if; end \$\$" -c "grant anon, authenticated to authenticator"
psql -X -q -v ON_ERROR_STOP=1 "$U" -f $HERE/seed.sql >/dev/null
$PGREST $HERE/pgrst.conf >/tmp/ada-pgrst.log 2>&1 & PG=$!
node $HERE/gateway.mjs >/tmp/ada-gateway.log 2>&1 & GW=$!
[ -d public-api/node_modules/pg ] || npm ci --no-audit --no-fund --prefix public-api >/dev/null
psql -X -q "$B" -c "alter role ada_public_api login password 'live-only'"
ADA_PUBLIC_API_SSL=off ADA_PUBLIC_API_DATABASE_URL="postgresql://ada_public_api:live-only@${BASE#postgresql://*@}/ada_live" PORT=8787 node public-api/src/server.mjs >/tmp/ada-public-api.log 2>&1 & PA=$!
(cd web && NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321 NEXT_PUBLIC_SUPABASE_ANON_KEY=anon-key npx next dev -p 3100 >/tmp/ada-next.log 2>&1) & NX=$!
trap 'kill $PG $GW $NX $PA 2>/dev/null; psql -X -q "$B" -c "alter role ada_public_api nologin password null" >/dev/null 2>&1; pkill -f "next dev -p 3100" 2>/dev/null || true' EXIT
for i in $(seq 1 60); do curl -s -o /dev/null localhost:3100/login && break; sleep 1; done
node $HERE/zeta-journey.mjs
