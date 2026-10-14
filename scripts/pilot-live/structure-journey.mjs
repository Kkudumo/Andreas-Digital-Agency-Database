// The arrangement through the real interface: the menu grouped by section, Divisions and a division workspace, the database index with its filter,
// who may see what, and the loading bar on a slow page. Run with JOURNEY=structure-journey scripts/pilot-live/run.sh
import { chromium } from 'playwright-core';
const BASE = 'http://localhost:3100';
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined, args: ['--no-sandbox'] });
const steps = []; let fails = 0;
const ok = (n, c, x = '') => { steps.push(`${c ? 'ok  ' : 'FAIL'} ${n}${c ? '' : ' :: ' + String(x).slice(0, 300)}`); if (!c) fails++; };
async function session(email) {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 800 } }); const page = await ctx.newPage(); page.setDefaultTimeout(30000);
  page.on('pageerror', (e) => { fails++; steps.push('FAIL page error: ' + e.message.slice(0, 200)); });
  await page.goto(BASE + '/login'); await page.fill('input[name=email]', email); await page.fill('input[name=password]', 'x'); await page.click('.ada-login-submit'); await page.waitForURL('**/dashboard**');
  return { ctx, page };
}
const main = async (p) => { await p.waitForSelector('[data-testid=page-skeleton]', { state: 'detached', timeout: 30000 }).catch(() => {}); return p.locator('main').innerText(); };
try {
  const { page: P } = await session('ceo@ada.test');
  const groups = await P.locator('.nav .grp').allInnerTexts();
  ok('the menu is grouped by section', ['Divisions', 'Organization & people', 'Clients & projects', 'Sales', 'Finance', 'Documents', 'Governance'].every((g) => groups.map((x) => x.toLowerCase()).includes(g.toLowerCase())), groups.join('|'));
  await P.goto(BASE + '/divisions'); const t1 = await main(P);
  ok('Divisions lists all nine divisions', ['ADA Web', 'ADA Tech', 'ADA Marketing', 'ADA Academy', 'ADA Software', 'ADA Consulting', 'Management', 'Administration', 'Finance'].every((d) => t1.includes(d)), t1);
  await P.click('a[data-division=web]'); await P.waitForSelector('[data-division-page=web]');
  const cards = await P.locator('[data-division-page=web] .stat .l').allInnerTexts();
  ok('a division workspace has its parts: services & prices, projects, clients, quotes, team, documents', ['Services & prices', 'Projects', 'Clients', 'Quotes', 'Team', 'Documents'].every((c) => cards.map((x) => x.toLowerCase()).includes(c.toLowerCase())), cards.join('|'));
  ok('every number on it is a real count (or a dash where nothing exists yet)', (await P.locator('[data-division-page=web] .stat .n').allInnerTexts()).every((n) => /^(\d+|—)$/.test(n.trim())));
  await P.click('[data-division-page=web] a.stat:has(.l:text-is("SERVICES & PRICES"))').catch(async () => { await P.locator('[data-division-page=web] a.stat').first().click(); });
  await P.waitForURL('**/search?q=**'); ok('a card opens that division\'s records in Search without an error', !/could not|error/i.test(await main(P)) && /division%3Aweb|division:web/.test(decodeURIComponent(P.url())), P.url());
  await P.goto(BASE + '/divisions/nope'); ok('an unknown division is simply not found', /not found|404/i.test(await P.content()));

  await P.goto(BASE + '/sections'); const t2 = await main(P);
  const secs = await P.locator('[data-section]').count();
  ok('the database index shows 13 sections', secs === 13, secs);
  ok('every table is listed once (141 names across the sections)', (await P.locator('.sec-tables code').count()) === 141, await P.locator('.sec-tables code').count());
  await P.fill('[data-testid=section-filter]', 'invoice');
  ok('the filter narrows to where invoices live', (await P.locator('[data-section]').count()) < 6 && (await P.locator('[data-section=finance]').count()) === 1 && /invoices/.test(await main(P)));
  await P.fill('[data-testid=section-filter]', 'zzzz'); ok('and says so when nothing matches', /Nothing matches/.test(await main(P)));

  // who may see the index
  const { page: W } = await session('web_staff@ada.test');
  await W.goto(BASE + '/sections'); ok('Web staff cannot open the database index', /do not have permission/i.test(await main(W)), await main(W));
  ok('and do not see it in their menu', !(await W.locator('.nav a[href="/sections"]').count()));
  await W.goto(BASE + '/divisions/web'); ok('but can open their division workspace', (await W.locator('[data-division-page=web]').count()) === 1);

  // loading feedback: slow the next page and look for the progress bar
  await P.goto(BASE + '/dashboard');
  await P.route('**/documents**', async (route) => { await new Promise((r) => setTimeout(r, 2500)); await route.continue(); });
  await P.click('.nav a[href="/documents"]');
  ok('a slow page shows the loading bar at once', await P.locator('[data-testid=nav-progress]').isVisible({ timeout: 1500 }).catch(() => false));
  await P.waitForURL('**/documents', { timeout: 20000 }); await P.waitForSelector('[data-testid=nav-progress]', { state: 'detached', timeout: 10000 }).catch(() => {});
  ok('and the bar is gone when the page has loaded', (await P.locator('[data-testid=nav-progress]').count()) === 0);
} catch (e) { fails++; steps.push('FAIL unexpected: ' + String(e.stack || e).slice(0, 600)); }
await browser.close();
console.log(steps.join('\n')); console.log(`\n${steps.filter((s) => s.startsWith('ok')).length} passed, ${fails} failed`); process.exit(fails ? 1 : 0);
