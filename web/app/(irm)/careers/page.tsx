import Link from 'next/link';
import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { fmtDate, label } from '@/lib/format';
import { createVacancyAction } from './actions';
import { VacancyFields } from './vacancy-fields';

// Careers: the vacancies of every division you may see, how many people applied, and a form for a new vacancy.
// A vacancy is written as a draft, approved by the CEO, then published to the careers page on the website.
export default async function CareersPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string; show?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const showAll = sp.show === 'all';
  let q = supabase.from('vacancies').select('id, ada_id, title, status, employment_type, closing_date, published_at, division_id, divisions(name)').is('deleted_at', null).order('created_at', { ascending: false });
  if (!showAll) q = q.in('status', ['draft', 'pending_approval', 'approved', 'published']);
  const [{ data: vacs }, { data: apps }, { data: positions }] = await Promise.all([
    q,
    supabase.from('applications').select('vacancy_id, status').limit(5000),
    supabase.from('positions').select('id, title, divisions(name)').order('title'),
  ]);
  const count = (id: string, open?: boolean) => (apps ?? []).filter((a: any) => a.vacancy_id === id && (!open || !['rejected', 'withdrawn', 'accepted', 'offer_declined'].includes(a.status))).length;
  const rows = (vacs ?? []) as any[];
  const canCreate = canAnywhere(access, 'vacancies.create');

  return (
    <>
      <PageHead title="Careers" sub="Vacancies, applications and CVs. Published vacancies appear on the website's careers page." />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        <div className="muted small" style={{ marginBottom: 8 }}>{showAll ? <Link href="/careers">Show only open and in progress</Link> : <Link href="/careers?show=all">Also show closed, filled and cancelled</Link>}</div>
        {rows.length === 0 ? <Empty>No vacancies yet.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Vacancy</th><th>Status</th><th>Closes</th><th>Applications</th></tr></thead>
            <tbody>{rows.map((v) => (
              <tr key={v.id}>
                <td><Link href={`/careers/${v.id}`}><b>{v.title}</b></Link><div className="muted small">{v.divisions?.name} · {label(v.employment_type)}</div><div className="id">{v.ada_id}</div></td>
                <td><Badge v={v.status} /></td>
                <td>{fmtDate(v.closing_date)}</td>
                <td>{count(v.id)}{count(v.id) > 0 && <span className="muted small"> · {count(v.id, true)} open</span>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
      {canCreate && (
        <section className="card">
          <h2>New vacancy</h2>
          <form action={createVacancyAction} className="stack">
            <label>Position<span className="muted small"> (the role this vacancy fills; its division owns the vacancy)</span>
              <select name="position_id" required defaultValue="">
                <option value="" disabled>Choose a position</option>
                {(positions ?? []).map((p: any) => <option key={p.id} value={p.id}>{p.title} · {p.divisions?.name}</option>)}
              </select></label>
            <VacancyFields />
            <button className="primary" type="submit">Create draft</button>
          </form>
        </section>
      )}
    </>
  );
}
