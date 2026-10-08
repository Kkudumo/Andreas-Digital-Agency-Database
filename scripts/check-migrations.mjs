#!/usr/bin/env node
// Filesystem sanity check: migrations are numbered 0001.. with no gaps or duplicates.
import { readdirSync } from 'node:fs';
const dir = new URL('../supabase/migrations/', import.meta.url);
const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
let ok = true;
files.forEach((f, i) => {
  const n = Number(f.slice(0, 4));
  if (!/^\d{4}_[a-z0-9_]+\.sql$/.test(f) || n !== i + 1) { console.error(`bad migration name/sequence: ${f} (expected ${String(i + 1).padStart(4, '0')})`); ok = false; }
});
if (!ok) process.exit(1);
console.log(`migrations ok (${files.length})`);
