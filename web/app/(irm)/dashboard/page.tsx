import Link from 'next/link';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { call, money, type Rec } from '@/lib/db';
import { fmtDate, fmtDateTime, label } from '@/lib/format';
import { Badge, Empty } from '@/components/ui';

// The first screen after sign-in: one screen, no scrolling on a desktop.
//   Top row     - the key figures
//   Left card   - needs your attention (decisions, money, delivery, risk), most urgent first
//   Middle      - each division at a glance, and your open tasks
//   Right       - quick access, and recent activity
// The full tables (pipeline, projects, receivables, spend, tickets, watch list) are one click away at /dashboard?view=overview.
// Every figure is derived at read time by dashboard_summary() under the caller's own row-level security.

type MoneyRow = { currency: string; value: number | string; count?: number; status?: string };
const Money = ({ rows }: { rows?: MoneyRow[] }) => (!rows || rows.length === 0)
  ? <>—</> : <>{rows.map((r) => <span key={r.currency} style={{ display: 'block' }}>{money(r.value, r.currency)}{r.count !== undefined && <span className="muted small"> · {r.count}</span>}</span>)}</>;
const sum = (o?: Record<string, number>) => Object.values(o ?? {}).reduce((a, b) => a + Number(b), 0);
const q = (s: string) => `/search?q=${encodeURIComponent(s)}`;
const n = (v: unknown) => Number(v ?? 0);
const Row = ({ k, children, to }: { k: string; children: React.ReactNode; to?: string }) => (
  <tr><td>{to ? <Link href={to}>{k}</Link> : k}</td><td style={{ textAlign: 'right' }}>{children}</td></tr>
);
const Bar = ({ pct }: { pct: number }) => (
  <div aria-hidden="true" style={{ background: '#e4e9f0', height: 6, minWidth: 80 }}><div style={{ width: `${Math.max(2, Math.min(100, pct))}%`, background: '#1b63c6', height: 6 }} /></div>
);

type Attn = { group: 'Decisions' | 'Money' | 'Delivery' | 'Risk'; text: string; value: React.ReactNode; href?: string; tone: 'bad' | 'warn' };

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ view?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const overview = sp.view === 'overview';
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const soon = new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10);
  const tz = 'Africa/Windhoek';
  const hour = Number(new Intl.DateTimeFormat('en-GB', { hour: 'numeric', hour12: false, timeZone: tz }).format(new Date())) % 24;
  const greeting = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  const dateLine = new Intl.DateTimeFormat('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', timeZone: tz }).format(new Date());
  const first = access.staff.full_name.split(' ')[0];

  const { data: dash } = await call<Rec>('dashboard_summary');
  const D: Rec = dash ?? {};
  const P = D.pipeline ?? {}; const PR = D.projects ?? {}; const R = D.receivables ?? {}; const T = D.tickets ?? {};
  const A = D.approvals ?? {}; const W = D.watch ?? {}; const C = D.contracts ?? {}; const S = D.spend ?? {}; const B = D.billing ?? {};

  const showClients = canAnywhere(access, 'clients.view');
  const showProjects = canAnywhere(access, 'projects.view');
  const showQuotes = canAnywhere(access, 'quotes.view');
  const showFin = canAnywhere(access, 'invoices.view');
  const showExpenses = canAnywhere(access, 'expenses.view');
  const showTickets = canAnywhere(access, 'tickets.view');
  const showAssets = canAnywhere(access, 'assets.view');
  const showContracts = canAnywhere(access, 'contracts.view');
  const showDomains = canAnywhere(access, 'domains.view');
  const isExecutive = access.roles.some((r) => r.key === 'ceo' && r.division_id === null);

  const [clients, myTasks, dueSoon, audit, divs, svc, pendingPrices] = await Promise.all([
    showClients ? supabase.from('clients').select('id', { count: 'exact', head: true }).neq('status', 'archived') : null,
    showProjects
      ? supabase.from('tasks').select('id, ada_id, title, status, priority, due_date, project:projects(id, name)')
          .eq('assignee_id', access.staff.id).in('status', ['todo', 'in_progress', 'blocked']).order('due_date', { nullsFirst: false }).limit(8)
      : null,
    overview && showProjects
      ? supabase.from('projects').select('id, ada_id, name, status, due_date, client:clients(name)')
          .in('status', ['proposed', 'approved', 'active', 'on_hold']).lte('due_date', soon).order('due_date').limit(6)
      : null,
    can(access, 'audit.view')
      ? supabase.from('audit_log').select('id, occurred_at, actor_ada_id, action, table_name, record_ada_id').order('id', { ascending: false }).limit(overview ? 8 : 5)
      : null,
    supabase.from('divisions').select('id, key, name, description').eq('is_active', true).eq('kind', 'service').order('sort_order'),
    supabase.from('services').select('division_id, status').is('deleted_at', null).limit(2000),
    supabase.from('service_prices').select('id', { count: 'exact', head: true }).eq('status', 'pending_approval'),
  ]);

  const tasks = (myTasks?.data ?? []) as any[];
  const myOverdue = tasks.filter((t) => t.due_date && t.due_date < today).length;
  const services = (svc.data ?? []) as any[];
  const servicesPending = services.filter((s) => s.status === 'pending_approval').length;
  const pricesPending = pendingPrices?.count ?? 0;
  const divisions = (divs.data ?? []) as any[];

  const openQuotes: MoneyRow[] = P.open_quotes ?? [];
  const byCur = new Map<string, number>(); openQuotes.forEach((r) => byCur.set(r.currency, (byCur.get(r.currency) ?? 0) + Number(r.value)));
  const maxByCur = new Map<string, number>(); openQuotes.forEach((r) => maxByCur.set(r.currency, Math.max(maxByCur.get(r.currency) ?? 0, Number(r.value))));
  const outstanding: MoneyRow[] = R.outstanding ?? []; const overdueMoney: MoneyRow[] = R.overdue ?? [];
  const slaBreached = Number(T.sla_breached ?? 0);
  const expAwait: MoneyRow[] = S.awaiting_approval ?? [];
  const expAwaitCount = expAwait.reduce((a, r) => a + n(r.count), 0);

  // ---------- what needs attention ----------
  const attnAll: Attn[] = [
    { group: 'Decisions', text: 'Approvals waiting for your decision (prices, quotes, invoices, contracts…)', value: n(A.awaiting_decision), href: '/approvals', tone: 'warn' },
    { group: 'Decisions', text: 'Services awaiting approval to publish', value: servicesPending, href: '/services', tone: 'warn' },
    { group: 'Decisions', text: 'Credit notes awaiting approval', value: showFin ? n(R.credit_notes_awaiting_approval) : 0, href: '/credit-notes', tone: 'warn' },
    { group: 'Decisions', text: 'Expenses awaiting approval', value: showExpenses ? expAwaitCount : 0, href: '/expenses', tone: 'warn' },
    { group: 'Money', text: 'Overdue invoices', value: showFin && overdueMoney.length ? <Money rows={overdueMoney} /> : 0, href: '/invoices', tone: 'bad' },
    { group: 'Money', text: 'Recurring billing due for a run', value: showFin ? n(B.schedules_due) : 0, href: '/billing', tone: 'warn' },
    { group: 'Money', text: 'Sent quotes expiring in 14 days', value: showQuotes ? n(P.quotes_expiring_14d) : 0, href: '/quotes', tone: 'warn' },
    { group: 'Delivery', text: 'Projects past their due date', value: showProjects ? n(PR.overdue) : 0, href: q('type:project'), tone: 'bad' },
    { group: 'Delivery', text: 'Your tasks overdue', value: myOverdue, href: '/projects', tone: 'bad' },
    { group: 'Delivery', text: 'Tickets past their response target', value: showTickets ? slaBreached : 0, href: q('type:ticket'), tone: 'bad' },
    { group: 'Risk', text: 'Contracts ending in 60 days', value: showContracts ? n(C.ending_60d) : 0, href: q('type:contract status:active'), tone: 'warn' },
  ];
  // late things first, then what waits on you; within a tone keep the group order above
  const attn = attnAll.filter((a) => (typeof a.value === 'number' ? a.value > 0 : true)).sort((a, b) => (a.tone === b.tone ? 0 : a.tone === 'bad' ? -1 : 1));

  // watch figures are always shown, zero included, so an empty register is visible rather than hidden
  const watchRows: { text: string; value: number; href: string }[] = [
    ...(showDomains ? [{ text: 'Domains lapsed', value: n(W.domains_due?.lapsed), href: q('type:domain') }, { text: 'Domains due for renewal', value: n(W.domains_due?.due_soon), href: q('type:domain') }] : []),
    ...(showAssets ? [{ text: 'Warranties ending in 30 days', value: n(W.warranties_ending_30d), href: q('type:asset') }] : []),
  ];

  // ---------- compact key figures ----------
  const kpi = (l: string, v: React.ReactNode, s: string, href: string, bad?: boolean) => (
    <Link className={`d1-kpi${bad ? ' bad' : ''}`} href={href} key={l}><span>{l}</span><strong>{v}</strong><small>{s}</small></Link>
  );
  const stackMoney = (rows: MoneyRow[]) => rows.length === 0 ? '—' : rows.map((r) => <span key={r.currency} style={{ display: 'block', fontSize: rows.length > 1 ? '.95rem' : '1.2rem' }}>{money(r.value, r.currency)}</span>);
  const divCount = (id: string, st?: string) => services.filter((s) => s.division_id === id && (!st || s.status === st)).length;
  const activeIn = (name: string) => ((PR.active_by_division ?? []) as any[]).find((d) => d.division === name)?.count ?? 0;

  const quick = [
    { href: '/search', t: 'Find a record', show: true },
    { href: '/clients/new', t: 'New client', show: canAnywhere(access, 'clients.create') },
    { href: '/services', t: 'Services & prices', show: true },
    { href: '/quotes', t: 'Quotes', show: showQuotes },
    { href: '/projects', t: 'Projects', show: showProjects },
    { href: '/invoices', t: 'Invoices', show: showFin },
    { href: '/expenses', t: 'Expenses', show: showExpenses },
    { href: '/staff', t: 'Staff', show: true },
  ].filter((x) => x.show);

  const who = isExecutive ? 'Chief Executive · Organization-wide' : `${access.staff.position ?? 'ADA'}${access.staff.division_name ? ' · ' + access.staff.division_name : ''}`;

  // =====================================================================================================================
  // Full overview: the detailed tables, one click from the dashboard
  // =====================================================================================================================
  if (overview) {
    return (
      <>
        <header className="dash-head">
          <p>{who}</p>
          <h1>Operational overview</h1>
          <span><Link href="/dashboard">← Back to dashboard</Link> · {dateLine}</span>
        </header>
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

          {showProjects && (
            <section className="card"><h2>Projects</h2>
              <table><tbody>
                {['proposed', 'approved', 'active', 'on_hold'].map((st) => <Row key={st} k={label(st)} to={q(`type:project status:${st}`)}>{PR.by_status?.[st] ?? 0}</Row>)}
                <Row k="Overdue"><span style={{ color: n(PR.overdue) ? 'var(--danger)' : undefined }}>{PR.overdue ?? 0}{n(PR.overdue) ? ' overdue' : ''}</span></Row>
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
                <Row k="of which overdue"><span style={{ color: overdueMoney.length ? 'var(--danger)' : undefined }}><Money rows={R.overdue} /></span></Row>
                <Row k="Invoiced in the last 30 days"><Money rows={R.invoiced_30d} /></Row>
                <Row k="Received in the last 30 days"><Money rows={R.received_30d} /></Row>
                <Row k="Received, not yet allocated"><Money rows={R.unallocated_credit} /></Row>
                <Row k="Customer credit not yet applied"><Money rows={R.credit_unapplied} /></Row>
              </tbody></table>
              <p className="muted small" style={{ marginBottom: 0 }}>Derived from invoices and payment allocations each time; nothing here is stored. Totals never mix currencies.</p>
            </section>
          )}

          {showExpenses && (
            <section className="card"><h2>Spend</h2>
              <table><tbody>
                <Row k="Expenses awaiting approval" to="/expenses"><Money rows={S.awaiting_approval as MoneyRow[]} /></Row>
                <Row k="Approved, not yet paid" to="/expenses"><Money rows={S.approved_unpaid as MoneyRow[]} /></Row>
                <Row k="Paid in the last 30 days"><Money rows={S.paid_30d as MoneyRow[]} /></Row>
              </tbody></table>
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
                {showDomains && <Row k="Domains lapsed"><span style={{ color: n(W.domains_due?.lapsed) ? 'var(--danger)' : undefined }}>{W.domains_due?.lapsed ?? 0}{n(W.domains_due?.lapsed) ? ' lapsed' : ''}</span></Row>}
                {showAssets && <Row k="Warranties ending in 30 days">{W.warranties_ending_30d ?? 0}</Row>}
                {showAssets && Object.entries(W.assets_by_status ?? {}).map(([k, v]) => <Row key={k} k={`Assets ${label(k)}`} to={q(`type:asset status:${k}`)}>{String(v)}</Row>)}
                {showContracts && <Row k="Contracts ending in 60 days">{C.ending_60d ?? 0}</Row>}
              </tbody></table>
            </section>
          )}

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

  // =====================================================================================================================
  // The one-screen dashboard
  // =====================================================================================================================
  const recent = ((audit?.data ?? []) as any[]);
  return (
    <div className="d1">
      <header className="d1-head">
        <div><p>{who}</p><h1>{greeting}, {first}</h1></div>
        <div className="d1-head-r"><span>{dateLine}</span><Link href="/dashboard?view=overview">Full overview →</Link></div>
      </header>

      <section className="d1-kpis" aria-label="Key figures">
        {showQuotes && kpi('Open quotes', stackMoney([...byCur].map(([currency, value]) => ({ currency, value }))), 'Not yet decided', '/quotes')}
        {showFin && kpi('Receivables', stackMoney(outstanding), overdueMoney.length ? 'Some overdue' : 'Nothing overdue', '/invoices', overdueMoney.length > 0)}
        {showProjects && kpi('Live projects', sum(PR.by_status), `${n(PR.overdue)} overdue`, '/projects', n(PR.overdue) > 0)}
        {showTickets && kpi('Open tickets', sum(T.open_by_priority), slaBreached ? `${slaBreached} past target` : 'All within target', q('type:ticket'), slaBreached > 0)}
        {showContracts && kpi('Active contracts', n(C.active), `${n(C.ending_60d)} end in 60 days`, q('type:contract status:active'))}
        {showClients && kpi('Clients', clients?.count ?? 0, 'You can see', '/clients')}
      </section>

      <div className="d1-grid">
        {/* left: needs attention */}
        <section className="d1-card d1-attn" aria-label="Needs your attention">
          <div className="d1-card-h"><h2>Needs your attention</h2><span className={`d1-count${attn.length ? '' : ' ok'}`}>{attn.length ? attn.length : 'All clear'}</span></div>
          <div className="d1-scroll">
            {attn.length === 0 ? (
              <div className="d1-clear"><b>✓</b><div><strong>Nothing needs your attention</strong><span>Approvals, overdue invoices, late projects and expiring items will appear here first.</span></div></div>
            ) : attn.map((a) => (
              <Link className={`d1-row ${a.tone}`} key={a.text} href={a.href ?? '#'}>
                <span className="dot" aria-hidden="true" /><span className="t">{a.text}</span><em>{a.group}</em><strong>{a.value}</strong>
              </Link>
            ))}
            {watchRows.map((w) => (
              <Link className="d1-row" key={w.text} href={w.href} style={{ opacity: w.value ? 1 : .7 }}>
                <span className="dot" aria-hidden="true" /><span className="t">{w.text}</span><em>Watch</em><strong>{w.value}</strong>
              </Link>
            ))}
          </div>
        </section>

        {/* middle: divisions + your tasks */}
        <div className="d1-col">
          <section className="d1-card" aria-label="Divisions">
            <div className="d1-card-h"><h2>Divisions</h2><Link href="/services">Services →</Link></div>
            <div className="d1-scroll">
              {divisions.map((d) => (
                <Link className="d1-div" key={d.id} href={`/services/${d.key}`}>
                  <strong>{d.name}</strong><small>{divCount(d.id)} services · {divCount(d.id, 'published')} live{showProjects ? ` · ${activeIn(d.name)} projects` : ''}</small><b>→</b>
                </Link>
              ))}
              {divisions.length === 0 && <Empty>No divisions visible to you.</Empty>}
            </div>
          </section>
          <section className="d1-card" aria-label="Your tasks">
            <div className="d1-card-h"><h2>Your open tasks</h2>{myOverdue > 0 && <span className="d1-count">{myOverdue} overdue</span>}</div>
            <div className="d1-scroll">
              {tasks.length === 0 ? <div className="d1-empty">No open tasks assigned to you.</div> : tasks.slice(0, 5).map((t) => (
                <Link className="d1-task" key={t.id} href={`/projects/${t.project?.id}`}>
                  <span><strong>{t.title}</strong><small>{t.project?.name}</small></span>
                  <span style={{ color: t.due_date && t.due_date < today ? '#b0181e' : undefined }}>{fmtDate(t.due_date)}</span>
                </Link>
              ))}
            </div>
          </section>
        </div>

        {/* right: quick access + recent activity */}
        <div className="d1-col">
          <section className="d1-card" aria-label="Quick access">
            <div className="d1-card-h"><h2>Quick access</h2></div>
            <div className="d1-quick">{quick.map((x) => <Link key={x.href} href={x.href}>{x.t}<b>→</b></Link>)}</div>
          </section>
          <section className="d1-card" aria-label="Recent activity">
            <div className="d1-card-h"><h2>{audit ? 'Recent activity' : 'Your access'}</h2>{audit && <Link href="/audit">Audit log →</Link>}</div>
            <div className="d1-scroll">
              {audit ? (recent.length === 0 ? <div className="d1-empty">No activity yet.</div> : recent.map((a) => (
                <div className="d1-act" key={a.id}><span>{a.action} <em>{label(a.table_name)}</em></span><small>{fmtDateTime(a.occurred_at)}</small></div>
              ))) : access.roles.map((r, i) => (
                <div className="d1-act" key={i}><span>{r.name}</span><small>{r.division_name ? `Scoped to ${r.division_name}` : 'Organization-wide'}</small></div>
              ))}
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}
