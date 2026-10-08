import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';

export default async function StaffPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess();
  const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase
    .from('staff')
    .select('id, ada_id, full_name, email, work_phone, employment_status, account_status, position:positions(title), division:divisions!primary_division_id(name)')
    .is('deleted_at', null).order('full_name');
  const staff = (data ?? []) as any[];

  // Role assignments are only visible to people who may view the access model.
  const roleMap = new Map<string, string[]>();
  if (can(access, 'roles.view')) {
    const { data: sr } = await supabase.from('staff_roles').select('staff_id, role:roles(name), division:divisions(name)');
    for (const r of (sr ?? []) as any[]) {
      const arr = roleMap.get(r.staff_id) ?? [];
      arr.push(`${r.role?.name}${r.division ? ` (${r.division.name})` : ''}`);
      roleMap.set(r.staff_id, arr);
    }
  }
  const showRoles = can(access, 'roles.view');

  return (
    <>
      <PageHead title="Staff" sub="ADA staff directory" action={can(access, 'staff.create') ? { href: '/staff/new', label: 'Add staff' } : null} />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        {staff.length === 0 ? <Empty>No staff records.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ADA ID</th><th>Name</th><th>Position</th><th>Division</th><th>Employment</th><th>Account</th>{showRoles && <th>Roles</th>}</tr></thead>
            <tbody>
              {staff.map((s) => (
                <tr key={s.id}>
                  <td className="mono">{s.ada_id}</td>
                  <td><b>{s.full_name}</b><div className="muted small">{s.email}{s.work_phone ? ` · ${s.work_phone}` : ''}</div></td>
                  <td>{s.position?.title ?? '—'}</td>
                  <td>{s.division?.name ?? '—'}</td>
                  <td><Badge v={s.employment_status} /></td>
                  <td><Badge v={s.account_status} /></td>
                  {showRoles && <td className="small">{(roleMap.get(s.id) ?? []).join(', ') || <span className="muted">none</span>}</td>}
                </tr>
              ))}
            </tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
