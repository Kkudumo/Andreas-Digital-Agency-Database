import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, LinkTable, Return, Section, Transitions } from '@/components/panels';
import {
  creditNoteAllocateAction, creditNoteCustomLineAction, creditNoteLineAction, creditNoteRemoveLineAction, creditNoteTransitionAction, creditNoteUnallocateAction,
} from '../../actions';
import { fmtDate, fmtDateTime } from '@/lib/format';

const NEXT: Record<string, string[]> = {
  draft: ['pending_approval', 'cancelled'], pending_approval: ['approved', 'draft', 'cancelled'], approved: ['issued', 'cancelled'], issued: [], cancelled: [],
};

export default async function CreditNotePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: c } = await supabase.from('credit_notes').select('*, invoice:invoices(id, ada_id), client:clients(id, name)').eq('id', id).maybeSingle();
  if (!c) notFound();
  const here = `/credit-notes/${id}`;
  const [{ data: lines }, { data: allocs }, { data: bal }, { data: invLines }] = await Promise.all([
    supabase.from('credit_note_lines').select('*').eq('credit_note_id', id).order('position'),
    supabase.from('credit_note_allocations').select('id, amount, status, allocated_at, released_at, invoice:invoices(id, ada_id)').eq('credit_note_id', id).order('allocated_at'),
    supabase.from('credit_note_balances').select('applied, unapplied').eq('credit_note_id', id).maybeSingle(),
    c.status === 'draft' ? supabase.from('invoice_lines').select('id, description, quantity').eq('invoice_id', c.invoice_id).eq('active', true).order('position') : Promise.resolve({ data: [] as any[] }),
  ]);
  const { data: open } = c.status === 'issued' && Number(bal?.unapplied ?? 0) > 0
    ? await supabase.from('invoice_balances').select('invoice_id, ada_id, balance').eq('client_id', c.client_id).eq('currency', c.currency).gt('balance', 0).in('status', ['issued', 'partially_paid'])
    : { data: [] as any[] };
  const draft = c.status === 'draft';
  return (
    <>
      <PageHead title={`Credit note ${c.ada_id}`} sub={c.client?.name ? `For ${c.client.name}` : undefined} />
      <Flash error={sp.error} ok={sp.ok} />
      <div className="grid g4" style={{ marginBottom: '1rem' }}>
        {[['Total', c.total], ['Applied', bal?.applied], ['Unapplied', bal?.unapplied]].map(([l, n]) => <div className="stat" key={String(l)}><div className="n">{money(n as number, c.currency)}</div><div className="l">{l}</div></div>)}
      </div>
      <p className="muted small">Applied and unapplied are derived from the applications on every view; they are not stored.</p>
      <Section title="Credit note">
        <KV rows={[['Status', <Badge key="s" v={c.status} />], ['Against invoice', c.invoice ? <Link key="i" href={`/invoices/${c.invoice.id}`}>{c.invoice.ada_id}</Link> : '—'],
          ['Reason', c.reason_code.replace(/_/g, ' ')], ['Note', c.reason_note], ['Issue date', fmtDate(c.issue_date)], ['Created', fmtDateTime(c.created_at)]]} />
        <div style={{ marginTop: '.8rem' }}><Transitions action={creditNoteTransitionAction} field="credit_note" id={id} options={NEXT[c.status] ?? []} returnTo={here} /></div>
        <div className="muted small" style={{ marginTop: '.4rem' }}>Nothing can be credited beyond what was invoiced. On issue the credit is applied to its own invoice up to what is still owed; the rest stays as credit for the client. An issued credit note is never edited.</div>
      </Section>
      <Section title="Lines" count={lines?.length}>
        <LinkTable rows={(lines ?? []) as any[]} cols={[{ head: 'Description', render: (l) => <b>{l.description}</b> }, { head: 'Qty', key: 'quantity' }, { head: 'Unit price', render: (l) => money(l.unit_price, c.currency) }, { head: 'Total', render: (l) => money(l.line_total, c.currency) },
          { head: '', render: (l) => draft ? <form action={creditNoteRemoveLineAction}><Return to={here} /><input type="hidden" name="line" value={l.id} /><button className="link" type="submit">Remove</button></form> : null }]} />
        {draft && (
          <>
            <form action={creditNoteLineAction} className="row" style={{ gridTemplateColumns: '2fr 1fr auto', alignItems: 'end', marginTop: '.7rem' }}>
              <Return to={here} /><input type="hidden" name="credit_note" value={id} />
              <label>Credit part of an invoice line<select name="invoice_line">{(invLines ?? []).map((l: any) => <option key={l.id} value={l.id}>{l.description} (qty {l.quantity})</option>)}</select></label>
              <label>Quantity (blank = all remaining)<input name="quantity" type="number" step="0.01" min="0.01" /></label>
              <button className="primary" type="submit">Add line</button>
            </form>
            <form action={creditNoteCustomLineAction} className="row" style={{ gridTemplateColumns: '2fr 1fr 1fr auto', alignItems: 'end', marginTop: '.7rem' }}>
              <Return to={here} /><input type="hidden" name="credit_note" value={id} />
              <label>Or a free-form line<input name="description" required /></label>
              <label>Quantity<input name="quantity" type="number" step="0.01" min="0.01" defaultValue="1" /></label>
              <label>Unit price<input name="unit_price" type="number" step="0.01" min="0.01" required /></label>
              <button type="submit">Add</button>
            </form>
          </>
        )}
      </Section>
      <Section title="Applications" count={allocs?.length}>
        <LinkTable rows={(allocs ?? []) as any[]} cols={[{ head: 'Invoice', render: (a) => a.invoice ? <Link className="mono" href={`/invoices/${a.invoice.id}`}>{a.invoice.ada_id}</Link> : '—' }, { head: 'Amount', render: (a) => money(a.amount, c.currency) }, { head: 'Applied', render: (a) => fmtDate(a.allocated_at) },
          { head: 'State', render: (a) => a.status === 'active' ? 'active' : `released ${fmtDate(a.released_at)}` },
          { head: '', render: (a) => a.status === 'active' ? <form action={creditNoteUnallocateAction} className="row" style={{ gridTemplateColumns: '1fr auto' }}><Return to={here} /><input type="hidden" name="allocation" value={a.id} /><input name="reason" placeholder="reason" required /><button className="link" type="submit">Release</button></form> : null }]} />
        {(open ?? []).length > 0 && (
          <form action={creditNoteAllocateAction} className="row" style={{ gridTemplateColumns: '1fr 1fr auto', alignItems: 'end', marginTop: '.7rem' }}>
            <Return to={here} /><input type="hidden" name="credit_note" value={id} />
            <label>Apply remaining credit to<select name="invoice">{(open ?? []).map((i: any) => <option key={i.invoice_id} value={i.invoice_id}>{i.ada_id} — owes {money(i.balance, c.currency)}</option>)}</select></label>
            <label>Amount (blank = as much as fits)<input name="amount" type="number" step="0.01" min="0.01" /></label>
            <button className="primary" type="submit">Apply</button>
          </form>
        )}
      </Section>
    </>
  );
}
