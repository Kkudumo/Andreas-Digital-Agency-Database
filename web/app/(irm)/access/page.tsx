import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Empty, PageHead } from '@/components/ui';

export default async function AccessPage() {
  const access = await requireAccess();
  if (!can(access, 'roles.view')) return <><PageHead title="Access control" /><div className="flash error" role="alert">You do not have permission to view roles.</div></>;
  const supabase = await createClient();
  const [{ data: roles }, { data: grants }, { data: perms }, { data: assigned }] = await Promise.all([
    supabase.from('roles').select('id, key, name, description').order('name'),
    supabase.from('role_permissions').select('role_id, permission_id'),
    supabase.from('permissions').select('id, key'),
    supabase.from('staff_roles').select('role_id, division:divisions(name), staff:staff(full_name, email, account_status)'),
  ]);
  const permKey = new Map(((perms ?? []) as any[]).map((p) => [p.id, p.key as string]));
  const byRole = new Map<string, string[]>();
  for (const g of (grants ?? []) as any[]) (byRole.get(g.role_id) ?? byRole.set(g.role_id, []).get(g.role_id)!).push(permKey.get(g.permission_id) ?? '');
  const people = new Map<string, any[]>();
  for (const a of (assigned ?? []) as any[]) (people.get(a.role_id) ?? people.set(a.role_id, []).get(a.role_id)!).push(a);
  const list = (roles ?? []) as any[];
  return (
    <>
      <PageHead title="Access control" sub="Who holds which role, and what each role may do. Roles are changed through reviewed database changes, not here." />
      {list.length === 0 ? <section className="card"><Empty>No roles visible.</Empty></section> : list.map((r) => {
        const keys = (byRole.get(r.id) ?? []).filter(Boolean).sort(); const modules = new Map<string, string[]>();
        for (const k of keys) { const [m, a] = k.split('.'); (modules.get(m) ?? modules.set(m, []).get(m)!).push(a); }
        const who = people.get(r.id) ?? [];
        return (
          <section className="card" key={r.id} data-role={r.key}>
            <h2>{r.name} <span className="muted small mono">{r.key}</span></h2>
            {r.description && <p className="muted">{r.description}</p>}
            <p><b>People:</b> {who.length === 0 ? <span className="muted">nobody yet</span> : who.map((w, i) => <span key={i}>{i ? ', ' : ''}{w.staff?.full_name ?? '—'}{w.division?.name ? ` (${w.division.name})` : ' (organization-wide)'}{w.staff?.account_status && w.staff.account_status !== 'active' ? ` [${w.staff.account_status}]` : ''}</span>)}</p>
            <details><summary><b>{keys.length}</b> permissions across {modules.size} areas</summary>
              <div className="scroll"><table><tbody>{[...modules].map(([m, acts]) => <tr key={m}><td><b>{m.replace(/_/g, ' ')}</b></td><td>{acts.join(', ')}</td></tr>)}</tbody></table></div>
            </details>
          </section>
        );
      })}
    </>
  );
}
