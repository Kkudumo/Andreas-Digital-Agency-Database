#!/usr/bin/env node
// Turns an EXPORT of the old website project's careers tables into a SQL script for ADA Core.
//   node scripts/import-careers.mjs --vacancies career_opportunities.json --applications career_applications.json --out careers-import.sql
// The exports are JSON arrays of the table rows (Supabase dashboard: Table Editor -> Export -> JSON, or `select json_agg(t) from career_opportunities t`).
// They contain PERSONAL DATA: keep them and the generated SQL out of git (this directory's .gitignore covers careers-*.json / careers-import*.sql), run the SQL once
// in the ADA Core SQL editor as the project owner, then delete the files. The SQL is safe to run again: records already imported are recognised and skipped.
// Nothing is guessed: an unknown division, employment type or status stops the script with the list of rows to fix. Test records (is_test) are not imported.
import fs from 'node:fs';

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : null; };
const files = { vacancies: arg('--vacancies'), applications: arg('--applications'), out: arg('--out') };
if (!files.out || (!files.vacancies && !files.applications)) { console.error('usage: node scripts/import-careers.mjs [--vacancies file.json] [--applications file.json] --out careers-import.sql'); process.exit(2); }
const read = (f) => { const v = JSON.parse(fs.readFileSync(f, 'utf8')); if (!Array.isArray(v)) throw new Error(`${f}: expected a JSON array of rows`); return v; };

const problems = [];
const bad = (what, row, why) => problems.push(`${what} ${row.id ?? '?'} (${row.title ?? row.full_name ?? ''}): ${why}`);
const text = (v) => (v === null || v === undefined ? '' : String(v).trim());

export function divisionKey(name) {
  const n = text(name).toLowerCase();
  for (const [k, re] of [['web', /\bweb\b/], ['tech', /\btech/], ['marketing', /marketing/], ['consulting', /consulting/], ['academy', /academy/], ['software', /software/], ['administration', /admin/], ['finance', /financ/], ['management', /management/]]) if (re.test(n)) return k;
  return null;
}
const EMPLOYMENT = { 'full-time': 'full_time', 'full time': 'full_time', full_time: 'full_time', 'part-time': 'part_time', 'part time': 'part_time', part_time: 'part_time', contract: 'contract', internship: 'internship', 'internship / attachment': 'internship', attachment: 'internship' };
const VACANCY_STATUS = { draft: 'draft', published: 'published', closed: 'closed', archived: 'closed', filled: 'filled', cancelled: 'cancelled' };
const APPLICATION_STATUS = { new: 'submitted', submitted: 'submitted', under_review: 'screening', screening: 'screening', shortlisted: 'shortlisted', interview: 'interview', accepted: 'accepted', rejected: 'rejected', archived: 'withdrawn', withdrawn: 'withdrawn' };
const STORAGE = 'legacy-storage:career-documents/';
const storageRef = (p) => (text(p) === '' ? '' : text(p).startsWith('legacy-storage:') ? text(p) : /^https?:/.test(text(p)) ? text(p) : STORAGE + text(p).replace(/^\/+/, ''));

export function mapVacancy(r) {
  const key = divisionKey(r.division);
  if (!key) return bad('vacancy', r, `unknown division "${r.division}"`);
  const type = EMPLOYMENT[text(r.employment_type).toLowerCase()];
  if (!type) return bad('vacancy', r, `unknown employment type "${r.employment_type}"`);
  const status = VACANCY_STATUS[text(r.status).toLowerCase()];
  if (!status) return bad('vacancy', r, `unknown status "${r.status}"`);
  const section = (h, v) => (text(v) ? `\n\n${h}\n${text(v)}` : '');
  return {
    legacy_id: text(r.id), title: text(r.title), division: key, employment_type: type, status, is_test: !!r.is_test,
    summary: text(r.summary).slice(0, 500), openings: Number(r.positions_available) > 0 ? Number(r.positions_available) : 1,
    closing_date: text(r.deadline).slice(0, 10) || null, created_at: text(r.created_at) || null, published_at: text(r.published_at) || null,
    description: (text(r.location) ? `Location: ${text(r.location)}\n\n` : '') + text(r.description) + section('Responsibilities', r.responsibilities) + section('How to apply', r.application_instructions),
    requirements: [text(r.requirements), section('Qualifications', r.qualifications).trim(), section('Experience', r.experience).trim()].filter(Boolean).join('\n\n'),
  };
}

const MAPPED = new Set(['id', 'opportunity_id', 'full_name', 'email', 'phone', 'status', 'created_at', 'updated_at', 'cover_letter', 'cv_url', 'internal_notes', 'division']);
export function mapApplication(r) {
  const status = APPLICATION_STATUS[text(r.status || 'new').toLowerCase()];
  if (!status) return bad('application', r, `unknown status "${r.status}"`);
  const details = {};
  for (const [k, v] of Object.entries(r)) {
    if (MAPPED.has(k) || v === null || v === undefined || text(v) === '') continue;
    details[k] = /(_url|_path|document)/.test(k) && typeof v === 'string' ? storageRef(v) : typeof v === 'string' ? v.slice(0, 4000) : v;
  }
  if (text(r.internal_notes)) details.internal_notes = text(r.internal_notes).slice(0, 8000);
  if (text(r.division)) details.division_applied = text(r.division);
  return {
    legacy_id: text(r.id), vacancy_legacy_id: text(r.opportunity_id) || null, full_name: text(r.full_name), email: text(r.email), phone: text(r.phone),
    status, cover_letter: text(r.cover_letter) || null, cv_ref: storageRef(r.cv_url) || null, submitted_at: text(r.created_at) || null, updated_at: text(r.updated_at) || null,
    division: divisionKey(r.division), details,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const vac = files.vacancies ? read(files.vacancies) : []; const app = files.applications ? read(files.applications) : [];
  const vm = vac.map(mapVacancy).filter(Boolean); const am = app.map(mapApplication).filter(Boolean);
  if (problems.length) { console.error('Fix these rows (or the mapping tables at the top of this script) and run again. Nothing was written.\n  ' + problems.join('\n  ')); process.exit(1); }
  const lit = (o) => { let tag = 'j'; const j = JSON.stringify(o); while (j.includes(`$${tag}$`)) tag += 'x'; return `$${tag}$${j}$${tag}$::jsonb`; };
  const sql = `-- Careers import for ADA Core. GENERATED ${new Date().toISOString().slice(0, 10)} from an export of the previous website's careers tables.
-- CONTAINS PERSONAL DATA of applicants: run it once in the SQL editor of the ADA Core project as the owner, then delete this file. Safe to run again.
-- ${vm.length} vacancies (${vac.length - vm.length} not mapped), ${am.length} applications. Test vacancies are skipped by the import itself.
-- CV and supporting files are NOT copied: each application keeps a reference 'legacy-storage:career-documents/<path>' to the previous project's storage.
begin;
${vm.map((v) => `select import_vacancy(${lit(v)});`).join('\n')}
${am.map((a) => `select import_application(${lit(a)});`).join('\n')}
-- What was NOT imported (test records, an unusable e-mail address, the same person applying twice to one vacancy):
select 'vacancy' as kind, v.id as old_id, v.title as label from (values ${vac.length ? vac.map((r) => `('${text(r.id).replace(/'/g, "''")}', '${text(r.title).replace(/'/g, "''")}')`).join(', ') : "(null, null)"}) as v(id, title)
  where v.id is not null and not exists (select 1 from legacy_imports l where l.source = 'career_opportunities' and l.source_id = v.id and l.entity_type = 'vacancy')
union all
select 'application', a.id, a.label from (values ${app.length ? app.map((r) => `('${text(r.id).replace(/'/g, "''")}', '${text(r.full_name).replace(/'/g, "''")}')`).join(', ') : "(null, null)"}) as a(id, label)
  where a.id is not null and not exists (select 1 from legacy_imports l where l.source = 'career_applications' and l.source_id = a.id and l.entity_type = 'application');
commit;
`;
  fs.writeFileSync(files.out, sql, { mode: 0o600 });
  console.log(`wrote ${files.out}: ${vm.length} vacancies, ${am.length} applications${vac.some((v) => v.is_test) ? ` (${vac.filter((v) => v.is_test).length} test vacancy record(s) will be skipped)` : ''}`);
}
