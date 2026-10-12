import Link from 'next/link';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { call, money, type Rec } from '@/lib/db';
import { fmtDate, fmtDateTime, label } from '@/lib/format';
import { Badge, Empty, PageHead } from '@/components/ui';


type MoneyRow = { currency: string; value: number | string; count?: number; status?: string };
/** One line per currency; money in different currencies is never added together. */
const Money = ({ rows }: { rows?: MoneyRow[] }) => (!rows || rows.length === 0)
  ? <>—</> : <>{rows.map((r, i) => <span key={r.currency} style={{ display: 'block' }}>{money(r.value, r.currency)}{r.count !== undefined && <span className="muted small"> · {r.count}</span>}</span>)}</>;
const sum = (o?: Record<string, number>) => Object.values(o ?? {}).reduce((a, b) => a + Number(b), 0);
const Tile = ({ n, l, href, tone }: { n: React.ReactNode; l: string; href?: string; tone?: 'bad' | 'warn' }) => {
  const body = <><div className="n" style={{ color: tone === 'bad' ? 'var(--danger)' : tone === 'warn' ? 'var(--warn)' : undefined }}>{n}</div><div className="l">{l}</div></>;
  return href ? <Link className="stat" href={href} style={{ color: 'inherit', textDecoration: 'none', display: 'block' }}>{body}</Link> : <div className="stat">{body}</div>;
};
const Bar = ({ pct }: { pct: number }) => (
  <div aria-hidden="true" style={{ background: 'var(--line)', borderRadius: 4, height: 6, minWidth: 80 }}><div style={{ width: `${Math.max(2, Math.min(100, pct))}%`, background: 'var(--accent)', borderRadius: 4, height: 6 }} /></div>
);
const Row = ({ k, children, to }: { k: string; children: React.ReactNode; to?: string }) => (
  <tr><td>{to ? <Link href={to}>{k}</Link> : k}</td><td style={{ textAlign: 'right' }}>{children}</td></tr>
);
const q = (s: string) => `/search?q=${encodeURIComponent(s)}`;

export default async function Dashboard() {
  const access = await requireAccess();
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const soon = new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10);

  const { data: dash } = await call<Rec>('dashboard_summary');
  const D: Rec = dash ?? {};
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


      {/* ---------- Operational picture: derived live from the authoritative records, restricted to what you may see ---------- */}
      {(() => {
        const P = D.pipeline ?? {}; const PR = D.projects ?? {}; const R = D.receivables ?? {}; const T = D.tickets ?? {}; const A = D.approvals ?? {}; const W = D.watch ?? {}; const C = D.contracts ?? {};
        const showQuotes = canAnywhere(access, 'quotes.view'); const showFin = canAnywhere(access, 'invoices.view'); const showTickets = canAnywhere(access, 'tickets.view');
        const showAssets = canAnywhere(access, 'assets.view'); const showContracts = canAnywhere(access, 'contracts.view'); const showDomains = canAnywhere(access, 'domains.view');
        const openQuotes: MoneyRow[] = P.open_quotes ?? [];
        const byCur = new Map<string, number>(); openQuotes.forEach((r) => byCur.set(r.currency, (byCur.get(r.currency) ?? 0) + Number(r.value)));
        const maxByCur = new Map<string, number>(); openQuotes.forEach((r) => maxByCur.set(r.currency, Math.max(maxByCur.get(r.currency) ?? 0, Number(r.value))));
        const outstanding: MoneyRow[] = R.outstanding ?? []; const overdue: MoneyRow[] = R.overdue ?? [];
        const slaBreached = Number(T.sla_breached ?? 0);
        return (
          <>
            <div className="grid g4" style={{ marginBottom: '1.1rem' }}>
              {showQuotes && <Tile n={byCur.size === 0 ? '—' : [...byCur].map(([c, v]) => money(v, c)).map((x, i) => <span key={i} style={{ display: 'block', fontSize: byCur.size > 1 ? '1.1rem' : undefined }}>{x}</span>)} l="Open quotes value" href={q('type:quote')} />}
              {showFin && <Tile n={outstanding.length === 0 ? '—' : outstanding.map((r) => <span key={r.currency} style={{ display: 'block', fontSize: outstanding.length > 1 ? '1.1rem' : undefined }}>{money(r.value, r.currency)}</span>)} l="Outstanding receivables" href={q('type:invoice')} />}
              {showFin && <Tile n={overdue.length === 0 ? '0' : overdue.map((r) => <span key={r.currency} style={{ display: 'block', fontSize: overdue.length > 1 ? '1.1rem' : undefined }}>{money(r.value, r.currency)}</span>)} l="Overdue (past due date)" tone={overdue.length ? 'bad' : undefined} href={q('type:invoice')} />}
              <Tile n={A.awaiting_decision ?? 0} l="Approvals waiting for a decision" tone={Number(A.awaiting_decision ?? 0) ? 'warn' : undefined} />
              {canAnywhere(access, 'projects.view') && <Tile n={sum(PR.by_status)} l={`Live projects · ${PR.overdue ?? 0} overdue`} tone={Number(PR.overdue ?? 0) ? 'bad' : undefined} href={q('type:project')} />}
              {showTickets && <Tile n={sum(T.open_by_priority)} l={`Open tickets${slaBreached ? ` · ${slaBreached} past SLA` : ''}`} tone={slaBreached ? 'bad' : undefined} href={q('type:ticket')} />}
              {showContracts && <Tile n={C.active ?? 0} l={`Active contracts · ${C.ending_60d ?? 0} end in 60 days`} href={q('type:contract status:active')} />}
              {showQuotes && <Tile n={P.quotes_expiring_14d ?? 0} l="Sent quotes expiring in 14 days" tone={Number(P.quotes_expiring_14d ?? 0) ? 'warn' : undefined} />}
            </div>

            <div className="grid g2">
              {showQuotes && (
                <section className="card"><h2>Sales pipeline</h2>
                  {openQuotes.length === 0 ? <Empty>No open quotes you can see.</Empty> : (
                    <table><thead><tr><th>Quote status</th><th style={{ textAlign: 'right' }}>Count</th><th style={{ textAlign: 'right' }}>Value</th><th></th></tr></thead>
                      <tbody>{openQuotes.map((r: any) => (
                        <tr key={r.status + r.currency}><td><Link href={q(`type:quote status:${r.status}`)}><Badge v={r.status} /></Link></td><td style={{ textAlign: 'right' }}>{r.count}</td>
                          <td style={{ textAlign: 'right' }}>{money(r.value, r.currency)}</td><td><Bar pct={(Number(r.value) / (maxByCur.get(r.currency) || 1)) * 100} /></td></tr>
                      ))}</tbody></table>
                  )}
                  <table style={{ marginTop: '.7rem' }}><tbody>
                    <Row k="Accepted in the last 30 days"><Money rows={P.accepted_30d} /></Row>
                    <Row k="Open leads" to={q('type:lead')}>{Object.entries(P.open_leads ?? {}).map(([k, v]) => `${v} ${k}`).join(' · ') || '—'}</Row>
                  </tbody></table>
                </section>
              )}

              {canAnywhere(access, 'projects.view') && (
                <section className="card"><h2>Projects</h2>
                  <table><tbody>
                    {['proposed', 'approved', 'active', 'on_hold'].map((st) => <Row key={st} k={label(st)} to={q(`type:project status:${st}`)}>{PR.by_status?.[st] ?? 0}</Row>)}
                    <Row k="Overdue">{<span style={{ color: Number(PR.overdue ?? 0) ? 'var(--danger)' : undefined }}>{PR.overdue ?? 0}{Number(PR.overdue ?? 0) ? ' overdue' : ''}</span>}</Row>
                    <Row k="Due in the next 14 days">{PR.due_14d ?? 0}</Row>
                  </tbody></table>
                  {(PR.active_by_division ?? []).length > 0 && (
                    <><h2 style={{ marginTop: '1rem' }}>Active by lead division</h2>
                      <table><tbody>{(PR.active_by_division as any[]).map((d) => <Row key={d.division} k={d.division}>{d.count}</Row>)}</tbody></table></>
                  )}
                </section>
              )}

              {showFin && (
                <section className="card"><h2>Receivables</h2>
                  <table><tbody>
                    <Row k="Outstanding (issued and part-paid)"><Money rows={R.outstanding} /></Row>
                    <Row k="of which overdue"><span style={{ color: overdue.length ? 'var(--danger)' : undefined }}><Money rows={R.overdue} /></span></Row>
                    <Row k="Invoiced in the last 30 days"><Money rows={R.invoiced_30d} /></Row>
                    <Row k="Received in the last 30 days"><Money rows={R.received_30d} /></Row>
                    <Row k="Received, not yet allocated"><Money rows={R.unallocated_credit} /></Row>
                    <Row k="Invoices awaiting approval">{R.invoices_awaiting_approval ?? 0}</Row>
                  </tbody></table>
                  <p className="muted small" style={{ marginBottom: 0 }}>Derived from invoices and payment allocations each time; nothing here is stored. Totals never mix currencies.</p>
                </section>
              )}

              {showTickets && (
                <section className="card"><h2>Tickets</h2>
                  <table><tbody>
                    {['urgent', 'high', 'normal', 'low'].map((pr) => <Row key={pr} k={`${label(pr)} priority`}>{T.open_by_priority?.[pr] ?? 0}</Row>)}
                    <Row k="Past first-response or resolution target"><span style={{ color: slaBreached ? 'var(--danger)' : undefined }}>{slaBreached}{slaBreached ? ' past SLA' : ''}</span></Row>
                    <Row k="Assigned to you">{T.assigned_to_me ?? 0}</Row>
                  </tbody></table>
                </section>
              )}

              {(showAssets || showDomains || showContracts) && (
                <section className="card"><h2>Watch list</h2>
                  <table><tbody>
                    {showDomains && <Row k="Domains due for renewal">{W.domains_due?.due_soon ?? 0}</Row>}
                    {showDomains && <Row k="Domains lapsed"><span style={{ color: Number(W.domains_due?.lapsed ?? 0) ? 'var(--danger)' : undefined }}>{W.domains_due?.lapsed ?? 0}{Number(W.domains_due?.lapsed ?? 0) ? ' lapsed' : ''}</span></Row>}
                    {showAssets && <Row k="Warranties ending in 30 days">{W.warranties_ending_30d ?? 0}</Row>}
                    {showAssets && Object.entries(W.assets_by_status ?? {}).map(([k, v]) => <Row key={k} k={`Assets ${label(k)}`} to={q(`type:asset status:${k}`)}>{String(v)}</Row>)}
                    {showContracts && <Row k="Contracts ending in 60 days">{C.ending_60d ?? 0}</Row>}
                  </tbody></table>
                </section>
              )}
            </div>
            <h2 style={{ margin: '1.4rem 0 .7rem' }}>Your own work</h2>
          </>
        );
      })()}
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
