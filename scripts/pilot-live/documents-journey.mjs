// The Documents workspace through the REAL interface: sign in, land on the executive overview, write a Word document, edit and save a new version,
// start an Excel spreadsheet, edit it, upload a PDF / a Word file / an Excel file, open earlier versions, download, and the security cases
// (another division, no permission, anonymous, forged links). Run through scripts/pilot-live/run.sh with JOURNEY=documents-journey.
import { chromium } from 'playwright-core';
import ExcelJS from 'exceljs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
const BASE = 'http://localhost:3100', GW = 'http://localhost:54321';
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined, args: ['--no-sandbox'] });
const steps = []; let fails = 0;
const ok = (name, cond, extra = '') => { steps.push(`${cond ? 'ok  ' : 'FAIL'} ${name}${cond ? '' : ' :: ' + String(extra).slice(0, 400)}`); if (!cond) fails++; };
async function session(email) {
  const ctx = await browser.newContext({ acceptDownloads: true }); const page = await ctx.newPage(); page.setDefaultTimeout(40000);
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource: the server responded with a status of 404/.test(m.text())) steps.push('  console error: ' + m.text().slice(0, 300)); });
  page.on('pageerror', (e) => { fails++; steps.push('FAIL page error: ' + e.message.slice(0, 300)); });
  await page.goto(BASE + '/login'); await page.fill('input[name=email]', email); await page.fill('input[name=password]', 'x'); await page.click('button[type=submit]');
  await page.waitForURL('**/dashboard**'); return { ctx, page };
}
const main = (page) => page.locator('main').innerText();
const seen = async (page, s, ms = 20000) => { try { await page.waitForFunction((t) => document.querySelector('main').innerText.includes(t), s, { timeout: ms }); return true; } catch { return false; } };
const tmp = (n, data) => { const f = path.join(os.tmpdir(), n); fs.writeFileSync(f, data); return f; };
async function newDoc(page, { how, title, type = 'report', file }) {
  await page.goto(BASE + '/documents/new'); await page.waitForSelector('form[data-ready=true]');
  await page.check(`input[name=how] >> nth=${how === 'docx' ? 0 : how === 'xlsx' ? 1 : 2}`);
  await page.fill('input[name=title]', title); await page.selectOption('select[name=type]', type); await page.selectOption('select[name=division]', { label: 'ADA Web' });
  if (file) await page.setInputFiles('input[name=file]', file);
  await page.click('[data-testid=new-document] button[type=submit]');
  try { await page.waitForURL(/\/documents\/[0-9a-f-]{36}$/, { timeout: 40000 }); }
  catch (e) { throw new Error('creating "' + title + '" did not finish; the form says: ' + (await page.locator('[data-testid=new-document] .flash').allInnerTexts().catch(() => [])).join(' | ')); }
  return page.url();
}
const need = async (page, sel, ms = 40000) => { try { await page.waitForSelector(sel, { timeout: ms }); } catch { throw new Error(`${sel} never appeared; the page says: ` + (await main(page)).replace(/\s+/g, ' ').slice(0, 500)); } };
const download = async (page) => { const [dl] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=download]')]); const f = await dl.path(); return { name: dl.suggestedFilename(), bytes: fs.readFileSync(f) }; };

try {
  const { ctx: cCeo, page: P } = await session('ceo@ada.test');
  ok('sign-in lands on the executive overview', P.url().includes('/dashboard') && /Executive overview/.test(await main(P)), await main(P));
  ok('the CEO sees Documents in the menu', await P.locator('nav a[href="/documents"]').first().isVisible());
  await P.goto(BASE + '/documents'); ok('documents list starts empty', /No documents yet/.test(await main(P)), await main(P));

  // ---- Word: write, save a version, reload, earlier version, download
  const wordUrl = await newDoc(P, { how: 'docx', title: 'Zeta website agreement', type: 'contract' });
  await need(P, '[data-testid=doc-page]'); ok('a new Word document opens in the editor', await P.locator('[data-testid=doc-page]').isVisible());
  await P.locator('[data-testid=doc-page]').click(); await P.keyboard.type('This agreement is between ADA and Zeta.'); await P.keyboard.press('Enter');
  await P.getByRole('button', { name: 'Bold' }).click(); await P.keyboard.type('Total: N$10,000'); 
  await P.click('[data-testid=save-version]'); ok('saving makes version 2', await seen(P, 'Saved as version 2'), await main(P));
  await P.reload(); await P.waitForSelector('[data-testid=doc-page]');
  ok('after a reload the typed text is back (stored, then read from the file)', (await P.locator('[data-testid=doc-page]').innerText()).includes('This agreement is between ADA and Zeta.') && (await P.locator('[data-testid=doc-page] strong').innerText()).includes('N$10,000'));
  const dw = await download(P); ok('download gives a real .docx', dw.name.endsWith('.docx') && dw.bytes[0] === 0x50 && dw.bytes[1] === 0x4b, dw.name);
  const opts = await P.locator('select[aria-label=Version] option').allTextContents(); ok('both versions are listed', opts.length === 2 && /v2 \(latest\)/.test(opts[0]) && /v1/.test(opts[1]), opts.join('|'));
  await P.selectOption('select[aria-label=Version]', '1'); ok('version 1 opens read-only and is blank', await seen(P, 'Viewing an earlier version') && !(await P.locator('[data-testid=doc-page]').innerText()).includes('agreement'));
  ok('no save button while viewing an old version', (await P.locator('[data-testid=save-version]').count()) === 0);

  // ---- Excel: new sheet, type into cells, save, download and read the file back
  const xlUrl = await newDoc(P, { how: 'xlsx', title: 'Zeta price sheet', type: 'proposal' });
  await P.waitForSelector('[data-testid=sheet-editor] canvas', { timeout: 60000 }); ok('the spreadsheet editor loads', true);
  const box = await P.locator('[data-testid=sheet-editor] canvas').first().boundingBox();
  await P.mouse.click(box.x + 120, box.y + 120); await P.keyboard.type('Security website'); await P.keyboard.press('Tab'); await P.keyboard.type('3000'); await P.keyboard.press('Enter');
  await P.keyboard.press('ArrowDown'); await P.keyboard.type('Mini market'); await P.keyboard.press('Tab'); await P.keyboard.type('2500'); await P.keyboard.press('Enter');
  await P.waitForTimeout(500); await P.click('[data-testid=save-version]'); ok('the spreadsheet saves as version 2', await seen(P, 'Saved as version 2', 30000), await main(P));
  const dx = await download(P); const wb = new ExcelJS.Workbook(); await wb.xlsx.load(dx.bytes); const flat = []; wb.worksheets[0].eachRow((r) => r.eachCell((c) => flat.push(String(c.value))));
  ok('the downloaded .xlsx contains what was typed', flat.includes('Security website') && flat.includes('3000') && flat.includes('Mini market') && flat.includes('2500'), flat.join(','));

  // ---- Uploads: PDF, Word, Excel
  const pdf = tmp('zeta-brief.pdf', '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF');
  const pdfUrl = await newDoc(P, { how: 'upload', title: 'Zeta brief (PDF)', type: 'report', file: pdf });
  await P.waitForSelector('[data-testid=pdf-view]'); const src = await P.locator('[data-testid=pdf-view]').getAttribute('src'); ok('a PDF opens in the viewer through a short-lived link', /token=/.test(src ?? ''), src);
  const dp = await download(P); ok('the PDF downloads intact', dp.bytes.slice(0, 5).toString() === '%PDF-', dp.bytes.slice(0, 8).toString());
  ok('a PDF has no edit button', (await P.locator('[data-testid=save-version]').count()) === 0);
  const ew = new ExcelJS.Workbook(); const sh = ew.addWorksheet('Costs'); sh.getCell('A1').value = 'Hosting'; sh.getCell('B1').value = 1200; sh.getCell('B2').value = { formula: 'B1*2', result: 2400 }; sh.getCell('A1').font = { bold: true };
  const xlsxUp = await newDoc(P, { how: 'upload', title: 'Existing costs', type: 'report', file: tmp('costs.xlsx', Buffer.from(await ew.xlsx.writeBuffer())) });
  await P.waitForSelector('[data-testid=sheet-editor] canvas', { timeout: 60000 }); ok('an uploaded Excel file opens in the editor', true);
  const dx2 = await download(P); const wb2 = new ExcelJS.Workbook(); await wb2.xlsx.load(dx2.bytes); ok('and downloads as the original (formula intact)', wb2.worksheets[0].getCell('B2').value.formula === 'B1*2');
  execFileSync('node', ['--experimental-strip-types', '--no-warnings', 'scripts/pilot-live/make-sample-docx.mjs', path.join(os.tmpdir(), 'notes.docx')], { stdio: 'inherit' });
  const wdoc = path.join(os.tmpdir(), 'notes.docx');
  await newDoc(P, { how: 'upload', title: 'Existing notes', type: 'minutes', file: wdoc });
  await P.waitForSelector('[data-testid=doc-page]'); ok('an uploaded Word file opens with its text and headings', /Meeting notes/.test(await P.locator('[data-testid=doc-page] h1').innerText()) && /Action list/.test(await P.locator('[data-testid=doc-page]').innerText()));

  await P.goto(BASE + '/documents'); const list = await main(P);
  ok('the list shows all five documents with their institutional IDs', ['Zeta website agreement', 'Zeta price sheet', 'Zeta brief (PDF)', 'Existing costs', 'Existing notes'].every((t) => list.includes(t)) && (await P.locator('td.mono').allInnerTexts()).every((x) => /^[0-9A-Z]{9}$/.test(x.trim())), list);


  // ---- Every menu entry the CEO has leads somewhere real (these were dead links before)
  for (const [href, head] of [['/quotes', 'Quotes'], ['/contracts', 'Contracts'], ['/invoices', 'Invoices'], ['/access', 'Access control'], ['/audit', 'Audit log'], ['/expenses', 'Expenses'], ['/reports', 'Reports'], ['/staff', 'Staff'], ['/organization', 'Organization']]) {
    const r = await P.goto(BASE + href); const t = await main(P);
    ok(`${href} opens a real page ("${head}")`, r.status() === 200 && t.includes(head), `${r.status()} ${t.slice(0, 120)}`);
  }
  await P.goto(BASE + '/access'); ok('Access control lists the CEO role with its people and permissions', /Chief Executive/.test(await main(P)) && /Ceo/i.test(await main(P)) && /permissions across/.test(await main(P)), (await main(P)).slice(0, 300));
  await P.goto(BASE + '/audit?table=documents'); ok('the audit log shows who created the documents', /documents/.test(await main(P)) && /INSERT/.test(await main(P)), (await main(P)).slice(0, 300));
  const menu = await P.locator('nav a').evaluateAll((as) => as.map((a) => a.getAttribute('href')).filter((h) => h && h.startsWith('/')));
  let dead = []; for (const h of [...new Set(menu)]) { const r = await P.goto(BASE + h); if (r.status() >= 400) dead.push(h + ' ' + r.status()); }
  ok('no menu entry for the CEO leads to a missing page', dead.length === 0, dead.join(', '));

  // ---- Security
  const { ctx: cTech, page: T } = await session('tech_staff@ada.test');
  await T.goto(wordUrl); ok('another division cannot open the document (looks like it does not exist)', /not found|could not be found|404/i.test(await main(T)) || /This page could not be found/i.test(await T.content()), (await main(T)).slice(0, 200));
  await T.goto(BASE + '/documents'); ok('and does not see it in the list', !/Zeta website agreement/.test(await main(T)));
  const docId = wordUrl.split('/').pop();
  // forged / replayed links against the file store
  const anon = await browser.newContext(); const ap = await anon.newPage();
  const r1 = await ap.request.get(`${GW}/storage/v1/object/sign/documents/${docId}/x.docx?e=9999999999&token=nope`); ok('a forged link is refused', r1.status() === 403, r1.status());
  const r2 = await ap.request.post(`${GW}/storage/v1/object/sign/documents/${docId}/x.docx`, { data: {} }); ok('asking for a link without signing in is refused', r2.status() === 401, r2.status());
  const r3 = await ap.request.post(`${GW}/storage/v1/object/documents/${docId}/00000000-0000-4000-8000-000000000001.docx`, { multipart: { file: { name: 'a.docx', mimeType: 'application/octet-stream', buffer: Buffer.from('x') } } }); ok('uploading without signing in is refused', r3.status() === 401, r3.status());
  await anon.close(); await cTech.close(); await cCeo.close();
} catch (e) { fails++; steps.push('FAIL unexpected: ' + String(e.stack || e).slice(0, 700)); }
await browser.close();
console.log(steps.join('\n')); console.log(`\n${steps.filter((s) => s.startsWith('ok')).length} passed, ${fails} failed`); process.exit(fails ? 1 : 0);
