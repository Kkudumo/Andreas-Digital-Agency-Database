import Link from 'next/link';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Empty, PageHead } from '@/components/ui';
import { fmtDateTime } from '@/lib/format';
import { rid } from '@/lib/db';

export default async function AuditPage({ searchParams }: { searchParams: Promise<{ table?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  if (!can(access, 'audit.view')) return <><PageHead title="Audit log" /><div className="flash error" role="alert">You do not have permission to read the audit log.</div></>;
  const supabase = await createClient();
  let query = supabase.from('audit_log').select('id, occurred_at, actor_ada_id, action, table_name, record_ada_id, changed_fields').order('id', { ascending: false }).limit(200);
  if (sp.table && /^[a-z_]+$/.test(sp.table)) query = query.eq('table_name', sp.table);
  const { data } = await query; const rows = (data ?? []) as any[];
  const tables = [...new Set(rows.map((r) => r.table_name))].sort();
  return (
    <>
      <PageHead title="Audit log" sub="Who changed what, and when. Written only by the database; it cannot be edited or deleted. The latest 200 entries." />
      <p className="small">Filter: <Link href="/audit">all</Link>{sp.table ? '' : tables.map((t) => <span key={t}> · <Link href={`/audit?table=${t}`}>{t}</Link></span>)}{sp.table ? <> · showing <b>{sp.table}</b></> : null}</p>
      <section className="card">
        {rows.length === 0 ? <Empty>No entries.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>When</th><th>Who</th><th>Action</th><th>Record type</th><th>Record</th><th>Changed</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id}><td className="muted">{fmtDateTime(r.occurred_at)}</td><td className="mono">{r.actor_ada_id ?? 'system'}</td><td>{r.action}</td><td>{r.table_name}</td>
                <td className="mono">{r.record_ada_id ? <Link href={rid(r.record_ada_id)}>{r.record_ada_id}</Link> : '—'}</td><td className="muted small">{Array.isArray(r.changed_fields) ? r.changed_fields.join(', ') : ''}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
