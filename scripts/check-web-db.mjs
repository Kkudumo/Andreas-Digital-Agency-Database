#!/usr/bin/env node
// Static check that the interface only calls database objects that exist: every call('fn', { p_arg: ... }) names a real public function and real argument
// names, every .from('table') names a real table or view, and every .eq/.select-embedded column of a plain select exists. Needs a migrated database:
//   node scripts/check-web-db.mjs postgresql://...   (scripts/test-db.sh runs it against the scratch database)
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const url = process.argv[2];
if (!url) { console.error('usage: check-web-db.mjs <postgres url>'); process.exit(2); }
const q = (sql) => execFileSync('psql', ['-X', '-At', '-F', '\t', url, '-c', sql], { encoding: 'utf8' }).trim().split('\n').filter(Boolean).map((l) => l.split('\t'));

const fns = new Map();   // name -> list of Set(arg names)
for (const [name, args] of q(`select p.proname, coalesce(array_to_string(p.proargnames, ','), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'`)) {
  if (!fns.has(name)) fns.set(name, []);
  fns.get(name).push(new Set(args.split(',').filter(Boolean)));
}
const cols = new Map();  // table -> Set(columns)
for (const [t, c] of q(`select table_name, column_name from information_schema.columns where table_schema = 'public'`)) {
  if (!cols.has(t)) cols.set(t, new Set());
  cols.get(t).add(c);
}

const files = [];
const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); if (f === 'node_modules' || f === '.next') continue; statSync(p).isDirectory() ? walk(p) : /\.(ts|tsx)$/.test(f) && files.push(p); } };
walk(new URL('../web', import.meta.url).pathname);

const problems = [];
let nCalls = 0, nTables = 0;
for (const f of files) {
  const src = readFileSync(f, 'utf8');
  for (const m of src.matchAll(/\b(?:call(?:<[^>]*>)?\(|run\(fd,)\s*'([a-z0-9_]+)'\s*(?:,\s*\{([^}]*)\})?/g)) {
    nCalls++;
    const [, fn, body = ''] = m;
    if (!fns.has(fn)) { problems.push(`${f}: unknown function ${fn}()`); continue; }
    const used = [...body.matchAll(/\b(p_[a-z0-9_]+)\s*:/g)].map((x) => x[1]);
    if (!fns.get(fn).some((set) => used.every((u) => set.has(u)))) problems.push(`${f}: ${fn}() has no signature with arguments ${used.join(', ')}`);
  }
  for (const m of src.matchAll(/\.from\('([a-z0-9_]+)'\)((?:\s*\.[a-z]+\([^)]*\))*)/g)) {
    nTables++;
    const [, t, chain] = m;
    if (!cols.has(t)) { problems.push(`${f}: unknown table/view ${t}`); continue; }
    for (const e of chain.matchAll(/\.(?:eq|in|is|gt|lte|order)\('([a-z_]+)'/g)) if (!cols.get(t).has(e[1])) problems.push(`${f}: ${t} has no column ${e[1]}`);
    const sel = chain.match(/\.select\('([^']*)'/);
    if (sel) for (const part of sel[1].split(/,(?![^()]*\))/).map((s) => s.trim())) {
      if (part === '*' || part.includes(':') || part.includes('(')) continue;      // embedded relations are validated at runtime by PostgREST
      if (!cols.get(t).has(part)) problems.push(`${f}: ${t} has no column ${part}`);
    }
  }
}
if (problems.length) { console.error('Interface references that do not exist in the database:\n  - ' + [...new Set(problems)].join('\n  - ')); process.exit(1); }
console.log(`interface references ok (${nCalls} function calls, ${nTables} table reads)`);
