import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, PageHead } from '@/components/ui';
import { fmtDate } from '@/lib/format';

export default async function CreditNotesPage() {
  await requireAccess();
  const supabase = await createClient();
  const { data } = await supabase.from('credit_note_balances').select('*').order('credit_note_id');
  const { data: cns } = await supabase.from('credit_notes').select('id, ada_id, status, total, currency, reason_code, issue_date, invoice:invoices(id, ada_id), client:clients(id, name)').order('created_at', { ascending: false }).limit(300);
  const bal = new Map(((data ?? []) as any[]).map((b) => [b.credit_note_id, b]));
  const rows = (cns ?? []) as any[];
  return (
    <>
      <PageHead title="Credit notes" sub="Corrections to issued invoices. Start one from the invoice it corrects." />
      <section className="card">
        {rows.length === 0 ? <Empty>No credit notes visible to you.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ID</th><th>Invoice</th><th>Client</th><th>Reason</th><th>Total</th><th>Unapplied</th><th>Issued</th><th>Status</th></tr></thead>
            <tbody>{rows.map((c) => (
              <tr key={c.id}><td className="mono"><Link href={`/credit-notes/${c.id}`}>{c.ada_id}</Link></td><td>{c.invoice ? <Link className="mono" href={`/invoices/${c.invoice.id}`}>{c.invoice.ada_id}</Link> : '—'}</td>
                <td>{c.client?.name ?? '—'}</td><td>{c.reason_code.replace(/_/g, ' ')}</td><td>{money(c.total, c.currency)}</td>
                <td>{c.status === 'issued' ? money(bal.get(c.id)?.unapplied, c.currency) : '—'}</td><td>{fmtDate(c.issue_date)}</td><td><Badge v={c.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
