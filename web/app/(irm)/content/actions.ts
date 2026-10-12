'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { call } from '@/lib/db';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';
import { rebuildWebsites } from '@/lib/rebuild';
import { createClient } from '@/lib/supabase/server';

// News, testimonials and FAQs. Writes are row-level-security protected inserts/updates plus content_transition(); the database decides who may do what.
const TABLE = { post: 'content_posts', testimonial: 'testimonials', faq: 'faqs' } as const;
type Kind = keyof typeof TABLE;
const kindOf = (v: FormDataEntryValue | null): Kind => (String(v) in TABLE ? (String(v) as Kind) : 'post');
const where = (fd: FormData) => { const p = String(fd.get('return') ?? '/content'); return p.startsWith('/') && !p.startsWith('//') ? p : '/content'; };
const told = (r: 'sent' | 'none' | 'partial') => r === 'sent' ? ' The websites were told to refresh.' : r === 'partial' ? ' Some websites could not be told to refresh.' : '';

function fields(kind: Kind, fd: FormData): Record<string, unknown> {
  const division = str(fd.get('division'));
  if (kind === 'post') return {
    division_id: division, content_type: str(fd.get('content_type')) ?? 'news', title: str(fd.get('title')), slug: str(fd.get('slug')) ?? '', summary: str(fd.get('summary')), body: str(fd.get('body')) ?? '',
    cover_image_url: str(fd.get('cover_image_url')), image_alt_text: str(fd.get('image_alt_text')), author_name: str(fd.get('author_name')), source_label: str(fd.get('source_label')), featured: fd.get('featured') === 'on',
  };
  if (kind === 'testimonial') return {
    division_id: division, quote: str(fd.get('quote')), person_name: str(fd.get('person_name')), person_role: str(fd.get('person_role')), organization_name: str(fd.get('organization_name')),
    service_id: str(fd.get('service')), consent_confirmed: fd.get('consent_confirmed') === 'on', consent_note: str(fd.get('consent_note')), sort_order: Number(str(fd.get('sort_order')) ?? 100),
  };
  return { division_id: division, question: str(fd.get('question')), answer: str(fd.get('answer')), category: str(fd.get('category')), service_id: str(fd.get('service')), sort_order: Number(str(fd.get('sort_order')) ?? 100) };
}

export async function createContentAction(fd: FormData) {
  const kind = kindOf(fd.get('kind'));
  const supabase = await createClient();
  const { data, error } = await supabase.from(TABLE[kind]).insert(fields(kind, fd)).select('id').single();
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/content/${kind}/${data!.id}?ok=${encodeURIComponent('Saved as a draft. Publish it when it is ready.')}`);
}

export async function saveContentAction(fd: FormData) {
  const kind = kindOf(fd.get('kind')); const id = str(fd.get('id'));
  const supabase = await createClient();
  const { data: before } = await supabase.from(TABLE[kind]).select('status').eq('id', id).maybeSingle();
  const { error } = await supabase.from(TABLE[kind]).update(fields(kind, fd)).eq('id', id);
  if (error) back(where(fd), 'error', friendly(error));
  let msg = 'Saved.';
  if (before?.status === 'published' && fd.get('keep_published') === 'on') {
    const reached = await publishChain(kind, id!);
    msg += reached === 'published' ? ' It stays published with the new wording.' + told(await rebuildWebsites()) : ' The wording changed, so it went back to draft and needs approval before it is live again.';
  }
  revalidatePath(where(fd));
  back(where(fd), 'ok', msg);
}

async function publishChain(kind: Kind, id: string): Promise<string> {
  const supabase = await createClient();
  for (let i = 0; i < 4; i++) {
    const { data: s } = await supabase.from(TABLE[kind]).select('status').eq('id', id).maybeSingle();
    const status = s?.status as string | undefined;
    if (!status || status === 'published') return status ?? 'unknown';
    const to = status === 'draft' || status === 'unpublished' ? 'pending_approval' : status === 'pending_approval' ? 'approved' : status === 'approved' ? 'published' : null;
    if (!to) return status;
    const r = await call('content_transition', { p_kind: kind, p_id: id, p_to: to, p_reason: null });
    if (r.error) return status;
  }
  return 'unknown';
}

export async function publishContentAction(fd: FormData) {
  const kind = kindOf(fd.get('kind'));
  const reached = await publishChain(kind, String(fd.get('id')));
  revalidatePath(where(fd));
  if (reached !== 'published') back(where(fd), 'error', `Could not publish: it is ${reached.replace(/_/g, ' ')}.${kind === 'testimonial' ? ' A testimonial needs the person\'s consent recorded first.' : ' Someone with content.publish must approve it.'}`);
  back(where(fd), 'ok', 'Published.' + told(await rebuildWebsites()));
}

export async function contentTransitionAction(fd: FormData) {
  const kind = kindOf(fd.get('kind')); const to = str(fd.get('to'));
  const r = await call('content_transition', { p_kind: kind, p_id: str(fd.get('id')), p_to: to, p_reason: str(fd.get('note')) });
  if (r.error) back(where(fd), 'error', friendly(r.error));
  revalidatePath(where(fd));
  back(where(fd), 'ok', `Now ${to?.replace(/_/g, ' ')}.` + (to === 'unpublished' || to === 'archived' ? told(await rebuildWebsites()) : ''));
}

// --- site settings -------------------------------------------------------------------------------------------------------------------------
export async function saveSettingAction(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from('site_settings').update({ value: str(fd.get('value')) ?? '', is_public: fd.get('is_public') === 'on' }).eq('id', str(fd.get('id')));
  if (error) back('/site-settings', 'error', friendly(error));
  revalidatePath('/site-settings');
  back('/site-settings', 'ok', 'Setting saved.' + told(await rebuildWebsites()));
}

export async function addSettingAction(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from('site_settings').insert({
    division_id: str(fd.get('division')), key: str(fd.get('key')), label: str(fd.get('label')), value: str(fd.get('value')) ?? '', value_type: str(fd.get('value_type')) ?? 'text',
    group_name: str(fd.get('group_name')) ?? 'general', is_public: fd.get('is_public') === 'on',
  });
  if (error) back('/site-settings', 'error', friendly(error));
  revalidatePath('/site-settings');
  back('/site-settings', 'ok', 'Setting added.');
}
