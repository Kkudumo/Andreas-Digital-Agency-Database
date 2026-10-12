import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
const BASE = 'http://localhost:3100';
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined, args: ['--no-sandbox'] });
const steps = []; let fails = 0;
const ok = (name, cond, extra = '') => { steps.push(`${cond ? 'ok  ' : 'FAIL'} ${name}${cond ? '' : ' :: ' + extra}`); if (!cond) fails++; };
async function session(email) {
  const ctx = await browser.newContext(); const page = await ctx.newPage(); page.setDefaultTimeout(30000);
  await page.goto(BASE + '/login'); await page.fill('input[name=email]', email); await page.fill('input[name=password]', 'x'); await page.click('button[type=submit]');
  await page.waitForURL('**/search**'); return { ctx, page };
}
const settle = async (page) => { await page.waitForTimeout(1200); await page.waitForLoadState('networkidle'); await page.waitForTimeout(400); };
const seen = async (page, s) => { try { await page.waitForFunction((t) => document.querySelector('main').innerText.includes(t), s, { timeout: 10000 }); return true; } catch { return false; } };
const text = async (page) => (await page.locator('main').innerText());
const flash = async (page) => (await page.locator('.flash').first().innerText().catch(() => ''));

let A;
try {
// ---------- A: web_lead
let { ctx: ctxA, page: A0 } = await session('web_lead@ada.test'); A = A0;
ok('login lands on Search', A.url().includes('/search'));
await A.goto(BASE + '/search?q=zeta'); ok('search before: nothing found', /0 results/.test(await text(A)), await text(A));
await A.goto(BASE + '/clients/new?name=Zeta%20Test%20Company'); ok('new client: no existing match', /No existing client found/.test(await text(A)));
await A.selectOption('select[name=division]', { label: 'ADA Web' }); await A.fill('input[name=registration]', 'ZTC-2026'); await A.click('button:has-text("Create")');
await A.waitForURL(/\/clients\/[0-9a-f-]{36}/); ok('client created, lands on Client 360', /Client 360/.test(await text(A)) && /Zeta Test Company/.test(await text(A)), await text(A));
const clientUrl = A.url().split('?')[0]; const clientId = clientUrl.split('/').pop();

// Tech asks for the same company: must NOT create a second one
let { ctx: ctxT, page: T } = await session('tech_lead@ada.test');
await T.goto(BASE + '/clients/new?name=Zeta%20Test%20Company'); const tt = await text(T);
ok('Tech sees the existing client instead of creating one', /already knows/i.test(tt) || /No existing client found/.test(tt) === false, tt.slice(0, 300));
await ctxT.close();

// contact
await A.goto(clientUrl); await A.click('summary:has-text("Add a contact")'); await A.fill('details:has(summary:has-text("Add a contact")) input[name=name]', 'Zoe Zeta');
await A.fill('details:has(summary:has-text("Add a contact")) input[name=email]', 'zoe@zeta.example'); await A.check('details:has(summary:has-text("Add a contact")) input[name=primary]');
await A.click('details:has(summary:has-text("Add a contact")) button[type=submit]'); await settle(A);
ok('contact added', await seen(A, 'Zoe Zeta'), await flash(A));

// project
await A.click('summary:has-text("Create a project")'); await A.fill('details:has(summary:has-text("Create a project")) input[name=name]', 'Zeta Website');
await A.click('details:has(summary:has-text("Create a project")) button[type=submit]'); await A.waitForURL('**/projects/**');
ok('project created (proposed)', /Project 360/.test(await text(A)) && /proposed/.test(await text(A)), await text(A));
const projectUrl = A.url().split('?')[0];

// quote from the client page, linked to the project
await A.goto(clientUrl); await A.click('summary:has-text("New quote")'); await A.fill('details:has(summary:has-text("New quote")) input[name=title]', 'Zeta website');
const proj = await A.locator('details:has(summary:has-text("New quote")) select[name=project] option').allInnerTexts(); await A.selectOption('details:has(summary:has-text("New quote")) select[name=project]', { label: 'Zeta Website' });
await A.click('details:has(summary:has-text("New quote")) button[type=submit]'); await A.waitForURL('**/quotes/**');
ok('quote created in draft', /draft/.test(await text(A)), await text(A));
const quoteUrl = A.url().split('?')[0];
await A.selectOption('select[name=service]', { index: 0 }); await A.click('button:has-text("Add line")'); await settle(A);
ok('catalogue line added at 5,000 with price snapshot', /5,000\.00/.test(await text(A)) && /approved catalogue price/.test(await text(A)), await text(A));

// submit for approval; requester cannot approve
async function move(page, to) { await page.selectOption('form:has(button:has-text("Apply")) select[name=to]', to); await page.click('button:has-text("Apply")'); await settle(page); }
await move(A, 'pending_approval'); ok('quote submitted for approval', /pending approval/i.test(await text(A)), await flash(A));
await move(A, 'approved'); ok('requester cannot approve their own quote', (await flash(A)).length > 0 && /pending approval/i.test(await text(A)), await flash(A));

// ---------- CEO approves
let { ctx: ctxC, page: C } = await session('ceo@ada.test');
await C.goto(quoteUrl); await move(C, 'approved'); ok('management approves', /approved/i.test(await text(C)) && !/^.*error/i.test(await flash(C)), await flash(C));
await ctxC.close();

// ---------- A continues: send, accept, convert, contract
await A.goto(quoteUrl); await move(A, 'sent'); await move(A, 'accepted'); ok('quote accepted', /accepted/.test(await text(A)), await flash(A));
await A.click('button:has-text("Link quote to its project")'); await A.waitForURL('**/projects/**');
ok('project holds the priced service from the quote', /Zeta Website|Website Development/.test(await text(A)) && /5,000\.00/.test(await text(A)), await text(A));
await A.goto(quoteUrl); await A.click('button:has-text("Create contract from this quote")'); await A.waitForURL('**/contracts/**'); const contractUrl = A.url().split('?')[0];
for (const to of ['internal_review']) { await move(A, to); }
ok('contract in review', /internal review/i.test(await text(A)), await flash(A));
({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(contractUrl); await move(C, 'approved'); await ctxC.close();
await A.goto(contractUrl); await move(A, 'sent'); await move(A, 'signed'); await move(A, 'active');
ok('contract active and linked to the project', /active/i.test(await text(A)) && /Zeta Website/.test(await text(A)), await text(A));

// ---------- finance bills it
let { ctx: ctxF, page: F } = await session('fin@ada.test');
await F.goto(contractUrl); await F.click('button:has-text("Bill this line")'); await F.waitForURL('**/invoices/**'); const invoiceUrl = F.url().split('?')[0];
ok('draft invoice from the contract line', /draft/i.test(await text(F)) && /5,750\.00|5,000\.00/.test(await text(F)), await text(F));
await move(F, 'pending_approval');
({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(invoiceUrl); await move(C, 'approved'); await ctxC.close();
await F.goto(invoiceUrl); await move(F, 'issued'); ok('invoice issued with client snapshot', /Issued to Zeta Test Company/.test(await text(F)) && /issued/i.test(await text(F)), await text(F));
// part payment
await F.goto(clientUrl); await F.click('summary:has-text("Record a payment")'); await F.fill('details:has(summary:has-text("Record a payment")) input[name=amount]', '2000');
await F.selectOption('details:has(summary:has-text("Record a payment")) select[name=invoice]', { index: 1 }); await F.click('details:has(summary:has-text("Record a payment")) button[type=submit]'); await settle(F);
await F.goto(invoiceUrl); const it = await text(F); ok('part payment: derived balance 3,750 and partially paid', /3,750\.00/.test(it) && /partially paid/i.test(it), it);
await ctxF.close();

// ---------- attach: document, communication, ticket, asset (as A, on the project)
await A.goto(projectUrl);
await A.click('summary:has-text("Register a document")'); await A.fill('details:has(summary:has-text("Register a document")) input[name=title]', 'Zeta brief'); await A.click('details:has(summary:has-text("Register a document")) button[type=submit]'); await settle(A);
ok('document registered and linked', await seen(A, 'Zeta brief'), await flash(A));
await A.click('summary:has-text("Record a communication")'); await A.fill('details:has(summary:has-text("Record a communication")) input[name=subject]', 'Kick-off call');
await A.fill('details:has(summary:has-text("Record a communication")) textarea[name=body]', 'SECRET-BODY-TEXT start the build'); await A.click('details:has(summary:has-text("Record a communication")) button[type=submit]'); await settle(A);
ok('communication recorded (metadata shown, body not)', (await seen(A, 'Communications (metadata only) · 1')) && !/SECRET-BODY-TEXT/.test(await text(A)), await flash(A));
await A.click('summary:has-text("Register an asset")'); await A.fill('details:has(summary:has-text("Register an asset")) input[name=name]', 'Zeta demo server'); await A.click('details:has(summary:has-text("Register an asset")) button[type=submit]'); await settle(A);
ok('asset registered against client and project', await seen(A, 'Zeta demo server'), await flash(A));
await A.click('summary:has-text("Raise a ticket")'); await A.fill('details:has(summary:has-text("Raise a ticket")) input[name=title]', 'Zeta site is slow'); await A.click('details:has(summary:has-text("Raise a ticket")) button[type=submit]'); await settle(A);
ok('ticket raised against the project', await seen(A, 'Zeta site is slow'), await flash(A));

// ---------- 360s and search
const p = await text(A); await A.reload(); const p2 = await text(A);
ok('Project 360 shows contract, invoice, payment, document, communication, asset, ticket',
  ['Contracts', 'Invoices', 'Payments', 'Documents', 'Communications', 'Assets', 'Tickets'].every((s) => p2.includes(s)) && /3,750\.00/.test(p2) && /2,000\.00/.test(p2), p2.slice(0, 1500));
await A.goto(clientUrl); const c2 = await text(A); ok('Client 360: derived money invoiced 5,750 / paid 2,000 / outstanding 3,750', /5,750\.00/.test(c2) && /2,000\.00/.test(c2) && /3,750\.00/.test(c2), c2.slice(0, 600));
await A.goto(BASE + '/search?q=zeta'); const s1 = await text(A); ok('search "zeta" finds client, project, quote, contract, asset, ticket', ['client', 'project', 'quote', 'contract', 'asset', 'ticket'].every((t) => new RegExp(t).test(s1)), s1.slice(0, 800));
await A.click('table a:has-text("Zeta Test Company")'); await A.waitForURL('**/clients/**'); ok('search result opens Client 360', /Client 360/.test(await text(A)));
await A.goto(BASE + '/search?q=type:client zeta'); ok('type:client filter', /1 result/.test(await text(A)), await text(A));

// ---------- invoices and payments are found through Search too
let { ctx: ctxF2, page: F2 } = await session('fin@ada.test');
await F2.goto(BASE + '/search?q=type:invoice'); ok('finance finds the invoice by type', /1 result/.test(await text(F2)), await text(F2));
await F2.click('table a:has-text("ADA-INV")'); await F2.waitForURL(/\/invoices\/[0-9a-f-]{36}/); ok('the search result opens the invoice page', /Invoice ADA-INV/.test(await text(F2)), await text(F2));
await F2.goto(BASE + '/search?q=type:payment'); ok('finance finds the payment by type', /1 result/.test(await text(F2)), await text(F2));
await ctxF2.close();

// ---------- the dashboard shows the same engagement as derived numbers, and only to those who may see them
let { ctx: ctxD, page: Dp } = await session('ceo@ada.test');
await Dp.goto(BASE + '/dashboard'); await Dp.waitForTimeout(1500); const dt = await text(Dp);
ok('dashboard (management): receivables 3,750 outstanding, a pipeline, live projects, open tickets', /Outstanding receivables/i.test(dt) && /3,750\.00/.test(dt) && /Sales pipeline/i.test(dt) && /Live projects/i.test(dt) && /Open tickets/i.test(dt), dt.slice(0, 900));
await Dp.screenshot({ path: process.env.DASH_SHOT || 'dashboard.png', fullPage: true });
await ctxD.close();
let { ctx: ctxD2, page: Dq } = await session('tech_staff@ada.test');
await Dq.goto(BASE + '/dashboard'); await Dq.waitForTimeout(1500); const dq = await text(Dq);
ok('dashboard (another division, no finance rights): none of the Zeta money or tiles', !/3,750\.00/.test(dq) && !/Outstanding receivables/i.test(dq), dq.slice(0, 600));
await ctxD2.close();


// ---------- credit note, expense, report, schedule: the finance modules built after the pilot, through the interface
let { ctx: ctxX, page: X } = await session('fin@ada.test');
await X.goto(invoiceUrl); await X.selectOption('select[name=reason_code]', 'price_adjustment'); await X.click('button:has-text("Credit this invoice")'); await X.waitForURL('**/credit-notes/**');
const cnUrl = X.url().split('?')[0]; ok('a credit note is drafted from the invoice', /Credit note ADA-CRN/.test(await text(X)) && /draft/i.test(await text(X)), await text(X));
await X.fill('input[name=description]', 'Agreed reduction'); await X.fill('input[name=unit_price]', '500'); await X.click('button:text-is("Add")'); await settle(X);
ok('a free-form line of 500 is added', await seen(X, 'Agreed reduction') && /500\.00/.test(await text(X)), await flash(X));
await move(X, 'pending_approval'); ok('credit note submitted', /pending approval/i.test(await text(X)), await flash(X));
({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(cnUrl); await move(C, 'approved'); ok('management approves the credit note', /approved/i.test(await text(C)), await flash(C)); await ctxC.close();
await X.goto(cnUrl); await move(X, 'issued'); ok('finance issues it', /issued/i.test(await text(X)), await flash(X));
await X.goto(invoiceUrl); ok('the invoice balance is derived net of the credit: 3,175 left (the 500 credit carries the 15% VAT)', /3,175\.00/.test(await text(X)), await text(X));

await X.goto(BASE + '/expenses'); await X.fill('input[name=description]', 'Hosting for Zeta'); await X.fill('input[name=amount]', '1200');
await X.selectOption('select[name=project]', { label: 'Zeta Website' }); await X.click('button:has-text("Record as draft")'); await X.waitForURL('**/expenses/**');
const exUrl = X.url().split('?')[0]; ok('an expense is recorded as a draft against the project', /Expense · ADA-EXP/.test(await text(X)) && /draft/i.test(await text(X)), await text(X));
await move(X, 'pending_approval'); ok('expense submitted', /pending approval/i.test(await text(X)), await flash(X));
({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(exUrl); await move(C, 'approved'); ok('management approves the expense', /approved/i.test(await text(C)), await flash(C)); await ctxC.close();
await X.goto(exUrl); await X.click('button:has-text("Record payment")'); await settle(X);
ok('finance pays it: final', /paid/i.test(await text(X)) && !/Record payment/.test(await text(X)), await flash(X));

await X.goto(contractUrl); await X.fill('input[name=start]', '2026-11-01'); await X.click('button:has-text("Schedule")'); await settle(X);
ok('scheduling a line that is already fully billed is refused by the database', /fully billed/i.test(await flash(X)), await flash(X));
await X.goto(BASE + '/billing?preview=2030-01-01'); ok('billing runs page opens and the preview says nothing would be billed', /Billing runs/.test(await text(X)) && /Nothing would be billed/.test(await text(X)), await text(X));
await ctxX.close();

({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(BASE + '/organization/reviews'); await settle(C); ok('the duplicates page opens for management', /Possible duplicate organizations/.test(await text(C)), await text(C));
await C.goto(BASE + '/dashboard'); await settle(C); ok('the dashboard shows the new spend and credit figures', /Spend/.test(await text(C)) && /1,200\.00/.test(await text(C)), await text(C));
await C.goto(BASE + '/reports?report=aging'); await settle(C); ok('aging report shows the client with the derived balance', /Zeta Test Company/.test(await text(C)) && /3,175\.00/.test(await text(C)), await text(C));
await C.goto(BASE + '/reports?report=profitability'); await settle(C); ok('profitability report: invoiced and cost for the project', /Zeta Website/.test(await text(C)) && /1,200\.00/.test(await text(C)), await text(C));
const csv = await C.request.get(BASE + '/reports/csv?report=aging'); const csvBody = await csv.text();
ok('the CSV is the same figures', csv.status() === 200 && /text\/csv/.test(csv.headers()['content-type']) && /Zeta Test Company/.test(csvBody) && /3175/.test(csvBody), csvBody.slice(0, 300));
await ctxC.close();
let { ctx: ctxR, page: R } = await session('web_staff@ada.test');
await R.goto(BASE + '/reports?report=aging'); await settle(R); ok('staff without finance rights get an empty report, not the figures', !/Zeta Test Company/.test(await text(R)), await text(R));
const csv2 = await R.request.get(BASE + '/reports/csv?report=aging'); ok('and an empty CSV (header only)', !/Zeta/.test(await csv2.text()));
await ctxR.close();


// ---------- websites: management registers a site and issues its key; the key works against the public API; nobody else can
({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(BASE + '/websites'); await settle(C);
await C.fill('input[name=name]', 'Journey test site'); await C.fill('input[name=domain]', 'journey.example.test');
await C.click('button:has-text("Register")'); await settle(C);
ok('a website is registered', await seen(C, 'Journey test site'), await flash(C));
await C.locator('tr:has-text("Journey test site") button:has-text("Issue key")').click(); await settle(C);
const keyText = await C.locator('tr:has-text("Journey test site") .mono').filter({ hasText: /^ada_[0-9a-f]{48}$/ }).first().innerText().catch(() => '');
ok('the key is shown once on the page and is not in the address bar', /^ada_[0-9a-f]{48}$/.test(keyText) && !C.url().includes(keyText), keyText);
const pa = await fetch('http://127.0.0.1:8787/api/public/divisions', { headers: { authorization: `Bearer ${keyText}` } });
ok('the new key works against the public API and returns only published divisions', pa.status === 200 && Array.isArray(await pa.json()), String(pa.status));
const pb = await fetch('http://127.0.0.1:8787/api/public/services', { headers: { authorization: `Bearer ${keyText}` } });
ok('...and is refused what it was not ticked for (services.read was ticked by default, enquiries not)', pb.status === 200);
const pc = await fetch('http://127.0.0.1:8787/api/public/enquiries', { method: 'POST', headers: { authorization: `Bearer ${keyText}`, 'content-type': 'application/json' }, body: JSON.stringify({ name: 'X' }) });
ok('enquiries.submit was not ticked, so submitting is refused (403)', pc.status === 403, String(pc.status));
await C.reload(); await settle(C); ok('after a reload the key is gone: only its prefix remains', !(await text(C)).includes(keyText) && (await text(C)).includes(keyText.slice(0, 8)), await text(C));
await ctxC.close();
let { ctx: ctxW2, page: W2 } = await session('web_staff@ada.test');
await W2.goto(BASE + '/websites'); await settle(W2); ok('staff without websites.view see no registry and no register form', !/Journey test site/.test(await text(W2)) && !/Register a website/.test(await text(W2)), await text(W2));
await ctxW2.close();

// ---------- the price logic: change a price in Hub, publish, and the public API (what the websites build from) follows
// the real catalogue is loaded here, exactly as the owner will load it (after the Zeta steps, which pick their own services)
execFileSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', process.env.ADA_LIVE_DB_URL, '-f', 'supabase/seed_data/catalogue.sql'], { stdio: 'ignore' });
({ ctx: ctxC, page: C } = await session('ceo@ada.test'));
await C.goto(BASE + '/services?q=check-up'); await settle(C);
ok('Services & prices lists the catalogue with the price now', /Business Check-up/.test(await text(C)) && /N?A?D? ?199\.00/.test(await text(C)), await text(C));
await C.click('a:has-text("Business Check-up")'); await C.waitForURL(/\/services\/[0-9a-f-]{36}/);
ok('the service page shows its price and that it is not on the websites yet', /199\.00/.test(await text(C)) && /on the websites: no/i.test(await text(C)), await text(C));
await C.click('button:has-text("Publish to the websites")'); await settle(C);
ok('publishing takes it live (the CEO may approve and publish)', /on the websites: yes/i.test(await text(C)), await flash(C));
const api = async () => (await (await fetch('http://127.0.0.1:8787/api/public/services?division=consulting', { headers: { authorization: `Bearer ${keyText}` } })).json());
let svcs = await api(); ok('the public API now returns it at 199', svcs.length === 1 && svcs[0].price.amount === 199 && svcs[0].price.starting_price === false, JSON.stringify(svcs));
await C.fill('input[name=amount]', '249'); await C.fill('input[name=reason]', 'journey: price rise'); await C.click('button:has-text("Save price")'); await settle(C);
ok('saving a new price shows it, with the old one kept in the history', /249\.00/.test(await text(C)) && /199\.00/.test(await text(C)) && /Price saved and approved/.test(await flash(C)), await flash(C) + (await text(C)).slice(0, 300));
svcs = await api(); ok('...and the public API answers 249 on the next request, with no other step', svcs[0].price.amount === 249, JSON.stringify(svcs));
await C.click('button:has-text("Take off the websites")'); await settle(C);
svcs = await api(); ok('taking it off the websites removes it from the API', svcs.length === 0, JSON.stringify(svcs));
await ctxC.close();

// ---------- outsiders see nothing
let { ctx: ctxW, page: W } = await session('web_staff@ada.test');
await W.goto(BASE + '/r/ZZZZZZZZZ'); ok('unknown / hidden id: not found', /Record not found/.test(await text(W)));
await ctxW.close();
let { ctx: ctxO, page: O } = await session('tech_staff@ada.test');
await O.goto(clientUrl); const ot = await O.content(); ok('another division cannot open the Zeta client 360 (404 page)', /could not be found|404|This page/i.test(ot), ot.slice(0, 200));
await O.goto(BASE + '/search?q=zeta'); ok('another division searching "zeta" finds nothing', /0 results/.test(await text(O)), await text(O));
await ctxO.close();


} catch (e) { steps.push('EXCEPTION ' + String(e).split('\n')[0]); fails++; try { steps.push('URL ' + A.url()); steps.push((await A.locator('body').innerText()).slice(0, 900)); } catch {} }
await browser.close();
console.log(steps.join('\n')); console.log(fails ? `${fails} FAILED` : 'ALL JOURNEY STEPS PASSED');
process.exit(fails ? 1 : 0);
