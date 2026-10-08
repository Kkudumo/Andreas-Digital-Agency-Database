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
# committed demo communications: a thread with two messages (an email from a stranger, a call), a client link and an attached document; a restricted thread; a thread
# under legal hold; a thread whose content was disposed of after retention (two-person approval)
psql_ "$SRC_URL" >/dev/null <<'SQL'
select tests.mk_thread('web_lead', 'rc1', 'Rehearsal enquiry thread');
select tests.say('web_lead', 'rc1', 'rc1a', 'email', 'inbound', 'Rehearsal enquiry body', jsonb_build_array(jsonb_build_object('role', 'from', 'address', 'stranger@rehearsal.example')));
select tests.say('web_lead', 'rc1', 'rc1b', 'phone_call', 'outbound', null);
select tests.clink('web_lead', 'rc1', 'clients', 'client:C_web');
select tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:rc1a'), tests.id('doc:rd1')));
select tests.mk_thread('ceo', 'rc2', 'Rehearsal restricted thread', 'web', 'restricted');
select tests.say('ceo', 'rc2', 'rc2a', 'email', 'inbound', 'Rehearsal restricted body');
select tests.mk_thread('ceo', 'rc3', 'Rehearsal held thread');
select tests.say('ceo', 'rc3', 'rc3a', 'email', 'inbound', 'Rehearsal held body');
select tests.scalar('ceo', format($q$ select communication_hold_place(%L, 'rehearsal hold')::text $q$, tests.id('thr:rc3')));
select tests.mk_thread('ceo', 'rc4', 'Rehearsal disposed thread');
select tests.say('ceo', 'rc4', 'rc4a', 'email', 'inbound', 'Rehearsal disposed body', jsonb_build_array(jsonb_build_object('role', 'from', 'address', 'gone@rehearsal.example')));
select tests.try('ceo', format($q$ select communication_set_retention(%L, 'transient_1y', null, 'rehearsal') $q$, tests.id('thr:rc4')));
select tests.try('ceo', format($q$ select communication_archive(%L, 'rehearsal') $q$, tests.id('thr:rc4')));
select tests.backdate_thread('thr:rc4', interval '400 days');
select tests.remember('disp:rc4', tests.scalar('admin', format($q$ select communication_request_disposal(%L, 'rehearsal disposal')::text $q$, tests.id('thr:rc4'))));
select tests.scalar('ceo', format($q$ select communication_disposal_decide(%L, true, 'approved')$q$, tests.id('disp:rc4')));
SQL
[ "$(psql_ "$SRC_URL" -Atc "select count(*) from communication_threads")" = "4" ] || fail "demo communications were not created in the source"
[ "$(psql_ "$SRC_URL" -Atc "select count(*) from communication_messages where body_purged_at is not null")" = "1" ] || fail "the demo disposal did not purge the content"
# committed demo organizations: one company that is client + supplier + partner, plus an ambiguous look-alike pair awaiting human review
psql_ "$SRC_URL" >/dev/null <<'SQL'
insert into clients (name, registration_number) values ('Rehearsal Org Ltd', 'RO-1');
insert into suppliers (name) values ('REHEARSAL ORG');
insert into partners (name, kind, status) values ('Rehearsal Org (Pty)', 'technology', 'active');
insert into suppliers (name) values ('Rehearse Lookalike');
insert into clients (name) values ('Rehearse Lookalikes');
SQL
[ "$(psql_ "$SRC_URL" -Atc "select (select count(*) from organizations where name_key = 'rehearsalorg')::text || ',' || (select count(*) from organization_reviews where status = 'open')")" = "1,1" ] || fail "demo organizations were not created as expected in the source"
# committed demo domains: an active one with a client relation and a two-period ledger, a retired one, a hidden one, one with an open transfer
psql_ "$SRC_URL" >/dev/null <<'SQL'
insert into suppliers (name) values ('Rehearsal Registrar');
insert into domains (name, division_id) select n, (select id from divisions where key = 'web') from unnest(array['rehearsal.example', 'retired-rehearsal.example', 'transferring-rehearsal.example']) n;
insert into domains (name, division_id, classification) values ('hidden-rehearsal.example', (select id from divisions where key = 'web'), 'restricted');
insert into domain_relations (domain_id, relation, entity_institutional_id)
  select d.id, 'registrar', (select institutional_id from entity_registry where table_name = 'suppliers' and entity_id = (select id from suppliers where name = 'Rehearsal Registrar')) from domains d where d.name like '%rehearsal.example';
insert into domain_relations (domain_id, relation, entity_institutional_id)
  select d.id, 'client', (select institutional_id from entity_registry where table_name = 'clients' and entity_id = (select id from clients where name = 'C_web')) from domains d where d.name = 'rehearsal.example';
insert into domain_registrations (domain_id, kind, period_start, period_end, order_reference) select d.id, 'registration', current_date - 65, current_date + 300, 'REH-1' from domains d where d.name like '%rehearsal.example';
insert into domain_registrations (domain_id, kind, period_start, period_end, order_reference) select d.id, 'renewal', current_date + 300, current_date + 665, 'REH-2' from domains d where d.name = 'rehearsal.example';
update domains set status = 'retired' where name = 'retired-rehearsal.example';
insert into domain_transfers (domain_id, kind, destination_note, reason) select id, 'out', 'to another agency', 'rehearsal' from domains where name = 'transferring-rehearsal.example';
SQL
[ "$(psql_ "$SRC_URL" -Atc "select count(*) from domains")" = "4" ] || fail "demo domains were not created in the source"
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

echo "== domains survive the restore: identity, ledger, relations, transfers, lifecycle rules"
[ "$(psql_ "$SRC_URL" -Atc "select domain_backup_manifest()::text")" = "$(psql_ "$DST_URL" -Atc "select domain_backup_manifest()::text")" ] || fail "domain backup manifest differs (records / relations / ledger / transfers / history / registry)"
ok "domain manifest identical (4 domains, relations with history, the ledger, transfers, events, registry entries)"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from domain_ledger_drift()")" = "0" ] || fail "ledger drift after restore"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from domains d join entity_registry r on r.table_name = 'domains' and r.entity_id = d.id")" = "4" ] || fail "restored domains lost their registry entries"
ok "every restored domain has its permanent institutional ID; the expiry mirror agrees with the ledger"
if psql_ "$DST_URL" -c "update domains set description = 'x' where name = 'retired-rehearsal.example'" >/dev/null 2>&1; then fail "a retired domain could be edited after restore"; fi
if psql_ "$DST_URL" -c "update domain_registrations set period_end = period_end + 1" >/dev/null 2>&1; then fail "the registration ledger was editable after restore"; fi
if psql_ "$DST_URL" -c "delete from domains" >/dev/null 2>&1; then fail "domains could be deleted after restore"; fi
ok "retired-record, append-only ledger and never-delete rules still enforced after restore"

echo "== communications survive the restore: records, messages and hashes, relationships, attachments, holds, disposal, history, immutability"
[ "$(psql_ "$SRC_URL" -Atc "select communication_backup_manifest()::text")" = "$(psql_ "$DST_URL" -Atc "select communication_backup_manifest()::text")" ] || fail "communication backup manifest differs (threads / messages / hashes / links / attachments / history / registry)"
ok "communication manifest identical (4 threads, 5 messages with their hashes, links, attachments, holds, disposal, events, registry entries)"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from communication_integrity_drift()")" = "0" ] || fail "message integrity drift after restore"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from communication_threads t join entity_registry r on r.table_name = 'communication_threads' and r.entity_id = t.id")" = "4" ] || fail "restored threads lost their registry entries"
[ "$(psql_ "$DST_URL" -Atc "select count(*) from communication_messages t join entity_registry r on r.table_name = 'communication_messages' and r.entity_id = t.id")" = "5" ] || fail "restored messages lost their registry entries"
ok "every restored thread and message has its permanent institutional ID; every undisposed body still matches its recorded SHA-256"
if psql_ "$DST_URL" -c "update communication_messages set body = 'tampered' where body is not null" >/dev/null 2>&1; then fail "a message body was editable after restore"; fi
if psql_ "$DST_URL" -c "delete from communication_messages" >/dev/null 2>&1; then fail "messages could be deleted after restore"; fi
if psql_ "$DST_URL" -c "delete from communication_threads" >/dev/null 2>&1; then fail "threads could be deleted after restore"; fi
if psql_ "$DST_URL" -c "update communication_threads set status = 'open' where status = 'disposed'" >/dev/null 2>&1; then fail "a disposed thread could be reopened after restore"; fi
if psql_ "$DST_URL" -c "delete from communication_events" >/dev/null 2>&1; then fail "communication history could be deleted after restore"; fi
ok "append-only messages, never-delete and closed-record rules still enforced after restore"

echo "== verify the restored system behaves"
before=$(psql_ "$SRC_URL" -Atc "select max(substring(ada_id from '[0-9]+\$')::int) from clients")
psql_ "$DST_URL" -c "insert into clients (name) values ('Post-restore client')" >/dev/null
after=$(psql_ "$DST_URL" -Atc "select substring(ada_id from '[0-9]+\$')::int from clients where name = 'Post-restore client'")
[ "$after" = "$((before + 1))" ] || fail "ADA ID sequence did not continue ($before -> $after)"; ok "ADA ID sequence continues after restore ($before -> $after)"
n=$(psql_ "$DST_URL" -Atc "select jsonb_array_length(public_api.divisions(encode(extensions.digest('testkey-main','sha256'),'hex')))")
[ "$n" = "6" ] || fail "public API on restored DB returned $n divisions"; ok "public API works on the restored database (6 public divisions)"
psql_ "$DST_URL" -f supabase/tests/01_helpers.sql >/dev/null
r1=$(psql_ "$DST_URL" -At <<'SQL'
select tests.scalar('web_lead', $q$ select (domain_renew((select id from domains where name = 'rehearsal.example'), 1, 'REH-POST') ->> 'period_start') $q$) || '|' || tests.scalar('web_lead', $q$ select count(*)::text from domains $q$) || '|' || tests.scalar('ceo', $q$ select count(*)::text from domains $q$);
SQL
)
[ "$r1" = "$(psql_ "$SRC_URL" -Atc "select (current_date + 665)::text")|3|4" ] || fail "restored domain behaviour wrong: $r1 (expected renewal from the old end, web lead sees 3, CEO 4)"
ok "after restore a renewal continues the ledger from where it ended; the hidden domain stays hidden from the web lead"
c1=$(psql_ "$DST_URL" -At <<'SQL'
select tests.scalar('web_lead', 'select count(*)::text from communication_threads') || '|' || tests.scalar('ceo', 'select count(*)::text from communication_threads') || '|' ||
       tests.scalar('web_lead', format($q$ select (communication_read(%L) -> 'messages' -> 0 ->> 'body') $q$, (select id from communication_threads where subject = 'Rehearsal enquiry thread'))) || '|' ||
       tests.scalar('web_lead', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, (select id from communication_threads where status = 'disposed'))) || '|' ||
       tests.scalar('fin', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, (select id from communication_threads where subject = 'Rehearsal enquiry thread'))) || '|' ||
       tests.scalar('web_lead', format($q$ select (communication_message_add(%L, 'email', 'outbound', now() - interval '1 minute', 'Post-restore reply') ->> 'seq') $q$, (select id from communication_threads where subject = 'Rehearsal enquiry thread'))) || '|' ||
       tests.scalar('ceo', format($q$ select communication_request_disposal(%L, 'x')::text $q$, (select id from communication_threads where subject = 'Rehearsal held thread')));
SQL
)
[ "$c1" = "3|4|Rehearsal enquiry body|null|null|3|ERR:42501" ] || fail "restored communication behaviour wrong: $c1 (expected: lead sees 3, CEO 4, body readable by the lead, disposed and metadata-only reads null, numbering continues at 3, the held thread is not yet archived)"
ok "after restore: the restricted thread stays hidden from the lead, content is readable only by those who may read it, numbering continues, disposed content stays gone"
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
