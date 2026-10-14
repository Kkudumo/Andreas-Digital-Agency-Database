import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { fmtDate, fmtDateTime, label } from '@/lib/format';
import { updateVacancyAction, vacancyStepAction } from '../actions';
import { VacancyFields } from '../vacancy-fields';

// One vacancy: its content (editable while it is a draft), the next approval step, and everyone who applied.
const STEPS: Record<string, { to: string; label: string; perm: 'update' | 'publish'; reason?: boolean; tone?: string }[]> = {
  draft: [{ to: 'pending_approval', label: 'Send for approval', perm: 'update' }, { to: 'cancelled', label: 'Cancel vacancy', perm: 'update', reason: true, tone: 'danger' }],
  pending_approval: [{ to: 'approved', label: 'Approve', perm: 'publish' }, { to: 'draft', label: 'Return to draft', perm: 'update', reason: true }],
  approved: [{ to: 'published', label: 'Publish on the website', perm: 'publish' }, { to: 'draft', label: 'Back to draft', perm: 'publish', reason: true }],
  published: [{ to: 'closed', label: 'Close (stop taking applications)', perm: 'publish', reason: true }, { to: 'draft', label: 'Unpublish and edit', perm: 'publish', reason: true }],
  closed: [{ to: 'draft', label: 'Reopen as draft', perm: 'publish', reason: true }],
};

export default async function VacancyPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: v } = await supabase.from('vacancies').select('*, divisions(name), positions(title)').eq('id', id).is('deleted_at', null).maybeSingle();
  if (!v) notFound();
  const { data: apps } = await supabase.from('applications').select('id, ada_id, status, submitted_at, people(full_name, email)').eq('vacancy_id', id).order('submitted_at', { ascending: false });
  const mayEdit = can(access, 'vacancies.update', v.division_id);
  const mayPublish = can(access, 'vacancies.publish', v.division_id);
  const steps = (STEPS[v.status] ?? []).filter((s) => (s.perm === 'update' ? mayEdit || mayPublish : mayPublish));

  return (
    <>
      <PageHead title={v.title} sub={`${v.positions?.title ?? ''} · ${v.divisions?.name ?? ''} · ${label(v.employment_type)}`} eyebrow={`Careers · ${v.ada_id}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        <p><Badge v={v.status} /> {v.status_reason && <span className="muted small"> {v.status_reason}</span>}</p>
        <p className="muted small">Closes {fmtDate(v.closing_date)}{v.published_at && <> · published {fmtDateTime(v.published_at)}</>}{v.slug && v.status === 'published' && <> · <a href={`https://www.andreasdigitalagency.com/careers/${v.slug}`} target="_blank" rel="noopener">see it on the website</a></>}</p>
        {steps.length > 0 && (
          <div className="stack">{steps.map((s) => (
            <form key={s.to} action={vacancyStepAction} className="inline">
              <input type="hidden" name="id" value={v.id} /><input type="hidden" name="to" value={s.to} />
              {s.reason && <input name="reason" placeholder="Reason" required={s.to === 'cancelled'} />}
              <button type="submit" className={s.tone === 'danger' ? '' : 'primary'}>{s.label}</button>
            </form>
          ))}</div>
        )}
      </section>
      <section className="card">
        <h2>Applications ({(apps ?? []).length})</h2>
        {(apps ?? []).length === 0 ? <Empty>Nobody has applied yet.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Applicant</th><th>Stage</th><th>Received</th></tr></thead>
            <tbody>{(apps ?? []).map((a: any) => (
              <tr key={a.id}>
                <td><Link href={`/careers/applications/${a.id}`}><b>{a.people?.full_name ?? 'Applicant'}</b></Link><div className="muted small">{a.people?.email}</div><div className="id">{a.ada_id}</div></td>
                <td><Badge v={a.status} /></td><td>{fmtDateTime(a.submitted_at)}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
      <section className="card">
        <h2>Vacancy details</h2>
        {v.status !== 'draft' && <p className="muted small">The details can be changed only while the vacancy is a draft. Use “Back to draft” or “Unpublish and edit” first.</p>}
        <form action={updateVacancyAction} className="stack">
          <input type="hidden" name="id" value={v.id} />
          <VacancyFields v={v} disabled={v.status !== 'draft' || !mayEdit} />
          {v.status === 'draft' && mayEdit && <button className="primary" type="submit">Save</button>}
        </form>
      </section>
    </>
  );
}
