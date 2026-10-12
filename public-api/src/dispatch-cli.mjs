// Runs the dispatcher: `node src/dispatch-cli.mjs --once` (for a scheduler) or with no flag as a long-running loop.
import { runOnce } from './dispatcher.mjs';
import { claim, report } from './dispatcher-db.mjs';

const opts = () => ({ claim, report, debounceSeconds: Number(process.env.ADA_DISPATCH_DEBOUNCE_SECONDS ?? 20), log: (m) => console.error(m) });
if (process.argv.includes('--once')) {
  const r = await runOnce(opts()); console.log(JSON.stringify(r)); process.exit(0);
}
const every = Number(process.env.ADA_DISPATCH_INTERVAL_MS ?? 15000);
console.log(`ADA dispatcher running every ${every / 1000}s`);
for (;;) {
  try { const r = await runOnce(opts()); if (r.batches) console.log(JSON.stringify(r)); } catch (e) { console.error('dispatch run failed:', e?.name ?? 'error'); }
  await new Promise((res) => setTimeout(res, every));
}
