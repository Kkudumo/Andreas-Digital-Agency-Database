import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';

export default async function ProjectsPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('projects').select('id, ada_id, name, status, priority, client:clients(id, name), division:divisions!lead_division_id(name)').is('deleted_at', null).order('created_at', { ascending: false }).limit(300);
  const rows = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Projects" sub="Create projects from a client page; find any project with Search" />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        {rows.length === 0 ? <Empty>No projects visible to you.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ADA ID</th><th>Project</th><th>Client</th><th>Lead division</th><th>Status</th></tr></thead>
            <tbody>{rows.map((p) => (
              <tr key={p.id}><td className="mono">{p.ada_id}</td><td><Link href={`/projects/${p.id}`}><b>{p.name}</b></Link></td>
                <td>{p.client ? <Link href={`/clients/${p.client.id}`}>{p.client.name}</Link> : '—'}</td><td>{p.division?.name ?? '—'}</td><td><Badge v={p.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
