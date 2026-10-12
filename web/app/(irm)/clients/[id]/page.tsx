import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { call, rid, money, type Rec } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { AttachPanel, IdLink, KV, LinkTable, Return, Section, Status, getDivisions } from '@/components/panels';
import { addContactAction, claimClientAction, createProjectAction, createQuoteAction, recordPaymentAction } from '../../actions';
import { fmtDate, fmtDateTime } from '@/lib/format';

export default async function ClientPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const { data: v } = await call<Rec>('client_360', { p_client: id });
  if (!v) notFound();                       // a client that does not exist and one you may not see look the same
  const here = `/clients/${id}`;
  const o = v.overview; const fin = v.finance_summary ?? {};
  const divisions = await getDivisions();
  const supabase = await createClient();
  const { data: accounts } = await supabase.from('bank_accounts').select('id, name').eq('is_active', true);
  const { data: me } = await supabase.from('clients').select('owner_division_id').eq('id', id).maybeSingle();
  const instClient = (await call<Rec>('entity_resolve', { p_id: o.id })).data?.institutional_id as string | undefined;
  const mine = v.relationship?.divisions?.map((d: Rec) => d.code) ?? [];
  const links = instClient ?? '';

  return (
    <>
      <PageHead title={o.name} sub={`Client 360 · ${o.id}${instClient ? ` · ${instClient}` : ''}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <p style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap' }}>
        <Link className="primary" href={`/search?q=${encodeURIComponent('related:' + (instClient ?? o.id))}`}>Related records</Link>
        <a className="primary" href="#new-project">New project</a><a className="primary" href="#attach">Attach</a>
      </p>

      <div className="grid g4" style={{ marginBottom: '1rem' }}>
        {[['Invoiced', fin.invoiced], ['Paid', fin.paid], ['Outstanding', fin.outstanding], ['Overdue', fin.overdue]].map(([l, n]) => (
          <div className="stat" key={String(l)}><div className="n">{money(n as number, 'NAD')}</div><div className="l">{l}</div></div>
        ))}
      </div>
      <p className="muted small">Figures are derived from invoices and payments; nothing is stored on the client.</p>

      <Section title="Organization and relationship">
        <KV rows={[
          ['Organization', v.organization?.institutional_id ? <IdLink key="o" id={v.organization.institutional_id} /> : '—'],
          ['Status', <Badge key="s" v={o.status} />], ['Type', o.type], ['Classification', <Badge key="c" v={o.classification} />],
          ['Registration', o.registration_number], ['Email', o.email], ['Phone', o.phone], ['Owner', o.owner?.name],
          ['Divisions', (v.relationship?.divisions ?? []).map((d: Rec) => d.name).join(', ') || '—'],
          ['Created', fmtDateTime(o.created_at)],
        ]} />
        {divisions.some((d) => !mine.includes(d.key)) && (
          <form action={claimClientAction} className="row" style={{ gridTemplateColumns: '1fr auto', alignItems: 'end', marginTop: '.8rem' }}>
            <Return to={here} /><input type="hidden" name="client" value={id} />
            <label>Work with this client from another division (no new client is created)
              <select name="division">{divisions.filter((d) => !mine.includes(d.key)).map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
            <button className="primary" type="submit">Join</button>
          </form>
        )}
      </Section>

      <Section title="Contacts" count={v.contacts?.length}>
        <LinkTable rows={v.contacts} cols={[{ head: 'Name', render: (c) => <b>{c.name}</b> }, { head: 'Role', key: 'role' }, { head: 'Email', key: 'email' }, { head: 'Phone', key: 'phone' },
          { head: 'Flags', render: (c) => [c.primary && 'primary', c.billing && 'billing', !c.active && 'inactive'].filter(Boolean).join(', ') || '—' }]} />
        <details style={{ marginTop: '.7rem' }}><summary>Add a contact</summary>
          <form action={addContactAction} className="stack" style={{ marginTop: '.6rem' }}>
            <Return to={here} /><input type="hidden" name="client" value={id} />
            <div className="row"><label>Name<input name="name" required /></label><label>Role<input name="role" /></label></div>
            <div className="row"><label>Email<input name="email" type="email" /></label><label>Phone<input name="phone" /></label></div>
            <div className="row"><label><span><input type="checkbox" name="primary" style={{ width: 'auto' }} /> primary</span></label><label><span><input type="checkbox" name="billing" style={{ width: 'auto' }} /> billing</span></label></div>
            <button className="primary" type="submit">Add contact</button>
          </form>
          <div className="muted small">If a person with this email already exists in ADA, that same person is linked; no copy is made.</div>
        </details>
      </Section>

      <Section title="Projects" count={v.projects?.length} id="new-project">
        <LinkTable rows={v.projects} cols={[{ head: 'Project', render: (p) => <Link href={rid(p.id)}><b>{p.name}</b></Link> }, { head: 'ID', render: (p) => <span className="mono">{p.id}</span> }, { head: 'Status', render: (p) => <Status r={p} /> }, { head: 'Division', key: 'division' }, { head: 'Due', render: (p) => fmtDate(p.due_date) }]} />
        <details style={{ marginTop: '.7rem' }}><summary>Create a project</summary>
          <form action={createProjectAction} className="stack" style={{ marginTop: '.6rem' }}>
            <Return to={here} /><input type="hidden" name="client" value={id} />
            <label>Project name<input name="name" required /></label>
            <label>Lead division<select name="division" defaultValue={me?.owner_division_id ?? undefined}>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
            <label>Description<input name="description" /></label>
            <button className="primary" type="submit">Create project</button>
          </form>
        </details>
      </Section>

      <Section title="Quotes" count={v.quotes?.length}>
        <LinkTable rows={v.quotes} cols={[{ head: 'Quote', render: (q) => <Link href={rid(q.id)}><b>{q.title}</b></Link> }, { head: 'ID', render: (q) => <span className="mono">{q.id}</span> }, { head: 'Status', render: (q) => <Status r={q} /> }, { head: 'Total', render: (q) => money(q.total, q.currency) }, { head: 'Project', render: (q) => <IdLink id={q.project} /> }]} />
        <details style={{ marginTop: '.7rem' }}><summary>New quote</summary>
          <form action={createQuoteAction} className="stack" style={{ marginTop: '.6rem' }}>
            <Return to={here} /><input type="hidden" name="client" value={id} />
            <label>Title<input name="title" required /></label>
            <div className="row">
              <label>Division<select name="division" defaultValue={me?.owner_division_id ?? undefined}>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
              <label>Project (optional)<select name="project"><option value="">— none yet —</option>{(await projectOptions(id)).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
            </div>
            <button className="primary" type="submit">Create quote</button>
          </form>
        </details>
      </Section>

      <Section title="Contracts" count={v.contracts?.length}>
        <LinkTable rows={v.contracts} cols={[{ head: 'Contract', render: (c) => <Link href={rid(c.id)}><b>{c.title}</b></Link> }, { head: 'ID', render: (c) => <span className="mono">{c.id}</span> }, { head: 'Status', render: (c) => <Status r={c} /> }, { head: 'Total', render: (c) => money(c.total, c.currency) }, { head: 'Quote', render: (c) => <IdLink id={c.quote} /> }]} />
      </Section>

      <Section title="Invoices" count={v.invoices?.length}>
        <LinkTable rows={v.invoices} cols={[{ head: 'Invoice', render: (i) => <Link className="mono" href={rid(i.id)}>{i.id}</Link> }, { head: 'Status', render: (i) => <Status r={i} /> }, { head: 'Total', render: (i) => money(i.total, i.currency) }, { head: 'Paid', render: (i) => money(i.paid, i.currency) }, { head: 'Balance', render: (i) => money(i.balance, i.currency) }, { head: 'Due', render: (i) => fmtDate(i.due_date) }]} />
      </Section>

      <Section title="Payments" count={v.payments?.length}>
        <LinkTable rows={v.payments} cols={[{ head: 'Payment', render: (p) => <span className="mono">{p.id}</span> }, { head: 'Status', render: (p) => <Status r={p} /> }, { head: 'Amount', render: (p) => money(p.amount, p.currency) }, { head: 'Received', render: (p) => fmtDate(p.received_on) }, { head: 'Unallocated', render: (p) => money(p.credit, p.currency) }]} />
        {(accounts ?? []).length > 0 && (
          <details style={{ marginTop: '.7rem' }}><summary>Record a payment</summary>
            <form action={recordPaymentAction} className="stack" style={{ marginTop: '.6rem' }}>
              <Return to={here} /><input type="hidden" name="client" value={id} />
              <div className="row"><label>Amount<input name="amount" type="number" step="0.01" min="0.01" required /></label>
                <label>Received into<select name="account">{(accounts ?? []).map((a: any) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label></div>
              <div className="row"><label>Method<select name="method">{['bank_transfer', 'card', 'cash', 'cheque', 'mobile_money', 'other'].map((m) => <option key={m}>{m}</option>)}</select></label>
                <label>Allocate to invoice (optional)<select name="invoice"><option value="">— allocate later —</option>{(await invoiceOptions(id)).map((i) => <option key={i.id} value={i.id}>{i.ada_id}</option>)}</select></label></div>
              <label>Reference<input name="reference" /></label>
              <button className="primary" type="submit">Record payment</button>
            </form>
          </details>
        )}
      </Section>

      <Section title="Services purchased" count={v.relationship?.services_purchased?.length}>
        <LinkTable rows={v.relationship?.services_purchased ?? []} cols={[{ head: 'Service', render: (s) => <b>{s.service}</b> }, { head: 'Division', key: 'division' }, { head: 'Qty', key: 'quantity' }, { head: 'Spent', render: (s) => money(s.spent, s.currency) }]} />
      </Section>

      <div className="grid g2">
        <Section title="Assets" count={v.assets?.length}><LinkTable rows={v.assets} cols={[{ head: 'Asset', render: (a) => <Link href={rid(a.id)}><b>{a.name}</b></Link> }, { head: 'Status', render: (a) => <Status r={a} /> }, { head: 'Project', render: (a) => <IdLink id={a.project} /> }]} /></Section>
        <Section title="Tickets" count={v.tickets?.length}><LinkTable rows={v.tickets} cols={[{ head: 'Ticket', render: (t) => <Link href={rid(t.id)}><b>{t.title}</b></Link> }, { head: 'Status', render: (t) => <Status r={t} /> }, { head: 'Priority', key: 'priority' }]} /></Section>
        <Section title="Documents" count={v.documents?.length}><LinkTable rows={v.documents} cols={[{ head: 'Document', render: (d) => <Link href={rid(d.document)}><b>{d.title}</b></Link> }, { head: 'Type', key: 'type' }, { head: 'Status', render: (d) => <Status r={d} /> }]} /></Section>
        <Section title="Communications (metadata only)" count={v.communications?.length}><LinkTable rows={v.communications} cols={[{ head: 'Thread', render: (c) => <Link className="mono" href={rid(c.thread)}>{c.thread}</Link> }, { head: 'Status', render: (c) => <Status r={c} /> }, { head: 'Messages', key: 'messages' }, { head: 'Last', render: (c) => fmtDate(c.last_occurred) }]} /></Section>
        <Section title="Domains" count={v.domains?.length}><LinkTable rows={v.domains} cols={[{ head: 'Domain', render: (d) => <Link href={rid(d.domain)}><b>{d.name}</b></Link> }, { head: 'Status', render: (d) => <Status r={d} /> }, { head: 'Expires', render: (d) => fmtDate(d.expires_on) }]} /></Section>
      </div>

      <AttachPanel divisions={divisions} returnTo={here} clientId={id} links={links} defaultDivision={me?.owner_division_id} />

      <Section title="History" count={v.activity?.length}>
        <div className="muted small" style={{ marginBottom: '.5rem' }}>Recent audited changes to the client, its contacts and divisions. Each module keeps its own further history (contract trail, ticket events, asset history, document and communication events).</div>
        <LinkTable rows={(v.activity ?? []).map((a: Rec, i: number) => ({ ...a, id: i }))} cols={[{ head: 'When', render: (a) => fmtDateTime(a.at) }, { head: 'Action', key: 'action' }, { head: 'Record', render: (a) => `${a.table} ${a.record ?? ''}` }, { head: 'Changed', render: (a) => (a.changed ?? []).join(', ') }]} />
      </Section>
    </>
  );
}

async function projectOptions(clientId: string) {
  const supabase = await createClient();
  const { data } = await supabase.from('projects').select('id, name').eq('client_id', clientId).is('deleted_at', null).order('created_at');
  return (data ?? []) as { id: string; name: string }[];
}
async function invoiceOptions(clientId: string) {
  const supabase = await createClient();
  const { data } = await supabase.from('invoices').select('id, ada_id').eq('client_id', clientId).in('status', ['issued', 'partially_paid']).order('created_at');
  return (data ?? []) as { id: string; ada_id: string }[];
}
