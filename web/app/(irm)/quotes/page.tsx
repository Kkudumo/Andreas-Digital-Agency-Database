import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, PageHead } from '@/components/ui';
import { fmtDate } from '@/lib/format';

export default async function QuotesPage() {
  await requireAccess();
  const supabase = await createClient();
  const { data } = await supabase.from('quotes').select('id, ada_id, title, status, total, currency, valid_until, created_at, client:clients(id, name), project:projects(id, name), division:divisions(name)').order('created_at', { ascending: false }).limit(300);
  const rows = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Quotes" sub="Create a quote from a client or project page; prices come from the central catalogue" />
      <section className="card">
        {rows.length === 0 ? <Empty>No quotes visible to you yet.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ID</th><th>Quote</th><th>Client</th><th>Project</th><th>Division</th><th>Total</th><th>Valid until</th><th>Status</th></tr></thead>
            <tbody>{rows.map((q) => (
              <tr key={q.id}><td className="mono"><Link href={`/quotes/${q.id}`}>{q.ada_id}</Link></td><td><Link href={`/quotes/${q.id}`}><b>{q.title}</b></Link></td>
                <td>{q.client ? <Link href={`/clients/${q.client.id}`}>{q.client.name}</Link> : '—'}</td><td>{q.project ? <Link href={`/projects/${q.project.id}`}>{q.project.name}</Link> : '—'}</td>
                <td>{q.division?.name ?? '—'}</td><td>{money(q.total, q.currency)}</td><td>{fmtDate(q.valid_until)}</td><td><Badge v={q.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
