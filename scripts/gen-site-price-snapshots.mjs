#!/usr/bin/env node
// Writes one price snapshot per division site from the reviewed catalogue (supabase/seed_data/catalogue.csv), in the shape of the public API's /services answer,
// into public-api/clients/python/snapshots/<division>.json. A division site commits its snapshot as build/prices.json. Run with --check in tests.
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const text = fs.readFileSync(path.join(root, 'supabase/seed_data/catalogue.csv'), 'utf8');
function parse(s) { const rows = []; let row = [], cell = '', q = false; for (let i = 0; i < s.length; i++) { const c = s[i]; if (q) { if (c === '"') { if (s[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; } else if (c === '"') q = true; else if (c === ',') { row.push(cell); cell = ''; } else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; } else if (c !== '\r') cell += c; } if (cell || row.length) { row.push(cell); rows.push(row); } return rows; }
const [head, ...rows] = parse(text).filter((r) => r.length > 1);
const col = Object.fromEntries(head.map((h, i) => [h, i]));
const byDivision = {};
for (const r of rows) {
  const g = (k) => r[col[k]];
  (byDivision[g('division')] ??= []).push({
    name: g('name'), category: g('category'), pricing_model: g('pricing_model'), billing_unit: g('billing_unit'),
    ...(g('amount') === '' ? {} : { price: { amount: Number(g('amount')), currency: 'NAD', starting_price: g('price_kind') === 'from' } }),
  });
}
const dir = path.join(root, 'public-api/clients/python/snapshots');
fs.mkdirSync(dir, { recursive: true });
let stale = false;
for (const [division, services] of Object.entries(byDivision)) {
  const body = JSON.stringify({ division, source: 'supabase/seed_data/catalogue.csv', services: services.sort((a, b) => a.name.localeCompare(b.name)) }, null, 1) + '\n';
  const file = path.join(dir, `${division}.json`);
  if (process.argv.includes('--check')) { if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== body) { console.error(`${file} is out of date`); stale = true; } }
  else fs.writeFileSync(file, body);
}
if (stale) process.exit(1);
console.log(process.argv.includes('--check') ? 'snapshots are up to date' : `wrote snapshots for ${Object.keys(byDivision).join(', ')}`);
