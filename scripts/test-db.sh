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
node scripts/check-protected-tests.mjs
psql_ "$URL" -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do
  echo "migrate  $(basename "$f")"
  psql_ "$URL" -f "$f" >/dev/null
done
psql_ "$URL" -f supabase/tests/01_helpers.sql >/dev/null

status=0
for f in supabase/tests/[1-9][0-9]*_*.sql; do
  echo "== $(basename "$f")"
  if ! grep -q 'tests.finish()' "$f"; then echo "  FAIL: $(basename "$f") never calls tests.finish(), so its failures would go unreported"; status=1; fi
  if out=$(psql_ "$URL" -f "$f" 2>&1 >/dev/null); then rc=0; else rc=$?; fi
  # keep failures, errors and the summary line; drop passing checks
  printf '%s\n' "$out" | sed -E 's/^psql:[^:]+:[0-9]+: //' | grep -vE '^(NOTICE:  ok  |CONTEXT:|PL/pgSQL|LINE|HINT)' | sed 's/^/  /' || true
  [ "$rc" -eq 0 ] || status=1
done
# Concurrency: ADA IDs must stay unique and gap-free under parallel inserts from separate connections.
echo "== concurrent_ids"
N_PROC=8; N_ROWS=40
for i in $(seq 1 $N_PROC); do
  psql_ "$URL" -c "insert into clients (name) select 'c$i-' || g from generate_series(1, $N_ROWS) g" >/dev/null &
done
wait
res=$(psql_ "$URL" -Atc "select count(*) || ',' || count(distinct ada_id) || ',' || max(substring(ada_id from '[0-9]+\$')::int) from clients")
expected="$((N_PROC * N_ROWS)),$((N_PROC * N_ROWS)),$((N_PROC * N_ROWS))"
if [ "$res" = "$expected" ]; then echo "  $((N_PROC * N_ROWS)) parallel inserts: all ADA IDs unique and gap-free"; else echo "  FAIL concurrent ids: got $res expected $expected"; status=1; fi

# Concurrency: ADA-AST IDs stay unique and gap-free when assets are registered in parallel from separate connections.
echo "== concurrent_asset_ids"
for i in $(seq 1 $N_PROC); do
  psql_ "$URL" -c "insert into assets (name, category_id, division_id) select 'a$i-' || g, (select id from asset_categories where key = 'other'), (select id from divisions where key = 'web') from generate_series(1, $N_ROWS) g" >/dev/null &
done
wait
res=$(psql_ "$URL" -Atc "select count(*) || ',' || count(distinct ada_id) || ',' || max(substring(ada_id from '[0-9]+\$')::int) from assets")
if [ "$res" = "$expected" ]; then echo "  $((N_PROC * N_ROWS)) parallel asset registrations: all ADA-AST IDs unique and gap-free"; else echo "  FAIL concurrent asset ids: got $res expected $expected"; status=1; fi

# Concurrency across ENTITY FAMILIES: one central generator, many entity types at once. Every institutional ID must be unique,
# well-formed (9 chars, check character valid) and every (type, cycle) counter must equal the number of IDs issued from it (no gaps, no reuse).
echo "== concurrent_institutional_ids"
for i in $(seq 1 $N_PROC); do
  psql_ "$URL" -c "insert into clients (name) select 'm$i-' || g from generate_series(1, $N_ROWS) g;
                   insert into assets (name, category_id, division_id) select 'm$i-' || g, (select id from asset_categories where key = 'other'), (select id from divisions where key = 'tech') from generate_series(1, $N_ROWS) g;
                   insert into people (full_name, email) select 'Person $i ' || g, 'p${i}_' || g || '@conc.test' from generate_series(1, $N_ROWS) g;
                   insert into tickets (title, division_id) select 'm$i-' || g, (select id from divisions where key = 'web') from generate_series(1, $N_ROWS) g;
                   insert into domains (name, division_id) select 'm$i-' || g || '.example', (select id from divisions where key = 'web') from generate_series(1, $N_ROWS) g;
                   select set_config('ada.communication_start', 'on', true);
                   insert into communication_threads (subject, division_id, retention_class_id, retention_months) select 'c$i-' || g, (select id from divisions where key = 'web'), (select id from retention_classes where key = 'communications_standard'), 60 from generate_series(1, $N_ROWS) g;
                   select set_config('ada.communication_record', 'on', true);
                   insert into communication_messages (thread_id, seq, type_key, direction, occurred_at, body, body_hash, division_id) select t.id, 1, 'phone_call', 'inbound', now(), null, repeat('0', 64), t.division_id from communication_threads t where t.subject like 'c$i-%';
                   insert into documents (title, document_type_id, division_id, retention_class_id, retention_months) select 'm$i-' || g, (select id from document_types where key = 'report'), (select id from divisions where key = 'web'), (select id from retention_classes where key = 'general_5y'), 60 from generate_series(1, $N_ROWS) g;" >/dev/null &
done
wait
res=$(psql_ "$URL" -Atc "select count(*) || ',' || count(distinct institutional_id) || ',' || count(*) filter (where institutional_id !~ '^[0-9A-HJKMNP-TV-Z]{9}\$' or not ada_id_valid(institutional_id)) || ',' || (select count(*) from id_counters c where c.last_value <> (select count(*) from entity_registry r where substr(r.institutional_id, 1, 3) = c.type_code || c.cycle_code)) || ',' || (select count(*) from entity_registry where ada_id is not null and table_name in ('clients','assets','people','tickets') and (select count(*) from entity_registry x where x.ada_id = entity_registry.ada_id) > 1) from entity_registry")
total=$(psql_ "$URL" -Atc "select count(*) from entity_registry")
if [ "$res" = "$total,$total,0,0,0" ]; then echo "  $total registered entities across all families: every institutional ID unique, well-formed and gap-free; no legacy alias collisions"; else echo "  FAIL institutional ids: got $res expected $total,$total,0,0,0"; status=1; fi

# Concurrency: a payment can never be allocated beyond its amount, nor an invoice beyond its total, however many sessions race.
echo "== concurrent_allocations"
psql_ "$URL" -f supabase/tests/concurrency/finance_setup.sql >/dev/null
psql_ "$URL" -At -c "select string_agg(id::text, ',' order by created_at, id) from (select i.id, i.created_at from invoices i join clients c on c.id = i.client_id where c.name = 'Concurrency Client') q" > /tmp/conc_inv_$$.txt
IFS=',' read -r -a INVS < /tmp/conc_inv_$$.txt
SMALL=$(psql_ "$URL" -At -c "select p.id from payments p join clients c on c.id = p.client_id where c.name = 'Concurrency Client' and p.amount = 1000")
mapfile -t SLICES < <(psql_ "$URL" -At -c "select p.id from payments p join clients c on c.id = p.client_id where c.name = 'Concurrency Client' and p.amount = 100 order by p.created_at, p.id")
OKDIR=$(mktemp -d)
# A start barrier: one session holds an exclusive advisory lock for a moment; every racer blocks on it first and they are
# all released together, so the allocations really do collide instead of running one after another.
( psql -X -q "$URL" -c "select pg_advisory_lock(7770001), pg_sleep(2)" >/dev/null 2>&1 ) &
sleep 0.5
for n in 0 1 2 3 4 5 6 7; do   # eight sessions race to spend the SAME 1000 payment on eight different invoices
  ( psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "select pg_advisory_lock_shared(7770001); insert into payment_allocations (payment_id, invoice_id, amount) values ('$SMALL', '${INVS[$n]}', 1000)" >/dev/null 2>&1 && touch "$OKDIR/small_$n" ) &
done
for n in $(seq 0 13); do       # fourteen sessions each pay 100 of the ninth invoice (total 1000) from their own 100 payment
  ( psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "select pg_advisory_lock_shared(7770001); insert into payment_allocations (payment_id, invoice_id, amount) values ('${SLICES[$n]}', '${INVS[8]}', 100)" >/dev/null 2>&1 && touch "$OKDIR/big_$n" ) &
done
wait
res=$(psql_ "$URL" -At -c "select coalesce((select sum(amount) from payment_allocations where payment_id = '$SMALL' and status = 'active'), 0) || ',' || (select count(*) from payment_allocations where payment_id = '$SMALL') || ',' || coalesce((select sum(amount) from payment_allocations where invoice_id = '${INVS[8]}' and status = 'active'), 0)")
rm -rf "$OKDIR" /tmp/conc_inv_$$.txt
if [ "$res" = "1000.00,1,1000.00" ]; then echo "  22 racing allocations: the contested payment was spent exactly once and the invoice was never over-paid"; else echo "  FAIL concurrent allocations: got $res expected 1000.00,1,1000.00"; status=1; fi

# Concurrency: versions of ONE document, added by eight sessions at once through the real command, stay consecutive and unique.
echo "== concurrent_document_versions"
psql_ "$URL" -f supabase/tests/concurrency/documents_setup.sql >/dev/null
DOC=$(psql_ "$URL" -At -c "select id from documents where title = 'Concurrent versions'")
for i in $(seq 1 $N_PROC); do
  ( for k in 1 2 3 4 5; do
      psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "select set_config('request.jwt.claim.sub', md5('conc-doc-user'), false); set role authenticated; select document_add_version('$DOC', 'memstore', 'c/$i/$k', encode(sha256(convert_to('c$i-$k', 'UTF8')), 'hex'), 10, 'application/pdf')" >/dev/null 2>&1
    done ) &
done
wait
res=$(psql_ "$URL" -At -c "select count(*) || ',' || count(distinct version_no) || ',' || max(version_no) || ',' || min(version_no) from document_versions where document_id = '$DOC'")
if [ "$res" = "40,40,40,1" ]; then echo "  40 versions added by 8 racing sessions: numbered 1..40, no duplicates, no gaps"; else echo "  FAIL concurrent document versions: got $res expected 40,40,40,1"; status=1; fi

# Concurrency: organizations. Eight sessions create the SAME client at once (exactly one wins, one organization), and eight client+supplier PAIRS race
# for the same name (each pair ends as ONE organization with BOTH roles - the relationship never creates a second organization).
echo "== concurrent_organizations"
for i in $(seq 1 $N_PROC); do
  ( psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "insert into clients (name) values ('Race Corporation')" >/dev/null 2>&1 ) &
done
wait
for i in $(seq 1 $N_PROC); do
  ( psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "insert into clients (name) values ('Pairing $i Holdings')" >/dev/null 2>&1 ) &
  ( psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "insert into suppliers (name) values ('Pairing $i Holdings')" >/dev/null 2>&1 ) &
done
wait
res=$(psql_ "$URL" -At -c "select (select count(*) from clients where name = 'Race Corporation') || ',' || (select count(*) from organizations where name = 'Race Corporation') || ',' || (select count(*) from organizations o where o.name like 'Pairing % Holdings' and exists (select 1 from clients c where c.organization_id = o.id) and exists (select 1 from suppliers s where s.organization_id = o.id)) || ',' || (select count(*) from organizations where name like 'Pairing % Holdings') || ',' || (select count(*) from organization_mirror_drift())")
if [ "$res" = "1,1,8,8,0" ]; then echo "  8 racing creations of one client: exactly one organization and one client; 8 racing client+supplier pairs: 8 organizations, each with both roles; no mirror drift"; else echo "  FAIL concurrent organizations: got $res expected 1,1,8,8,0"; status=1; fi

# Upgrade path: a database that already holds clients and suppliers (migrations up to 0037) is upgraded by 0038 itself. Strong evidence links roles to
# one organization; ambiguity stays separate with a review item; IDs, aliases and audit history survive; nothing is left unlinked.
echo "== upgrade_0038"
UDB="${DB}_up"; UURL="$BASE/$UDB"
psql_ "$ADMIN_URL" -c "create database $UDB"
psql_ "$UURL" -f supabase/tests/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do case "$f" in *0038_*|*0039_*|*0040_*) continue;; esac; psql_ "$UURL" -f "$f" >/dev/null; done
psql_ "$UURL" -f supabase/tests/concurrency/org_legacy_seed.sql >/dev/null
before=$(psql_ "$UURL" -At -c "select string_agg(id::text || ada_id, ',' order by id) from (select id, ada_id from clients union all select id, ada_id from suppliers) x")
audit_before=$(psql_ "$UURL" -At -c "select count(*) from audit_log")
psql_ "$UURL" -f supabase/migrations/0038_organization_unification.sql >/dev/null
after=$(psql_ "$UURL" -At -c "select string_agg(id::text || ada_id, ',' order by id) from (select id, ada_id from clients union all select id, ada_id from suppliers) x")
res=$(psql_ "$UURL" -At -c "select (select count(*) from organizations) || ',' || (select count(*) from clients where organization_id is null) || ',' || (select count(*) from suppliers where organization_id is null) || ',' || (select count(*) from organization_reviews where status = 'open' and origin = 'migration') || ',' || (select count(*) from organization_mirror_drift()) || ',' || (select count(distinct c.organization_id) from clients c join suppliers s on s.organization_id = c.organization_id where c.name like 'Legacy Alpha%' or c.name = 'Legacy Gamma' or c.name = 'Hidden Hotel') || ',' || (select count(*) from entity_registry where table_name = 'organizations' and origin_kind = 'migrated') || ',' || (select count(*) from audit_log where table_name in ('clients', 'suppliers') and action = 'INSERT') || ',' || (select count(*) from clients where deleted_at is not null and updated_at < now() - interval '1 day')")
if [ "$before" = "$after" ] && [ "$res" = "9,0,0,3,0,3,9,13,1" ] && [ "$(psql_ "$UURL" -At -c "select count(*) from audit_log")" -ge "$audit_before" ]; then
  echo "  existing clients and suppliers upgraded: 9 organizations (3 shared by client + supplier), 3 ambiguous pairs queued for review, all role IDs and ADA aliases unchanged, audit history kept, no drift"
else echo "  FAIL upgrade_0038: ids-same=$([ "$before" = "$after" ] && echo yes || echo no) got $res expected 9,0,0,3,0,3,9,13,1"; status=1; fi
psql_ "$ADMIN_URL" -c "drop database if exists $UDB" >/dev/null 2>&1 || true

# Concurrency: domains. Eight sessions create the SAME domain name at once (one record, one registry entry); eight renewals with DIFFERENT order references
# extend the ledger without gaps or overlaps; eight renewals with the SAME reference add exactly one period; eight transfer requests open exactly one transfer.
echo "== concurrent_domains"
psql_ "$URL" -f supabase/tests/concurrency/domains_setup.sql >/dev/null
DIVW=$(psql_ "$URL" -At -c "select id from divisions where key = 'web'")
D1=$(psql_ "$URL" -At -c "select id from domains where name = 'race-distinct.example'")
D2=$(psql_ "$URL" -At -c "select id from domains where name = 'race-same.example'")
D3=$(psql_ "$URL" -At -c "select id from domains where name = 'race-transfer.example'")
AS="select set_config('request.jwt.claim.sub', md5('conc-dom-user'), false); set role authenticated;"
for i in $(seq 1 $N_PROC); do
  ( psql -X -q "$URL" -c "$AS select domain_create('race-create.example', '$DIVW')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$AS select domain_renew('$D1', 1, 'DR-$i')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$AS select domain_renew('$D2', 1, 'SAME-REF')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$AS select domain_transfer_request('$D3', 'out', null, null, 'race', 'race')" >/dev/null 2>&1 ) &
done
wait
res=$(psql_ "$URL" -At -c "select (select count(*) from domains where name = 'race-create.example') || ',' || (select count(*) from entity_registry r join domains d on d.id = r.entity_id and r.table_name = 'domains' where d.name = 'race-create.example') || ',' || (select count(*) from domain_registrations where domain_id = '$D1') || ',' || (select count(*) from (select period_start, lag(period_end) over (order by period_start) p from domain_registrations where domain_id = '$D1') x where p is not null and period_start <> p) || ',' || (select expires_on = (current_date + 300 + interval '8 years')::date from domains where id = '$D1') || ',' || (select count(*) from domain_registrations where domain_id = '$D2') || ',' || (select count(*) from domain_transfers where domain_id = '$D3') || ',' || (select status from domains where id = '$D3') || ',' || (select count(*) from domain_ledger_drift())")
if [ "$res" = "1,1,9,0,true,2,1,transfer_pending,0" ]; then echo "  8 racing creations of one name: one record; 8 distinct renewals: gap-free 9-period ledger; 8 same-reference renewals: exactly one period added; 8 racing transfer requests: exactly one open transfer; no ledger drift"; else echo "  FAIL concurrent domains: got $res expected 1,1,9,0,true,2,1,transfer_pending,0"; status=1; fi

# Concurrency: communications. Eight sessions record five messages each into ONE thread through the real command: the numbering stays 1..N with no gap and
# no duplicate, every message gets its own registry row. Eight sessions record the SAME source reference: exactly one message is added. Eight sessions
# start three threads each: every thread gets a distinct permanent ID and the counter equals the number of threads.
echo "== concurrent_communications"
psql_ "$URL" -f supabase/tests/concurrency/communications_setup.sql >/dev/null
T1=$(psql_ "$URL" -At -c "select id from communication_threads where subject = 'race-numbering'")
T2=$(psql_ "$URL" -At -c "select id from communication_threads where subject = 'race-source'")
DIVW=$(psql_ "$URL" -At -c "select id from divisions where key = 'web'")
ASC="select set_config('request.jwt.claim.sub', md5('conc-com-user'), false); set role authenticated;"
psql_ "$URL" -c "$ASC select communication_message_add('$T1', 'email', 'inbound', now() - interval '1 hour', 'first'), communication_message_add('$T2', 'email', 'inbound', now() - interval '1 hour', 'first')" >/dev/null
THREADS_BEFORE=$(psql_ "$URL" -At -c "select count(*) from communication_threads")
for i in $(seq 1 $N_PROC); do
  ( for k in 1 2 3 4 5; do psql -X -q "$URL" -c "$ASC select communication_message_add('$T1', 'email', 'inbound', now() - interval '1 minute', 'm$i-$k')" >/dev/null 2>&1; done ) &
  ( psql -X -q "$URL" -c "$ASC select communication_message_add('$T2', 'email', 'inbound', now() - interval '1 minute', 'same', '[]', null, null, 'connector_x', 'msg-race')" >/dev/null 2>&1 ) &
  ( for k in 1 2 3; do psql -X -q "$URL" -c "$ASC select communication_start('$DIVW', 'new-$i-$k')" >/dev/null 2>&1; done ) &
done
wait
res=$(psql_ "$URL" -At -c "select (select count(*) from communication_messages where thread_id = '$T1') || ',' || (select count(distinct seq) from communication_messages where thread_id = '$T1') || ',' || (select max(seq) from communication_messages where thread_id = '$T1') || ',' || (select count(*) from entity_registry r join communication_messages m on m.id = r.entity_id and r.table_name = 'communication_messages' where m.thread_id = '$T1') || ',' || (select count(*) from communication_messages where thread_id = '$T2' and source_reference = 'msg-race') || ',' || (select count(*) from communication_messages where thread_id = '$T2') || ',' || ((select count(*) from communication_threads) - $THREADS_BEFORE) || ',' || (select count(*) from communication_integrity_drift()) || ',' || (select (coalesce(sum(last_value), 0) = (select count(*) from communication_threads))::text from id_counters where type_code = (select id_code from entity_types where key = 'communication'))")
if [ "$res" = "41,41,41,41,1,2,$((N_PROC * 3)),0,true" ]; then echo "  8x5 racing messages: numbered 1..41 with no gap or duplicate and a registry row each; 8 racing recordings of one source reference: exactly one added; 24 racing thread starts: distinct IDs, counter equals count; no integrity drift"; else echo "  FAIL concurrent communications: got $res expected 41,41,41,41,1,2,$((N_PROC * 3)),0,true"; status=1; fi

[ "$status" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $status
