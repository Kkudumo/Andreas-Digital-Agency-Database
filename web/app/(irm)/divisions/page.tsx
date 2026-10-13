import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Empty, PageHead } from '@/components/ui';

export default async function DivisionsPage() {
  await requireAccess();
  const supabase = await createClient();
  const { data } = await supabase.from('divisions').select('id, key, name, description, sort_order').order('sort_order');
  const rows = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Divisions" sub="Pick a division to work on its services, prices, projects, clients, team and documents in one place." />
      {rows.length === 0 ? <section className="card"><Empty>No divisions visible to you.</Empty></section> : (
        <div className="div-grid">
          {rows.map((d) => (
            <Link key={d.id} href={`/divisions/${d.key}`} className="div-tile" data-division={d.key}>
              <strong>{d.name}</strong><small>{d.description ?? 'Division workspace'}</small><span className="open">Open →</span>
            </Link>
          ))}
        </div>
      )}
    </>
  );
}
