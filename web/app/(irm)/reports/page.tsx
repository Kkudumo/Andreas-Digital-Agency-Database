import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { Empty, PageHead } from '@/components/ui';
import { REPORTS, range, runReport } from '@/lib/reports';

export default async function ReportsPage({ searchParams }: { searchParams: Promise<{ report?: string; from?: string; to?: string }> }) {
  await requireAccess(); const sp = await searchParams;
  const spec = REPORTS.find((r) => r.key === sp.report) ?? REPORTS[0];
  const { from, to } = range(sp);
  const { data, error } = await runReport(spec, from, to);
  const rows = data ?? [];
  const qs = `report=${spec.key}&from=${from}&to=${to}`;
  return (
    <>
      <PageHead title="Reports" sub="Every figure is derived on the spot from the records you can read; nothing is stored" />
      <nav className="row" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', marginBottom: '1rem' }}>
        {REPORTS.map((r) => <Link key={r.key} className={r.key === spec.key ? 'primary' : ''} href={`/reports?report=${r.key}&from=${from}&to=${to}`}>{r.title}</Link>)}
      </nav>
      <section className="card">
        <h2>{spec.title}</h2>
        <p className="muted small">{spec.about}</p>
        <form method="get" className="row" style={{ gridTemplateColumns: 'repeat(2, 1fr) auto', alignItems: 'end' }}>
          <input type="hidden" name="report" value={spec.key} />
          {spec.ranged ? <>
            <label>From<input name="from" type="date" defaultValue={from} /></label>
            <label>To<input name="to" type="date" defaultValue={to} /></label>
            <button type="submit">Update</button>
          </> : <span className="muted small">Shown as of today.</span>}
        </form>
        {error ? <p className="error">The report could not be produced.</p> : rows.length === 0 ? <Empty>Nothing to report for what you can see.</Empty> : (
          <>
            <div className="scroll"><table>
              <thead><tr>{spec.cols.map((c) => <th key={c.key} style={c.money ? { textAlign: 'right' } : undefined}>{c.head}</th>)}</tr></thead>
              <tbody>{rows.map((r, i) => (
                <tr key={i}>{spec.cols.map((c) => <td key={c.key} style={c.money ? { textAlign: 'right' } : undefined}>{c.money ? money(r[c.key], r.currency).replace(/^[A-Z]{3} /, '') : String(r[c.key] ?? '—')}</td>)}</tr>
              ))}</tbody>
            </table></div>
            <p style={{ marginTop: '.8rem' }}><a href={`/reports/csv?${qs}`}>Download CSV</a></p>
          </>
        )}
      </section>
    </>
  );
}
