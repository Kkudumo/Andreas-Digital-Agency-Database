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
# committed demo documents: a contract with a signed version and a draft amendment (plus a link and a legal hold), a restricted file and a critical file
psql_ "$SRC_URL" >/dev/null <<'SQL'
select tests.mk_doc('web_lead', 'rd1', 'Rehearsal agreement', 'contract', 'web', 'project:P_web');
select tests.add_ver('web_lead', 'rd1', 'rd1v1', 'rehearsal agreement v1');
select tests.scalar('web_lead', format($q$ select document_version_transition(%L, 'review')::text $q$, tests.id('ver:rd1v1')));
select tests.scalar('ceo', format($q$ select document_version_transition(%L, 'approved')::text $q$, tests.id('ver:rd1v1')));
select tests.scalar('ceo', format($q$ select document_version_transition(%L, 'signed', 'Signed by the client', current_date - 3)::text $q$, tests.id('ver:rd1v1')));
select tests.add_ver('web_lead', 'rd1', 'rd1v2', 'rehearsal agreement amendment', 'Amendment 1');
select tests.scalar('ceo', format($q$ select document_hold_place(%L, 'rehearsal hold')::text $q$, tests.id('doc:rd1')));
select tests.mk_doc('ceo', 'rd2', 'Rehearsal legal file', 'legal', 'web');
select tests.add_ver('ceo', 'rd2', 'rd2v1', 'rehearsal legal content');
select tests.mk_doc('ceo', 'rd3', 'Rehearsal critical file', 'report', 'web', null, null, true);
select tests.add_ver('ceo', 'rd3', 'rd3v1', 'rehearsal critical content');
SQL
[ "$(psql_ "$SRC_URL" -Atc "select count(*) from documents")" = "3" ] || fail "demo documents were not created in the source"
# committed demo organizations: one company that is client + supplier + partner, plus an ambiguous look-alike pair awaiting human review
psql_ "$SRC_URL" >/dev/null <<'SQL'
insert into clients (name, registration_number) values ('Rehearsal Org Ltd', 'RO-1');
insert into suppliers (name) values ('REHEARSAL ORG');
insert into partners (name, kind, status) values ('Rehearsal Org (Pty)', 'technology', 'active');
insert into suppliers (name) values ('Rehearse Lookalike');
insert into clients (name) values ('Rehearse Lookalikes');
SQL
[ "$(psql_ "$SRC_URL" -Atc "select (select count(*) from organizations where name_key = 'rehearsalorg')::text || ',' || (select count(*) from organization_reviews where status = 'open')")" = "1,1" ] || fail "demo organizations were not created as expected in the source"
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

echo "== documents survive the restore: records, versions, content references, links, classification, history, immutability"
[ "$(psql_ "$SRC_URL" -Atc "select document_backup_manifest()::text")" = "$(psql_ "$DST_URL" -Atc "select document_backup_manifest()::text")" ] || fail "document backup manifest differs (records / versions / references / links / classification / history / registry)"
ok "document manifest identical (3 documents, versions, content references and hashes, links, classification, history, registry entries)"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from documents d join entity_registry r on r.table_name = 'documents' and r.entity_id = d.id")" = "3" ] || fail "restored documents lost their registry entries"
ok "every restored document still has its permanent institutional ID in the registry"
if psql_ "$DST_URL" -c "update document_versions set label = 'tampered' where state = 'signed'" >/dev/null 2>&1; then fail "a signed version could be edited after restore"; fi
if psql_ "$DST_URL" -c "update document_versions set content_hash = repeat('0', 64) where version_no = 1" >/dev/null 2>&1; then fail "version content was editable after restore"; fi
if psql_ "$DST_URL" -c "delete from document_events" >/dev/null 2>&1; then fail "document history could be deleted after restore"; fi
ok "signed-version immutability, content permanence and append-only history still enforced after restore"
echo "  (the same document checks run against the restored database's behaviour below)"

echo "== organizations survive the restore: one identity, many roles, stable role IDs, mirrors, review queue"
[ "$(psql_ "$SRC_URL" -Atc "select organization_backup_manifest()::text")" = "$(psql_ "$DST_URL" -Atc "select organization_backup_manifest()::text")" ] || fail "organization backup manifest differs (organizations / role links / reviews / registry)"
ok "organization manifest identical (organizations, role links, review queue, zero mirror drift)"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from organization_mirror_drift()")" = "0" ] || fail "mirror drift after restore"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from clients where organization_id is null") $(psql_ "$DST_URL" -Atc "select count(*) from suppliers where organization_id is null")" = "0 0" ] || fail "roles without an organization after restore"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from organizations o join entity_registry r on r.table_name = 'organizations' and r.entity_id = o.id")" = "$(psql_ "$SRC_URL" -Atc "select count(*) from organizations")" ] || fail "restored organizations lost their registry entries"
ok "every restored role has its organization, every organization its permanent ID, no mirror differs"
psql_ "$DST_URL" -c "update clients set name = 'Rehearsal Org Renamed' where name = 'Rehearsal Org Ltd'" >/dev/null
[ "$(psql_ "$DST_URL" -Atc "select (select o.name from organizations o join clients c on c.organization_id = o.id where c.registration_number = 'RO-1') || '|' || (select s.name from suppliers s join clients c on c.organization_id = s.organization_id where c.registration_number = 'RO-1') || '|' || (select count(*) from organization_mirror_drift())")" = "Rehearsal Org Renamed|Rehearsal Org Renamed|0" ] || fail "mirror redirect / sync does not work after restore"
ok "after restore a direct write to a mirror is still redirected to the organization and every role follows"

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
d1=$(psql_ "$DST_URL" -Atc "select tests.scalar('web_lead', 'select count(*)::text from documents') || '/' || tests.scalar('ceo', 'select count(*)::text from documents')")
[ "$d1" = "1/3" ] || fail "restored document visibility wrong (web lead / ceo): $d1 (expected 1/3: the lead sees only the agreement; the CEO sees the restricted and the critical file too)"
ok "restored document access is unchanged: the web lead sees only the agreement; restricted and critical files are hidden from them"
d2=$(psql_ "$DST_URL" -At <<'SQL'
select tests.scalar('ceo', $q$ select (document_register('Post-restore document', 'report', (select id from divisions where key = 'web')) ->> 'institutional_id') $q$);
SQL
)
echo "$d2" | grep -Eq '^[0-9A-HJKMNP-TV-Z]{9}$' || fail "registering a document after restore failed: $d2"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from entity_registry where institutional_id = '$d2'")" = "1" ] && [ "$(psql_ "$SRC_URL" -Atc "select count(*) from entity_registry where institutional_id = '$d2'")" = "0" ] || fail "post-restore document ID collides with an existing one"
ok "document IDs keep being minted centrally after restore (new ID $d2, never reused)"
psql_ "$DST_URL" -f supabase/tests/30_structure.sql 2>&1 >/dev/null | grep -E "checks" | sed 's/^psql:[^:]*:[0-9]*: NOTICE:  /  structure suite on restored DB: /'
echo "MIGRATION REHEARSAL PASSED"
