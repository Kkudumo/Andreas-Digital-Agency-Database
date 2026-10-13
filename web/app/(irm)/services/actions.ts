'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { call } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';

// Services are written under the signed-in user's own session. The database's row-level security
// (services.create / services.update), its guard triggers and the controlled functions decide what is
// allowed; nothing here uses a service-role key. Status changes and prices only go through their functions.

const PRICING_MODELS = ['fixed', 'hourly', 'monthly', 'per_unit', 'quote_based'];
const num = (v: FormDataEntryValue | null) => { const s = str(v); return s === null ? null : Number(s); };

const here = (fd: FormData, fallback: string) => {
  const p = String(fd.get('return') ?? fallback);
  return p.startsWith('/services') ? p : fallback;
};

export async function createServiceAction(fd: FormData) {
  const path = here(fd, '/services');
  const model = str(fd.get('pricing_model')) ?? 'fixed';
  const name = str(fd.get('name'));
  if (!name) back(path, 'error', 'A name is required.');
  if (!PRICING_MODELS.includes(model)) back(path, 'error', 'Choose a valid pricing model.');
  const supabase = await createClient();
  const { data, error } = await supabase.from('services').insert({
    division_id: str(fd.get('division')),
    name,
    category: str(fd.get('category')),
    summary: str(fd.get('summary')),
    description: str(fd.get('description')),
    pricing_model: model,
    billing_unit: str(fd.get('billing_unit')) ?? 'project',
    show_price: fd.get('show_price') === 'on',
  }).select('id').single();
  if (error || !data) back(path, 'error', friendly(error));
  revalidatePath('/services', 'layout');
  redirect(`${path}/${data!.id}?ok=${encodeURIComponent('Service added as a draft. Add its price below when you are ready.')}`);
}

export async function updateServiceAction(fd: FormData) {
  const path = here(fd, '/services');
  const model = str(fd.get('pricing_model')) ?? 'fixed';
  const name = str(fd.get('name'));
  if (!name) back(path, 'error', 'A name is required.');
  if (!PRICING_MODELS.includes(model)) back(path, 'error', 'Choose a valid pricing model.');
  const supabase = await createClient();
  const { error } = await supabase.from('services').update({
    name,
    category: str(fd.get('category')),
    summary: str(fd.get('summary')),
    description: str(fd.get('description')),
    pricing_model: model,
    billing_unit: str(fd.get('billing_unit')) ?? 'project',
    show_price: fd.get('show_price') === 'on',
    is_active: fd.get('is_active') === 'on',
  }).eq('id', str(fd.get('id')));
  if (error) back(path, 'error', friendly(error));
  revalidatePath('/services', 'layout');
  back(path, 'ok', 'Service saved. If it was already approved, it goes back to draft and needs approval again.');
}

export async function proposePriceAction(fd: FormData) {
  const path = here(fd, '/services');
  const quote = fd.get('no_price') === 'on';
  const { error } = await call('price_propose', {
    p_service: str(fd.get('id')),
    p_amount: quote ? null : num(fd.get('amount')),
    p_currency: 'NAD',
    p_effective_from: str(fd.get('effective_from')) ?? new Date().toISOString().slice(0, 10),
    p_reason: str(fd.get('reason')),
  });
  if (error) back(path, 'error', friendly(error));
  revalidatePath('/services', 'layout');
  back(path, 'ok', 'Price proposed. It applies once it is approved.');
}

export async function decidePriceAction(fd: FormData) {
  const path = here(fd, '/services');
  const approve = str(fd.get('decision')) === 'approve';
  const { error } = await call('price_decide', { p_price: str(fd.get('price')), p_approve: approve, p_note: str(fd.get('note')) });
  if (error) back(path, 'error', friendly(error));
  revalidatePath('/services', 'layout');
  back(path, 'ok', approve ? 'Price approved. It is now the price for this service.' : 'Price rejected.');
}

export async function withdrawPriceAction(fd: FormData) {
  const path = here(fd, '/services');
  const { error } = await call('price_withdraw', { p_price: str(fd.get('price')) });
  if (error) back(path, 'error', friendly(error));
  revalidatePath('/services', 'layout');
  back(path, 'ok', 'Price proposal withdrawn.');
}

export async function serviceStatusAction(fd: FormData) {
  const path = here(fd, '/services');
  const { error } = await call('service_transition', { p_id: str(fd.get('id')), p_to: str(fd.get('to')), p_reason: str(fd.get('note')) });
  if (error) back(path, 'error', friendly(error));
  revalidatePath('/services', 'layout');
  back(path, 'ok', 'Service status changed.');
}
