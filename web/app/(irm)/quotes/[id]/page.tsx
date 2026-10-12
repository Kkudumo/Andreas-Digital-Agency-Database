import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, LinkTable, Return, Section, Transitions, getCatalogue } from '@/components/panels';
import { addQuoteLineAction, convertQuoteAction, createContractAction, quoteTransitionAction } from '../../actions';
import { fmtDate, fmtDateTime } from '@/lib/format';

// What each status may move to. The database enforces the same table, the approval policy and who may approve; the buttons only mirror it.
const NEXT: Record<string, string[]> = {
  draft: ['pending_approval', 'cancelled'], pending_approval: ['approved', 'rejected', 'draft'], approved: ['sent', 'cancelled'],
  sent: ['accepted', 'rejected', 'expired'], accepted: [], rejected: ['draft'], expired: [], cancelled: [],
};

export default async function QuotePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: q } = await supabase.from('quotes').select('*, client:clients(id, name, ada_id), project:projects(id, name, ada_id), division:divisions(name)').eq('id', id).maybeSingle();
  if (!q) notFound();
  const [{ data: lines }, { data: approvals }, catalogue] = await Promise.all([
    supabase.from('quote_lines').select('*, service:services(name)').eq('quote_id', id).order('position'),
    supabase.from('approval_requests').select('status, requested_at, decided_at, decision_note, self_approved, summary').eq('entity_table', 'quotes').eq('entity_id', id).order('requested_at'),
    getCatalogue(),
  ]);
  const here = `/quotes/${id}`;
  const open = q.status === 'draft';
  const { data: contracts } = await supabase.from('contracts').select('id, ada_id, status').eq('quote_id', id);

  return (
    <>
      <PageHead title={q.title} sub={`Quote · ${q.ada_id} · ${q.division?.name ?? ''}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <Section title="Quote">
        <KV rows={[['Status', <Badge key="s" v={q.status} />], ['Client', q.client ? <Link key="c" href={`/clients/${q.client.id}`}>{q.client.name}</Link> : '—'],
          ['Project', q.project ? <Link key="p" href={`/projects/${q.project.id}`}>{q.project.name}</Link> : 'not linked yet'], ['Total', money(q.total, q.currency)], ['Valid until', fmtDate(q.valid_until)], ['Created', fmtDateTime(q.created_at)]]} />
        <div style={{ marginTop: '.8rem' }}><Transitions action={quoteTransitionAction} field="quote" id={id} options={NEXT[q.status] ?? []} returnTo={here} /></div>
        <div className="muted small" style={{ marginTop: '.4rem' }}>Approval is decided by the approval policy: the person who requests it generally cannot approve it. The database refuses what you may not do.</div>
      </Section>

      <Section title="Lines — prices are copied from the approved catalogue" count={lines?.length}>
        <LinkTable rows={(lines ?? []) as any[]} cols={[{ head: '#', key: 'position' }, { head: 'Service', render: (l) => <b>{l.service?.name ?? l.description}</b> }, { head: 'Qty', key: 'quantity' }, { head: 'Unit price (snapshot)', render: (l) => money(l.unit_price, q.currency) },
          { head: 'Discount', render: (l) => money(l.discount_amount, q.currency) }, { head: 'Line total', render: (l) => money(l.line_total, q.currency) }, { head: 'Basis', render: (l) => (l.price_id ? 'approved catalogue price' : `override: ${l.price_override_reason ?? ''}`) }]} />
        {open && (
          <details style={{ marginTop: '.7rem' }} open><summary>Add a catalogue service</summary>
            <form action={addQuoteLineAction} className="stack" style={{ marginTop: '.6rem' }}>
              <Return to={here} /><input type="hidden" name="quote" value={id} />
              <div className="row"><label>Service<select name="service" required>{catalogue.map((s) => <option key={s.id} value={s.id}>{s.name}{s.price !== null ? ` — ${money(s.price, s.currency)}` : ' — no approved price'}</option>)}</select></label>
                <label>Quantity<input name="quantity" type="number" step="0.01" min="0.01" defaultValue="1" /></label></div>
              <label>Discount (amount, optional)<input name="discount" type="number" step="0.01" min="0" /></label>
              <button className="primary" type="submit">Add line</button>
            </form>
          </details>
        )}
      </Section>

      <Section title="Approvals" count={approvals?.length}>
        <LinkTable rows={((approvals ?? []) as any[]).map((a, i) => ({ ...a, id: i }))} cols={[{ head: 'Requested', render: (a) => fmtDateTime(a.requested_at) }, { head: 'Status', render: (a) => <Badge v={a.status} /> }, { head: 'Decided', render: (a) => fmtDateTime(a.decided_at) }, { head: 'Self-approved', render: (a) => (a.self_approved ? 'yes (sole approver)' : 'no') }, { head: 'Note', key: 'decision_note' }]} />
      </Section>

      {q.status === 'accepted' && (
        <Section title="Next: project and contract">
          <div style={{ display: 'flex', gap: '1rem', flexWrap: 'wrap' }}>
            <form action={convertQuoteAction}><Return to={here} /><input type="hidden" name="quote" value={id} />
              <button className="primary" type="submit">{q.project_id ? 'Link quote to its project' : 'Create the project from this quote'}</button></form>
            {(contracts ?? []).length === 0 ? (
              <form action={createContractAction}><Return to={here} /><input type="hidden" name="quote" value={id} /><button className="primary" type="submit">Create contract from this quote</button></form>
            ) : (contracts ?? []).map((c: any) => <Link key={c.id} className="primary" href={`/contracts/${c.id}`}>Contract {c.ada_id} ({c.status})</Link>)}
          </div>
        </Section>
      )}
    </>
  );
}
