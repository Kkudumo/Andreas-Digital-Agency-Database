'use server';
import { createClient } from '@/lib/supabase/server';
import { call } from '@/lib/db';
import { friendly } from '@/lib/flash';

// Controlled operations only, run as the signed-in user: the Documents module decides who may register, add a version, open or download.
type Fail = { ok: false; error: string };

export async function createDocument(input: { title: string; type: string; division: string; link?: string | null }): Promise<{ ok: true; id: string } | Fail> {
  const title = input.title.trim();
  if (title.length < 2) return { ok: false, error: 'Give the document a title.' };
  const { data, error } = await call<{ id: string }>('document_register', { p_title: title, p_type: input.type, p_division: input.division });
  if (error || !data?.id) return { ok: false, error: friendly(error) };
  if (input.link?.trim()) {
    const l = await call('document_link_add', { p_doc: data.id, p_entity: input.link.trim() });
    if (l.error) return { ok: false, error: `The document was created, but it could not be linked: ${friendly(l.error)}` };
  }
  return { ok: true, id: data.id };
}

export async function addVersion(input: { doc: string; key: string; hash: string; size: number; mime: string; filename: string; label?: string }): Promise<{ ok: true; version: number } | Fail> {
  const { data, error } = await call<{ version_no: number }>('document_add_version', { p_doc: input.doc, p_provider: 'supabase', p_key: input.key, p_hash: input.hash, p_size: input.size, p_mime: input.mime, p_filename: input.filename, p_label: input.label ?? null });
  if (error || !data) {
    if (error?.code === '23514' && /identical/i.test(error.message ?? '')) return { ok: false, error: 'Nothing has changed since the last version, so no new version was saved.' };
    return { ok: false, error: friendly(error) };
  }
  return { ok: true, version: data.version_no };
}

/** Opens (and logs) a document for reading or download, then hands back a short-lived link to the stored file. A document the caller may not open looks like one that does not exist. */
export async function openDocument(doc: string, mode: 'read' | 'download', version?: number): Promise<{ ok: true; url: string; filename: string; mime: string; version: number; state: string } | Fail> {
  const { data, error } = await call<any>('document_open', { p_doc: doc, p_mode: mode, p_version: version ?? null });
  if (error) return { ok: false, error: error.code === '55000' ? (error.message ?? 'This version is not available.') : friendly(error) };
  if (!data?.storage_key) return { ok: false, error: 'This document is not available to you.' };
  const supabase = await createClient();
  const { data: signed, error: e2 } = await supabase.storage.from('documents').createSignedUrl(data.storage_key, 120, mode === 'download' ? { download: data.filename ?? true } : undefined);
  if (e2 || !signed?.signedUrl) return { ok: false, error: 'The file could not be retrieved.' };
  return { ok: true, url: signed.signedUrl, filename: data.filename ?? 'document', mime: data.mime_type, version: data.version_no, state: data.state };
}
