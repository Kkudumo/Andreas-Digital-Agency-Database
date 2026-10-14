import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, PageHead } from '@/components/ui';
import { fmtDate } from '@/lib/format';

export default async function ContractsPage() {
  await requireAccess();
  const supabase = await createClient();
  const { data } = await supabase.from('contracts').select('id, ada_id, title, status, currency, signed_at, activated_at, created_at, client:clients(id, name), quote:quotes(id, ada_id), division:divisions(name)').order('created_at', { ascending: false }).limit(300);
  const rows = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Contracts" sub="A contract is made from an accepted quote; invoices are billed from its lines" />
      <section className="card">
        {rows.length === 0 ? <Empty>No contracts visible to you yet.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ID</th><th>Contract</th><th>Client</th><th>From quote</th><th>Division</th><th>Signed</th><th>Status</th></tr></thead>
            <tbody>{rows.map((c) => (
              <tr key={c.id}><td className="mono"><Link href={`/contracts/${c.id}`}>{c.ada_id}</Link></td><td><Link href={`/contracts/${c.id}`}><b>{c.title}</b></Link></td>
                <td>{c.client ? <Link href={`/clients/${c.client.id}`}>{c.client.name}</Link> : '—'}</td><td>{c.quote ? <Link className="mono" href={`/quotes/${c.quote.id}`}>{c.quote.ada_id}</Link> : '—'}</td>
                <td>{c.division?.name ?? '—'}</td><td>{fmtDate(c.signed_at)}</td><td><Badge v={c.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
