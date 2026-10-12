// Vercel Cron entry: GET /api/dispatch with `Authorization: Bearer $CRON_SECRET` (Vercel sends it when CRON_SECRET is set on the project).
import { timingSafeEqual } from 'node:crypto';
import { runOnce } from '../src/dispatcher.mjs';
import { claim, report } from '../src/dispatcher-db.mjs';

const same = (a, b) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));

export default {
  async fetch(request) {
    const secret = process.env.CRON_SECRET;
    const got = request.headers.get('authorization') ?? '';
    if (!secret || !same(got, `Bearer ${secret}`)) return new Response('unauthorized', { status: 401 });
    const r = await runOnce({ claim, report, debounceSeconds: Number(process.env.ADA_DISPATCH_DEBOUNCE_SECONDS ?? 20), log: (m) => console.error(m) });
    return new Response(JSON.stringify(r), { headers: { 'content-type': 'application/json' } });
  },
};
