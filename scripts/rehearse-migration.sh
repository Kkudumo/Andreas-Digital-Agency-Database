#!/usr/bin/env bash
# Migration rehearsal (master spec section 53, database part): build a populated source database from
# migrations, back it up, restore into a brand-new database, and prove the copy is equivalent and working.
#   ADA_TEST_PG_URL  admin connection URL (default postgresql://postgres:postgres@localhost:5432/postgres)
set -euo pipefail
cd "$(dirname "$0")/.."
ADMIN_URL="${ADA_TEST_PG_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
BASE="${ADMIN_URL%/*}"; SRC="ada_rehearse_src_$$"; DST="ada_rehearse_dst_$$"; BAD="ada_rehearse_bad_$$"
SRC_URL="$BASE/$SRC"; DST_URL="$BASE/$DST"; WORK=$(mktemp -d)
psql_() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
trap 'psql_ "$ADMIN_URL" -c "drop database if exists $SRC" -c "drop database if exists $DST" -c "drop database if exists $BAD" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok()   { echo "  ok - $*"; }

echo "== build source from migrations"
psql_ "$ADMIN_URL" -c "create database $SRC" -c "create database $DST"
psql_ "$SRC_URL" -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do psql_ "$SRC_URL" -f "$f" >/dev/null; done
psql_ "$SRC_URL" -f supabase/tests/01_helpers.sql >/dev/null
psql_ "$SRC_URL" -c "select tests.setup(); select tests.setup_hr();" >/dev/null     # committed demo data
PGPASSWORD="${PGPASSWORD:-}" ADA_BACKUP_DIR="$WORK" DATABASE_URL="$SRC_URL" scripts/backup.sh >/dev/null
DUMP=$(ls "$WORK"/*.dump); ok "backup created and checksummed ($(du -h "$DUMP" | cut -f1))"

echo "== restore into a brand-new database"
psql_ "$DST_URL" -f supabase/tests/00_supabase_shim.sql >/dev/null                    # platform prerequisites only
pg_dump --data-only --table=auth.users "$SRC_URL" | psql_ "$DST_URL" >/dev/null         # auth is migrated separately
TARGET_URL="$DST_URL" scripts/restore.sh "$DUMP" >/dev/null; ok "restore completed"
if TARGET_URL="$DST_URL" scripts/restore.sh "$DUMP" >/dev/null 2>&1; then fail "restore must refuse a non-empty target"; fi; ok "restore refuses a non-empty target"

echo "== a restore whose security posture differs must be refused"
psql_ "$ADMIN_URL" -c "create database $BAD"; psql_ "$BASE/$BAD" -f supabase/tests/00_supabase_shim.sql >/dev/null
pg_dump --data-only --table=auth.users "$SRC_URL" | psql_ "$BASE/$BAD" >/dev/null
cp "$DUMP" "$WORK/tampered.dump"; echo "0000" > "$WORK/tampered.dump.fingerprint"
set +e; TARGET_URL="$BASE/$BAD" scripts/restore.sh "$WORK/tampered.dump" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "2" ] || fail "tampered fingerprint was not rejected (exit $rc)"; ok "restore exits non-zero on a security fingerprint mismatch"

echo "== verify equivalence"
rowcounts="select string_agg(t || '=' || c, ',' order by t) from (select tablename t, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text c from pg_tables where schemaname in ('public')) q"
[ "$(psql_ "$SRC_URL" -Atc "$rowcounts")" = "$(psql_ "$DST_URL" -Atc "$rowcounts")" ] || fail "row counts differ"; ok "every table has the same row count"
[ "$(psql_ "$SRC_URL" -Atf scripts/security-fingerprint.sql)" = "$(psql_ "$DST_URL" -Atf scripts/security-fingerprint.sql)" ] || fail "security fingerprint differs (grants / RLS / policies / function privileges)"
ok "security fingerprint identical (grants, column grants, RLS flags, policies, function privileges)"
fn="select md5(string_agg(p.oid::regprocedure::text || md5(p.prosrc), '|' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace in ('public'::regnamespace, 'public_api'::regnamespace) and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')"
[ "$(psql_ "$SRC_URL" -Atc "$fn")" = "$(psql_ "$DST_URL" -Atc "$fn")" ] || fail "function bodies differ"; ok "every function body is identical"
tg="select count(*) from pg_trigger t where not t.tgisinternal and t.tgrelid::regclass::text in (select 'public.' || tablename from pg_tables where schemaname = 'public') or (not t.tgisinternal and t.tgrelid::regclass::text in (select tablename from pg_tables where schemaname = 'public'))"
[ "$(psql_ "$SRC_URL" -Atc "$tg")" = "$(psql_ "$DST_URL" -Atc "$tg")" ] || fail "trigger counts differ"; ok "all triggers present"

echo "== verify the restored system behaves"
before=$(psql_ "$SRC_URL" -Atc "select max(substring(ada_id from '[0-9]+\$')::int) from clients")
psql_ "$DST_URL" -c "insert into clients (name) values ('Post-restore client')" >/dev/null
after=$(psql_ "$DST_URL" -Atc "select substring(ada_id from '[0-9]+\$')::int from clients where name = 'Post-restore client'")
[ "$after" = "$((before + 1))" ] || fail "ADA ID sequence did not continue ($before -> $after)"; ok "ADA ID sequence continues after restore ($before -> $after)"
n=$(psql_ "$DST_URL" -Atc "select jsonb_array_length(public_api.divisions(encode(extensions.digest('testkey-main','sha256'),'hex')))")
[ "$n" = "6" ] || fail "public API on restored DB returned $n divisions"; ok "public API works on the restored database (6 public divisions)"
psql_ "$DST_URL" -f supabase/tests/01_helpers.sql >/dev/null
c=$(psql_ "$DST_URL" -Atc "select tests.scalar('web_lead', 'select count(*)::text from clients')")
[ "$c" = "1" ] || fail "web lead sees $c clients on the restored DB (expected 1: their own division's client, not the new organization-level one)"
ok "row-level security still isolates divisions on the restored database"
psql_ "$DST_URL" -f supabase/tests/30_structure.sql 2>&1 >/dev/null | grep -E "checks" | sed 's/^psql:[^:]*:[0-9]*: NOTICE:  /  structure suite on restored DB: /'
echo "MIGRATION REHEARSAL PASSED"
