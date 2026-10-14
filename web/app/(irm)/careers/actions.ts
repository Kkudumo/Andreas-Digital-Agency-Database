'use server';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { call } from '@/lib/db';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';

// Careers writes go through the signed-in user's own session. Row-level security and the database's own functions
// (vacancy_transition, application_transition, the review rules) decide what each person may do; this file only
// collects the form fields.
const TYPES = ['full_time', 'part_time', 'contract', 'internship'];

function vacancyFields(fd: FormData) {
  const num = (k: string) => { const v = str(fd.get(k)); return v === null ? null : Number(v); };
  const type = str(fd.get('employment_type')) ?? 'full_time';
  return {
    title: str(fd.get('title')),
    slug: (str(fd.get('slug')) ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || null,
    location: str(fd.get('location')),
    employment_type: TYPES.includes(type) ? type : 'full_time',
    openings: num('openings') ?? 1,
    closing_date: str(fd.get('closing_date')),
    summary: str(fd.get('summary')),
    description: str(fd.get('description')),
    requirements: str(fd.get('requirements')),
    responsibilities: str(fd.get('responsibilities')),
    qualifications: str(fd.get('qualifications')),
    experience: str(fd.get('experience')),
    application_instructions: str(fd.get('application_instructions')),
    featured: fd.get('featured') === 'on',
    salary_min: num('salary_min'),
    salary_max: num('salary_max'),
    salary_public: fd.get('salary_public') === 'on',
  };
}

export async function createVacancyAction(fd: FormData) {
  const position = str(fd.get('position_id'));
  const fields = vacancyFields(fd);
  if (!position || !fields.title) back('/careers', 'error', 'Choose a position and give the vacancy a title.');
  const supabase = await createClient();
  const { data, error } = await supabase.from('vacancies').insert({ position_id: position, ...fields }).select('id').single();
  if (error || !data) back('/careers', 'error', friendly(error));
  revalidatePath('/careers');
  back(`/careers/${data.id}`, 'ok', 'Draft vacancy created. Complete it and submit it for approval.');
}

export async function updateVacancyAction(fd: FormData) {
  const id = str(fd.get('id'));
  const supabase = await createClient();
  const { error } = await supabase.from('vacancies').update(vacancyFields(fd)).eq('id', id);
  if (error) back(`/careers/${id}`, 'error', friendly(error));
  revalidatePath(`/careers/${id}`);
  back(`/careers/${id}`, 'ok', 'Vacancy saved.');
}

export async function vacancyStepAction(fd: FormData) {
  const id = str(fd.get('id'));
  const to = str(fd.get('to'));
  const reason = str(fd.get('reason'));
  const { error } = await call('vacancy_transition', { p_id: id, p_to: to, p_reason: reason });
  if (error) back(`/careers/${id}`, 'error', friendly(error));
  revalidatePath('/careers'); revalidatePath(`/careers/${id}`);
  const words: Record<string, string> = { pending_approval: 'Sent for approval.', approved: 'Approved.', published: 'Published: it is now on the careers page.',
    closed: 'Closed.', draft: 'Back to draft.', cancelled: 'Cancelled.' };
  back(`/careers/${id}`, 'ok', words[to ?? ''] ?? 'Updated.');
}

export async function applicationStepAction(fd: FormData) {
  const id = str(fd.get('id'));
  const to = str(fd.get('to'));
  const reason = str(fd.get('reason'));
  const { error } = await call('application_transition', { p_id: id, p_to: to, p_reason: reason });
  if (error) back(`/careers/applications/${id}`, 'error', friendly(error));
  revalidatePath(`/careers/applications/${id}`);
  back(`/careers/applications/${id}`, 'ok', `Moved to ${String(to).replace(/_/g, ' ')}.`);
}

export async function addReviewAction(fd: FormData) {
  const id = str(fd.get('id'));
  const notes = str(fd.get('notes'));
  const score = str(fd.get('score'));
  if (!notes) back(`/careers/applications/${id}`, 'error', 'Write a note first.');
  const supabase = await createClient();
  const { data: me } = await supabase.rpc('current_staff_id');
  const { data: app } = await supabase.from('applications').select('status').eq('id', id).single();
  const { error } = await supabase.from('application_reviews').insert({
    application_id: id, reviewer_id: me, stage: app?.status ?? 'screening', notes, score: score ? Number(score) : null,
  });
  if (error) back(`/careers/applications/${id}`, 'error', friendly(error));
  revalidatePath(`/careers/applications/${id}`);
  back(`/careers/applications/${id}`, 'ok', 'Note added.');
}
