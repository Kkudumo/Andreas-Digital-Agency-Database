import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, LinkTable, Return, Section, Transitions } from '@/components/panels';
import { expenseTransitionAction, payExpenseAction, voidExpenseAction } from '../../actions';
import { fmtDate, fmtDateTime } from '@/lib/format';

const NEXT: Record<string, string[]> = {
  draft: ['pending_approval', 'cancelled'], pending_approval: ['approved', 'rejected', 'draft', 'cancelled'], approved: [], paid: [], rejected: [], cancelled: [],
};

export default async function ExpensePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: e } = await supabase.from('expenses').select('*, category:expense_categories(name), supplier:suppliers(name), project:projects(id, name), client:clients(id, name), account:bank_accounts!paid_from_account_id(name)').eq('id', id).maybeSingle();
  if (!e) notFound();
  const here = `/expenses/${id}`;
  const [{ data: events }, { data: accounts }] = await Promise.all([
    supabase.from('expense_events').select('id, kind, from_status, to_status, note, at').eq('expense_id', id).order('at'),
    e.status === 'approved' ? supabase.from('bank_accounts').select('id, name, currency').eq('is_active', true).eq('currency', e.currency) : Promise.resolve({ data: [] as any[] }),
  ]);
  return (
    <>
      <PageHead title={e.description} sub={`Expense · ${e.ada_id}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <div className="grid g4" style={{ marginBottom: '1rem' }}>
        {[['Net', e.amount_net], ['Tax', e.tax_amount], ['Total', e.total]].map(([l, n]) => <div className="stat" key={String(l)}><div className="n">{money(n as number, e.currency)}</div><div className="l">{l}</div></div>)}
      </div>
      <Section title="Expense">
        <KV rows={[['Status', <Badge key="s" v={e.status} />], ['Category', e.category?.name], ['Supplier', e.supplier?.name], ['Supplier reference', e.supplier_reference],
          ['Project', e.project ? <Link key="p" href={`/projects/${e.project.id}`}>{e.project.name}</Link> : 'overhead'], ['Client', e.client ? <Link key="c" href={`/clients/${e.client.id}`}>{e.client.name}</Link> : '—'],
          ['Date', fmtDate(e.expense_date)], ['Paid', e.paid_on ? `${fmtDate(e.paid_on)} from ${e.account?.name ?? 'account'}${e.payment_reference ? ' · ' + e.payment_reference : ''}` : '—'], ['Recorded', fmtDateTime(e.created_at)]]} />
        <div style={{ marginTop: '.8rem' }}><Transitions action={expenseTransitionAction} field="expense" id={id} options={NEXT[e.status] ?? []} returnTo={here} /></div>
        <div className="muted small" style={{ marginTop: '.4rem' }}>Whoever recorded an expense cannot approve it while another qualified approver exists. A paid expense is final.</div>
      </Section>
      {e.status === 'approved' && (
        <Section title="Pay this expense">
          <form action={payExpenseAction} className="row" style={{ gridTemplateColumns: '1fr 1fr 1fr auto', alignItems: 'end' }}>
            <Return to={here} /><input type="hidden" name="expense" value={id} />
            <label>Paid from<select name="account">{(accounts ?? []).map((a: any) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            <label>Paid on<input name="paid_on" type="date" /></label>
            <label>Reference<input name="reference" /></label>
            <button className="primary" type="submit">Record payment</button>
          </form>
        </Section>
      )}
      {e.status === 'approved' && (
        <Section title="Void (approved, not yet paid)">
          <form action={voidExpenseAction} className="row" style={{ gridTemplateColumns: '1fr auto', alignItems: 'end' }}>
            <Return to={here} /><input type="hidden" name="expense" value={id} />
            <label>Reason (required)<input name="reason" required /></label>
            <button type="submit">Void expense</button>
          </form>
        </Section>
      )}
      <Section title="History" count={events?.length}>
        <LinkTable rows={(events ?? []) as any[]} cols={[{ head: 'When', render: (v) => fmtDateTime(v.at) }, { head: 'Event', key: 'kind' }, { head: 'From', render: (v) => v.from_status ?? '—' }, { head: 'To', render: (v) => v.to_status ?? '—' }, { head: 'Note', render: (v) => v.note ?? '—' }]} />
      </Section>
    </>
  );
}
