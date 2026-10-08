#!/usr/bin/env node
// Generates the SQL for the permission/role seed from supabase/seed_data/permission_matrix.csv.
// Used once to author migration 0004. After a migration has been applied anywhere, change the
// matrix with a NEW migration (and update the CSV); the DB test fails if they diverge.
import { readFileSync } from 'node:fs';

const rows = readFileSync(new URL('../supabase/seed_data/permission_matrix.csv', import.meta.url), 'utf8')
  .trim().split('\n').map((l) => l.split(','));
const header = rows.shift();
const roleKeys = header.slice(3);
const q = (s) => `'${s.replace(/'/g, "''")}'`;

const roles = {
  ceo: ['Chief Executive', 'Full organizational authority. Holds every permission.'],
  administration_officer: ['Administration Officer', 'Administrative records: staff, HR, clients; read-only on projects.'],
  finance_officer: ['Finance Officer', 'Financial records and reporting. No HR, no audit, no role administration.'],
  division_lead: ['Division Lead', 'Runs clients, projects and tasks within an assigned division (assign scoped to a division).'],
  division_staff: ['Division Staff', 'Works on clients, projects and tasks within an assigned division (assign scoped to a division).'],
  auditor: ['Auditor', 'Read-only oversight: audit log, access model and reports.'],
};

let sql = `-- 0004_rbac_seed: initial ADA organization, divisions, positions, permissions and roles.
-- Generated from supabase/seed_data/permission_matrix.csv by scripts/build-rbac-seed.mjs.

insert into organization (legal_name, trading_name, description)
values ('Andreas Digital Agency', 'ADA', 'Digital agency delivering web, technology, marketing, training, software and consulting services.');

insert into divisions (key, name, kind, sort_order, description) values
  ('management',     'Management',     'corporate', 10, 'Central executive and management function.'),
  ('administration', 'Administration', 'corporate', 20, 'Administrative records, documentation and internal coordination.'),
  ('finance',        'Finance',        'corporate', 30, 'Invoices, payments, expenses and financial reporting.'),
  ('web',            'ADA Web',        'service',   40, 'Web development and digital presence.'),
  ('tech',           'ADA Tech',       'service',   50, 'IT support, hardware, networking, CCTV, installations and maintenance.'),
  ('marketing',      'ADA Marketing',  'service',   60, 'Marketing and digital marketing.'),
  ('academy',        'ADA Academy',    'service',   70, 'Education, training and courses.'),
  ('software',       'ADA Software',   'service',   80, 'Software, portals, systems and application development.'),
  ('consulting',     'ADA Consulting', 'service',   90, 'Business and technology consulting.');

insert into positions (title, division_id, description)
select v.title, d.id, v.description
from (values
  ('Chief Executive',        'management',     'Head of ADA'),
  ('Administration Officer', 'administration', 'Administrative coordination'),
  ('Finance Officer',        'finance',        'Financial records'),
  ('Web Developer',          'web',            'Website design and development'),
  ('IT Technician',          'tech',           'IT support and installations'),
  ('Marketing Officer',      'marketing',      'Marketing delivery'),
  ('Academy Instructor',     'academy',        'Training delivery'),
  ('Software Developer',     'software',       'Application development'),
  ('Consultant',             'consulting',     'Advisory services')
) as v(title, division_key, description)
join divisions d on d.key = v.division_key;

insert into permissions (key, module, action, description, sensitivity) values
`;
sql += rows.map((r) => {
  const [mod, act] = r[0].split('.');
  return `  (${q(r[0])}, ${q(mod)}, ${q(act)}, ${q(r[2])}, ${q(r[1])}::data_classification)`;
}).join(',\n') + ';\n\n';

sql += `insert into roles (key, name, description, is_system) values\n`;
sql += roleKeys.map((k) => `  (${q(k)}, ${q(roles[k][0])}, ${q(roles[k][1])}, true)`).join(',\n') + ';\n\n';

sql += `insert into role_permissions (role_id, permission_id)\nselect r.id, p.id from (values\n`;
const pairs = [];
for (const r of rows) roleKeys.forEach((k, i) => { if (r[3 + i] === 'x') pairs.push(`  (${q(k)}, ${q(r[0])})`); });
sql += pairs.join(',\n') + `\n) as v(role_key, permission_key)\njoin roles r on r.key = v.role_key\njoin permissions p on p.key = v.permission_key;\n`;

process.stdout.write(sql);
