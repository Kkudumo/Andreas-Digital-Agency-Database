// End-to-end: the real HTTP server -> the real pg pool -> the real database, connected as the ada_public_api role (no table access).
// Needs ADA_PUBLIC_API_DATABASE_URL (the role's login) and the fixture loaded. Run by scripts/test-db.sh.
import assert from 'node:assert/strict';
import pg from 'pg';
import { createServer } from '../src/server.mjs';

const FULL = 'itest-full-key-0001', LIMITED = 'itest-limited-key-0002';
const server = createServer(); await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
const get = (path, key, extra = {}) => fetch(base + path, { headers: key ? { authorization: `Bearer ${key}`, ...extra } : extra });
const post = (path, key, body) => fetch(base + path, { method: 'POST', headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
let n = 0; const ok = (name, cond, extra = '') => { n++; if (!cond) { console.error(`FAIL ${name} ${extra}`); process.exitCode = 1; } else console.log(`  ok  ${name}`); };

try {
  let r = await get('/healthz'); ok('healthz', r.status === 200);
  r = await get('/api/public/divisions', FULL); const divs = await r.json();
  ok('divisions: only published ones (web, tech, marketing, consulting...), never management/administration/finance', r.status === 200 && divs.some((d) => d.code === 'web') && !divs.some((d) => ['management', 'administration', 'finance'].includes(d.code)), JSON.stringify(divs).slice(0, 200));
  r = await get('/api/public/services', FULL); const svc = await r.json();
  const by = Object.fromEntries(svc.map((s) => [s.name, s]));
  const catalogue = ['Business Check-up', 'Business website', 'CCTV installation'];
  ok('services: the 3 published catalogue entries are there; unpublished ones (Windows Ready, Care Essential...) are absent', r.status === 200 && catalogue.every((x) => by[x]) && !by['Windows Ready'] && !by['Care Essential'], svc.map((s) => s.name).join(','));
  ok('a fixed price is returned as such', by['Business Check-up']?.price?.amount === 199 && by['Business Check-up'].price.starting_price === false && by['Business Check-up'].price.currency === 'NAD', JSON.stringify(by['Business Check-up']));
  ok('a "from" price says so', by['Business website']?.price?.amount === 2629.99 && by['Business website'].price.starting_price === true, JSON.stringify(by['Business website']));
  ok('a quote-based service has no price at all', by['CCTV installation'] && by['CCTV installation'].price === undefined, JSON.stringify(by['CCTV installation']));
  r = await get('/api/public/services?division=consulting', FULL); const only = await r.json();
  ok('division filter', r.status === 200 && only.length === 1 && only[0].name === 'Business Check-up', JSON.stringify(only).slice(0, 200));
  const etag = (await get('/api/public/services', FULL)).headers.get('etag'); r = await get('/api/public/services', FULL, { 'if-none-match': etag });
  ok('ETag round trip gives 304', r.status === 304);
  r = await get('/api/public/services', LIMITED); ok('a website without the capability is refused (403)', r.status === 403);
  r = await get('/api/public/divisions', LIMITED); ok('...but can read what it is allowed to', r.status === 200);
  r = await get('/api/public/services', 'not-a-registered-key-xxxx'); ok('an unknown key is refused (403) with no detail', r.status === 403 && !(await r.text()).includes('websites'));
  r = await get('/api/public/services'); ok('no key: 401', r.status === 401);
  r = await post('/api/public/enquiries', FULL, { name: 'Integration Test', email: 'integration@example.test', message: 'Hello from the test', page: '/contact', utm: { utm_source: 'test' } });
  const enq = await r.json(); ok('an enquiry is accepted and only a reference comes back', r.status === 201 && /^ADA-ENQ-/.test(enq.reference) && Object.keys(enq).length === 1, JSON.stringify(enq));
  r = await post('/api/public/enquiries', LIMITED, { name: 'X' }); ok('a website without enquiries.submit cannot send one', r.status === 403);
  r = await post('/api/public/enquiries', FULL, { name: 'X', role: 'admin' }); ok('unknown fields are rejected before the database', r.status === 422);
  r = await post('/api/public/applications', FULL, { vacancy: 'ADA-VAC-2099-9999', name: 'A Person', email: 'person@example.test' }); ok('applying to a vacancy that does not exist is 404', r.status === 404);
  r = await get('/api/public/vacancies/ADA-VAC-2099-9999', FULL); ok('a missing vacancy is 404', r.status === 404);
  r = await get('/api/public/statistics', FULL); const st = await r.json(); ok('statistics are derived live', r.status === 200 && st.services === svc.length && st.services >= 3, JSON.stringify(st));

  // Content and settings (the owner-level fixture publishes one post and one FAQ; settings come from the migration's seed)
  r = await get('/api/public/posts', FULL); const posts = await r.json();
  ok('posts: only the published one, with the approved fields', r.status === 200 && posts.length === 1 && posts[0].title === 'Integration news' && !('status' in posts[0]) && !('created_by' in posts[0]), JSON.stringify(posts));
  r = await get('/api/public/posts/integration-news', FULL); ok('a post by its address', r.status === 200 && (await r.json()).slug === 'integration-news');
  r = await get('/api/public/posts/does-not-exist', FULL); ok('an unknown address is 404', r.status === 404);
  r = await get('/api/public/faqs', FULL); const faqs = await r.json(); ok('FAQs: published only', r.status === 200 && faqs.length === 1 && faqs[0].question === 'Integration question?', JSON.stringify(faqs));
  r = await get('/api/public/settings?division=marketing', FULL); const st2 = await r.json();
  ok('settings: company facts plus the marketing rule for that division, never internal ones', r.status === 200 && st2.some((x) => x.key === 'company.phone' && x.value === '+264 81 803 2641') && st2.some((x) => x.key === 'marketing.min_budget' && x.value === '1499.99') && !st2.some((x) => x.key === 'integration.internal_note'), JSON.stringify(st2).slice(0, 200));
  r = await get('/api/public/settings', LIMITED); ok('settings need their own capability (403)', r.status === 403);

  // The role itself: it can run the API functions and nothing else.
  const c = new pg.Client({ connectionString: process.env.ADA_PUBLIC_API_DATABASE_URL, ssl: false }); await c.connect();
  for (const q of ['select * from services', 'select * from websites', 'select * from staff', 'select api_key_hash from websites']) {
    let code = null; try { await c.query(q); } catch (e) { code = e.code; }
    ok(`the API role cannot read tables (${q})`, code === '42501', String(code));
  }
  await c.end();
} finally { server.close(); }
console.log(n + ' checks');
