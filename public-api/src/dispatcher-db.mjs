// The dispatcher's only database access: two functions, as the ada_dispatcher role (ADA_DISPATCHER_DATABASE_URL, set by the owner in the host's environment).
import pg from 'pg';

let pool;
function getPool() {
  if (!pool) {
    const url = process.env.ADA_DISPATCHER_DATABASE_URL;
    if (!url) throw new Error('ADA_DISPATCHER_DATABASE_URL is not set');
    pool = new pg.Pool({ connectionString: url, max: 2, idleTimeoutMillis: 10000, connectionTimeoutMillis: 5000, statement_timeout: 8000, ssl: process.env.ADA_PUBLIC_API_SSL === 'off' ? false : { rejectUnauthorized: true } });
    pool.on('error', () => {});
  }
  return pool;
}
export const claim = async (maxSubscriptions, debounceSeconds) => (await getPool().query('select * from dispatch_claim($1, $2)', [maxSubscriptions, debounceSeconds])).rows;
export const report = async (ids, ok, error) => (await getPool().query('select dispatch_report($1::bigint[], $2, $3) as n', [ids, ok, error])).rows[0].n;
export const closePool = async () => { if (pool) { await pool.end(); pool = undefined; } };
