// Unit tests: the HTTP layer's own rules, with a fake database function. Run: node --test test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { handle, createLimiter, keyHash, statusFor } from '../src/api.mjs';

const KEY = 'ada_0123456789abcdef';
const mk = (over = {}) => ({ method: 'GET', url: '/api/public/services', headers: { authorization: `Bearer ${KEY}` }, body: '', ip: '10.0.0.1', ...over });
const post = (path, body, over = {}) => mk({ method: 'POST', url: path, headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json' }, body: JSON.stringify(body), ...over });
const rec = (result = []) => { const calls = []; return { calls, call: async (fn, args) => { calls.push([fn, args]); return typeof result === 'function' ? result(fn, args) : result; } }; };

test('the key is hashed here: the database function gets the SHA-256 hex, never the key', async () => {
  const d = rec(); await handle(mk(), { call: d.call });
  assert.equal(d.calls[0][0], 'services');
  assert.equal(d.calls[0][1][0], keyHash(KEY)); assert.match(d.calls[0][1][0], /^[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(d.calls).includes(KEY));
});
test('no key: 401 and the database is not called; X-API-Key works too', async () => {
  const d = rec();
  assert.equal((await handle(mk({ headers: {} }), { call: d.call })).status, 401);
  assert.equal(d.calls.length, 0);
  assert.equal((await handle(mk({ headers: { 'x-api-key': KEY } }), { call: d.call })).status, 200);
});
test('unknown route 404, wrong method 405 with Allow', async () => {
  const d = rec();
  assert.equal((await handle(mk({ url: '/api/public/secrets' }), { call: d.call })).status, 404);
  const r = await handle(mk({ method: 'DELETE', url: '/api/public/services' }), { call: d.call });
  assert.equal(r.status, 405); assert.equal(r.headers.allow, 'GET');
  assert.equal(d.calls.length, 0);
});
test('database errors map to HTTP without leaking their text', async () => {
  for (const [code, status] of [['42501', 403], ['P0002', 404], ['22023', 422], ['23514', 422], ['23505', 409], ['XX000', 500], [undefined, 500]]) {
    const r = await handle(mk(), { call: async () => { const e = new Error('relation "staff" does not exist: secret detail'); e.code = code; throw e; } });
    assert.equal(r.status, status);
    assert.ok(!/staff|secret/.test(r.body), r.body);
  }
  assert.deepEqual(statusFor('42501'), [403, 'forbidden']);
});
test('a null result for a single record is a 404', async () => {
  assert.equal((await handle(mk({ url: '/api/public/vacancies/ADA-VAC-2026-0001' }), { call: async () => null })).status, 404);
  assert.equal((await handle(mk({ url: '/api/public/vacancies/ADA-VAC-2026-0001' }), { call: async () => ({ id: 'x' }) })).status, 200);
});
test('query parameters are validated before they reach the database', async () => {
  const d = rec();
  assert.equal((await handle(mk({ url: '/api/public/services?division=web' }), { call: d.call })).status, 200);
  assert.equal(d.calls[0][1][1], 'web');
  for (const bad of ["web';drop table x;--", 'WEB', 'a'.repeat(41)]) assert.equal((await handle(mk({ url: `/api/public/services?division=${encodeURIComponent(bad)}` }), { call: d.call })).status, 422);
  assert.equal(d.calls.length, 1);
});
test('GET responses carry Cache-Control and an ETag, and If-None-Match gives 304', async () => {
  const d = rec([{ id: 'a' }]);
  const a = await handle(mk(), { call: d.call });
  assert.match(a.headers['cache-control'], /max-age=300/); assert.match(a.headers.etag, /^"[A-Za-z0-9_-]{27}"$/); assert.match(a.headers.vary, /Authorization/);
  const b = await handle(mk({ headers: { authorization: `Bearer ${KEY}`, 'if-none-match': a.headers.etag } }), { call: d.call });
  assert.equal(b.status, 304); assert.equal(b.body, '');
  const c = await handle(mk(), { call: async () => [{ id: 'changed' }] });
  assert.notEqual(c.headers.etag, a.headers.etag);
});
test('POST enquiry: arguments in order, utm and currency normalised, 201 with the reference only and no caching', async () => {
  const d = rec({ reference: 'ADA-ENQ-2026-0001' });
  const r = await handle(post('/api/public/enquiries', { name: ' Ann ', email: 'a@x.na', message: 'Hi', utm: { utm_source: 'g' }, budget: 1500, currency: 'nad' }), { call: d.call });
  assert.equal(r.status, 201); assert.equal(r.headers['cache-control'], 'no-store'); assert.deepEqual(JSON.parse(r.body), { reference: 'ADA-ENQ-2026-0001' });
  const [fn, args] = d.calls[0];
  assert.equal(fn, 'submit_enquiry');
  assert.deepEqual(args.slice(1), ['Ann', 'a@x.na', null, null, null, 'Hi', null, null, { utm_source: 'g' }, 1500, 'NAD']);
});
test('POST validation: required fields, unknown fields, types, sizes, content type, malformed JSON', async () => {
  const d = rec({ reference: 'x' });
  const cases = [
    [post('/api/public/enquiries', { email: 'a@x.na' }), 422],
    [post('/api/public/enquiries', { name: 'A', isAdmin: true }), 422],
    [post('/api/public/enquiries', { name: 'A', message: 'x'.repeat(4001) }), 422],
    [post('/api/public/enquiries', { name: 'A', budget: '100' }), 422],
    [post('/api/public/enquiries', { name: 'A', utm: { utm_source: 1 } }), 422],
    [post('/api/public/enquiries', ['A']), 422],
    [post('/api/public/applications', { name: 'A', email: 'a@x.na' }), 422],
    [post('/api/public/enquiries', { name: 'A', message: 'x'.repeat(20000) }), 413],
    [{ ...post('/api/public/enquiries', { name: 'A' }), headers: { authorization: `Bearer ${KEY}`, 'content-type': 'text/plain' } }, 415],
    [{ ...post('/api/public/enquiries', { name: 'A' }), body: '{nope' }, 422],
  ];
  for (const [req, status] of cases) assert.equal((await handle(req, { call: d.call })).status, status, req.body.slice(0, 60));
  assert.equal(d.calls.length, 0);
});
test('rate limits: per key and per address, 429 with Retry-After, and a new window resets', async () => {
  let t = 0; const d = rec();
  const limiter = createLimiter({ perMinute: 2, now: () => t }); const ipLimiter = createLimiter({ perMinute: 3, now: () => t });
  const run = (over) => handle(mk(over), { call: d.call, limiter, ipLimiter }).then((r) => r.status);
  assert.deepEqual([await run(), await run(), await run()], [200, 200, 429]);
  assert.equal((await handle(mk(), { call: d.call, limiter, ipLimiter })).headers['retry-after'], '60');
  assert.equal(await run({ ip: '10.0.0.2', headers: { authorization: 'Bearer ada_ANOTHERKEY9999' } }), 200);
  t += 61000; assert.equal(await run(), 200);
});
