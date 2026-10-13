import Link from 'next/link';
import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';

export default async function DocumentsPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('documents')
    .select('id, title, status, effective_classification, created_at, updated_at, document_type:document_types(name), division:divisions!division_id(name)')
    .neq('status', 'disposed').order('updated_at', { ascending: false }).limit(200);
  const rows = (data ?? []) as any[];
  const ids = rows.map((r) => r.id);
  const reg = ids.length ? ((await supabase.from('entity_registry').select('entity_id, institutional_id').eq('table_name', 'documents').in('entity_id', ids)).data ?? []) : [];
  const inst = new Map(reg.map((r: any) => [r.entity_id, r.institutional_id]));
  const canCreate = canAnywhere(access, 'documents.create');
  return (
    <>
      <PageHead title="Documents" sub="Word documents, Excel spreadsheets and PDFs: open, edit in the browser, and keep every version" action={canCreate ? { href: '/documents/new', label: 'New document' } : null} />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        {rows.length === 0 ? <Empty>No documents yet. {canCreate ? <>Create one with <Link href="/documents/new">New document</Link>.</> : 'None are visible to you.'}</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ID</th><th>Title</th><th>Type</th><th>Division</th><th>Status</th><th>Updated</th></tr></thead>
            <tbody>{rows.map((d) => (
              <tr key={d.id}><td className="mono">{inst.get(d.id) ?? '—'}</td><td><Link href={`/documents/${d.id}`}><b>{d.title}</b></Link>{d.effective_classification !== 'internal' && <> <Badge v={d.effective_classification} /></>}</td>
                <td>{d.document_type?.name ?? '—'}</td><td>{d.division?.name ?? '—'}</td><td><Badge v={d.status} /></td><td className="muted">{new Date(d.updated_at).toLocaleDateString('en-GB')}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
