import Link from 'next/link';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';

export default async function ClientsPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('clients').select('id, ada_id, name, status, client_type, classification, owner:divisions!owner_division_id(name)').is('deleted_at', null).order('name').limit(300);
  const rows = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Clients" sub="Find a client with Search; this lists the ones you may see" action={canAnywhere(access, 'clients.create') ? { href: '/clients/new', label: 'New client' } : null} />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        {rows.length === 0 ? <Empty>No clients visible to you.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ADA ID</th><th>Client</th><th>Type</th><th>Status</th><th>Originating division</th></tr></thead>
            <tbody>{rows.map((c) => (
              <tr key={c.id}><td className="mono">{c.ada_id}</td><td><Link href={`/clients/${c.id}`}><b>{c.name}</b></Link></td><td>{c.client_type}</td><td><Badge v={c.status} /></td><td>{c.owner?.name ?? '—'}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
