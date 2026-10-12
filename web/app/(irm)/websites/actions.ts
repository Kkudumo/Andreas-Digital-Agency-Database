'use server';
import { revalidatePath } from 'next/cache';
import { call } from '@/lib/db';
import { friendly, back } from '@/lib/flash';
import { str } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';
import { CAPABILITIES } from '@/lib/website-capabilities';

export type IssueKeyState = { key?: string; error?: string };

export async function issueWebsiteKeyAction(_prev: IssueKeyState, fd: FormData): Promise<IssueKeyState> {
  const { data, error } = await call<string>('issue_website_key', { p_website_id: str(fd.get('website')) });
  if (error || !data) return { error: friendly(error) };
  return { key: data };
}

export async function registerWebsiteAction(fd: FormData) {
  const supabase = await createClient();
  const caps = CAPABILITIES.filter((c) => fd.get(`cap:${c}`) === 'on');
  const { error } = await supabase.from('websites').insert({
    name: str(fd.get('name')), domain: str(fd.get('domain'))?.toLowerCase(), division_id: str(fd.get('division')), environment: 'production', status: 'active', capabilities: caps,
  });
  if (error) back('/websites', 'error', friendly(error));
  revalidatePath('/websites');
  back('/websites', 'ok', 'Website registered. Issue its key below; the key is shown once.');
}

export async function setWebsiteStatusAction(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from('websites').update({ status: str(fd.get('status')) }).eq('id', str(fd.get('website')));
  if (error) back('/websites', 'error', friendly(error));
  revalidatePath('/websites');
  back('/websites', 'ok', 'Website status updated. A suspended website is refused immediately.');
}
