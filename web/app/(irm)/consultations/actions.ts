'use server';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { call } from '@/lib/db';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';

// Consultation settings, weekly hours and blocked dates are written under the signed-in user's own session:
// row-level security (consultations.configure) decides who may. Removing a row and acting on a booking are controlled
// database functions. Times are Namibia time (Africa/Windhoek, UTC+2, no daylight saving).
const P = '/consultations';
const finish = (error: any, ok: string) => { if (error) back(P, 'error', friendly(error)); revalidatePath(P); back(P, 'ok', ok); };
const num = (v: FormDataEntryValue | null) => { const s = str(v); return s === null ? NaN : Number(s); };

export async function saveSettingsAction(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from('consultation_settings').update({
    enabled: fd.get('enabled') === 'on', slot_minutes: num(fd.get('slot_minutes')),
    min_notice_hours: num(fd.get('min_notice_hours')), max_days_ahead: num(fd.get('max_days_ahead')),
  }).eq('single_row', true);
  finish(error, 'Booking settings saved.');
}

export async function addHoursAction(fd: FormData) {
  const supabase = await createClient();
  const days = fd.getAll('weekday').map(Number).filter((d) => d >= 0 && d <= 6);
  const opens = str(fd.get('opens_at')), closes = str(fd.get('closes_at'));
  if (!days.length || !opens || !closes) back(P, 'error', 'Choose at least one day and the opening and closing times.');
  const { error } = await supabase.from('consultation_hours').insert(days.map((weekday) => ({ weekday, opens_at: opens, closes_at: closes })));
  finish(error, 'Hours added. Free times appear on the website as soon as booking is switched on.');
}

export async function addBlockAction(fd: FormData) {
  const supabase = await createClient();
  const from = str(fd.get('starts_on'));
  const { error } = await supabase.from('consultation_blocks').insert({ starts_on: from, ends_on: str(fd.get('ends_on')) ?? from, reason: str(fd.get('reason')) });
  finish(error, 'Date blocked.');
}

export async function removeAction(fd: FormData) {
  const { error } = await call('consultation_remove', { p_kind: str(fd.get('kind')), p_id: str(fd.get('id')) });
  finish(error, 'Removed.');
}

export async function bookingAction(fd: FormData) {
  const action = str(fd.get('action'));
  const newStart = str(fd.get('new_start'));
  const { error } = await call('consultation_staff_action', {
    p_id: str(fd.get('id')), p_action: action,
    p_new_start: action === 'reschedule' && newStart ? `${newStart}:00+02:00` : null, p_reason: str(fd.get('reason')),
  });
  finish(error, action === 'cancel' ? 'Booking cancelled.' : action === 'reschedule' ? 'Booking moved.' : 'Booking updated.');
}
