import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section } from '@/components/panels';
import { runBillingAction } from '../actions';
import { fmtDate } from '@/lib/format';

export default async function BillingPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('billing_schedule_progress').select('*').order('next_bill_on');
  const { data: cs } = await supabase.from('contracts').select('id, title, client:clients(name)').in('id', [...new Set(((data ?? []) as any[]).map((r) => r.contract_id))]);
  const byId = new Map(((cs ?? []) as any[]).map((c) => [c.id, c]));
  const rows = ((data ?? []) as any[]).map((r) => ({ ...r, contract: byId.get(r.contract_id) }));
  const today = new Date().toISOString().slice(0, 10);
  const due = rows.filter((r) => r.status === 'active' && r.next_bill_on <= today).length;
  return (
    <>
      <PageHead title="Billing runs" sub="Recurring invoicing: bill every period that has come due, once" />
      <Flash error={sp.error} ok={sp.ok} />
      <Section title="Run billing">
        <form action={runBillingAction} className="row" style={{ gridTemplateColumns: '1fr 2fr auto', alignItems: 'end' }}>
          <Return to="/billing" />
          <label>Bill periods starting up to<input name="as_of" type="date" defaultValue={today} /></label>
          <label className="small"><input type="checkbox" name="invoices" /> also prepare one draft invoice per schedule (never issued automatically)</label>
          <button className="primary" type="submit">Run billing{due ? ` (${due} due)` : ''}</button>
        </form>
        <div className="muted small" style={{ marginTop: '.4rem' }}>Running twice for the same date bills nothing twice. A schedule ends when its line is fully billed and pauses (with the reason) if its contract can no longer be billed.</div>
      </Section>
      <section className="card">
        {rows.length === 0 ? <Empty>No billing schedules visible to you. Create one from a signed contract.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Contract</th><th>Client</th><th>Every</th><th>Next period</th><th>Billed</th><th>Remaining</th><th>Status</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.schedule_id}><td><Link href={`/contracts/${r.contract_id}`}><b>{r.contract?.title}</b></Link></td><td>{r.contract?.client?.name ?? '—'}</td>
                <td>{r.interval_months} month(s) × {r.quantity_per_period}</td><td>{r.status === 'ended' ? '—' : fmtDate(r.next_bill_on)}</td>
                <td>{r.periods_billed} period(s)</td><td>{r.line_remaining}</td><td><Badge v={r.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
