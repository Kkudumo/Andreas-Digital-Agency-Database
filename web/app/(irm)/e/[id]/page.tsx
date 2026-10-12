import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess } from '@/lib/access';
import { call, rid, type Rec } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, Return, Section } from '@/components/panels';
import { ticketTransitionAction, ticketCommentAction, assignAssetAction } from '../../actions';
import { fmtDateTime } from '@/lib/format';

const SKIP = new Set(['id', 'created_by', 'deleted_at', 'deleted_by', 'deletion_reason', 'client_deleted']);
const show = (v: unknown) => v === null || v === undefined || v === '' ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v);

// The generic record page: identity from the registry, fields from the authoritative table under the caller's own row-level security.
export default async function EntityPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const { data: ent } = await call<Rec>('entity_resolve', { p_id: decodeURIComponent(id) });
  if (!ent?.authoritative_domain) notFound();
  const supabase = await createClient();
  const { data: row } = await supabase.from(ent.authoritative_domain).select('*').eq('id', ent.authoritative_record_key).maybeSingle();
  if (!row) notFound();
  const here = `/e/${ent.institutional_id}`;
  const type = String(ent.entity_type);

  let projects: Rec[] = [];
  if (type === 'asset') {
    const { data } = await supabase.from('projects').select('id, ada_id, name').is('deleted_at', null).order('name').limit(200);
    projects = (data ?? []) as Rec[];
  }
  let comments: Rec[] = [];
  if (type === 'ticket') {
    const { data } = await supabase.from('ticket_comments').select('body, created_at, is_internal').eq('ticket_id', row.id).order('created_at');
    comments = (data ?? []) as Rec[];
  }

  return (
    <>
      <PageHead title={row.title ?? row.name ?? row.subject ?? ent.legacy_identifier ?? ent.institutional_id} sub={`${type.replace(/_/g, ' ')} · ${ent.institutional_id}${ent.legacy_identifier ? ` · ${ent.legacy_identifier}` : ''}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <p><Link className="primary" href={`/search?q=${encodeURIComponent('related:' + ent.institutional_id)}`}>Related records</Link></p>
      <Section title="Identity">
        <KV rows={[['Institutional ID', <span className="mono" key="i">{ent.institutional_id}</span>], ['Type', type], ['Status', <Badge key="s" v={ent.status} />], ['Classification', <Badge key="c" v={ent.classification} />],
          ['Origin', `${ent.origin?.kind ?? '—'} ${ent.origin?.year ?? ''}`]]} />
      </Section>
      <Section title="Record">
        <KV rows={Object.entries(row).filter(([k, v]) => !SKIP.has(k) && v !== null && v !== '').map(([k, v]): [string, React.ReactNode] => {
          if (k === 'created_at' || k === 'updated_at') return [k.replace(/_/g, ' '), fmtDateTime(String(v))];
          return [k.replace(/_/g, ' '), show(v)];
        })} />
      </Section>

      {type === 'ticket' && (
        <Section title="Work this ticket">
          <form action={ticketTransitionAction} className="row" style={{ gridTemplateColumns: '1fr 1fr auto', alignItems: 'end' }}>
            <Return to={here} /><input type="hidden" name="ticket" value={row.id} />
            <label>Move to<select name="to">{['open', 'in_progress', 'waiting', 'resolved', 'closed', 'cancelled'].map((s) => <option key={s}>{s}</option>)}</select></label>
            <label>Note<input name="note" /></label><button className="primary" type="submit">Apply</button>
          </form>
          <h2 style={{ marginTop: '1rem' }}>Comments</h2>
          {comments.length === 0 ? <div className="muted small">No comments visible to you.</div> : comments.map((c, i) => <p key={i}><span className="muted small">{fmtDateTime(c.created_at)}{c.is_internal ? ' · internal' : ''}</span><br />{c.body}</p>)}
          <form action={ticketCommentAction} className="stack"><Return to={here} /><input type="hidden" name="ticket" value={row.id} />
            <label>Add a comment<textarea name="body" rows={2} required /></label><button className="primary" type="submit">Comment</button></form>
        </Section>
      )}
      {type === 'asset' && (
        <Section title="Assign to a project">
          <form action={assignAssetAction} className="row" style={{ gridTemplateColumns: '1fr 1fr auto', alignItems: 'end' }}>
            <Return to={here} /><input type="hidden" name="asset" value={row.id} />
            <label>Project<select name="project">{projects.map((p) => <option key={p.id} value={p.id}>{p.name} ({p.ada_id})</option>)}</select></label>
            <label>Note<input name="note" /></label><button className="primary" type="submit">Assign</button>
          </form>
          <div className="muted small">The asset keeps its permanent institutional ID whichever project, division or person it is assigned to.</div>
        </Section>
      )}
      {(row.client_id || row.project_id) && (
        <Section title="Linked records">
          <KV rows={[
            ['Client', row.client_id ? <Link key="c" href={`/clients/${row.client_id}`}>open client</Link> : '—'],
            ['Project', row.project_id ? <Link key="p" href={`/projects/${row.project_id}`}>open project</Link> : '—'],
          ]} />
        </Section>
      )}
    </>
  );
}
