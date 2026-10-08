import Link from 'next/link';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { fmtDate, fmtDateTime, label } from '@/lib/format';
import { Badge, Empty, PageHead } from '@/components/ui';

export default async function Dashboard() {
  const access = await requireAccess();
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const soon = new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10);

  const showClients = canAnywhere(access, 'clients.view');
  const showProjects = canAnywhere(access, 'projects.view');

  const [clients, activeProjects, myTasks, dueSoon, audit] = await Promise.all([
    showClients ? supabase.from('clients').select('id', { count: 'exact', head: true }).neq('status', 'archived') : null,
    showProjects ? supabase.from('projects').select('id', { count: 'exact', head: true }).eq('status', 'active') : null,
    showProjects
      ? supabase.from('tasks').select('id, ada_id, title, status, priority, due_date, project:projects(id, name)')
          .eq('assignee_id', access.staff.id).in('status', ['todo', 'in_progress', 'blocked']).order('due_date', { nullsFirst: false }).limit(8)
      : null,
    showProjects
      ? supabase.from('projects').select('id, ada_id, name, status, due_date, client:clients(name)')
          .in('status', ['proposed', 'approved', 'active', 'on_hold']).lte('due_date', soon).order('due_date').limit(6)
      : null,
    can(access, 'audit.view')
      ? supabase.from('audit_log').select('id, occurred_at, actor_ada_id, action, table_name, record_ada_id').order('id', { ascending: false }).limit(8)
      : null,
  ]);

  const tasks = (myTasks?.data ?? []) as any[];
  const overdue = tasks.filter((t) => t.due_date && t.due_date < today).length;

  return (
    <>
      <PageHead title={`Welcome, ${access.staff.full_name.split(' ')[0]}`}
        sub={`${access.staff.position ?? 'ADA'}${access.staff.division_name ? ' · ' + access.staff.division_name : ''}`} />

      <div className="grid g4" style={{ marginBottom: '1.1rem' }}>
        {showClients && <div className="stat"><div className="n">{clients?.count ?? 0}</div><div className="l">Clients you can see</div></div>}
        {showProjects && <div className="stat"><div className="n">{activeProjects?.count ?? 0}</div><div className="l">Active projects</div></div>}
        {showProjects && <div className="stat"><div className="n">{tasks.length}</div><div className="l">Your open tasks</div></div>}
        {showProjects && <div className="stat"><div className="n" style={{ color: overdue ? 'var(--danger)' : undefined }}>{overdue}</div><div className="l">Overdue for you</div></div>}
      </div>

      <div className="grid g2">
        <section className="card">
          <h2>Needs your attention</h2>
          {tasks.length === 0 ? <Empty>No open tasks assigned to you.</Empty> : (
            <table><tbody>
              {tasks.map((t) => (
                <tr key={t.id}>
                  <td><Link href={`/projects/${t.project?.id}`}>{t.title}</Link><div className="muted small">{t.project?.name}</div></td>
                  <td><Badge v={t.status} /></td>
                  <td style={{ color: t.due_date && t.due_date < today ? 'var(--danger)' : undefined }}>{fmtDate(t.due_date)}</td>
                </tr>
              ))}
            </tbody></table>
          )}
        </section>

        {showProjects && (
          <section className="card">
            <h2>Projects due in the next 14 days</h2>
            {((dueSoon?.data ?? []) as any[]).length === 0 ? <Empty>Nothing due soon.</Empty> : (
              <table><tbody>
                {((dueSoon?.data ?? []) as any[]).map((p) => (
                  <tr key={p.id}>
                    <td><Link href={`/projects/${p.id}`}>{p.name}</Link><div className="muted small">{p.client?.name}</div></td>
                    <td><Badge v={p.status} /></td>
                    <td>{fmtDate(p.due_date)}</td>
                  </tr>
                ))}
              </tbody></table>
            )}
          </section>
        )}

        <section className="card">
          <h2>Your access</h2>
          <p className="muted small" style={{ marginTop: 0 }}>This is the part of ADA your roles authorise you to operate.</p>
          <table><tbody>
            {access.roles.map((r, i) => (
              <tr key={i}><td>{r.name}</td><td className="muted">{r.division_name ? `Scoped to ${r.division_name}` : 'Organization-wide'}</td></tr>
            ))}
          </tbody></table>
        </section>

        {audit && (
          <section className="card">
            <h2>Recent activity</h2>
            <table><tbody>
              {((audit.data ?? []) as any[]).map((a) => (
                <tr key={a.id}>
                  <td className="small">{fmtDateTime(a.occurred_at)}</td>
                  <td>{a.action} <span className="muted">{label(a.table_name)}</span></td>
                  <td className="mono small">{a.record_ada_id ?? ''}</td>
                </tr>
              ))}
            </tbody></table>
            <p className="small" style={{ marginBottom: 0 }}><Link href="/audit">Open audit log →</Link></p>
          </section>
        )}
      </div>
    </>
  );
}
