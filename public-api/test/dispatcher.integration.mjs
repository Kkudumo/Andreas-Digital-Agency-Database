// The dispatcher against the real database as the ada_dispatcher role: real claim/report, a fake network. Needs ADA_DISPATCHER_DATABASE_URL (the role's login)
// and ADA_OWNER_DATABASE_URL (to create a subscription and emit events, standing in for the Hub). Run by scripts/test-db.sh.
import assert from 'node:assert/strict';
import pg from 'pg';
import { runOnce } from '../src/dispatcher.mjs';
import { claim, report, closePool } from '../src/dispatcher-db.mjs';

let n = 0; const ok = (name, cond, extra = '') => { n++; if (!cond) { console.error(`FAIL ${name} ${extra}`); process.exitCode = 1; } else console.log(`  ok  ${name}`); };
const owner = new pg.Client({ connectionString: process.env.ADA_OWNER_DATABASE_URL, ssl: false }); await owner.connect();
const q = async (sql, args) => (await owner.query(sql, args)).rows;
try {
  const [site] = await q(`select id from websites where domain = 'integration.ada.test'`);
  await q(`delete from event_deliveries`); await q(`delete from event_subscriptions`);
  await q(`insert into event_subscriptions (website_id, url, secret_ref, event_types) values ($1, 'https://hooks.example.com/a-secret-token', 'ITEST_HOOK_SECRET', array['price.changed', 'content_post.published'])`, [site.id]);
  for (const t of ['price.changed', 'price.changed', 'content_post.published', 'something.else']) await q(`select emit_event($1, 'x', gen_random_uuid(), 'ADA-X-2026-0001', '{}')`, [t]);
  const posts = []; const post = async (url, o) => { posts.push({ url, ...o }); return { status: posts.length === 1 ? 502 : 200 }; };
  const env = { ITEST_HOOK_SECRET: 'integration-secret' };

  let r = await runOnce({ claim, report, post, env, debounceSeconds: 0, allowPrivate: false });
  ok('one batch with the three matching events (the unrelated event is not subscribed)', r.batches === 1 && JSON.parse(posts[0].body).events.length === 3, JSON.stringify(r));
  ok('it is signed', /^v1=[0-9a-f]{64}$/.test(posts[0].headers['x-ada-signature']));
  ok('a 502 is recorded as pending with the error and no URL', JSON.stringify(await q(`select distinct status, last_error, attempts from event_deliveries order by 1`)) === JSON.stringify([{ status: 'pending', last_error: 'HTTP 502', attempts: 1 }]));
  r = await runOnce({ claim, report, post, env, debounceSeconds: 0 });
  ok('nothing is due again until the back-off passes', r.batches === 0 && posts.length === 1, JSON.stringify(r));
  await q(`update event_deliveries set next_attempt_at = now() - interval '1 second'`);
  r = await runOnce({ claim, report, post, env, debounceSeconds: 0 });
  ok('after the back-off the same events are retried together and delivered', r.delivered === 1 && posts.length === 2 && JSON.stringify(await q(`select distinct status, attempts from event_deliveries`)) === JSON.stringify([{ status: 'delivered', attempts: 2 }]));
  ok('a missing secret never sends and the failure is recorded', await (async () => {
    await q(`select emit_event('price.changed', 'x', gen_random_uuid(), 'ADA-X-2026-0002', '{}')`);
    const before = posts.length; const r2 = await runOnce({ claim, report, post, env: {}, debounceSeconds: 0 });
    return r2.failed === 1 && posts.length === before && (await q(`select last_error from event_deliveries where status = 'pending'`))[0].last_error === 'signing secret is not configured';
  })());
} finally { await owner.end(); await closePool(); }
console.log(n + ' checks');
