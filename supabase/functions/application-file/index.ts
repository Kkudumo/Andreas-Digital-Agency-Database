// application-file: receives a job applicant's CV or supporting document straight from their browser.
//
// The browser sends multipart/form-data with: pass (the one-time upload pass the website received from the public API),
// kind ("cv" or "supporting") and file (PDF or Word, at most 10 MB). The function never decides on its own: the database
// checks the pass and names the storage path (application_upload_begin), the file is stored in the PRIVATE bucket
// `applications`, and the database records it (application_upload_done). Runs with the project's service role, which
// Supabase injects; no key is stored in this code.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const ALLOWED_ORIGINS = new Set([
  'https://www.andreasdigitalagency.com',
  'https://andreasdigitalagency.com',
  'https://web.andreasdigitalagency.com',
]);
const TYPES: Record<string, string> = {
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};
const MAX = 10 * 1024 * 1024;

function cors(origin: string | null): Record<string, string> {
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://www.andreasdigitalagency.com';
  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}

function reply(status: number, body: unknown, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...cors(origin) },
  });
}

// What a database refusal means to the applicant. Database messages are never echoed.
function refusal(code: string | undefined) {
  if (code === '42501') return { status: 403, error: 'This upload link has expired. Please send your application again.' };
  if (code === '23505') return { status: 409, error: 'This file was already received.' };
  if (code === '22023') return { status: 400, error: 'Please send a PDF or Word file of 10 MB or less.' };
  return { status: 500, error: 'The file could not be saved. Please try again.' };
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== 'POST') return reply(405, { error: 'Method not allowed' }, origin);
  if (origin && !ALLOWED_ORIGINS.has(origin)) return reply(403, { error: 'Not allowed from this site' }, origin);
  if (Number(req.headers.get('content-length') ?? 0) > MAX + 64 * 1024) return reply(413, { error: 'Please send a file of 10 MB or less.' }, origin);

  let form: FormData;
  try { form = await req.formData(); } catch { return reply(400, { error: 'Please choose a file.' }, origin); }
  const pass = String(form.get('pass') ?? '');
  const kind = String(form.get('kind') ?? '');
  const file = form.get('file');
  if (!(file instanceof File) || !pass || !['cv', 'supporting'].includes(kind)) return reply(400, { error: 'Please choose a file.' }, origin);

  const ext = (file.name.split('.').pop() ?? '').toLowerCase();
  const type = TYPES[ext];
  if (!type || file.size < 1 || file.size > MAX) return reply(400, { error: 'Please send a PDF or Word file of 10 MB or less.' }, origin);
  // The content must look like what its name says (PDF starts with %PDF, .doc is an OLE file, .docx is a ZIP).
  const head = new Uint8Array(await file.slice(0, 8).arrayBuffer());
  const magic = ext === 'pdf' ? [0x25, 0x50, 0x44, 0x46] : ext === 'doc' ? [0xd0, 0xcf, 0x11, 0xe0] : [0x50, 0x4b, 0x03, 0x04];
  if (!magic.every((b, i) => head[i] === b)) return reply(400, { error: 'Please send a PDF or Word file of 10 MB or less.' }, origin);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const meta = { p_pass: pass, p_kind: kind, p_file_name: file.name.slice(0, 200), p_content_type: type, p_size: file.size };

  const begin = await db.rpc('application_upload_begin', meta);
  if (begin.error) { const r = refusal(begin.error.code); return reply(r.status, { error: r.error }, origin); }
  const path = String((begin.data as { path?: string })?.path ?? '');

  const put = await db.storage.from('applications').upload(path, file, { contentType: type, upsert: false });
  if (put.error) return reply(500, { error: 'The file could not be saved. Please try again.' }, origin);

  const done = await db.rpc('application_upload_done', { p_pass: pass, p_kind: kind, p_path: path, p_file_name: meta.p_file_name, p_content_type: type, p_size: file.size });
  if (done.error) {
    await db.storage.from('applications').remove([path]);
    const r = refusal(done.error.code); return reply(r.status, { error: r.error }, origin);
  }
  return reply(201, { received: kind }, origin);
});
