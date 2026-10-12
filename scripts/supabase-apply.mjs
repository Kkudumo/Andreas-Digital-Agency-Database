#!/usr/bin/env node
// Applies supabase/migrations/*.sql, in order, to a hosted Supabase project through the Management API (no database password needed).
//   SUPABASE_ACCESS_TOKEN=sbp_...  node scripts/supabase-apply.mjs <project-ref> [--dry-run]
// Bookkeeping uses the same table the Supabase CLI uses (supabase_migrations.schema_migrations: version = the file's four-digit number), so the CLI sees
// what was applied. A migration already recorded is skipped; each file runs in one request (one transaction) and is recorded only if it succeeded.
// The token is read from the environment only; it is never written anywhere by this script.
import { readdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const [ref, ...flags] = process.argv.slice(2);
const dry = flags.includes('--dry-run');
const token = process.env.SUPABASE_ACCESS_TOKEN;
if (!ref || !token) { console.error('usage: SUPABASE_ACCESS_TOKEN=... node scripts/supabase-apply.mjs <project-ref> [--dry-run]'); process.exit(2); }
const dir = new URL('../supabase/migrations/', import.meta.url);
const tmp = mkdtempSync(join(tmpdir(), 'ada-apply-'));

function query(sql) {
  const body = join(tmp, 'q.json'); writeFileSync(body, JSON.stringify({ query: sql }));
  const out = execFileSync('curl', ['-sS', '-m', '300', '-w', '\n%{http_code}', '-X', 'POST', `https://api.supabase.com/v1/projects/${ref}/database/query`,
    '-H', `Authorization: Bearer ${token}`, '-H', 'Content-Type: application/json', '--data-binary', `@${body}`], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const i = out.lastIndexOf('\n'); const code = Number(out.slice(i + 1)); const text = out.slice(0, i);
  let json; try { json = JSON.parse(text); } catch { json = text; }
  if (code >= 300) throw new Error(`HTTP ${code}: ${typeof json === 'string' ? json : JSON.stringify(json)}`);
  return json;
}

try {
  if (!dry) query(`create schema if not exists supabase_migrations;
         create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);`);
  let done = new Set();
  try { done = new Set(query('select version from supabase_migrations.schema_migrations').map((r) => r.version)); } catch (e) { if (!dry) throw e; }   // a dry run on a project that has never been migrated finds no table
  const files = readdirSync(dir).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort();
  let applied = 0;
  for (const f of files) {
    const version = f.slice(0, 4), name = f.slice(5, -4);
    if (done.has(version)) { console.log(`skip     ${f}`); continue; }
    if (dry) { console.log(`would apply ${f}`); continue; }
    const sql = readFileSync(new URL(f, dir), 'utf8');
    process.stdout.write(`apply    ${f} ... `);
    // one transaction per file; recorded in the same transaction so a failure leaves nothing half-applied
    query(`begin;\n${sql}\n;\ninsert into supabase_migrations.schema_migrations (version, name) values ('${version}', '${name}');\ncommit;`);
    console.log('ok'); applied++;
  }
  console.log(dry ? 'dry run complete' : `done: ${applied} migration(s) applied, ${files.length - applied} already present`);
} catch (e) {
  console.error('\nFAILED: ' + String(e.message).slice(0, 1500)); process.exitCode = 1;
} finally { rmSync(tmp, { recursive: true, force: true }); }
