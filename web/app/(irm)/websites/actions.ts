'use server';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';
import { CAPABILITIES, type KeyState } from '@/lib/websites';

// Websites are written under the signed-in user's session: row-level security (websites.manage) decides
// who may register or change them. Keys are issued only by the database (issue_website_key), which stores
// a hash and returns the plain key once. The key is handed back to the page in the action's response,
// never put in a URL, a log line or the database.
const ALLOWED = new Set<string>(CAPABILITIES.map((c) => c.key));
const STATUSES = ['planned', 'active', 'suspended', 'retired'];

export async function registerWebsiteAction(fd: FormData) {
  const name = str(fd.get('name'));
  const domain = (str(fd.get('domain')) ?? '').toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  if (!name || !domain) back('/websites', 'error', 'A name and a domain are required.');
  const capabilities = fd.getAll('capability').map(String).filter((c) => ALLOWED.has(c));
  const supabase = await createClient();
  const { error } = await supabase.from('websites').insert({
    name, domain, division_id: str(fd.get('division')), status: 'active', environment: 'production', capabilities,
  });
  if (error) back('/websites', 'error', friendly(error));
  revalidatePath('/websites');
  back('/websites', 'ok', `${name} is registered. Create its access key below.`);
}

export async function updateWebsiteAction(fd: FormData) {
  const id = str(fd.get('id'));
  const status = str(fd.get('status')) ?? 'active';
  if (!STATUSES.includes(status)) back('/websites', 'error', 'Choose a valid status.');
  const capabilities = fd.getAll('capability').map(String).filter((c) => ALLOWED.has(c));
  const supabase = await createClient();
  const { error } = await supabase.from('websites').update({ status, capabilities }).eq('id', id);
  if (error) back('/websites', 'error', friendly(error));
  revalidatePath('/websites');
  back('/websites', 'ok', 'Website updated.');
}

export async function issueKeyAction(_prev: KeyState, fd: FormData): Promise<KeyState> {
  const id = str(fd.get('id'));
  const site = str(fd.get('site')) ?? 'this website';
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('issue_website_key', { p_website_id: id });
  if (error || typeof data !== 'string') return { error: friendly(error ?? { message: 'No key was returned.' }) };
  revalidatePath('/websites');
  return { key: data, site };
}
