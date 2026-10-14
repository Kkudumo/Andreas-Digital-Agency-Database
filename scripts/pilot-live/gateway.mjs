// Stand-in for the Supabase edge: /auth/v1 (password login + user lookup) answered locally, /rest/v1 proxied to PostgREST.
import http from 'node:http';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
const SECRET = 'live-test-secret-live-test-secret-123456';
const DB = 'postgresql://postgres:postgres@localhost:5432/ada_live';
const b64 = (x) => Buffer.from(x).toString('base64url');
const sign = (p) => { const h = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), b = b64(JSON.stringify(p)); return `${h}.${b}.${crypto.createHmac('sha256', SECRET).update(`${h}.${b}`).digest('base64url')}`; };
const userByEmail = (e) => { const r = execFileSync('psql', ['-X', '-At', '-F', '|', DB, '-c', `select id, email from auth.users where email = '${e.replace(/'/g, '')}'`], { encoding: 'utf8' }).trim(); if (!r) return null; const [id, email] = r.split('|'); return { id, email }; };
const userById = (i) => { const r = execFileSync('psql', ['-X', '-At', '-F', '|', DB, '-c', `select id, email from auth.users where id = '${i.replace(/[^0-9a-f-]/g, '')}'`], { encoding: 'utf8' }).trim(); if (!r) return null; const [id, email] = r.split('|'); return { id, email }; };
// The stand-in models a user who has already passed the authenticator step (ADA Hub requires aal2): a verified TOTP factor and an aal2 token.
const userJson = (u) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, app_metadata: {}, user_metadata: {}, factors: [{ id: 'f-' + u.id, factor_type: 'totp', status: 'verified', friendly_name: 'stand-in', created_at: new Date().toISOString(), updated_at: new Date().toISOString() }], created_at: new Date().toISOString() });
const session = (u) => { const exp = Math.floor(Date.now() / 1000) + 3600; return { access_token: sign({ sub: u.id, role: 'authenticated', aud: 'authenticated', aal: 'aal2', amr: [{ method: 'totp', timestamp: Math.floor(Date.now() / 1000) }], exp }), token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'r-' + u.id, user: userJson(u) }; };
// ---- Storage stand-in: bytes on local disk, but EVERY decision is the database's: the insert / select run as the caller against storage.objects, so the real
// bucket policies (document_storage_can -> document_can) allow or refuse.
const STORE = process.env.PILOT_STORE_DIR || '/tmp/ada-live-storage'; fs.mkdirSync(STORE, { recursive: true });
const bearer = (req) => { const t = (req.headers.authorization ?? '').replace(/^Bearer /, ''); const [h, p, s] = t.split('.'); if (!s || crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url') !== s) return null; try { const c = JSON.parse(Buffer.from(p, 'base64url').toString()); return c.role === 'authenticated' ? c.sub : null; } catch { return null; } };
const asUser = (uid, sql) => execFileSync('psql', ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', DB, '-c', `begin; select set_config('request.jwt.claim.sub', '${uid.replace(/[^0-9a-f-]/g, '')}', true); set local role authenticated; ${sql}; commit;`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const q = (x) => `'${String(x).replace(/'/g, "''")}'`;
const rawBody = (req) => new Promise((ok) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => ok(Buffer.concat(c))); });
const filePart = (buf, ctype) => { const m = /boundary=(.+)$/.exec(ctype ?? ''); if (!m) return buf; const b = Buffer.from('--' + m[1]); let i = 0; while ((i = buf.indexOf(b, i)) >= 0) { const hdrEnd = buf.indexOf('\r\n\r\n', i); if (hdrEnd < 0) break; const head = buf.slice(i, hdrEnd).toString('latin1'); const next = buf.indexOf(b, hdrEnd); if (/filename=|name=""/.test(head) || /Content-Type/i.test(head)) return buf.slice(hdrEnd + 4, next - 2); i = next < 0 ? buf.length : next; } return buf; };
const tok = (name, exp) => crypto.createHmac('sha256', SECRET).update(`${name}.${exp}`).digest('base64url');
const body = (req) => new Promise((ok) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => ok(d)); });

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  // the browser talks to this origin directly for file bytes (as it does to Supabase): answer CORS the way Supabase does
  res.setHeader('access-control-allow-origin', req.headers.origin ?? '*'); res.setHeader('access-control-allow-headers', 'authorization, apikey, content-type, x-client-info, x-upsert, cache-control'); res.setHeader('access-control-allow-methods', 'GET, POST, PUT, DELETE, OPTIONS'); res.setHeader('access-control-allow-credentials', 'true'); res.setHeader('access-control-expose-headers', 'content-disposition');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  const json = (code, o) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
  if (url.pathname === '/auth/v1/token') {
    const b = JSON.parse((await body(req)) || '{}');
    if (url.searchParams.get('grant_type') === 'refresh_token') { const u = userById(String(b.refresh_token).slice(2)); return u ? json(200, session(u)) : json(400, { error: 'bad refresh' }); }
    const u = userByEmail(b.email ?? ''); return u ? json(200, session(u)) : json(400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
  }
  if (process.env.GW_DEBUG) console.log(req.method, url.pathname, req.headers.authorization ? 'auth' : 'noauth');
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
  if (url.pathname.startsWith('/storage/v1/')) {
    const uid = bearer(req); const rest = url.pathname.replace('/storage/v1', '');
    const sg = /^\/object\/sign\/documents\/(.+)$/.exec(rest);
    if (req.method === 'GET' && sg) {                                    // delivery of a signed link: the token IS the authorisation
      const name = decodeURIComponent(sg[1]); const exp = Number(url.searchParams.get('e')); const t = url.searchParams.get('token');
      if (!t || exp < Date.now() / 1000 || tok(name, exp) !== t) return json(403, { statusCode: '403', error: 'Unauthorized', message: 'invalid or expired link' });
      const f = path.join(STORE, Buffer.from(name).toString('hex')); if (!fs.existsSync(f)) return json(404, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      const h = { 'content-type': 'application/octet-stream' }; const dl = url.searchParams.get('download'); if (dl !== null) h['content-disposition'] = `attachment; filename="${dl || 'file'}"`;
      res.writeHead(200, h); return res.end(fs.readFileSync(f));
    }
    if (!uid) return json(401, { statusCode: '401', error: 'Unauthorized', message: 'not signed in' });
    const ob = /^\/object\/documents\/(.+)$/.exec(rest);
    if (req.method === 'POST' && ob) {                                   // upload: the INSERT policy decides
      const name = decodeURIComponent(ob[1]); const data = filePart(await rawBody(req), req.headers['content-type']);
      try { asUser(uid, `insert into storage.objects (bucket_id, name) values ('documents', ${q(name)})`); }
      catch (e) { const m = String(e.stderr ?? e); return json(m.includes('row-level security') ? 403 : m.includes('duplicate key') ? 409 : 400, { statusCode: '403', error: 'Unauthorized', message: m.includes('row-level security') ? 'new row violates row-level security policy' : 'upload failed' }); }
      fs.writeFileSync(path.join(STORE, Buffer.from(name).toString('hex')), data); return json(200, { Key: `documents/${name}`, Id: name });
    }
    const sn = /^\/object\/sign\/documents\/(.+)$/.exec(rest);
    if (req.method === 'POST' && sn) {                                   // sign: the SELECT policy decides (a row the caller cannot see does not exist for them)
      const name = decodeURIComponent(sn[1]);
      const seen = (() => { try { return asUser(uid, `select count(*) from storage.objects where bucket_id = 'documents' and name = ${q(name)}`).trim().split('\n').pop() === '1'; } catch { return false; } })();
      if (!seen) return json(400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      const exp = Math.floor(Date.now() / 1000) + 120; return json(200, { signedURL: `/object/sign/documents/${encodeURIComponent(name).replace(/%2F/g, '/')}?e=${exp}&token=${tok(name, exp)}` });
    }
    return json(404, { error: 'not found' });
  }
  json(404, { error: 'not found' });
}).listen(54321, () => console.log('gateway on 54321'));
