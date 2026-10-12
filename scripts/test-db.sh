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
for f in supabase/migrations/*.sql; do [ "$((10#$(basename "$f" | cut -c1-4)))" -ge 38 ] && continue; psql_ "$UURL" -f "$f" >/dev/null; done
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

# Concurrency: search. Eight sessions create 20 clients each while two sessions rebuild the whole index three times and eight sessions keep renaming ONE client and
# searching: no search fails, every created client is findable afterwards, the contested client's index row equals its record, and the index agrees with the
# authoritative data (zero drift).
echo "== concurrent_search"
psql_ "$URL" -f supabase/tests/concurrency/search_setup.sql >/dev/null
SC="select set_config('request.jwt.claim.sub', md5('conc-search-user'), false); set role authenticated;"
ERRDIR=$(mktemp -d); ERRLOG=$(mktemp)
for i in $(seq 1 $N_PROC); do
  ( psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "insert into clients (name) select 'cs$i-' || g from generate_series(1, 20) g" >/dev/null 2>>"$ERRLOG" || touch "$ERRDIR/insert_$i" ) &
  ( for k in 1 2 3 4 5; do
      psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "update clients set name = 'cs-target-$i-$k' where name like 'cs-target%'" >/dev/null 2>>"$ERRLOG" || touch "$ERRDIR/rename_${i}_$k"
      psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "$SC select search('cs target', 5, 0, true), search_suggest('cs-t')" >/dev/null 2>>"$ERRLOG" || touch "$ERRDIR/search_${i}_$k"
    done ) &
done
for j in 1 2; do ( for k in 1 2 3; do psql -X -q -v ON_ERROR_STOP=1 "$URL" -c "set role service_role; select search_rebuild()" >/dev/null 2>>"$ERRLOG" || touch "$ERRDIR/rebuild_${j}_$k"; done ) & done
wait
psql_ "$URL" -c "set role service_role; select search_rebuild()" >/dev/null
res=$(psql_ "$URL" -At -c "select (select count(*) from search_index where entity_type = 'client' and label ~ '^cs[0-9]+-[0-9]+\$') || ',' || (select count(*) from search_drift()) || ',' || (select (i.label = c.name)::text from clients c join search_index i on i.entity_id = c.id and i.table_name = 'clients' where c.name like 'cs-target%') || ',' || (select count(*) from search_index i where not exists (select 1 from entity_registry r where r.institutional_id = i.institutional_id))")
nerr=$(ls "$ERRDIR" | wc -l); rm -rf "$ERRDIR"
if [ "$res" = "160,0,true,0" ] && [ "$nerr" = "0" ]; then echo "  160 concurrent client creations indexed, 2 sessions rebuilding the index 3 times each, 8 sessions renaming one client and searching at once: no failed statement, every client findable, the contested row equals its record, zero drift, no orphans"; else echo "  FAIL concurrent search: got $res with $nerr failed statements, expected 160,0,true,0 and 0"; sed -E 's/^/    stderr: /' "$ERRLOG" | sort | uniq -c | sort -rn | head -8; status=1; fi
rm -f "$ERRLOG"

# Concurrency: credit notes. Eight sessions submit eight credit notes of 400 against ONE invoice of 1000: exactly two can be accepted (the cap holds under the
# invoice lock). Sixteen sessions apply ONE issued credit of 600 to two invoices owing 500 each: exactly one application succeeds and nothing exceeds the credit.
# A payment of 300 and a credit of 300 race to settle ONE invoice owing 300: exactly one wins, the balance never goes negative.
echo "== concurrent_credit_notes"
psql_ "$URL" -f supabase/tests/concurrency/credit_setup.sql >/dev/null
ASK="select set_config('request.jwt.claim.sub', md5('conc-credit-user'), false); set role authenticated;"
CREDIT_IDS=$(psql_ "$URL" -At -c "select string_agg(c.id::text, ' ') from credit_notes c join invoices i on i.id = c.invoice_id where i.po_reference = 'CR-CAP' and c.status = 'draft'")
BIG=$(psql_ "$URL" -At -c "select c.id from credit_notes c join credit_note_lines l on l.credit_note_id = c.id where l.description = 'unapplied BIG'")
ZED=$(psql_ "$URL" -At -c "select c.id from credit_notes c join credit_note_lines l on l.credit_note_id = c.id where l.description = 'unapplied ZED'")
INVX=$(psql_ "$URL" -At -c "select id from invoices where po_reference = 'CR-X'")
INVY=$(psql_ "$URL" -At -c "select id from invoices where po_reference = 'CR-Y'")
INVZ=$(psql_ "$URL" -At -c "select id from invoices where po_reference = 'CR-Z'")
PAYZ=$(psql_ "$URL" -At -c "select p.id from payments p join clients c on c.id = p.client_id where c.name = 'Credit Race Client' and p.amount = 300")
for c in $CREDIT_IDS; do
  ( psql -X -q "$URL" -c "$ASK select credit_note_transition('$c', 'pending_approval')" >/dev/null 2>&1 ) &
done
for i in $(seq 1 8); do
  ( psql -X -q "$URL" -c "$ASK select credit_note_allocate('$BIG', '$INVX', 500)" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASK select credit_note_allocate('$BIG', '$INVY', 500)" >/dev/null 2>&1 ) &
done
for i in $(seq 1 4); do
  ( psql -X -q "$URL" -c "$ASK select payment_allocate('$PAYZ', '$INVZ', 300)" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASK select credit_note_allocate('$ZED', '$INVZ', 300)" >/dev/null 2>&1 ) &
done
wait
res=$(psql_ "$URL" -At -c "select (select count(*) from credit_notes c join invoices i on i.id = c.invoice_id where i.po_reference = 'CR-CAP' and c.status = 'pending_approval') || ',' || (select coalesce(sum(c.total), 0) from credit_notes c join invoices i on i.id = c.invoice_id where i.po_reference = 'CR-CAP' and c.status = 'pending_approval') || ',' || (select count(*) from credit_note_allocations where credit_note_id = '$BIG' and status = 'active') || ',' || (select coalesce(sum(amount), 0) from credit_note_allocations where credit_note_id = '$BIG' and status = 'active') || ',' || ((select count(*) from credit_note_allocations where invoice_id = '$INVZ' and status = 'active') + (select count(*) from payment_allocations where invoice_id = '$INVZ' and status = 'active')) || ',' || (select (i.total - invoice_valid_allocated(i.id) - invoice_credit_applied(i.id))::int from invoices i where i.id = '$INVZ') || ',' || (select status from invoices where id = '$INVZ')")
if [ "$res" = "2,800.00,1,500.00,1,0,paid" ]; then echo "  8 racing submissions of 400 against an invoice of 1000: exactly two accepted (800); 16 racing applications of one 600 credit to two invoices owing 500: exactly one (500); a payment and a credit racing for one invoice owing 300: exactly one wins, balance 0, invoice settled"; else echo "  FAIL concurrent credit notes: got $res expected 2,800.00,1,500.00,1,0,paid"; status=1; fi

# Concurrency: recurring invoicing. Sixteen sessions run the billing schedules at once for the same date: each of the two schedules bills exactly the three periods
# that came due (no period twice). Then eight sessions bill the shorter contract line by hand while eight more run the schedules: the line (4 units) is never
# billed beyond 4, and the longer schedule ends exactly when its line (10 units) is used up.
echo "== concurrent_billing_schedules"
psql_ "$URL" -f supabase/tests/concurrency/schedule_setup.sql >/dev/null
ASK="select set_config('request.jwt.claim.sub', md5('conc-sched-user'), false); set role authenticated;"
for i in $(seq 1 16); do
  ( psql -X -q "$URL" -c "$ASK select billing_schedule_run('2026-03-31')" >/dev/null 2>&1 ) &
done
wait
res1=$(psql_ "$URL" -At -c "select string_agg(c.title || '=' || (select count(*) from billing_schedule_runs r join billing_schedules s on s.id = r.schedule_id where s.contract_id = c.id) || '/' || (select count(*) from billable_items b where b.contract_id = c.id), ' ' order by c.title) from contracts c where c.title like 'SCHED-%'")
SB=$(psql_ "$URL" -At -c "select c.id from contracts c where c.title = 'SCHED-B'")
LB=$(psql_ "$URL" -At -c "select origin_line_id from billing_schedules where contract_id = '$SB'")
for i in $(seq 1 8); do
  ( psql -X -q "$URL" -c "$ASK select billable_from_contract('$SB', '$LB', 1)" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASK select billing_schedule_run('2026-12-31')" >/dev/null 2>&1 ) &
done
wait
res2=$(psql_ "$URL" -At -c "select string_agg(c.title || '=' || (select coalesce(sum(b.quantity), 0) from billable_items b where b.contract_id = c.id and b.status <> 'void') || '/' || (select count(*) from billable_items b where b.contract_id = c.id) || '/' || (select count(*) from billing_schedule_runs r join billing_schedules s on s.id = r.schedule_id where s.contract_id = c.id) || '/' || (select string_agg(s.status::text, ',') from billing_schedules s where s.contract_id = c.id), ' ' order by c.title) from contracts c where c.title like 'SCHED-%'")
if [ "$res1" = "SCHED-A=3/3 SCHED-B=3/3" ] && [ "${res2%% SCHED-B*}" = "SCHED-A=10.00/10/10/ended" ] && [[ "$res2" == *"SCHED-B=4.00/4/"* ]]; then echo "  16 racing runs: each schedule billed its three due periods exactly once; with ordinary billing racing the runs, the 4-unit line was billed exactly 4 and the 10-unit schedule ended exactly at 10"; else echo "  FAIL concurrent billing schedules: got '$res1' / '$res2'"; status=1; fi

# Concurrency: the pilot workflow. Eight sessions (half "Web", half "Tech") create the SAME organization/client at once: one organization, one client role. Eight
# sessions add the SAME contact: one person, one contact. Eight sessions convert the SAME accepted quote: one project, one priced service line. Eight sessions create
# a contract from the SAME quote: exactly one contract. Eight sessions invoice the SAME billable item: exactly one invoice with one active line.
echo "== concurrent_pilot"
psql_ "$URL" -f supabase/tests/concurrency/pilot_setup.sql >/dev/null
ASP="select set_config('request.jwt.claim.sub', md5('conc-pilot-user'), false); set role authenticated;"
DIVW=$(psql_ "$URL" -At -c "select id from divisions where key = 'web'")
DIVT=$(psql_ "$URL" -At -c "select id from divisions where key = 'tech'")
PCL=$(psql_ "$URL" -At -c "select id from clients where name = 'Pilot Race Client'")
PQ1=$(psql_ "$URL" -At -c "select id from quotes where title = 'race quote 1'")
PQ2=$(psql_ "$URL" -At -c "select id from quotes where title = 'race quote 2'")
psql_ "$URL" -c "$ASP select add_client_contact('$PCL', 'Billing Person', 'billing@pilotrace.example', null, 'Finance', false, true)" >/dev/null
PBI=$(psql_ "$URL" -At -c "insert into billable_items (client_id, division_id, source, description, quantity, unit_price, currency, manual_reason) values ('$PCL', '$DIVW', 'manual', 'race charge', 1, 500, 'NAD', 'race') returning id")
for i in $(seq 1 $N_PROC); do
  PDIV=$DIVW; [ $((i % 2)) -eq 0 ] || PDIV=$DIVT
  ( psql -X -q "$URL" -c "$ASP select client_create('Pilot Race Org Ltd', '$PDIV')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASP select add_client_contact('$PCL', 'Race Person', 'race@pilotrace.example', null, 'Director')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASP select quote_convert_to_project('$PQ1')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASP select contract_create_from_quote('$PQ2')" >/dev/null 2>&1 ) &
  ( psql -X -q "$URL" -c "$ASP select invoice_create(array['$PBI']::uuid[])" >/dev/null 2>&1 ) &
done
wait
res=$(psql_ "$URL" -At -c "select (select count(*) from organizations where name ilike 'pilot race org%') || ',' || (select count(*) from clients where name ilike 'pilot race org%') || ',' || (select count(*) from people where email = 'race@pilotrace.example') || ',' || (select count(*) from client_contacts cc join people p on p.id = cc.person_id where p.email = 'race@pilotrace.example') || ',' || (select count(*) from projects where client_id = '$PCL') || ',' || (select count(*) from project_services ps join projects p on p.id = ps.project_id where p.client_id = '$PCL') || ',' || (select count(*) from contracts where quote_id = '$PQ2') || ',' || (select count(distinct invoice_id) from invoice_lines where billable_item_id = '$PBI') || ',' || (select count(*) from invoice_lines where billable_item_id = '$PBI' and active)")
if [ "$res" = "1,1,1,1,1,1,1,1,1" ]; then echo "  8 racing creations of one organization/client from two divisions: one organization, one client; 8 racing contacts: one person, one contact; 8 racing quote conversions: one project, one service line; 8 racing contracts from one quote: one contract; 8 racing invoices of one billable item: one invoice, one active line"; else echo "  FAIL concurrent pilot: got $res expected 1,1,1,1,1,1,1,1,1"; status=1; fi

# The interface may only reference database functions, arguments, tables and columns that exist in the migrated schema.
echo "== web_db_references"
node scripts/check-web-db.mjs "$URL" || status=1
# The real catalogue (build step 2): the generated SQL is current, loads cleanly into a migrated database, is safe to run twice, never publishes anything, and the
# website's own pack arithmetic holds. Runs last: it adds services, which the transaction-wrapped suites above must not see.
echo "== catalogue_seed"
node scripts/gen-catalogue-sql.mjs --check || status=1
psql_ "$URL" -q -f supabase/seed_data/catalogue.sql >/dev/null
psql_ "$URL" -q -f supabase/seed_data/catalogue.sql >/dev/null
cat_res=$(psql_ "$URL" -At -c "select (select count(*) from services where status = 'approved' and status_reason = 'initial catalogue load') || ',' || (select count(*) from service_prices where decision_note = 'initial catalogue load by the owner' and status = 'approved' and version = 1) || ',' || (select count(*) from services where status_reason = 'initial catalogue load' and status = 'published') || ',' || (select count(*) from services s where s.status_reason = 'initial catalogue load' and s.pricing_model = 'quote_based' and exists (select 1 from service_prices p where p.service_id = s.id)) || ',' || (select count(*) from services s where s.status_reason = 'initial catalogue load' and s.pricing_model <> 'quote_based' and (price_on(s.id)).id is null) || ',' || (select (price_on(s.id)).amount from services s where s.name = 'Start-up Pack') || ',' || (select sum((price_on(s.id)).amount) from services s where s.name in ('Business Check-up', 'Customer and Competitor Study', 'Costing and Pricing', 'One-Year Plan') and s.status_reason = 'initial catalogue load') || ',' || (select count(*) from service_prices where decision_note = 'initial catalogue load by the owner' and is_starting_price) || ',' || (select (price_on(s.id)).is_starting_price::text from services s where s.name = 'Business Check-up' and s.status_reason = 'initial catalogue load') || ',' || (select (price_on(s.id)).is_starting_price::text from services s where s.name = 'Customer and Competitor Study' and s.status_reason = 'initial catalogue load')")
if [ "$cat_res" = "56,40,0,0,0,2899.00,3296.00,22,false,true" ]; then echo "  56 services and 40 prices from the published price lists; loaded twice with no duplicates; none published; quote-based services carry no price; every priced service has a price in force; Start-up Pack N\$2,899 against N\$3,296 booked separately; the 22 \"from\" prices are flagged as starting prices and the fixed ones are not"; else echo "  FAIL catalogue seed: got $cat_res expected 56,40,0,0,0,2899.00,3296.00,22,false,true"; status=1; fi



# The public API's HTTP layer (build step 3). Unit tests with a fake database, then the real server -> the real database as the ada_public_api role.
echo "== public_api_http"
[ -d public-api/node_modules/pg ] || npm ci --no-audit --no-fund --prefix public-api >/dev/null
(cd public-api && npm test --silent) || status=1
psql_ "$URL" -q -f public-api/test/fixture.sql >/dev/null
psql_ "$ADMIN_URL" -q -c "alter role ada_public_api login password 'itest-only'" >/dev/null
ADA_PUBLIC_API_SSL=off ADA_PUBLIC_API_DATABASE_URL="postgresql://ada_public_api:itest-only@${BASE#postgresql://*@}/$DB" node public-api/test/integration.mjs || status=1
psql_ "$ADMIN_URL" -q -c "alter role ada_public_api nologin password null" >/dev/null

[ "$status" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $status
