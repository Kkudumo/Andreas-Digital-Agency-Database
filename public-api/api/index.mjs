// Vercel entry (Node runtime, Web-standard handler). vercel.json rewrites /api/public/* here. Same logic as src/server.mjs.
import { handle, createLimiter, MAX_BODY_BYTES } from '../src/api.mjs';
import { call } from '../src/db.mjs';

const limiter = createLimiter({ perMinute: 600 });
const ipLimiter = createLimiter({ perMinute: 120 });

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const raw = request.method === 'POST' ? await request.text() : '';
    const headers = Object.fromEntries(request.headers);
    const ip = String(headers['x-forwarded-for'] ?? '').split(',')[0].trim() || 'unknown';
    const out = Buffer.byteLength(raw) > MAX_BODY_BYTES
      ? { status: 413, headers: { 'content-type': 'application/json' }, body: '{"error":"request too large"}' }
      : await handle({ method: request.method, url: url.pathname + url.search, headers, body: raw, ip }, { call, limiter, ipLimiter, log: (...a) => console.error(...a) });
    return new Response(out.status === 304 ? null : out.body, { status: out.status, headers: out.headers });
  },
};
