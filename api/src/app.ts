import http from 'node:http';
import { createHash } from 'node:crypto';
import postgres from 'postgres';
import { RateLimiter, cleanUtm, clip, hashKey, statusFor } from './core.js';

// The public API (request handler): a thin HTTP layer over the public_api.* functions. It connects as role ada_public_api,
// which can run those functions and nothing else. It never builds SQL from request data.
const url = process.env.PUBLIC_API_DATABASE_URL;
if (!url) throw new Error('PUBLIC_API_DATABASE_URL is not set');
// Serverless (Vercel) runs many short-lived copies: keep one connection each and go through Supabase's
// transaction pooler, which does not support prepared statements.
const serverless = !!process.env.VERCEL;
const sql = postgres(url, serverless ? { max: 1, idle_timeout: 5, prepare: false } : { max: 5, idle_timeout: 20 });
const perKey = new RateLimiter(Number(process.env.RATE_PER_KEY ?? 300), 60_000);
const perIp = new RateLimiter(Number(process.env.RATE_PER_IP ?? 120), 60_000);
const writeIp = new RateLimiter(Number(process.env.RATE_WRITE_PER_IP ?? 10), 60_000);
setInterval(() => { perKey.sweep(); perIp.sweep(); writeIp.sweep(); }, 60_000).unref();
const MAX_BODY = 32 * 1024;
// Where browsers send application files (the application-file Edge Function in the ADA Core project).
const UPLOAD_URL = process.env.APPLICATION_UPLOAD_URL ?? 'https://uyhwcbjfvfkqsixthxkn.supabase.co/functions/v1/application-file';

function send(res: http.ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'x-content-type-options': 'nosniff', ...headers });
  res.end(text);
}
async function readJson(req: http.IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []; let size = 0;
  for await (const c of req) { size += c.length; if (size > MAX_BODY) throw Object.assign(new Error('too large'), { status: 413 }); chunks.push(c); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { throw Object.assign(new Error('invalid json'), { status: 400 }); }
}

const reads: Record<string, (h: string, q: URLSearchParams, id?: string) => Promise<unknown>> = {
  divisions: (h) => sql`select public_api.divisions(${h}) as r`.then((x) => x[0].r),
  services: (h, q) => sql`select public_api.services(${h}, ${q.get('division')}) as r`.then((x) => x[0].r),
  vacancies: (h, q) => sql`select public_api.vacancies(${h}, ${q.get('division')}) as r`.then((x) => x[0].r),
  vacancy: (h, _q, id) => sql`select public_api.vacancy(${h}, ${id!}) as r`.then((x) => x[0].r),
  portfolio: (h, q) => sql`select public_api.portfolio(${h}, ${q.get('division')}) as r`.then((x) => x[0].r),
  team: (h) => sql`select public_api.team(${h}) as r`.then((x) => x[0].r),
  statistics: (h) => sql`select public_api.statistics(${h}) as r`.then((x) => x[0].r),
  documents: (h, q) => sql`select public_api.documents(${h}, ${q.get('type')}) as r`.then((x) => x[0].r),
  document: (h, _q, id) => sql`select public_api.document(${h}, ${id!}) as r`.then((x) => x[0].r),
};

export async function handle(req: http.IncomingMessage, res: http.ServerResponse) {
  try {
    const u = new URL(req.url ?? '/', 'http://x');
    const ip = (req.headers['x-forwarded-for'] as string | undefined)?.split(',')[0].trim() || req.socket.remoteAddress || 'unknown';
    if (u.pathname === '/health' || u.pathname === '/api/health') {
      if (!u.searchParams.has('db')) return send(res, 200, { ok: true });
      // Database check: reports only the kind of failure (an error code), never the address, user or message.
      try { await sql`select 1`; return send(res, 200, { ok: true, db: 'ok' }); }
      catch (e: any) { return send(res, 503, { ok: false, db: 'error', code: String(e?.code ?? 'unknown').slice(0, 40) }, { 'cache-control': 'no-store' }); }
    }
    const m = u.pathname.match(/^\/api\/public\/([a-z]+)(?:\/([^/]+))?$/);
    if (!m) return send(res, 404, { error: 'not_found' });
    const key = req.headers['x-api-key'];
    if (typeof key !== 'string' || key.length < 16 || key.length > 200) return send(res, 403, { error: 'forbidden' });
    const h = hashKey(key);
    if (!perIp.allow(ip) || !perKey.allow(h)) return send(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });
    const [, name, id] = m;

    if (req.method === 'GET') {
      let fn = name; if (name === 'vacancies' && id) fn = 'vacancy'; if (name === 'documents' && id) fn = 'document';
      if (!reads[fn] || (id && fn === name)) return send(res, 404, { error: 'not_found' });
      const data = await reads[fn](h, u.searchParams, id);
      if (data === null && id) return send(res, 404, { error: 'not_found' });
      const body = JSON.stringify(data); const etag = '"' + createHash('sha256').update(body).digest('hex').slice(0, 32) + '"';
      const cache = { 'cache-control': 'public, max-age=60, stale-while-revalidate=300', etag };
      if (req.headers['if-none-match'] === etag) { res.writeHead(304, cache); return res.end(); }
      return send(res, 200, data, cache);
    }

    if (req.method === 'POST' && (name === 'enquiries' || name === 'applications') && !id) {
      if (!writeIp.allow(ip)) return send(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });
      const b = await readJson(req);
      if (name === 'enquiries') {
        const budget = typeof b.budget === 'number' && isFinite(b.budget) && b.budget >= 0 ? b.budget : null;
        const r = await sql`select public_api.submit_enquiry(${h}, ${clip(b.name, 200)}, ${clip(b.email, 254)}, ${clip(b.phone, 40)}, ${clip(b.organization, 200)}, ${clip(b.service, 200)}, ${clip(b.message, 5000)}, ${clip(b.page, 500)}, ${clip(b.referrer, 500)}, ${sql.json(cleanUtm(b.utm))}, ${budget}, ${clip(b.currency, 3)}) as r`;
        return send(res, 201, r[0].r, { 'cache-control': 'no-store' });
      }
      const r = await sql`select public_api.submit_application(${h}, ${clip(b.vacancy, 40)}, ${clip(b.name, 200)}, ${clip(b.email, 254)}, ${clip(b.phone, 40)}, ${clip(b.cover, 8000)}, ${clip(b.page, 500)}, ${clip(b.referrer, 500)}, ${sql.json(cleanUtm(b.utm))}) as r`;
      const out: Record<string, unknown> = { ...r[0].r };
      const reference = String(out.reference ?? '');
      // The applicant's own answers (education, links, motivation ...) - optional, validated by the database.
      if (b.profile && typeof b.profile === 'object' && !Array.isArray(b.profile)) {
        await sql`select public_api.submit_application_profile(${h}, ${reference}, ${sql.json(b.profile)}) as r`;
      }
      // A one-time pass for the visitor's browser to send the CV straight to ADA Core (files never pass through a website server).
      if (b.files === true) {
        const u = await sql`select public_api.open_application_upload(${h}, ${reference}) as r`;
        out.upload = { pass: u[0].r.upload_pass, expires_in_seconds: u[0].r.expires_in_seconds, url: UPLOAD_URL };
      }
      return send(res, 201, out, { 'cache-control': 'no-store' });
    }
    return send(res, 405, { error: 'method_not_allowed' });
  } catch (e: any) {
    if (e?.status) return send(res, e.status, { error: e.message });
    const status = statusFor(e?.code);
    if (status === 500) console.error('public api error', e?.code, e?.message);
    // never echo database messages to a website
    send(res, status, { error: status === 403 ? 'forbidden' : status === 500 ? 'server_error' : 'rejected' });
  }
}
