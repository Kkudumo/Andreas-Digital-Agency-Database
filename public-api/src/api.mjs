// The public API's logic, with no network and no database in it (both are injected), so every rule here is testable on its own.
//
// What this layer does, and only this:
//   * identify the caller by hashing the API key (SHA-256 hex) - the database never sees the key, only the hash;
//   * map an HTTP route to ONE public_api.* function and pass the typed arguments in;
//   * size-limit and validate request bodies; rate-limit per key and per address;
//   * map database errors to HTTP statuses without leaking their text; add Cache-Control and ETag.
// It decides nothing about WHAT may be returned: the database function authorizes the website, checks its capability and builds the DTO.
import { createHash } from 'node:crypto';

export const MAX_BODY_BYTES = 16 * 1024;
const text = (max) => (v) => (typeof v === 'string' && v.trim() !== '' && v.length <= max ? v.trim() : v === undefined || v === null || v === '' ? null : undefined);
const required = (f) => (v) => { const r = f(v); return r === null ? undefined : r; };
const utm = (v) => {
  if (v === undefined || v === null) return {};
  if (typeof v !== 'object' || Array.isArray(v)) return undefined;
  const out = {};
  for (const k of ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content']) {
    if (v[k] === undefined || v[k] === null) continue;
    if (typeof v[k] !== 'string' || v[k].length > 200) return undefined;
    out[k] = v[k];
  }
  return out;
};
const money = (v) => (v === undefined || v === null ? null : typeof v === 'number' && Number.isFinite(v) && v >= 0 && v < 1e12 ? v : undefined);
const currency = (v) => (v === undefined || v === null ? 'NAD' : typeof v === 'string' && /^[A-Za-z]{3}$/.test(v) ? v.toUpperCase() : undefined);
const code = (v) => (v === undefined || v === null || v === '' ? null : typeof v === 'string' && /^[a-z0-9-]{1,40}$/.test(v) ? v : undefined);
const limit = (v) => (v === null || v === undefined || v === '' ? 30 : /^[0-9]{1,3}$/.test(v) && Number(v) >= 1 && Number(v) <= 100 ? Number(v) : undefined);
const id = (v) => (typeof v === 'string' && /^[A-Za-z0-9._-]{1,60}$/.test(v) ? v : undefined);

// Each GET: the function, and how the query string / path becomes its (typed) arguments after the key hash.
// Each POST: the function and the body fields in argument order, with a validator for each (undefined = invalid).
export const ROUTES = [
  { method: 'GET', path: /^\/divisions$/, fn: 'divisions', args: () => [], cache: 300 },
  { method: 'GET', path: /^\/vacancies$/, fn: 'vacancies', args: (m, q) => [code(q.get('division'))], bad: (a) => a[0] === undefined, cache: 60 },
  { method: 'GET', path: /^\/vacancies\/([^/]+)$/, fn: 'vacancy', args: (m) => [id(decodeURIComponent(m[1]))], bad: (a) => a[0] === undefined, cache: 60, nullIs404: true },
  { method: 'GET', path: /^\/services$/, fn: 'services', args: (m, q) => [code(q.get('division'))], bad: (a) => a[0] === undefined, cache: 300 },
  { method: 'GET', path: /^\/portfolio$/, fn: 'portfolio', args: (m, q) => [code(q.get('division'))], bad: (a) => a[0] === undefined, cache: 300 },
  { method: 'GET', path: /^\/posts$/, fn: 'posts', args: (m, q) => [code(q.get('type')), code(q.get('division')), limit(q.get('limit'))], bad: (a) => a.includes(undefined), cache: 60 },
  { method: 'GET', path: /^\/posts\/([^/]+)$/, fn: 'post', args: (m) => [code(decodeURIComponent(m[1]))], bad: (a) => a[0] === undefined || a[0] === null, cache: 60, nullIs404: true },
  { method: 'GET', path: /^\/testimonials$/, fn: 'testimonials', args: (m, q) => [code(q.get('division'))], bad: (a) => a[0] === undefined, cache: 300 },
  { method: 'GET', path: /^\/faqs$/, fn: 'faqs', args: (m, q) => [code(q.get('division'))], bad: (a) => a[0] === undefined, cache: 300 },
  { method: 'GET', path: /^\/settings$/, fn: 'settings', args: (m, q) => [code(q.get('division'))], bad: (a) => a[0] === undefined, cache: 300 },
  { method: 'GET', path: /^\/team$/, fn: 'team', args: () => [], cache: 300 },
  { method: 'GET', path: /^\/statistics$/, fn: 'statistics', args: () => [], cache: 300 },
  { method: 'GET', path: /^\/documents$/, fn: 'documents', args: (m, q) => [code(q.get('type'))], bad: (a) => a[0] === undefined, cache: 300 },
  { method: 'GET', path: /^\/documents\/([^/]+)$/, fn: 'document', args: (m) => [id(decodeURIComponent(m[1]))], bad: (a) => a[0] === undefined, cache: 300, nullIs404: true },
  {
    method: 'POST', path: /^\/enquiries$/, fn: 'submit_enquiry',
    body: [['name', required(text(200))], ['email', text(320)], ['phone', text(60)], ['organization', text(200)], ['service', text(200)], ['message', text(4000)],
           ['page', text(500)], ['referrer', text(500)], ['utm', utm], ['budget', money], ['currency', currency]],
  },
  {
    method: 'POST', path: /^\/applications$/, fn: 'submit_application',
    body: [['vacancy', required(id)], ['name', required(text(200))], ['email', required(text(320))], ['phone', text(60)], ['cover', text(8000)],
           ['page', text(500)], ['referrer', text(500)], ['utm', utm]],
  },
];

export const keyHash = (key) => createHash('sha256').update(key, 'utf8').digest('hex');

/** SQLSTATE -> HTTP status. Anything else is a 500 with no detail. */
export function statusFor(sqlstate) {
  switch (sqlstate) {
    case '42501': return [403, 'forbidden'];
    case 'P0002': return [404, 'not found'];
    case '22023': case '23514': return [422, 'invalid request'];
    case '23505': return [409, 'already submitted'];
    default: return [500, 'internal error'];
  }
}

const json = (status, body, headers = {}) => ({ status, headers: { 'content-type': 'application/json; charset=utf-8', 'x-content-type-options': 'nosniff', ...headers }, body: JSON.stringify(body) });

/** A fixed-window counter per (bucket, key). Good enough per instance; the platform's firewall is the real limit across instances. */
export function createLimiter({ perMinute, now = () => Date.now() } = {}) {
  const windows = new Map();
  return {
    allow(bucket) {
      const t = Math.floor(now() / 60000);
      const w = windows.get(bucket);
      if (!w || w.t !== t) { windows.set(bucket, { t, n: 1 }); if (windows.size > 50000) for (const [k, v] of windows) if (v.t !== t) windows.delete(k); return true; }
      w.n += 1; return w.n <= perMinute;
    },
  };
}

/**
 * handle({ method, url, headers, body, ip }, { call, limiter }) -> { status, headers, body }
 * call(fn, args) runs public_api.<fn>(...args) and resolves to its JSON value; it rejects with an error carrying .code (SQLSTATE).
 */
export async function handle(req, { call, limiter, ipLimiter, log = () => {} }) {
  const u = new URL(req.url, 'http://api.local');
  const path = u.pathname.replace(/^\/api\/public(?=\/)/, '').replace(/\/+$/, '') || '/';
  const route = ROUTES.map((r) => ({ r, m: r.path.exec(path) })).find((x) => x.m && x.r.method === req.method);
  if (!route) {
    const other = ROUTES.some((r) => r.path.test(path));
    return other ? json(405, { error: 'method not allowed' }, { allow: ROUTES.filter((r) => r.path.test(path)).map((r) => r.method).join(', ') }) : json(404, { error: 'not found' });
  }
  if (ipLimiter && !ipLimiter.allow(`ip:${req.ip ?? 'unknown'}`)) return json(429, { error: 'too many requests' }, { 'retry-after': '60' });

  const auth = req.headers['authorization'] ?? '';
  const key = (/^Bearer\s+(\S{8,200})$/i.exec(auth)?.[1]) ?? (typeof req.headers['x-api-key'] === 'string' && req.headers['x-api-key'].length >= 8 && req.headers['x-api-key'].length <= 200 ? req.headers['x-api-key'] : null);
  if (!key) return json(401, { error: 'an API key is required (Authorization: Bearer <key>)' }, { 'www-authenticate': 'Bearer' });
  const hash = keyHash(key);
  if (limiter && !limiter.allow(`key:${hash}`)) return json(429, { error: 'too many requests' }, { 'retry-after': '60' });

  let args;
  if (route.r.method === 'GET') {
    args = route.r.args(route.m, u.searchParams);
    if (route.r.bad?.(args)) return json(422, { error: 'invalid request' });
  } else {
    const ct = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    if (ct !== 'application/json') return json(415, { error: 'send application/json' });
    const raw = req.body ?? '';
    if (Buffer.byteLength(raw, 'utf8') > MAX_BODY_BYTES) return json(413, { error: 'request too large' });
    let b;
    try { b = JSON.parse(raw); } catch { return json(422, { error: 'invalid JSON' }); }
    if (!b || typeof b !== 'object' || Array.isArray(b)) return json(422, { error: 'invalid request' });
    const known = new Set(route.r.body.map(([k]) => k));
    if (Object.keys(b).some((k) => !known.has(k))) return json(422, { error: 'unknown field' });
    args = [];
    for (const [k, f] of route.r.body) {
      const v = f(b[k]);
      if (v === undefined) return json(422, { error: `invalid field: ${k}` });
      args.push(v);
    }
  }

  let data;
  try { data = await call(route.r.fn, [hash, ...args]); }
  catch (e) {
    const [status, msg] = statusFor(e?.code);
    if (status === 500) log('database error', e?.code ?? 'unknown');
    return json(status, { error: msg });
  }
  if (data === null && route.r.nullIs404) return json(404, { error: 'not found' });

  if (route.r.method === 'POST') return json(201, data, { 'cache-control': 'no-store' });
  const body = JSON.stringify(data);
  const etag = `"${createHash('sha256').update(body).digest('base64url').slice(0, 27)}"`;
  const headers = { 'cache-control': `public, max-age=${route.r.cache}, stale-while-revalidate=${route.r.cache * 5}`, etag, vary: 'Authorization, X-API-Key' };
  if (req.headers['if-none-match'] === etag) return { status: 304, headers, body: '' };
  return { status: 200, headers: { 'content-type': 'application/json; charset=utf-8', 'x-content-type-options': 'nosniff', ...headers }, body };
}
