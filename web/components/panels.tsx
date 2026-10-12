import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { Badge } from '@/components/ui';
import { rid, type Rec } from '@/lib/db';
import {
  registerDocumentAction, startCommunicationAction, createTicketAction, createAssetAction,
} from '@/app/(irm)/actions';

export type Division = { id: string; key: string; name: string };

export async function getDivisions(): Promise<Division[]> {
  const supabase = await createClient();
  const { data } = await supabase.from('divisions').select('id, key, name').eq('is_active', true).order('sort_order');
  return (data ?? []) as Division[];
}

/** Catalogue services with the CURRENTLY approved price (read from the immutable price versions). */
export async function getCatalogue(): Promise<{ id: string; name: string; division_id: string; price: number | null; currency: string | null }[]> {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const [{ data: svc }, { data: prices }] = await Promise.all([
    supabase.from('services').select('id, name, division_id').eq('is_active', true).is('deleted_at', null).order('name'),
    supabase.from('service_prices').select('service_id, amount, currency, effective_from, effective_to').eq('status', 'approved').lte('effective_from', today).order('effective_from', { ascending: false }),
  ]);
  return ((svc ?? []) as any[]).map((s) => {
    const p = ((prices ?? []) as any[]).find((x) => x.service_id === s.id && (!x.effective_to || x.effective_to >= today));
    return { id: s.id, name: s.name, division_id: s.division_id, price: p ? Number(p.amount) : null, currency: p?.currency ?? null };
  });
}

export function Section({ title, count, children, id }: { title: string; count?: number; children: React.ReactNode; id?: string }) {
  return (
    <section className="card" id={id}>
      <h2>{title}{count !== undefined && <span className="muted small"> · {count}</span>}</h2>
      {children}
    </section>
  );
}

export function KV({ rows }: { rows: [string, React.ReactNode][] }) {
  return <dl className="kv">{rows.map(([k, v]) => <div key={k} style={{ display: 'contents' }}><dt>{k}</dt><dd>{v ?? '—'}</dd></div>)}</dl>;
}

export function Return({ to }: { to: string }) { return <input type="hidden" name="return" value={to} />; }

/** One button per allowed next status; the database refuses the ones the user or the state does not allow. */
export function Transitions({ action, field, id, options, returnTo, label = 'Move to' }: {
  action: (fd: FormData) => Promise<void>; field: string; id: string; options: string[]; returnTo: string; label?: string;
}) {
  if (options.length === 0) return null;
  return (
    <form action={action} className="row" style={{ gridTemplateColumns: '1fr 1fr auto', alignItems: 'end' }}>
      <Return to={returnTo} />
      <input type="hidden" name={field} value={id} />
      <label>{label}<select name="to">{options.map((o) => <option key={o} value={o}>{o.replace(/_/g, ' ')}</option>)}</select></label>
      <label>Note (optional)<input name="note" /></label>
      <button className="primary" type="submit">Apply</button>
    </form>
  );
}

/** Related records of one kind as a table of links; every row opens through the resolver, so authorization is the database's. */
export function LinkTable({ rows, cols }: { rows: Rec[]; cols: { head: string; key?: string; render?: (r: Rec) => React.ReactNode }[] }) {
  if (!rows || rows.length === 0) return <div className="muted small">None visible to you.</div>;
  return (
    <div className="scroll"><table>
      <thead><tr>{cols.map((c) => <th key={c.head}>{c.head}</th>)}</tr></thead>
      <tbody>{rows.map((r, i) => (
        <tr key={r.id ?? i}>{cols.map((c) => <td key={c.head}>{c.render ? c.render(r) : (r[c.key!] ?? '—')}</td>)}</tr>
      ))}</tbody>
    </table></div>
  );
}
export const IdLink = ({ id }: { id?: string | null }) => id ? <Link className="mono" href={rid(id)}>{id}</Link> : <>—</>;
export const Status = ({ r }: { r: Rec }) => <Badge v={r.status} />;

/** The four things a client or project can have attached, each through its own module's controlled operation. */
export function AttachPanel({ divisions, returnTo, clientId, projectId, links, defaultDivision }: {
  divisions: Division[]; returnTo: string; clientId?: string | null; projectId?: string | null; links: string; defaultDivision?: string | null;
}) {
  const divSelect = (
    <label>Division<select name="division" defaultValue={defaultDivision ?? undefined}>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
  );
  return (
    <Section title="Attach to this record" id="attach">
      <div className="muted small" style={{ marginBottom: '.6rem' }}>Each form calls the owning module (documents, communications, tickets, assets). Nothing here is stored on the client or project.</div>
      <details><summary>Register a document</summary>
        <form action={registerDocumentAction} className="stack" style={{ marginTop: '.6rem' }}>
          <Return to={returnTo} /><input type="hidden" name="links" value={links} />
          <label>Title<input name="title" required /></label>
          <div className="row">
            <label>Type<select name="type" defaultValue="report">{['report', 'proposal', 'requirements', 'contract', 'correspondence', 'deliverable', 'minutes', 'other'].map((t) => <option key={t}>{t}</option>)}</select></label>
            {divSelect}
          </div>
          <label>Description<input name="description" /></label>
          <button className="primary" type="submit">Register and link</button>
        </form>
      </details>
      <details style={{ marginTop: '.5rem' }}><summary>Record a communication</summary>
        <form action={startCommunicationAction} className="stack" style={{ marginTop: '.6rem' }}>
          <Return to={returnTo} /><input type="hidden" name="links" value={links} />
          <label>Subject<input name="subject" required /></label>
          <div className="row">
            <label>Type<select name="type">{['email', 'phone_call', 'meeting', 'video_call', 'sms', 'instant_message', 'letter', 'other'].map((t) => <option key={t}>{t}</option>)}</select></label>
            <label>Direction<select name="direction">{['inbound', 'outbound', 'internal', 'mutual'].map((t) => <option key={t}>{t}</option>)}</select></label>
          </div>
          {divSelect}
          <label>Message (kept as the record; not shown on client or project pages)<textarea name="body" rows={3} /></label>
          <button className="primary" type="submit">Record and link</button>
        </form>
      </details>
      <details style={{ marginTop: '.5rem' }}><summary>Raise a ticket</summary>
        <form action={createTicketAction} className="stack" style={{ marginTop: '.6rem' }}>
          <Return to={returnTo} />
          {clientId && <input type="hidden" name="client" value={clientId} />}
          {projectId && <input type="hidden" name="project" value={projectId} />}
          <label>Title<input name="title" required /></label>
          <label>Description<textarea name="description" rows={2} /></label>
          {divSelect}
          <button className="primary" type="submit">Raise ticket</button>
        </form>
      </details>
      <details style={{ marginTop: '.5rem' }}><summary>Register an asset for this {projectId ? 'project' : 'client'}</summary>
        <form action={createAssetAction} className="stack" style={{ marginTop: '.6rem' }}>
          <Return to={returnTo} />
          {clientId && <input type="hidden" name="client" value={clientId} />}
          {projectId && <input type="hidden" name="project" value={projectId} />}
          <label>Name<input name="name" required /></label>
          <div className="row">
            <label>Category<select name="category" defaultValue="server">{['laptop', 'desktop', 'server', 'network', 'mobile', 'peripheral', 'camera', 'storage', 'software_license', 'other'].map((t) => <option key={t}>{t}</option>)}</select></label>
            <label>Serial number<input name="serial" /></label>
          </div>
          {divSelect}
          <button className="primary" type="submit">Register asset</button>
        </form>
      </details>
    </Section>
  );
}
