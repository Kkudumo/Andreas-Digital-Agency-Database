#!/usr/bin/env node
// Fails if any protected regression check (supabase/tests/PROTECTED.txt) has been removed or renamed away,
// or if the runner/rehearsal scripts lost their integrity checks.
import { readFileSync, readdirSync } from 'node:fs';
const dir = new URL('../supabase/tests/', import.meta.url);
const corpus = readdirSync(dir).filter((f) => f.endsWith('.sql')).map((f) => readFileSync(new URL(f, dir), 'utf8')).join('\n');
const phrases = readFileSync(new URL('PROTECTED.txt', dir), 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
const missing = phrases.filter((p) => !corpus.includes(p.replace(/'/g, "''")) && !corpus.includes(p));
const scripts = [['test-db.sh', 'concurrent_ids'], ['test-db.sh', 'concurrent_allocations'], ['test-db.sh', 'concurrent_asset_ids'], ['test-db.sh', 'concurrent_institutional_ids'], ['test-db.sh', 'concurrent_document_versions'], ['test-db.sh', 'concurrent_organizations'], ['test-db.sh', 'concurrent_domains'], ['test-db.sh', 'concurrent_communications'], ['test-db.sh', 'concurrent_search'], ['test-db.sh', 'upgrade_0038'], ['test-db.sh', 'never calls tests.finish()'], ['rehearse-migration.sh', 'security fingerprint'], ['restore.sh', 'SECURITY FINGERPRINT MISMATCH']];
for (const [file, needle] of scripts) {
  if (!readFileSync(new URL(`../scripts/${file}`, import.meta.url), 'utf8').includes(needle)) missing.push(`scripts/${file} must still contain "${needle}"`);
}
// every numbered suite file must be picked up by the runner's glob ([1-9][0-9]*_*.sql); an unrun suite protects nothing
const runnerGlob = /^[1-9][0-9]+_.*\.sql$/;
for (const f of readdirSync(dir)) if (/^[0-9]+_.*\.sql$/.test(f) && !/^0[01]_/.test(f) && !runnerGlob.test(f)) missing.push(`supabase/tests/${f} would not be executed by scripts/test-db.sh`);
if (missing.length) {
  console.error('Protected regression checks are missing:\n  - ' + missing.join('\n  - '));
  console.error('\nDo not delete these to make work easier. Replace with an equal-or-stronger check and update PROTECTED.txt in the same commit.');
  process.exit(1);
}
console.log(`protected regression checks present (${phrases.length} phrases)`);
