import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Empty, Flash, PageHead } from '@/components/ui';

// Step 1: choose a division. Its services, add-ons and prices are on the next page.
export default async function ServicesIndex({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const [{ data: divs }, { data: svc }] = await Promise.all([
    supabase.from('divisions').select('id, key, name, description').eq('is_active', true).eq('kind', 'service').order('sort_order'),
    supabase.from('services').select('division_id, status').is('deleted_at', null).limit(2000),
  ]);
  const count = (id: string, status?: string) => (svc ?? []).filter((s: any) => s.division_id === id && (!status || s.status === status)).length;
  const rows = (divs ?? []) as any[];
  return (
    <>
      <PageHead title="Services" sub="Everything each division sells: services, packages, plans and add-ons, with their prices" />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        {rows.length === 0 ? <Empty>No divisions visible to you.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Division</th><th>Services</th><th>Published</th><th>Drafts</th></tr></thead>
            <tbody>{rows.map((d) => (
              <tr key={d.id}>
                <td><Link href={`/services/${d.key}`}><b>{d.name}</b></Link><div className="muted small">{d.description}</div></td>
                <td>{count(d.id)}</td><td>{count(d.id, 'published')}</td><td>{count(d.id, 'draft')}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
