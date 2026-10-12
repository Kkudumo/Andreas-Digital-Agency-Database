// Stand-in for the Supabase edge: /auth/v1 (password login + user lookup) answered locally, /rest/v1 proxied to PostgREST.
import http from 'node:http';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
const SECRET = 'live-test-secret-live-test-secret-123456';
const DB = 'postgresql://postgres:postgres@localhost:5432/ada_live';
const b64 = (x) => Buffer.from(x).toString('base64url');
const sign = (p) => { const h = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), b = b64(JSON.stringify(p)); return `${h}.${b}.${crypto.createHmac('sha256', SECRET).update(`${h}.${b}`).digest('base64url')}`; };
const userByEmail = (e) => { const r = execFileSync('psql', ['-X', '-At', '-F', '|', DB, '-c', `select id, email from auth.users where email = '${e.replace(/'/g, '')}'`], { encoding: 'utf8' }).trim(); if (!r) return null; const [id, email] = r.split('|'); return { id, email }; };
const userById = (i) => { const r = execFileSync('psql', ['-X', '-At', '-F', '|', DB, '-c', `select id, email from auth.users where id = '${i.replace(/[^0-9a-f-]/g, '')}'`], { encoding: 'utf8' }).trim(); if (!r) return null; const [id, email] = r.split('|'); return { id, email }; };
// The stand-in models a user who has already passed the authenticator step (ADA Hub requires aal2): a verified TOTP factor and an aal2 token.
const userJson = (u) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, app_metadata: {}, user_metadata: {}, factors: [{ id: 'f-' + u.id, factor_type: 'totp', status: 'verified', friendly_name: 'stand-in', created_at: new Date().toISOString(), updated_at: new Date().toISOString() }], created_at: new Date().toISOString() });
const session = (u) => { const exp = Math.floor(Date.now() / 1000) + 3600; return { access_token: sign({ sub: u.id, role: 'authenticated', aud: 'authenticated', aal: 'aal2', amr: [{ method: 'totp', timestamp: Math.floor(Date.now() / 1000) }], exp }), token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'r-' + u.id, user: userJson(u) }; };
const body = (req) => new Promise((ok) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => ok(d)); });

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const json = (code, o) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
  if (url.pathname === '/auth/v1/token') {
    const b = JSON.parse((await body(req)) || '{}');
    if (url.searchParams.get('grant_type') === 'refresh_token') { const u = userById(String(b.refresh_token).slice(2)); return u ? json(200, session(u)) : json(400, { error: 'bad refresh' }); }
    const u = userByEmail(b.email ?? ''); return u ? json(200, session(u)) : json(400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
  }
  if (url.pathname === '/auth/v1/user') {
    const t = (req.headers.authorization ?? '').replace(/^Bearer /, ''); const [h, p, s] = t.split('.');
    if (!s || crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url') !== s) return json(401, { msg: 'invalid token' });
    const u = userById(JSON.parse(Buffer.from(p, 'base64url').toString()).sub); return u ? json(200, userJson(u)) : json(401, { msg: 'no user' });
  }
  if (url.pathname === '/auth/v1/logout') { res.writeHead(204); return res.end(); }
  if (url.pathname.startsWith('/rest/v1/')) {
    const d = await body(req);
    const headers = { ...req.headers, host: 'localhost:3001' }; delete headers['content-length'];
    const pr = http.request({ host: 'localhost', port: 3001, path: url.pathname.replace('/rest/v1', '') + url.search, method: req.method, headers: { ...headers, 'content-length': Buffer.byteLength(d) } }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    pr.on('error', (e) => json(502, { message: String(e) })); pr.end(d); return;
  }
  json(404, { error: 'not found' });
}).listen(54321, () => console.log('gateway on 54321'));
