import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { call, rid, money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, LinkTable, Return, Section, Transitions } from '@/components/panels';
import { allocatePaymentAction, invoiceTransitionAction } from '../../actions';
import { fmtDate, fmtDateTime } from '@/lib/format';

const NEXT: Record<string, string[]> = {
  draft: ['pending_approval', 'cancelled'], pending_approval: ['approved', 'draft', 'cancelled'], approved: ['issued', 'cancelled'], issued: ['cancelled'], partially_paid: [], paid: [], cancelled: [],
};

export default async function InvoicePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: i } = await supabase.from('invoices').select('*, client:clients(id, name), contract:contracts(id, ada_id, title), project:projects(id, name)').eq('id', id).maybeSingle();
  if (!i) notFound();
  const here = `/invoices/${id}`;
  const [{ data: lines }, { data: allocs }, bal, paid] = await Promise.all([
    supabase.from('invoice_lines').select('*').eq('invoice_id', id).eq('active', true).order('position'),
    supabase.from('payment_allocations').select('amount, status, allocated_at, payment:payments(id, ada_id, reference, received_on)').eq('invoice_id', id).eq('status', 'active'),
    call<number>('invoice_balance', { p_invoice: id }), call<number>('invoice_paid', { p_invoice: id }),
  ]);
  const issued = ['issued', 'partially_paid'].includes(i.status);
  const { data: open } = issued ? await supabase.from('payment_balances').select('payment_id, credit').eq('client_id', i.client_id).eq('status', 'received').gt('credit', 0) : { data: [] as any[] };

  return (
    <>
      <PageHead title={`Invoice ${i.ada_id}`} sub={i.client_name_snapshot ? `Issued to ${i.client_name_snapshot}` : 'Draft'} />
      <Flash error={sp.error} ok={sp.ok} />
      <div className="grid g4" style={{ marginBottom: '1rem' }}>
        {[['Total', i.total], ['Paid', paid.data], ['Balance', bal.data]].map(([l, n]) => <div className="stat" key={String(l)}><div className="n">{money(n as number, i.currency)}</div><div className="l">{l}</div></div>)}
      </div>
      <p className="muted small">Paid and balance are derived from payment allocations on every view; they are not stored on the invoice.</p>
      <Section title="Invoice">
        <KV rows={[['Status', <Badge key="s" v={i.status} />], ['Client', i.client ? <Link key="c" href={`/clients/${i.client.id}`}>{i.client.name}</Link> : '—'],
          ['Contract', i.contract ? <Link key="k" href={`/contracts/${i.contract.id}`}>{i.contract.ada_id} — {i.contract.title}</Link> : '—'], ['Project', i.project ? <Link key="p" href={`/projects/${i.project.id}`}>{i.project.name}</Link> : '—'],
          ['Subtotal', money(i.subtotal, i.currency)], ['VAT', money(i.tax_total, i.currency)], ['Issue date', fmtDate(i.issue_date)], ['Due date', fmtDate(i.due_date)], ['Created', fmtDateTime(i.created_at)]]} />
        <div style={{ marginTop: '.8rem' }}><Transitions action={invoiceTransitionAction} field="invoice" id={id} options={NEXT[i.status] ?? []} returnTo={here} /></div>
        <div className="muted small" style={{ marginTop: '.4rem' }}>Once issued, an invoice and its lines can no longer be edited; corrections happen through cancellation and re-billing under the approval policy.</div>
      </Section>
      <Section title="Lines (values copied at billing time)" count={lines?.length}>
        <LinkTable rows={(lines ?? []) as any[]} cols={[{ head: 'Description', render: (l) => <b>{l.description}</b> }, { head: 'Qty', key: 'quantity' }, { head: 'Unit price', render: (l) => money(l.unit_price, i.currency) }, { head: 'VAT', render: (l) => money(l.tax_amount, i.currency) }, { head: 'Total', render: (l) => money(l.line_total, i.currency) }]} />
      </Section>
      <Section title="Payments allocated" count={allocs?.length}>
        <LinkTable rows={((allocs ?? []) as any[]).map((a, k) => ({ ...a, id: k }))} cols={[{ head: 'Payment', render: (a) => <Link className="mono" href={rid(a.payment?.ada_id)}>{a.payment?.ada_id}</Link> }, { head: 'Reference', render: (a) => a.payment?.reference ?? '—' }, { head: 'Received', render: (a) => fmtDate(a.payment?.received_on) }, { head: 'Allocated', render: (a) => money(a.amount, i.currency) }]} />
        {issued && (open ?? []).length > 0 && (
          <form action={allocatePaymentAction} className="row" style={{ gridTemplateColumns: '1fr 1fr auto', alignItems: 'end', marginTop: '.7rem' }}>
            <Return to={here} /><input type="hidden" name="invoice" value={id} />
            <label>Unallocated payment<select name="payment">{(open ?? []).map((p: any) => <option key={p.payment_id} value={p.payment_id}>{money(p.credit, i.currency)} available</option>)}</select></label>
            <label>Amount (blank = as much as fits)<input name="amount" type="number" step="0.01" min="0.01" /></label>
            <button className="primary" type="submit">Allocate</button>
          </form>
        )}
      </Section>
    </>
  );
}
