// Client-side helpers for the document files: hashing, upload to the private bucket, recording a version.
import { createBrowserSupabase } from '@/lib/supabase/browser';
import { addVersion } from '@/app/(irm)/documents/actions';

export const MIME = {
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  pdf: 'application/pdf',
} as const;
export type Kind = keyof typeof MIME;
export const kindOfName = (name: string): Kind | null => { const e = name.toLowerCase().split('.').pop(); return e === 'docx' || e === 'xlsx' || e === 'pdf' ? e : null; };

export async function sha256(bytes: ArrayBuffer): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Puts the bytes in the private bucket under <document>/<new version id>.<ext>, then records the version through the Documents module. */
export async function saveVersion(doc: string, bytes: ArrayBuffer, kind: Kind, filename: string, label?: string): Promise<{ ok: true; version: number } | { ok: false; error: string }> {
  const hash = await sha256(bytes);
  const key = `${doc}/${crypto.randomUUID()}.${kind}`;
  const supabase = createBrowserSupabase();
  const up = await supabase.storage.from('documents').upload(key, new Blob([bytes], { type: MIME[kind] }), { contentType: MIME[kind], upsert: false });
  if (up.error) return { ok: false, error: /row-level security|not allowed|policy/i.test(up.error.message) ? 'You do not have permission to save to this document.' : 'The file could not be stored. Please try again.' };
  const r = await addVersion({ doc, key, hash, size: bytes.byteLength, mime: MIME[kind], filename, label });
  return r.ok ? { ok: true, version: r.version } : { ok: false, error: r.error };
}
