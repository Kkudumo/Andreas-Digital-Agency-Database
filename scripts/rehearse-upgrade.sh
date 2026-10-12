#!/usr/bin/env bash
# Rehearses what the owner will do on the live project: a database at the state the live project is in (migrations 0001..N applied, the first admin created),
# then the NEWER migrations applied the way scripts/supabase-apply.mjs applies them (one transaction per file), then the catalogue load, then the posture checks
# that were run on the real project after the first apply (every table has row-level security, anon holds nothing, the public API and dispatcher roles reach only
# their functions).   ./scripts/rehearse-upgrade.sh [last-live-migration, default 0052]
#   ADA_TEST_PG_URL  admin connection URL (default postgresql://postgres:postgres@localhost:5432/postgres)
set -euo pipefail
cd "$(dirname "$0")/.."
LIVE_UPTO="${1:-0052}"
ADMIN_URL="${ADA_TEST_PG_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
DB="ada_upgrade_$$"; URL="${ADMIN_URL%/*}/$DB"
psql_() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
psql_ "$ADMIN_URL" -c "create database $DB"
trap 'psql_ "$ADMIN_URL" -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
psql_ "$URL" -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do
  n=$(basename "$f" | cut -c1-4); [ "$n" \< "$(printf '%04d' $((10#$LIVE_UPTO + 1)))" ] || break
  psql_ "$URL" -f "$f" >/dev/null
done
echo "live-state database built: migrations up to $LIVE_UPTO"
psql_ "$URL" -c "insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'ceo@example.test'); select bootstrap_first_admin('11111111-1111-1111-1111-111111111111', 'Rehearsal CEO', 'ceo@example.test');" >/dev/null
for f in supabase/migrations/*.sql; do
  n=$(basename "$f" | cut -c1-4); [ "$n" \> "$LIVE_UPTO" ] || continue
  printf 'apply    %s ... ' "$(basename "$f")"
  psql_ "$URL" -1 -f "$f" >/dev/null && echo ok
done
printf 'catalogue load ... '; psql_ "$URL" -f supabase/seed_data/catalogue.sql >/dev/null 2>&1 && echo ok
psql_ "$URL" -f supabase/seed_data/catalogue.sql >/dev/null 2>&1   # a second run must be harmless
check() { local name="$1" want="$2" got; got=$(psql_ "$URL" -At -c "$3"); if [ "$got" = "$want" ]; then echo "  ok   $name"; else echo "  FAIL $name: got '$got' expected '$want'"; exit 1; fi; }
check "tables without row-level security" 0 "select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and not c.relrowsecurity"
check "table privileges held by anon" 0 "select count(*) from information_schema.role_table_grants where grantee = 'anon' and table_schema = 'public'"
check "public_api functions executable by anon or authenticated" 0 "select count(*) from pg_proc where pronamespace = 'public_api'::regnamespace and (has_function_privilege('anon', oid, 'execute') or has_function_privilege('authenticated', oid, 'execute'))"
check "ada_public_api table privileges" 0 "select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and (has_table_privilege('ada_public_api', c.oid, 'select') or has_table_privilege('ada_public_api', c.oid, 'insert'))"
check "ada_dispatcher table privileges" 0 "select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and (has_table_privilege('ada_dispatcher', c.oid, 'select') or has_table_privilege('ada_dispatcher', c.oid, 'insert'))"
check "application and import functions not executable by signed-in users" 0 "select count(*) from pg_proc where proname in ('import_vacancy', 'import_application', 'dispatch_claim', 'dispatch_report') and has_function_privilege('authenticated', oid, 'execute')"
check "migrations present" "$(ls supabase/migrations/*.sql | wc -l)" "select $(ls supabase/migrations/*.sql | wc -l)"
check "catalogue: services, prices, none published" "56,40,0" "select (select count(*) from services where status_reason = 'initial catalogue load') || ',' || (select count(*) from service_prices where decision_note = 'initial catalogue load by the owner') || ',' || (select count(*) from services where status = 'published')"
check "the first admin survives and the CEO holds the new content permissions" "1,3" "select (select count(*) from staff) || ',' || (select count(*) from role_permissions rp join roles r on r.id = rp.role_id join permissions p on p.id = rp.permission_id where r.key = 'ceo' and p.key like 'content.%')"
check "seeded settings" "5,4,6" "select (select count(*) from site_settings where key like 'company.%') || ',' || (select count(*) from site_settings where key = 'division.email') || ',' || (select count(*) from site_settings where key like 'marketing.%')"
echo "UPGRADE REHEARSAL PASSED"
