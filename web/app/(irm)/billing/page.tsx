import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section } from '@/components/panels';
import { runBillingAction, setBillingRunnerAction } from '../actions';
import { fmtDate } from '@/lib/format';

export default async function BillingPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string; preview?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('billing_schedule_progress').select('*').order('next_bill_on');
  const { data: cs } = await supabase.from('contracts').select('id, title, client:clients(name)').in('id', [...new Set(((data ?? []) as any[]).map((r) => r.contract_id))]);
  const byId = new Map(((cs ?? []) as any[]).map((c) => [c.id, c]));
  const rows = ((data ?? []) as any[]).map((r) => ({ ...r, contract: byId.get(r.contract_id) }));
  const today = new Date().toISOString().slice(0, 10);
  const previewDate = sp.preview && /^\d{4}-\d{2}-\d{2}$/.test(sp.preview) ? sp.preview : null;
  const { data: prev } = previewDate ? await supabase.rpc('billing_schedule_preview', { p_as_of: previewDate }) : { data: [] as any[] };
  const canConfigure = access.permissions.some((g) => g.key === 'finance.configure');
  const { data: settings } = await supabase.from('finance_settings').select('billing_runner_id').maybeSingle();
  const { data: staff } = canConfigure ? await supabase.from('staff').select('id, full_name').eq('account_status', 'active').is('deleted_at', null).order('full_name') : { data: [] as any[] };
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
      <Section title="Preview">
        <form method="get" className="row" style={{ gridTemplateColumns: '1fr auto', alignItems: 'end' }}>
          <label>What would a run for this date bill?<input name="preview" type="date" defaultValue={previewDate ?? today} /></label>
          <button type="submit">Preview</button>
        </form>
        {previewDate && (((prev ?? []) as any[]).length === 0 ? <p className="muted small">Nothing would be billed.</p> : (
          <div className="scroll"><table><thead><tr><th>Schedule</th><th>Period starting</th><th>Quantity</th></tr></thead>
            <tbody>{((prev ?? []) as any[]).map((p, i) => <tr key={i}><td className="mono">{String(p.schedule_id).slice(0, 8)}</td><td>{fmtDate(p.period_start)}</td><td>{p.quantity}</td></tr>)}</tbody></table></div>
        ))}
        <p className="muted small">A preview changes nothing.</p>
      </Section>
      {canConfigure && (
        <Section title="Unattended billing">
          <form action={setBillingRunnerAction} className="row" style={{ gridTemplateColumns: '2fr auto', alignItems: 'end' }}>
            <Return to="/billing" />
            <label>Billing job runs as<select name="staff" defaultValue={settings?.billing_runner_id ?? ''}><option value="">— off —</option>{(staff ?? []).map((m: any) => <option key={m.id} value={m.id}>{m.full_name}</option>)}</select></label>
            <button type="submit">Save</button>
          </form>
          <div className="muted small" style={{ marginTop: '.4rem' }}>The scheduled job acts as this person and can bill only what they could bill by hand; it prepares draft invoices and never issues them. See docs/workflows/RECURRING_INVOICING.md for the schedule.</div>
        </Section>
      )}
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
