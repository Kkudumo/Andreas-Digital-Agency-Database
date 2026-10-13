#!/usr/bin/env node
// Fails if the interface links to a page that does not exist (a menu entry or button that "takes you nowhere").
// Scans web/ for string-literal and template-literal paths used as links / redirects and matches them with the page files of the Next.js app router.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
const root = new URL('../web/', import.meta.url).pathname;
const walk = (d) => readdirSync(d).flatMap((f) => { if (['node_modules', '.next'].includes(f)) return []; const p = join(d, f); return statSync(p).isDirectory() ? walk(p) : [p]; });
const files = walk(join(root, 'app')).concat(walk(join(root, 'components')), walk(join(root, 'lib')));
const routes = files.filter((f) => /[\\/]page\.tsx$/.test(f) || /[\\/]route\.ts$/.test(f)).map((f) => '/' + relative(join(root, 'app'), f).split(sep).slice(0, -1).filter((s) => !/^\(.*\)$/.test(s)).join('/')).map((r) => (r === '/' ? '/' : r.replace(/\/$/, '')));
const matches = (path) => routes.some((r) => { const a = r.split('/'), b = path.split('/'); return a.length === b.length && a.every((s, i) => /^\[.+\]$/.test(s) || s === b[i]); });
const bad = [];
const re = /(?:href=|href:\s*|redirect\(|push\(|back\()\s*\{?\s*(?:'|"|`)(\/[A-Za-z0-9_\-/\[\]${}.]*)/g;
for (const f of files.filter((f) => /\.(tsx?|mjs)$/.test(f))) {
  const src = readFileSync(f, 'utf8');
  for (const m of src.matchAll(re)) {
    let p = m[1].replace(/\$\{[^}]*\}/g, 'x').replace(/\/+$/, '') || '/';
    if (p.startsWith('/_next') || p === '/#') continue;
    if (!matches(p)) bad.push(`${relative(root, f)}: ${m[1]}`);
  }
}
// the menu in the layout is built from object literals { href: '/x' }
for (const f of files.filter((f) => /layout\.tsx$/.test(f))) for (const m of readFileSync(f, 'utf8').matchAll(/href:\s*'(\/[^']*)'/g)) { if (!matches(m[1])) bad.push(`${relative(root, f)}: menu entry ${m[1]}`); }
if (bad.length) { console.error('Links to pages that do not exist:\n  - ' + [...new Set(bad)].join('\n  - ')); process.exit(1); }
console.log(`web links ok (${routes.length} pages)`);
