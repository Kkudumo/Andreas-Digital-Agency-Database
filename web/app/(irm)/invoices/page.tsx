import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, PageHead } from '@/components/ui';
import { fmtDate } from '@/lib/format';

export default async function InvoicesPage() {
  await requireAccess();
  const supabase = await createClient();
  const { data } = await supabase.from('invoices').select('id, ada_id, status, total, currency, issue_date, due_date, created_at, client:clients(id, name), project:projects(id, name), contract:contracts(id, ada_id)').order('created_at', { ascending: false }).limit(300);
  const rows = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Invoices" sub="Invoices are raised from a contract line or a project; the balance is worked out from the payments applied" />
      <section className="card">
        {rows.length === 0 ? <Empty>No invoices visible to you yet.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Invoice</th><th>Client</th><th>Project</th><th>Contract</th><th>Total</th><th>Issued</th><th>Due</th><th>Status</th></tr></thead>
            <tbody>{rows.map((i) => (
              <tr key={i.id}><td className="mono"><Link href={`/invoices/${i.id}`}>{i.ada_id}</Link></td>
                <td>{i.client ? <Link href={`/clients/${i.client.id}`}>{i.client.name}</Link> : '—'}</td><td>{i.project ? <Link href={`/projects/${i.project.id}`}>{i.project.name}</Link> : '—'}</td>
                <td>{i.contract ? <Link className="mono" href={`/contracts/${i.contract.id}`}>{i.contract.ada_id}</Link> : '—'}</td>
                <td>{money(i.total, i.currency)}</td><td>{fmtDate(i.issue_date)}</td><td>{fmtDate(i.due_date)}</td><td><Badge v={i.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
