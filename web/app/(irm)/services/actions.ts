'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { call } from '@/lib/db';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';
import { rebuildWebsites } from '@/lib/rebuild';
import { createClient } from '@/lib/supabase/server';

// The catalogue is edited here and nowhere else. Every operation is a controlled database operation run as the signed-in person: the database decides
// who may edit, propose, approve and publish, and what the price history looks like. These actions only pass the person's input through.

const where = (fd: FormData) => { const p = String(fd.get('return') ?? '/services'); return p.startsWith('/') && !p.startsWith('//') ? p : '/services'; };
const num = (v: FormDataEntryValue | null) => { const s = str(v); return s === null ? null : Number(s); };
const told = (r: 'sent' | 'none' | 'partial') => r === 'sent' ? ' The websites were told to refresh.' : r === 'partial' ? ' Some websites could not be told to refresh; check their deploy hooks.' : ' (No website rebuild hooks are configured, so static websites update on their next rebuild.)';

export async function createServiceAction(fd: FormData) {
  const supabase = await createClient();
  const model = str(fd.get('pricing_model')) ?? 'fixed';
  const { data, error } = await supabase.from('services').insert({
    division_id: str(fd.get('division')), name: str(fd.get('name')), category: str(fd.get('category')), summary: str(fd.get('summary')), description: str(fd.get('description')) ?? str(fd.get('summary')),
    pricing_model: model, billing_unit: str(fd.get('billing_unit')) ?? 'project', show_price: model !== 'quote_based',
  }).select('id').single();
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/services/${data!.id}?ok=${encodeURIComponent('Service created as a draft. Set its price and publish it when it is ready.')}`);
}

/** Moves a service as far toward `published` as this person is allowed to take it. Returns the status reached. */
async function publishAsFarAsAllowed(id: string): Promise<string> {
  const supabase = await createClient();
  for (let i = 0; i < 4; i++) {
    const { data: s } = await supabase.from('services').select('status').eq('id', id).maybeSingle();
    const status = s?.status as string | undefined;
    if (!status || status === 'published') return status ?? 'unknown';
    const to = status === 'draft' || status === 'unpublished' ? 'pending_approval' : status === 'pending_approval' ? 'approved' : status === 'approved' ? 'published' : null;
    if (!to) return status;
    const r = await call('service_transition', { p_id: id, p_to: to, p_reason: null });
    if (r.error) return status;
  }
  return 'unknown';
}

export async function saveServiceAction(fd: FormData) {
  const id = str(fd.get('service'));
  const supabase = await createClient();
  const { data: before } = await supabase.from('services').select('status').eq('id', id).maybeSingle();
  const { error } = await supabase.from('services').update({
    name: str(fd.get('name')), category: str(fd.get('category')), summary: str(fd.get('summary')), description: str(fd.get('description')),
    billing_unit: str(fd.get('billing_unit')) ?? 'project', show_price: fd.get('show_price') === 'on', is_active: fd.get('is_active') === 'on',
  }).eq('id', id);
  if (error) back(where(fd), 'error', friendly(error));
  // Editing public wording of an approved/published service returns it to draft (re-approval). If it was live and this person may publish, put it straight back.
  let msg = 'Service saved.';
  if (before?.status === 'published' && fd.get('keep_published') === 'on') {
    const reached = await publishAsFarAsAllowed(id!);
    msg += reached === 'published' ? ' It stays published with the new wording.' : ' The wording changed, so it went back to draft and needs approval before it is live again.';
    if (reached === 'published') msg += told(await rebuildWebsites());
  }
  revalidatePath(where(fd));
  back(where(fd), 'ok', msg);
}

export async function proposePriceAction(fd: FormData) {
  const id = str(fd.get('service'));
  const p = await call<string>('price_propose', {
    p_service: id, p_amount: num(fd.get('amount')), p_currency: 'NAD', p_effective_from: str(fd.get('effective_from')) ?? new Date().toISOString().slice(0, 10),
    p_reason: str(fd.get('reason')) ?? 'Price updated in ADA Hub', p_starting: fd.get('starting') === 'on',
  });
  if (p.error || !p.data) back(where(fd), 'error', friendly(p.error));
  // A person who may approve prices (the CEO) has their change take effect straight away; anyone else leaves it waiting for approval.
  const d = await call('price_decide', { p_price: p.data, p_approve: true, p_note: 'approved when saved' });
  revalidatePath(where(fd));
  if (d.error) back(where(fd), 'ok', 'Price saved and waiting for approval: ' + friendly(d.error));
  back(where(fd), 'ok', 'Price saved and approved.' + told(await rebuildWebsites()));
}

export async function decidePriceAction(fd: FormData) {
  const approve = fd.get('decision') === 'approve';
  const r = await call('price_decide', { p_price: str(fd.get('price')), p_approve: approve, p_note: str(fd.get('note')) });
  if (r.error) back(where(fd), 'error', friendly(r.error));
  revalidatePath(where(fd));
  back(where(fd), 'ok', approve ? 'Price approved.' + told(await rebuildWebsites()) : 'Price rejected.');
}

export async function serviceTransitionAction(fd: FormData) {
  const to = str(fd.get('to'));
  const r = await call('service_transition', { p_id: str(fd.get('service')), p_to: to, p_reason: str(fd.get('note')) });
  if (r.error) back(where(fd), 'error', friendly(r.error));
  revalidatePath(where(fd));
  back(where(fd), 'ok', `Service is now ${to?.replace(/_/g, ' ')}.` + (to === 'published' || to === 'unpublished' || to === 'archived' ? told(await rebuildWebsites()) : ''));
}

export async function publishServiceAction(fd: FormData) {
  const reached = await publishAsFarAsAllowed(String(fd.get('service')));
  revalidatePath(where(fd));
  if (reached !== 'published') back(where(fd), 'error', `Could not publish: the service is ${reached.replace(/_/g, ' ')}. Someone with services.publish must approve it.`);
  back(where(fd), 'ok', 'Service is published.' + told(await rebuildWebsites()));
}
