import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { call, rid, money, type Rec } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, LinkTable, Return, Section, Transitions } from '@/components/panels';
import { billContractLineAction, contractTransitionAction, linkContractProjectAction } from '../../actions';
import { fmtDate, fmtDateTime } from '@/lib/format';

const NEXT: Record<string, string[]> = {
  draft: ['internal_review', 'cancelled'], internal_review: ['approved', 'rejected', 'draft'], approved: ['sent', 'cancelled'], sent: ['signed', 'rejected'],
  signed: ['active'], active: ['terminated', 'expired'], rejected: ['draft'], expired: [], terminated: [], cancelled: [], renewed: [],
};

export default async function ContractPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: c } = await supabase.from('contracts').select('*, client:clients(id, name), quote:quotes(id, ada_id, title)').eq('id', id).maybeSingle();
  if (!c) notFound();
  const here = `/contracts/${id}`;
  const { data: terms } = await call<Rec>('contract_terms', { p_contract: id });
  const { data: ver } = await supabase.from('contract_versions').select('id').eq('contract_id', id).eq('version_no', c.current_version_no).maybeSingle();
  const { data: lines } = ver ? await supabase.from('contract_lines').select('*, service:services(name)').eq('version_id', ver.id).order('position') : { data: [] as any[] };
  const { data: linked } = await supabase.from('contract_projects').select('project:projects(id, name, ada_id)').eq('contract_id', id);
  const { data: candidates } = await supabase.from('projects').select('id, name').eq('client_id', c.client_id).is('deleted_at', null);
  const { data: invoices } = await supabase.from('invoices').select('id, ada_id, status, total').eq('contract_id', id).order('created_at');
  const t = (terms ?? {}) as Rec;
  const billable = ['signed', 'active'].includes(c.status);

  return (
    <>
      <PageHead title={c.title} sub={`Contract · ${c.ada_id} · version ${c.current_version_no}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <Section title="Contract">
        <KV rows={[['Status', <Badge key="s" v={c.status} />], ['Client', c.client ? <Link key="c" href={`/clients/${c.client.id}`}>{c.client.name}</Link> : '—'],
          ['From quote', c.quote ? <Link key="q" href={`/quotes/${c.quote.id}`}>{c.quote.ada_id} — {c.quote.title}</Link> : '—'], ['Total', money(t.total, c.currency)],
          ['Start', fmtDate(t.start_date)], ['End', fmtDate(t.end_date)], ['Payment terms', t.payment_terms_days ? `${t.payment_terms_days} days` : '—'], ['Created', fmtDateTime(c.created_at)]]} />
        <div style={{ marginTop: '.8rem' }}><Transitions action={contractTransitionAction} field="contract" id={id} options={NEXT[c.status] ?? []} returnTo={here} /></div>
      </Section>

      <Section title="Projects covered by this contract" count={linked?.length}>
        <LinkTable rows={((linked ?? []) as any[]).map((l) => ({ ...l.project, id: l.project?.id }))} cols={[{ head: 'Project', render: (p) => <Link href={`/projects/${p.id}`}><b>{p.name}</b></Link> }, { head: 'ID', render: (p) => <span className="mono">{p.ada_id}</span> }]} />
        {(candidates ?? []).length > 0 && (
          <form action={linkContractProjectAction} className="row" style={{ gridTemplateColumns: '1fr auto', alignItems: 'end', marginTop: '.7rem' }}>
            <Return to={here} /><input type="hidden" name="contract" value={id} />
            <label>Link a project of this client<select name="project">{(candidates ?? []).map((p: any) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
            <button className="primary" type="submit">Link project</button>
          </form>
        )}
      </Section>

      <Section title="Lines — agreed values, not today’s catalogue" count={lines?.length}>
        <LinkTable rows={(lines ?? []) as any[]} cols={[{ head: '#', key: 'position' }, { head: 'Service', render: (l) => <b>{l.service?.name ?? l.description}</b> }, { head: 'Qty', key: 'quantity' }, { head: 'Unit price', render: (l) => money(l.unit_price, c.currency) }, { head: 'Line total', render: (l) => money(l.line_total, c.currency) },
          { head: '', render: (l) => billable ? (
            <form action={billContractLineAction}><Return to={here} /><input type="hidden" name="contract" value={id} /><input type="hidden" name="line" value={l.id} /><button className="link" type="submit">Bill this line</button></form>
          ) : <span className="muted small">billable once signed</span> }]} />
      </Section>

      <Section title="Invoices from this contract" count={invoices?.length}>
        <LinkTable rows={(invoices ?? []) as any[]} cols={[{ head: 'Invoice', render: (i) => <Link className="mono" href={rid(i.ada_id)}>{i.ada_id}</Link> }, { head: 'Status', render: (i) => <Badge v={i.status} /> }, { head: 'Total', render: (i) => money(i.total, c.currency) }]} />
      </Section>
    </>
  );
}
