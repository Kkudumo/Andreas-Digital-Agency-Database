import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { fmtDateTime, label } from '@/lib/format';
import { addReviewAction, applicationStepAction } from '../../actions';

// One application: who applied, their answers, their CV, the stage it is at, and the review notes.
// Everything here is personal data; the database shows it only to those who may read this application.
const NEXT: Record<string, string[]> = {
  submitted: ['screening', 'rejected', 'withdrawn'],
  screening: ['shortlisted', 'rejected', 'withdrawn'],
  shortlisted: ['interview', 'rejected', 'withdrawn'],
  interview: ['final_review', 'rejected', 'withdrawn'],
  final_review: ['rejected', 'withdrawn'],
  offer: ['withdrawn', 'offer_declined'],
};
const PROFILE: [string, string][] = [
  ['application_type', 'Applying as'], ['location', 'Lives in'], ['nationality', 'Nationality'], ['availability', 'Available'],
  ['highest_qualification', 'Highest qualification'], ['institution', 'Institution'], ['field_of_study', 'Field of study'], ['completion_year', 'Completed'],
  ['current_or_recent_role', 'Current or recent role'], ['years_experience', 'Experience'], ['skills', 'Skills'],
  ['motivation', 'Why ADA'], ['contribution', 'What they would contribute'], ['achievement', 'An achievement'],
];

export default async function ApplicationPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: a } = await supabase.from('applications')
    .select('id, ada_id, status, status_reason, cover_letter, submitted_at, source_page, vacancy_id, people(full_name, email, phone), vacancies(id, title, division_id)')
    .eq('id', id).maybeSingle();
  if (!a) notFound();
  const vac = a.vacancies as any; const person = a.people as any;
  const [{ data: profile }, { data: files }, { data: reviews }] = await Promise.all([
    supabase.from('application_profiles').select('*').eq('application_id', id).maybeSingle(),
    supabase.from('application_files').select('id, kind, file_name, size_bytes, uploaded_at').eq('application_id', id).order('kind'),
    supabase.from('application_reviews').select('id, stage, score, notes, created_at, staff:reviewer_id(full_name)').eq('application_id', id).order('created_at', { ascending: false }),
  ]);
  const mayReview = can(access, 'applications.review', vac?.division_id);
  const next = (NEXT[a.status] ?? []).filter((s) => mayReview || s === 'rejected');
  const link = (u?: string | null) => (u && /^https?:\/\//.test(u) ? <a href={u} target="_blank" rel="noopener noreferrer">{u}</a> : null);

  return (
    <>
      <PageHead title={person?.full_name ?? 'Applicant'} sub={`Applied for ${vac?.title ?? 'a vacancy'} · ${fmtDateTime(a.submitted_at)}`} eyebrow={`Careers · ${a.ada_id}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        <p><Badge v={a.status} /> {a.status_reason && <span className="muted small"> {a.status_reason}</span>} · <Link href={`/careers/${a.vacancy_id}`}>{vac?.title}</Link></p>
        <p>{person?.email && <a href={`mailto:${person.email}`}>{person.email}</a>}{person?.phone && <> · {person.phone}</>}</p>
        {next.length > 0 && (
          <div className="stack">{next.map((to) => (
            <form key={to} action={applicationStepAction} className="inline">
              <input type="hidden" name="id" value={a.id} /><input type="hidden" name="to" value={to} />
              {to === 'rejected' && <input name="reason" placeholder="Reason (kept on record)" required />}
              <button type="submit" className={to === 'rejected' || to === 'withdrawn' ? '' : 'primary'}>{to === 'withdrawn' ? 'Mark withdrawn' : `Move to ${label(to)}`}</button>
            </form>
          ))}</div>
        )}
      </section>
      <section className="card">
        <h2>Documents</h2>
        {(files ?? []).length === 0 ? <Empty>No files were sent with this application.</Empty> : (
          <ul>{(files ?? []).map((f: any) => (
            <li key={f.id}><a href={`/careers/files/${f.id}`}>{f.kind === 'cv' ? 'CV' : 'Supporting document'}: {f.file_name}</a> <span className="muted small">{Math.ceil(f.size_bytes / 1024)} KB · {fmtDateTime(f.uploaded_at)}</span></li>
          ))}</ul>
        )}
      </section>
      <section className="card">
        <h2>Their answers</h2>
        {!profile && !a.cover_letter ? <Empty>The applicant did not add more details.</Empty> : (
          <dl className="kv">
            {PROFILE.filter(([k]) => profile?.[k]).map(([k, t]) => <div key={k}><dt>{t}</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{label(String(profile[k]))}</dd></div>)}
            {(['portfolio_url', 'github_url', 'linkedin_url'] as const).filter((k) => profile?.[k]).map((k) => <div key={k}><dt>{k.split('_')[0]}</dt><dd>{link(profile[k])}</dd></div>)}
            {a.cover_letter && <div><dt>Message</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{a.cover_letter}</dd></div>}
          </dl>
        )}
      </section>
      <section className="card">
        <h2>Review notes</h2>
        {mayReview && (
          <form action={addReviewAction} className="stack">
            <input type="hidden" name="id" value={a.id} />
            <label>Note<textarea name="notes" rows={3} required /></label>
            <label>Score (optional)<select name="score" defaultValue=""><option value="">—</option>{[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n}</option>)}</select></label>
            <button type="submit">Add note</button>
          </form>
        )}
        {(reviews ?? []).length === 0 ? <Empty>No notes yet.</Empty> : (
          <ul>{(reviews ?? []).map((r: any) => (
            <li key={r.id}><b>{r.staff?.full_name ?? 'Staff'}</b> <span className="muted small">· {label(r.stage)} · {fmtDateTime(r.created_at)}{r.score ? ` · score ${r.score}/5` : ''}</span><div style={{ whiteSpace: 'pre-wrap' }}>{r.notes}</div></li>
          ))}</ul>
        )}
      </section>
    </>
  );
}
