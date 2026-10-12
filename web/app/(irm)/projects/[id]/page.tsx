import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { call, rid, money, type Rec } from '@/lib/db';
import { Badge, Flash, PageHead } from '@/components/ui';
import { AttachPanel, IdLink, KV, LinkTable, Return, Section, Status, Transitions, getCatalogue, getDivisions } from '@/components/panels';
import { addProjectServiceAction, projectTransitionAction } from '../../actions';
import { fmtDate } from '@/lib/format';

const NEXT: Record<string, string[]> = {
  proposed: ['approved', 'cancelled'], approved: ['active', 'on_hold', 'cancelled'], active: ['on_hold', 'completed', 'cancelled'],
  on_hold: ['active', 'cancelled'], completed: ['archived'], cancelled: ['archived'], archived: [],
};

export default async function ProjectPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const { data: v } = await call<Rec>('project_360', { p_project: id });
  if (!v) notFound();
  const here = `/projects/${id}`;
  const o = v.overview;
  const [divisions, catalogue] = await Promise.all([getDivisions(), getCatalogue()]);
  const inst = (await call<Rec>('entity_resolve', { p_id: o.id })).data?.institutional_id as string | undefined;
  const clientInst = (await call<Rec>('entity_resolve', { p_id: v.client.id })).data;
  const clientUuid = clientInst?.authoritative_record_key as string | undefined;
  const links = [inst, clientInst?.institutional_id].filter(Boolean).join(',');
  const billed = (v.invoices ?? []) as Rec[];

  return (
    <>
      <PageHead title={o.name} sub={`Project 360 · ${o.id}${inst ? ` · ${inst}` : ''}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <p style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap' }}>
        <Link className="primary" href={`/search?q=${encodeURIComponent('related:' + (inst ?? o.id))}`}>Related records</Link>
        <a className="primary" href="#attach">Attach</a>
        {clientUuid && <Link className="primary" href={`/clients/${clientUuid}`}>Client 360</Link>}
      </p>

      <Section title="Overview">
        <KV rows={[['Status', <Badge key="s" v={o.status} />], ['Priority', <Badge key="p" v={o.priority} />], ['Client', <IdLink key="c" id={v.client.id} />], ['Client name', v.client.name],
          ['Lead division', o.division], ['Participating divisions', (v.divisions ?? []).join(', ') || '—'], ['Start', fmtDate(o.start_date)], ['Due', fmtDate(o.due_date)], ['Description', o.description]]} />
        <div style={{ marginTop: '.8rem' }}><Transitions action={projectTransitionAction} field="project" id={id} options={NEXT[o.status] ?? []} returnTo={here} /></div>
      </Section>

      <Section title="Services" count={v.services?.length}>
        <LinkTable rows={(v.services ?? []).map((s: Rec, i: number) => ({ ...s, id: i }))} cols={[{ head: 'Service', render: (s) => <b>{s.service}</b> }, { head: 'Qty', key: 'quantity' }, { head: 'Agreed unit price', render: (s) => money(s.unit_price, s.currency) },
          { head: 'Line total', render: (s) => money(s.total, s.currency) }, { head: 'Catalogue price used', render: (s) => (s.catalogue_price_used ? 'yes' : 'override') }, { head: 'Quote', render: (s) => <IdLink id={s.quote} /> }]} />
        <details style={{ marginTop: '.7rem' }}><summary>Add a service at today’s catalogue price</summary>
          <form action={addProjectServiceAction} className="stack" style={{ marginTop: '.6rem' }}>
            <Return to={here} /><input type="hidden" name="project" value={id} />
            <div className="row"><label>Service<select name="service">{catalogue.map((s) => <option key={s.id} value={s.id}>{s.name}{s.price !== null ? ` — ${money(s.price, s.currency)}` : ' — no approved price'}</option>)}</select></label>
              <label>Quantity<input name="quantity" type="number" step="0.01" min="0.01" defaultValue="1" /></label></div>
            <button className="primary" type="submit">Add service</button>
          </form>
        </details>
      </Section>

      <Section title="Quotes" count={v.quotes?.length}>
        <LinkTable rows={v.quotes} cols={[{ head: 'Quote', render: (q) => <Link href={rid(q.id)}><b>{q.title}</b></Link> }, { head: 'ID', render: (q) => <span className="mono">{q.id}</span> }, { head: 'Status', render: (q) => <Status r={q} /> }, { head: 'Total', render: (q) => money(q.total, 'NAD') }]} />
      </Section>
      <Section title="Contracts" count={v.contracts?.length}>
        <LinkTable rows={v.contracts} cols={[{ head: 'Contract', render: (c) => <Link href={rid(c.id)}><b>{c.title}</b></Link> }, { head: 'Status', render: (c) => <Status r={c} /> }, { head: 'Total', render: (c) => money(c.total, c.currency) }]} />
      </Section>
      <Section title="Invoices" count={billed.length}>
        <LinkTable rows={billed} cols={[{ head: 'Invoice', render: (i) => <Link className="mono" href={rid(i.id)}>{i.id}</Link> }, { head: 'Status', render: (i) => <Status r={i} /> }, { head: 'Total', render: (i) => money(i.total, i.currency) }, { head: 'Paid', render: (i) => money(i.paid, i.currency) }, { head: 'Balance', render: (i) => money(i.balance, i.currency) }]} />
      </Section>
      <Section title="Payments" count={v.payments?.length}>
        <LinkTable rows={v.payments} cols={[{ head: 'Payment', render: (p) => <span className="mono">{p.id}</span> }, { head: 'Status', render: (p) => <Status r={p} /> }, { head: 'Amount', render: (p) => money(p.amount, p.currency) }, { head: 'Received', render: (p) => fmtDate(p.received_on) }]} />
      </Section>

      <div className="grid g2">
        <Section title="Contacts" count={v.contacts?.length}><LinkTable rows={(v.contacts ?? []).map((c: Rec, i: number) => ({ ...c, id: i }))} cols={[{ head: 'Name', render: (c) => <b>{c.name}</b> }, { head: 'Role', key: 'role' }, { head: 'Email', key: 'email' }]} /></Section>
        <Section title="Staff" count={v.staff?.length}><LinkTable rows={(v.staff ?? []).map((c: Rec, i: number) => ({ ...c, id: i }))} cols={[{ head: 'Name', render: (c) => <b>{c.name}</b> }, { head: 'Role', key: 'role' }]} /></Section>
        <Section title="Tasks" count={(v.tasks?.open ?? 0) + (v.tasks?.done ?? 0)}><LinkTable rows={v.tasks?.items ?? []} cols={[{ head: 'Task', render: (t) => <b>{t.title}</b> }, { head: 'Status', render: (t) => <Status r={t} /> }, { head: 'Assignee', key: 'assignee' }, { head: 'Due', render: (t) => fmtDate(t.due_date) }]} /></Section>
        <Section title="Assets" count={v.assets?.length}><LinkTable rows={v.assets} cols={[{ head: 'Asset', render: (a) => <Link href={rid(a.id)}><b>{a.name}</b></Link> }, { head: 'Status', render: (a) => <Status r={a} /> }, { head: 'Condition', key: 'condition' }]} /></Section>
        <Section title="Tickets" count={v.tickets?.length}><LinkTable rows={v.tickets} cols={[{ head: 'Ticket', render: (t) => <Link href={rid(t.id)}><b>{t.title}</b></Link> }, { head: 'Status', render: (t) => <Status r={t} /> }, { head: 'Priority', key: 'priority' }]} /></Section>
        <Section title="Documents" count={v.documents?.length}><LinkTable rows={v.documents} cols={[{ head: 'Document', render: (d) => <Link href={rid(d.document)}><b>{d.title}</b></Link> }, { head: 'Type', key: 'type' }, { head: 'Status', render: (d) => <Status r={d} /> }]} /></Section>
        <Section title="Communications (metadata only)" count={v.communications?.length}><LinkTable rows={v.communications} cols={[{ head: 'Thread', render: (c) => <Link className="mono" href={rid(c.thread)}>{c.thread}</Link> }, { head: 'Status', render: (c) => <Status r={c} /> }, { head: 'Messages', key: 'messages' }, { head: 'Last', render: (c) => fmtDate(c.last_occurred) }]} /></Section>
        <Section title="Domains" count={v.domains?.length}><LinkTable rows={v.domains} cols={[{ head: 'Domain', render: (d) => <Link href={rid(d.domain)}><b>{d.name}</b></Link> }, { head: 'Status', render: (d) => <Status r={d} /> }, { head: 'Expires', render: (d) => fmtDate(d.expires_on) }]} /></Section>
      </div>

      <AttachPanel divisions={divisions} returnTo={here} clientId={clientUuid} projectId={id} links={links} />

      <Section title="History" count={v.activity?.length}>
        <LinkTable rows={(v.activity ?? []).map((a: Rec, i: number) => ({ ...a, id: i }))} cols={[{ head: 'When', render: (a) => new Date(a.at).toLocaleString('en-GB') }, { head: 'Action', key: 'action' }, { head: 'Changed', render: (a) => (a.changed ?? []).join(', ') }]} />
      </Section>
    </>
  );
}
