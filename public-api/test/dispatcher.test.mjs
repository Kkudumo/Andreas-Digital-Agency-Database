import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { runOnce, sign, targetProblem } from '../src/dispatcher.mjs';

const batch = (over = {}) => ({ subscription_id: 's1', url: 'https://hooks.example.com/abc-secret-token', secret_ref: null, domain: 'tech.example.com', delivery_ids: ['1', '2'], events: [{ id: 1, type: 'price.changed', entity: { ada_id: 'ADA-SVC-2026-0001' }, payload: {} }, { id: 2, type: 'service.published' }], ...over });
const harness = (batches, postImpl, env = {}) => {
  const reports = [], posts = [];
  return { reports, posts, run: (extra = {}) => runOnce({ claim: async () => batches, report: async (ids, ok, err) => { reports.push([ids, ok, err]); return ids.length; }, post: async (url, o) => { posts.push([url, o]); return postImpl(url, o); }, env, now: () => 1_700_000_000_000, ...extra }) };
};

test('one request per subscription carrying all its events; success is reported as delivered', async () => {
  const h = harness([batch()], async () => ({ status: 204 }));
  const r = await h.run();
  assert.deepEqual(r, { batches: 1, delivered: 1, failed: 0 });
  assert.equal(h.posts.length, 1);
  const body = JSON.parse(h.posts[0][1].body); assert.equal(body.website, 'tech.example.com'); assert.equal(body.events.length, 2);
  assert.deepEqual(h.reports, [[['1', '2'], true, null]]);
});
test('a signed subscription: timestamp and HMAC over "<ts>.<body>" with the secret from the named environment variable', async () => {
  const h = harness([batch({ secret_ref: 'WEBHOOK_SECRET_TECH' })], async () => ({ status: 200 }), { WEBHOOK_SECRET_TECH: 'shh-secret' });
  await h.run();
  const o = h.posts[0][1]; const ts = o.headers['x-ada-timestamp'];
  assert.equal(ts, '1700000000');
  assert.equal(o.headers['x-ada-signature'], 'v1=' + createHmac('sha256', 'shh-secret').update(`${ts}.${o.body}`).digest('hex'));
  assert.equal(o.headers['x-ada-signature'], sign('shh-secret', ts, o.body));
});
test('a subscription whose secret is not configured is never sent unsigned: it fails and is reported', async () => {
  const h = harness([batch({ secret_ref: 'WEBHOOK_SECRET_TECH' }), batch({ secret_ref: 'not a valid name!', delivery_ids: ['3'] })], async () => ({ status: 200 }), {});
  const r = await h.run();
  assert.equal(h.posts.length, 0); assert.deepEqual([r.delivered, r.failed], [0, 2]);
  assert.deepEqual(h.reports.map((x) => x[1]), [false, false]); assert.match(h.reports[0][2], /not configured/);
});
test('failures are reported without the URL or the error text; other batches still go out', async () => {
  const h = harness([batch({ delivery_ids: ['1'] }), batch({ delivery_ids: ['2'], url: 'https://ok.example.com/x' }), batch({ delivery_ids: ['3'], url: 'https://boom.example.com/hook-token-123' })],
    async (url) => { if (url.includes('boom')) throw Object.assign(new Error('connect ECONNREFUSED https://boom.example.com/hook-token-123'), { name: 'TypeError' }); return { status: url.includes('ok.') ? 200 : 502 }; });
  const r = await h.run();
  assert.deepEqual(r, { batches: 3, delivered: 1, failed: 2 });
  assert.deepEqual(h.reports.map((x) => [x[0][0], x[1], x[2]]), [['1', false, 'HTTP 502'], ['2', true, null], ['3', false, 'request failed (TypeError)']]);
  assert.ok(!JSON.stringify(h.reports).includes('token'));
});
test('targets must be https and public', () => {
  for (const bad of ['http://x.example.com/', 'https://localhost/x', 'https://127.0.0.1/x', 'https://10.1.2.3/x', 'https://192.168.0.5/', 'https://172.20.0.1/', 'https://169.254.169.254/latest', 'https://[::1]/', 'https://db.internal/x', 'not a url']) assert.notEqual(targetProblem(bad), null, bad);
  for (const good of ['https://hooks.example.com/a', 'https://api.vercel.com/v1/integrations/deploy/x', 'https://8.8.8.8/x']) assert.equal(targetProblem(good), null, good);
  assert.equal(targetProblem('https://localhost/x', { allowPrivate: true }), null);
});
test('a private target is refused before any request is made', async () => {
  const h = harness([batch({ url: 'https://169.254.169.254/latest/meta-data' })], async () => ({ status: 200 }));
  const r = await h.run();
  assert.equal(h.posts.length, 0); assert.equal(r.failed, 1); assert.equal(h.reports[0][2], 'private address');
});
