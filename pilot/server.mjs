// ADA Hub Pilot V0.1 - development console server.
//
// ONE job: expose the controlled database functions to the browser as POST /rpc/<function> (the same contract PostgREST gives
// the SPA on Supabase) and run every call AS the signed-in staff member, under row-level security: inside a transaction,
// `request.jwt.claim.sub` = the user and `set local role authenticated` - exactly how the test suites act.
// It holds NO business logic, reads or writes NO table directly, and exposes only functions that `authenticated` may execute.
//
// DEV ONLY: the sign-in below is a stand-in for Supabase Auth (any known e-mail, no password, signed cookie). Replace it
// with Supabase Auth in production; nothing here grants a permission the database does not already grant.
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 3100);
const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://postgres:postgres@localhost:5432/ada_pilot';
const SECRET = process.env.PILOT_DEV_SECRET || crypto.randomBytes(32).toString('hex');
const OBJECTS = process.env.PILOT_OBJECT_DIR || path.join(here, 'data', 'objects');
const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 10 });

const sign = (v) => crypto.createHmac('sha256', SECRET).update(v).digest('hex');
const mkCookie = (uid) => { const body = `${uid}.${Date.now() + 8 * 3600e3}`; return `${body}.${sign(body)}`; };
function sessionUser(req) {
  const m = /(?:^|;\s*)ada_pilot=([^;]+)/.exec(req.headers.cookie || '');
  if (!m) return null;
  const [uid, exp, mac] = m[1].split('.');
  if (!mac || sign(`${uid}.${exp}`) !== mac || Number(exp) < Date.now()) return null;
  return uid;
}

// The allow-list: public functions that `authenticated` may execute, with their named arguments (loaded once).
let FUNCS = null;
async function loadFuncs() {
  const { rows } = await pool.query(`
    select p.proname, p.proretset, p.proargnames, p.pronargs, p.pronargdefaults,
           (select array_agg(format_type(t, null) order by o) from unnest(p.proargtypes::oid[]) with ordinality u(t, o)) as argtypes
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute')`);
  FUNCS = new Map();
  for (const r of rows) {
    const names = (r.proargnames || []).slice(0, r.pronargs);
    (FUNCS.get(r.proname) || FUNCS.set(r.proname, []).get(r.proname)).push({ names, types: r.argtypes || [], retset: r.proretset, required: r.pronargs - r.pronargdefaults });
  }
}

async function callAs(uid, fn, args) {
  if (!FUNCS) await loadFuncs();
  const overloads = FUNCS.get(fn);
  if (!overloads) return { status: 404, body: { code: 'PGRST202', message: `no such function: ${fn}` } };
  const keys = Object.keys(args || {});
  const o = overloads.filter((c) => keys.every((k) => c.names.includes(k)) && c.names.slice(0, c.required).every((k) => keys.includes(k)))
    .sort((a, b) => a.names.length - b.names.length)[0];
  if (!o) return { status: 404, body: { code: 'PGRST202', message: `no matching overload of ${fn}` } };
  const used = o.names.filter((n) => keys.includes(n));
  const vals = used.map((n) => { const v = args[n]; const t = o.types[o.names.indexOf(n)]; return v !== null && typeof v === 'object' && !Array.isArray(v) || t === 'jsonb' ? JSON.stringify(v) : v; });
  const sql = `select to_jsonb(r) as r from public.${fn}(${used.map((n, i) => `${n} => $${i + 1}::${o.types[o.names.indexOf(n)]}`).join(', ')}) as r`;
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query(`select set_config('request.jwt.claim.sub', $1, true)`, [uid]);
    await c.query('set local role authenticated');
    let res;
    try { res = await c.query(sql, vals); } catch (e) { await c.query('rollback'); return { status: e.code === '42501' ? 403 : 400, body: { code: e.code, message: e.message } }; }
    await c.query('commit');   // denials that log in-transaction (security notes) are kept by the function itself
    const out = o.retset ? res.rows.map((x) => x.r) : (res.rows[0] ? res.rows[0].r : null);
    return { status: 200, body: out };
  } catch (e) {
    try { await c.query('rollback'); } catch {}
    return { status: 500, body: { code: e.code || 'XX000', message: e.message } };
  } finally { c.release(); }
}

const send = (res, status, body, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers }); res.end(JSON.stringify(body)); };
const readBody = (req, max = 25e6) => new Promise((ok, no) => { const ch = []; let n = 0; req.on('data', (d) => { n += d.length; if (n > max) { no(new Error('too large')); req.destroy(); } else ch.push(d); }); req.on('end', () => ok(Buffer.concat(ch))); req.on('error', no); });
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    if (req.method === 'GET' && url.pathname === '/auth/people') {      // dev sign-in picker: e-mail + name only
      const { rows } = await pool.query(`select s.email, s.full_name, coalesce((select string_agg(r.name, ', ') from staff_roles sr join roles r on r.id = sr.role_id where sr.staff_id = s.id), '') as roles
                                           from staff s join auth.users u on u.id = s.user_id where s.email like '%@pilot.test' order by s.full_name`);
      return send(res, 200, rows);
    }
    if (req.method === 'POST' && url.pathname === '/auth/login') {
      const { email } = JSON.parse((await readBody(req)).toString() || '{}');
      const { rows } = await pool.query('select id::text from auth.users where lower(email) = lower($1)', [String(email || '')]);
      if (!rows[0]) return send(res, 401, { code: 'AUTH', message: 'Unknown account' });
      return send(res, 200, { ok: true }, { 'set-cookie': `ada_pilot=${mkCookie(rows[0].id)}; Path=/; HttpOnly; SameSite=Strict` });
    }
    if (req.method === 'POST' && url.pathname === '/auth/logout') return send(res, 200, { ok: true }, { 'set-cookie': 'ada_pilot=; Path=/; Max-Age=0' });
    if (req.method === 'GET' && url.pathname === '/auth/me') {
      const uid = sessionUser(req); if (!uid) return send(res, 401, { code: 'AUTH', message: 'Not signed in' });
      const r = await callAs(uid, 'my_access', {});
      const who = await pool.query(`select s.full_name, s.email, s.account_status::text as status from staff s where s.user_id = $1`, [uid]);
      return send(res, 200, { user: uid, staff: who.rows[0] || null, access: r.body });
    }
    if (req.method === 'POST' && url.pathname.startsWith('/rpc/')) {
      const uid = sessionUser(req); if (!uid) return send(res, 401, { code: 'AUTH', message: 'Not signed in' });
      const r = await callAs(uid, url.pathname.slice(5), JSON.parse((await readBody(req)).toString() || '{}'));
      return send(res, r.status, r.body);
    }
    // Dev object store: documents are held BY REFERENCE (provider + key + SHA-256); this stands in for the real object store.
    if (req.method === 'PUT' && url.pathname.startsWith('/dev/object/')) {
      if (!sessionUser(req)) return send(res, 401, { code: 'AUTH', message: 'Not signed in' });
      const buf = await readBody(req); const hash = crypto.createHash('sha256').update(buf).digest('hex');
      fs.mkdirSync(OBJECTS, { recursive: true }); fs.writeFileSync(path.join(OBJECTS, hash), buf);
      return send(res, 200, { provider: 'pilot-dev', key: hash, hash, size: buf.length });
    }
    if (req.method === 'GET') {
      const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
      const file = path.join(here, 'public', path.normalize(rel).replace(/^(\.\.[/\\])+/, ''));
      if (file.startsWith(path.join(here, 'public')) && fs.existsSync(file) && fs.statSync(file).isFile()) {
        res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
        return res.end(fs.readFileSync(file));
      }
    }
    send(res, 404, { code: 'NOT_FOUND', message: 'Not found' });
  } catch (e) { send(res, 500, { code: 'XX000', message: String(e.message || e) }); }
});
server.listen(PORT, () => console.log(`ADA Hub pilot console on http://localhost:${PORT}  (DEV sign-in stand-in; database ${DATABASE_URL.replace(/:[^:@/]+@/, ':***@')})`));
