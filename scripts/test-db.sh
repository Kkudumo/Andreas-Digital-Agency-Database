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
for f in supabase/tests/[1-9][0-9]_*.sql; do
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

[ "$status" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $status
