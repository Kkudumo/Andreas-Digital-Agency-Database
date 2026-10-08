import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, PageHead } from '@/components/ui';

export default async function OrganizationPage() {
  await requireAccess();
  const supabase = await createClient();
  const [org, divisions, positions, staff] = await Promise.all([
    supabase.from('organization').select('*').maybeSingle(),
    supabase.from('divisions').select('id, ada_id, key, name, kind, description, is_active').order('sort_order'),
    supabase.from('positions').select('id, title, division:divisions(name)').order('title'),
    supabase.from('staff').select('primary_division_id').is('deleted_at', null),
  ]);
  const counts = new Map<string, number>();
  for (const s of (staff.data ?? []) as any[]) if (s.primary_division_id) counts.set(s.primary_division_id, (counts.get(s.primary_division_id) ?? 0) + 1);
  const o = org.data as any;

  return (
    <>
      <PageHead title="Organization" sub="Andreas Digital Agency — structure and divisions" />
      {o && (
        <section className="card">
          <h2>{o.legal_name} <span className="mono muted">{o.ada_id}</span></h2>
          <p className="muted" style={{ marginTop: 0 }}>{o.description}</p>
        </section>
      )}
      <section className="card">
        <h2>Divisions</h2>
        <div className="scroll"><table>
          <thead><tr><th>ADA ID</th><th>Division</th><th>Type</th><th>Staff</th><th>Purpose</th></tr></thead>
          <tbody>
            {((divisions.data ?? []) as any[]).map((d) => (
              <tr key={d.id}>
                <td className="mono">{d.ada_id}</td>
                <td><b>{d.name}</b> {!d.is_active && <Badge v="disabled" />}</td>
                <td><Badge v={d.kind} /></td>
                <td>{counts.get(d.id) ?? 0}</td>
                <td className="muted">{d.description}</td>
              </tr>
            ))}
          </tbody>
        </table></div>
      </section>
      <section className="card">
        <h2>Positions</h2>
        <div className="scroll"><table>
          <thead><tr><th>Position</th><th>Division</th></tr></thead>
          <tbody>{((positions.data ?? []) as any[]).map((p) => <tr key={p.id}><td>{p.title}</td><td className="muted">{p.division?.name ?? '—'}</td></tr>)}</tbody>
        </table></div>
      </section>
    </>
  );
}
