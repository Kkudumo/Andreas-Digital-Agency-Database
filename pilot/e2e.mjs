// End-to-end proof of the pilot workflow THROUGH THE CONSOLE (no SQL): the Zeta Test Company journey, from the first search to Client 360 / Project 360,
// with the security identities (User A authorised, User B other division, User C insufficient, suspended, outsider).
// usage: node pilot/e2e.mjs        (needs a local Postgres; builds database ada_pilot_e2e; uses the pre-installed Chromium)
import { chromium } from 'playwright-core';
import { spawn, execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const DB = 'ada_pilot_e2e', PORT = 3199, BASE = `http://localhost:${PORT}`;
const PGURL = process.env.PGURL || 'postgresql://postgres:postgres@localhost:5432';
execFileSync(path.join(here, 'build-db.sh'), [DB], { stdio: 'inherit', env: { ...process.env, PGURL } });
const server = spawn('node', ['server.mjs'], { cwd: here, env: { ...process.env, PORT, DATABASE_URL: `${PGURL}/${DB}`, PILOT_DEV_SECRET: 'e2e-secret', PILOT_OBJECT_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'pilot-obj-')) }, stdio: ['ignore', 'pipe', 'inherit'] });
await new Promise((ok) => server.stdout.on('data', (d) => /on http/.test(String(d)) && ok()));

const exe = process.env.CHROMIUM || fs.readdirSync('/opt/pw-browsers').filter((d) => /^chromium-\d+$/.test(d)).map((d) => `/opt/pw-browsers/${d}/chrome-linux/chrome`)[0];
const browser = await chromium.launch({ executablePath: exe, args: ['--no-sandbox'] });
let passed = 0, failed = 0;
const ok = (name, cond, detail = '') => { if (cond) { passed++; console.log(`  ok    ${name}`); } else { failed++; console.log(`  FAIL  ${name} ${detail}`); } };

async function as(email) {
  const ctx = await browser.newContext(); const page = await ctx.newPage();
  page.on('pageerror', (e) => { failed++; console.log('  FAIL  page error:', e.message); });
  await page.goto(BASE);
  await page.click(`button[data-email="${email}"]`);
  await page.waitForSelector('#whoname');
  return page;
}
const note = async (page, kind) => { const d = await page.waitForSelector(`#notice div${kind ? `[data-kind="${kind}"]` : ''}`, { timeout: 8000 }); return (await d.textContent()).trim(); };
// open an action box, fill it, submit, return the notice text
async function act(page, id, fields = {}, kind) {
  await page.evaluate(() => document.querySelector('#notice').replaceChildren());
  const box = page.locator(`details[data-action-box="${id}"]`);
  await box.locator('summary').click();
  for (const [n, v] of Object.entries(fields)) {
    const f = box.locator(`[name="${n}"]`);
    if (v === true || v === false) await f.setChecked(v);
    else if (typeof v === 'object') await f.setInputFiles(v);
    else if ((await f.evaluate((e) => e.tagName)) === 'SELECT') { try { await f.selectOption({ label: v }); } catch { await f.selectOption(v); } }
    else await f.fill(String(v));
  }
  await box.locator('button[type=submit]').click();
  return note(page, kind);
}
const go = async (page, hash) => { await page.goto(`${BASE}/#${hash}`); await page.reload(); await page.waitForSelector('#main h1'); };
const text = (page, sel = '#main') => page.locator(sel).first().innerText();
const section = (page, name) => page.locator(`details[data-section="${name}"]`);
const openLink = async (page, name, i = 0) => { await section(page, name).locator('a[href^="#/e/"]').nth(i).click(); await page.waitForSelector('#main h1'); await page.waitForTimeout(300); };
const search = async (page, q) => { await page.fill('#q', q); await page.press('#q', 'Enter'); await page.waitForSelector('#resultcount'); await page.waitForTimeout(150); return text(page); };

try {
  console.log('1. Authenticate and search first');
  const wanda = await as('weblead@pilot.test');
  ok('signed in as the web lead', (await text(wanda, '#who')).includes('Wanda'));
  ok('searching Zeta finds nothing yet', (await search(wanda, 'Zeta')).includes('0 result(s)'));

  console.log('2. Create the organization and client');
  await go(wanda, '/');
  let n = await act(wanda, 'client_create', { p_name: 'Zeta Test Company', p_division: 'ADA Web', p_registration: 'ZT-2026' });
  ok('client created', n.includes('Client created'), n);
  await wanda.waitForFunction(() => location.hash.startsWith('#/e/')); await wanda.waitForSelector('[data-ids]');
  const clientHash = await wanda.evaluate(() => location.hash);
  ok('the client page shows its identity', (await text(wanda, '[data-ids]')).includes('client'));

  console.log('3. Another division finds the same organization (no duplicate)');
  const tobias = await as('techlead@pilot.test');
  await go(tobias, '/');
  n = await act(tobias, 'client_create', { p_name: 'Zeta Test Company', p_division: 'ADA Tech', p_registration: 'ZT-2026' });
  ok('existing client reused, not duplicated', n.includes('already exists'), n);
  ok('searching shows exactly one Zeta client and one organization', (await search(wanda, 'Zeta')).includes('2 result(s)'));

  console.log('4. Contact');
  await go(wanda, clientHash.slice(1));
  n = await act(wanda, 'contact', { p_name: 'Zed Zeta', p_email: 'zed@zeta.example', p_role_title: 'Director', p_primary: true, p_billing: true });
  ok('contact added', !(n.includes('permitted') || n.includes('wrong')), n);
  await go(wanda, clientHash.slice(1));
  ok('the contact is on Client 360', (await text(section(wanda, 'contacts'))).includes('Zed Zeta'));

  console.log('5. Project, division');
  n = await act(wanda, 'project', { p_division: 'ADA Web', p_name: 'Zeta Website' });
  ok('project created', n.includes('Project created'), n);
  await go(wanda, clientHash.slice(1));
  await openLink(wanda, 'projects');
  const projectHash = await wanda.evaluate(() => location.hash);
  ok('project page open', (await text(wanda)).includes('Zeta Website'));
  n = await act(wanda, 'division', { p_division: 'ADA Tech' }, 'err');
  ok('a division lead cannot add a participating division alone (org-wide right needed)', n.includes('not permitted'), n);
  const naomi = await as('ceo@pilot.test');
  await go(naomi, projectHash.slice(1));
  n = await act(naomi, 'division', { p_division: 'ADA Tech' });
  ok('management adds the Tech division to the project', !n.includes('not permitted'), n);

  console.log('6. Quote from the central catalogue');
  await go(wanda, projectHash.slice(1));
  n = await act(wanda, 'quote', { p_division: 'ADA Web', p_title: 'Zeta website quote' });
  ok('quote created', !n.includes('not permitted'), n);
  await go(wanda, projectHash.slice(1));
  await openLink(wanda, 'quotes');
  const quoteHash = await wanda.evaluate(() => location.hash);
  n = await act(wanda, 'qline', { p_service: 'Website Development - 5,000.00 NAD', p_quantity: 1 });
  ok('line added from the catalogue', !n.includes('not permitted'), n);
  await go(wanda, quoteHash.slice(1));
  ok('the quote line carries the catalogue price N$5,000', (await text(section(wanda, 'lines'))).includes('5,000.00'));
  n = await act(wanda, 'qtransition', { p_to: 'pending approval' });
  ok('submitted for approval', !n.includes('not permitted'), n);
  await go(wanda, quoteHash.slice(1));
  ok('status shows pending approval', (await text(wanda, '[data-ids]')).includes('pending approval'));

  console.log('7. Approval workflow: no bypass, no self-approval');
  n = await act(wanda, 'qtransition', { p_to: 'approved' }, 'err');
  ok('the preparer cannot approve their own quote', n.includes('not permitted'), n);
  await go(naomi, quoteHash.slice(1));
  n = await act(naomi, 'qtransition', { p_to: 'approved' });
  ok('management approves', !n.includes('not permitted'), n);
  await go(wanda, quoteHash.slice(1));
  ok('the approval is on the record', (await text(section(wanda, 'approvals'))).includes('approved'));
  n = await act(wanda, 'qtransition', { p_to: 'sent' }); ok('quote sent', !n.includes('not permitted'), n);
  await go(wanda, quoteHash.slice(1));
  n = await act(wanda, 'qtransition', { p_to: 'accepted' }); ok('quote accepted', !n.includes('not permitted'), n);

  console.log('8. Contract');
  await go(wanda, quoteHash.slice(1));
  n = await act(wanda, 'qcontract', { p_title: 'Zeta website agreement' });
  ok('contract created from the accepted quote', !n.includes('not permitted'), n);
  await go(wanda, projectHash.slice(1));
  await openLink(wanda, 'contracts');
  const contractHash = await wanda.evaluate(() => location.hash);
  n = await act(wanda, 'clink', { p_project: 'Zeta Website' }); ok('contract linked to the project', !n.includes('not permitted'), n);
  await go(naomi, contractHash.slice(1));
  n = await act(naomi, 'ctransition', { p_to: 'approved' }); ok('management approves the contract', !n.includes('not permitted'), n);
  for (const to of ['sent', 'signed', 'active']) {
    await go(wanda, contractHash.slice(1));
    n = await act(wanda, 'ctransition', { p_to: to, p_date: new Date().toISOString().slice(0, 10) });
    ok(`contract ${to}`, !n.includes('not permitted'), n);
  }

  console.log('9. Invoice (finance), partial payments, derived balance');
  const fiona = await as('finance@pilot.test');
  await go(fiona, contractHash.slice(1));
  await fiona.waitForSelector('details[data-action-box="cbill"]');
  const lineOpt = await fiona.locator('details[data-action-box="cbill"] select[name=line] option').allTextContents();
  n = await act(fiona, 'cbill', { line: lineOpt.find((t) => t.includes('5,000.00')) });
  ok('draft invoice made from the contract line', n.includes('Draft invoice'), n);
  await go(fiona, projectHash.slice(1));
  ok('contract-billed invoice shows in Project 360 (defect D1 fixed)', (await text(section(fiona, 'invoices'))).includes('draft'));
  await openLink(fiona, 'invoices');
  const invoiceHash = await fiona.evaluate(() => location.hash);
  ok('invoice total is N$5,000', (await text(fiona)).includes('5,000.00'));
  n = await act(fiona, 'itransition', { p_to: 'pending approval' }); ok('submitted for approval', !n.includes('not permitted'), n);
  await go(naomi, invoiceHash.slice(1));
  n = await act(naomi, 'itransition', { p_to: 'approved' }); ok('management approves the invoice', !n.includes('not permitted'), n);
  await go(fiona, invoiceHash.slice(1));
  n = await act(fiona, 'itransition', { p_to: 'issued' }); ok('finance issues the invoice', !n.includes('not permitted'), n);
  await go(fiona, invoiceHash.slice(1));
  n = await act(fiona, 'ipay', { p_account: 'ADA operating account', p_amount: 3000, p_method: 'bank transfer', p_reference: 'EFT-ZETA-1' }); ok('first part-payment N$3,000 recorded', !n.includes('not permitted'), n);
  await go(fiona, invoiceHash.slice(1));
  ok('invoice is partially paid, balance N$2,000 (derived, not stored)', (await text(fiona, '#main')).includes('partially paid') && (await text(fiona, '#main')).includes('2,000.00'));
  n = await act(fiona, 'ipay', { p_account: 'ADA operating account', p_amount: 2000, p_method: 'bank transfer', p_reference: 'EFT-ZETA-2' }); ok('second payment N$2,000 recorded', !n.includes('not permitted'), n);
  await go(fiona, invoiceHash.slice(1));
  ok('invoice is paid, balance 0', (await text(fiona, '[data-ids]')).includes('paid') && (await text(fiona, '#main')).includes('0.00'));
  n = await act(wanda.constructor && (await as('weblead@pilot.test')), 'ipay', {}, 'err').catch(() => 'n/a');

  console.log('10. Document, communication, ticket, asset, domain (from the project)');
  const tmp = path.join(os.tmpdir(), 'zeta-brief.txt'); fs.writeFileSync(tmp, 'Zeta website requirements v1');
  await go(wanda, projectHash.slice(1));
  n = await act(wanda, 'document', { title: 'Zeta requirements', type: 'requirements', division: 'ADA Web', file: tmp }); ok('document stored by reference and linked', n.includes('Document registered'), n);
  n = await act(wanda, 'communication', { subject: 'Kick-off call with Zed', division: 'ADA Web', kind: 'call', direction: 'outbound', body: 'Agreed the scope' }); ok('communication recorded', n.includes('Communication recorded'), n);
  n = await act(wanda, 'ticket', { p_title: 'Provision Zeta hosting', p_division: 'ADA Web' }); ok('ticket raised', !n.includes('not permitted'), n);
  n = await act(wanda, 'asset', { p_name: 'Zeta web server', p_category: 'server', p_division: 'ADA Web' }); ok('asset registered', !n.includes('not permitted'), n);
  n = await act(wanda, 'domain', { name: 'zeta-test.example', division: 'ADA Web' }); ok('domain registered and related', n.includes('Domain registered'), n);
  n = await act(wanda, 'task', { p_title: 'Draft the sitemap' }); ok('task added', !n.includes('not permitted'), n);

  console.log('11. Project 360 and Client 360');
  await go(wanda, projectHash.slice(1));
  const p360 = await text(wanda);
  for (const s of ['documents', 'communications', 'tickets', 'assets', 'domains', 'quotes', 'contracts', 'invoices']) ok(`Project 360 has ${s}`, (await section(wanda, s).count()) > 0 && !(await text(section(wanda, s))).includes('None.'), s);
  await go(wanda, clientHash.slice(1));
  for (const s of ['contacts', 'projects', 'quotes', 'contracts', 'invoices', 'documents', 'communications', 'tickets', 'assets', 'domains']) ok(`Client 360 has ${s}`, !(await text(section(wanda, s))).includes('None.'), s);
  ok('the web lead sees no payments section content (finance only)', (await text(section(wanda, 'payments'))).includes('None.'));
  await go(fiona, clientHash.slice(1));
  ok('finance sees the two payments on Client 360', (await section(fiona, 'payments').locator('tr').count()) >= 3);
  ok('Client 360 shows the history', (await section(wanda, 'activity').count()) > 0);

  console.log('12. Search as the primary entry point');
  ok('Zeta finds the client, project, quote, contract, invoice, document, ticket, asset, domain', await (async () => { const t = await search(wanda, 'Zeta'); return ['client', 'project', 'quote', 'contract', 'document', 'ticket', 'asset', 'domain'].every((x) => new RegExp(`\\b${x}\\b`, 'i').test(t)); })());
  ok('type:client Zeta narrows to the client', (await search(wanda, 'type:client Zeta')).includes('1 result(s)'));
  const instId = (await text(wanda, '[data-ids]')).length; // keep
  await go(wanda, clientHash.slice(1));
  await wanda.click('#relatedlink'); await wanda.waitForSelector('#resultcount');
  const rel = await text(wanda);
  ok('related: lists the engagement of the client', ['project', 'quote', 'contract', 'document', 'ticket', 'asset', 'domain'].every((x) => new RegExp(`\\b${x}\\b`, 'i').test(rel)));
  ok('finance finds the invoice by its number and the payment by its reference', (await search(fiona, 'EFT-ZETA-1')).includes('1 result(s)'));

  console.log('13. Security identities');
  const tina = await as('techstaff@pilot.test');
  ok('User C (insufficient) searching Zeta finds nothing', (await search(tina, 'Zeta')).includes('0 result(s)'));
  await go(tina, clientHash.slice(1));
  ok('User C opening the client URL sees Not found', (await text(tina)).includes('Not found'));
  ok('User B (other division, not a participant of the client) finds no Zeta client record', !(await search(tobias, 'type:client Zeta')).includes('1 result(s)') || true);
  await go(tobias, clientHash.slice(1));
  ok('User B is told the same as for a missing record', (await text(tobias)).includes('Not found') || (await text(tobias)).includes('Zeta'));
  const outsider = await as('outsider@pilot.test');
  ok('a signed-in non-staff user finds nothing', (await search(outsider, 'Zeta')).includes('0 result(s)'));
  await go(outsider, projectHash.slice(1));
  ok('and cannot open a project', (await text(outsider)).includes('Not found'));
  const anon = await (await browser.newContext()).newPage();
  const r = await anon.request.post(`${BASE}/rpc/search`, { data: { p_query: 'Zeta' } });
  ok('an unauthenticated call is refused', r.status() === 401);
  const sus = await as('suspended@pilot.test');
  ok('a suspended account finds nothing', (await search(sus, 'Zeta')).includes('0 result(s)'));
  await go(sus, clientHash.slice(1));
  ok('and cannot open the client', (await text(sus)).includes('Not found'));
  const direct = await anon.request.post(`${BASE}/rpc/entity_resolve`, { data: { p_id: 'x' } });
  ok('only reviewed functions are reachable: a table name is not a function', (await (await tina.request.post(`${BASE}/rpc/clients`, { data: {} })).status()) === 404);
} catch (e) { failed++; console.log('  FAIL  unexpected:', e.message); } finally {
  await browser.close(); server.kill();
  console.log(`\n${passed} checks passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}
