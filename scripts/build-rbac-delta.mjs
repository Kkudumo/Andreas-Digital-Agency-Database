#!/usr/bin/env node
// Emits the SQL needed to move the database from an older permission matrix to the current one.
//   node scripts/build-rbac-delta.mjs <old.csv> > supabase/migrations/NNNN_xxx.sql
// Only additions are generated; removals/changes must be written by hand (and reviewed).
import { readFileSync } from 'node:fs';
const splitCsv = (line) => { const out = []; let cur = '', q = false;
  for (let i = 0; i < line.length; i++) { const c = line[i];
    if (q) { if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c; }
    else if (c === '"') q = true; else if (c === ',') { out.push(cur); cur = ''; } else cur += c; }
  out.push(cur); return out; };

const parse = (f) => { const r = readFileSync(f, 'utf8').trim().split('\n').map(splitCsv); const h = r.shift(); return { h, r }; };
const oldM = parse(process.argv[2]);
const newM = parse(new URL('../supabase/seed_data/permission_matrix.csv', import.meta.url).pathname);
const q = (s) => `'${s.replace(/'/g, "''")}'`;
const ROLE_META = { recruiter: ['Recruiter', 'Handles vacancies and applications; no access to finance or other HR data.'] };
const grants = (m) => { const set = new Set(); for (const r of m.r) m.h.slice(3).forEach((k, i) => { if (r[3 + i] === 'x') set.add(`${k}|${r[0]}`); }); return set; };
const oldPerms = new Set(oldM.r.map((r) => r[0]));
const oldGrants = grants(oldM);
let sql = '';
const newRoles = newM.h.slice(3).filter((k) => !oldM.h.includes(k));
if (newRoles.length) sql += `insert into roles (key, name, description, is_system) values\n` + newRoles.map((k) => `  (${q(k)}, ${q(ROLE_META[k][0])}, ${q(ROLE_META[k][1])}, true)`).join(',\n') + ';\n\n';
const newPerms = newM.r.filter((r) => !oldPerms.has(r[0]));
if (newPerms.length) sql += `insert into permissions (key, module, action, description, sensitivity) values\n` + newPerms.map((r) => { const [m, a] = r[0].split('.'); return `  (${q(r[0])}, ${q(m)}, ${q(a)}, ${q(r[2])}, ${q(r[1])}::data_classification)`; }).join(',\n') + ';\n\n';
const add = [...grants(newM)].filter((g) => !oldGrants.has(g)).map((g) => g.split('|'));
if (add.length) sql += `insert into role_permissions (role_id, permission_id)\nselect r.id, p.id from (values\n` + add.map(([r, p]) => `  (${q(r)}, ${q(p)})`).join(',\n') + `\n) as v(role_key, permission_key)\njoin roles r on r.key = v.role_key\njoin permissions p on p.key = v.permission_key;\n`;
process.stdout.write(sql);
