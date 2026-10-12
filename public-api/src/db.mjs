// The ONLY place that talks to PostgreSQL. It connects as the ada_public_api role (no table access; it can execute the public_api.* functions and nothing else).
// ADA_PUBLIC_API_DATABASE_URL is set by the owner in the host's environment; it is never in the repository and never logged.
import pg from 'pg';

let pool;
export function getPool() {
  if (!pool) {
    const url = process.env.ADA_PUBLIC_API_DATABASE_URL;
    if (!url) throw new Error('ADA_PUBLIC_API_DATABASE_URL is not set');
    pool = new pg.Pool({ connectionString: url, max: 5, idleTimeoutMillis: 10000, connectionTimeoutMillis: 5000, statement_timeout: 8000, ssl: process.env.ADA_PUBLIC_API_SSL === 'off' ? false : { rejectUnauthorized: true } });
    pool.on('error', () => {});
  }
  return pool;
}

// Function names come from the fixed ROUTES table (never from the request), and arguments are always bound parameters.
const FUNCTIONS = new Set(['divisions', 'vacancies', 'vacancy', 'services', 'portfolio', 'team', 'statistics', 'documents', 'document', 'submit_enquiry', 'submit_application']);
export async function call(fn, args) {
  if (!FUNCTIONS.has(fn)) throw new Error('unknown function');
  const params = args.map((_, i) => `$${i + 1}`).join(', ');
  const { rows } = await getPool().query(`select public_api.${fn}(${params}) as result`, args.map((a) => (a !== null && typeof a === 'object' ? JSON.stringify(a) : a)));
  return rows[0].result;
}
