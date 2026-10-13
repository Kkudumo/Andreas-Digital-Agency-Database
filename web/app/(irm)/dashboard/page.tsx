import Link from 'next/link';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { call, money, type Rec } from '@/lib/db';
import { fmtDate, fmtDateTime, label } from '@/lib/format';
import { Badge, Empty } from '@/components/ui';

// The first screen after sign-in, organised by what needs doing:
//   1. Needs your attention  - decisions, money, delivery and risk, only what is actually pending
//   2. Key figures           - the handful of numbers that describe the agency right now
//   3. Quick access          - where people go most
//   4. Divisions             - each division at a glance
//   5. Operational detail    - the full tables (pipeline, projects, receivables, spend, tickets, watch list)
//   6. Your own work         - your tasks, what is due soon, your access, recent activity
// Every figure is derived at read time by dashboard_summary() under the caller's own row-level security.

type MoneyRow = { currency: string; value: number | string; count?: number; status?: string };
const Money = ({ rows }: { rows?: MoneyRow[] }) => (!rows || rows.length === 0)
  ? <>—</> : <>{rows.map((r) => <span key={r.currency} style={{ display: 'block' }}>{money(r.value, r.currency)}{r.count !== undefined && <span className="muted small"> · {r.count}</span>}</span>)}</>;
const sum = (o?: Record<string, number>) => Object.values(o ?? {}).reduce((a, b) => a + Number(b), 0);
const q = (s: string) => `/search?q=${encodeURIComponent(s)}`;
const Row = ({ k, children, to }: { k: string; children: React.ReactNode; to?: string }) => (
  <tr><td>{to ? <Link href={to}>{k}</Link> : k}</td><td style={{ textAlign: 'right' }}>{children}</td></tr>
);
const Bar = ({ pct }: { pct: number }) => (
  <div aria-hidden="true" style={{ background: '#e4e9f0', height: 6, minWidth: 80 }}><div style={{ width: `${Math.max(2, Math.min(100, pct))}%`, background: '#1b63c6', height: 6 }} /></div>
);

type Attn = { group: 'Decisions' | 'Money' | 'Delivery' | 'Risk'; text: string; value: React.ReactNode; href?: string; tone: 'bad' | 'warn' };

export default async function Dashboard() {
  const access = await requireAccess();
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
    showProjects
      ? supabase.from('projects').select('id, ada_id, name, status, due_date, client:clients(name)')
          .in('status', ['proposed', 'approved', 'active', 'on_hold']).lte('due_date', soon).order('due_date').limit(6)
      : null,
    can(access, 'audit.view')
      ? supabase.from('audit_log').select('id, occurred_at, actor_ada_id, action, table_name, record_ada_id').order('id', { ascending: false }).limit(8)
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
  const n = (v: unknown) => Number(v ?? 0);
  const expAwait: MoneyRow[] = S.awaiting_approval ?? [];
  const expAwaitCount = expAwait.reduce((a, r) => a + n(r.count), 0);

  // ---------- 1. what needs attention ----------
  const attnAll: Attn[] = [
    { group: 'Decisions', text: 'Approvals waiting for your decision', value: n(A.awaiting_decision), href: '/search', tone: 'warn' },
    { group: 'Decisions', text: 'Price changes awaiting approval', value: pricesPending, href: '/services', tone: 'warn' },
    { group: 'Decisions', text: 'Services awaiting approval to publish', value: servicesPending, href: '/services', tone: 'warn' },
    { group: 'Decisions', text: 'Invoices awaiting approval', value: showFin ? n(R.invoices_awaiting_approval) : 0, href: '/invoices', tone: 'warn' },
    { group: 'Decisions', text: 'Credit notes awaiting approval', value: showFin ? n(R.credit_notes_awaiting_approval) : 0, href: '/credit-notes', tone: 'warn' },
    { group: 'Decisions', text: 'Expenses awaiting approval', value: showExpenses ? expAwaitCount : 0, href: '/expenses', tone: 'warn' },
    { group: 'Money', text: 'Overdue invoices (past due date)', value: showFin && overdueMoney.length ? <Money rows={overdueMoney} /> : 0, href: '/invoices', tone: 'bad' },
    { group: 'Money', text: 'Recurring billing due for a run', value: showFin ? n(B.schedules_due) : 0, href: '/billing', tone: 'warn' },
    { group: 'Money', text: 'Sent quotes expiring in 14 days', value: showQuotes ? n(P.quotes_expiring_14d) : 0, href: '/quotes', tone: 'warn' },
    { group: 'Delivery', text: 'Projects past their due date', value: showProjects ? n(PR.overdue) : 0, href: q('type:project'), tone: 'bad' },
    { group: 'Delivery', text: 'Your tasks overdue', value: myOverdue, href: '/projects', tone: 'bad' },
    { group: 'Delivery', text: 'Tickets past their response target', value: showTickets ? slaBreached : 0, href: q('type:ticket'), tone: 'bad' },
    { group: 'Risk', text: 'Domains lapsed', value: showDomains ? n(W.domains_due?.lapsed) : 0, href: q('type:domain'), tone: 'bad' },
    { group: 'Risk', text: 'Domains due for renewal', value: showDomains ? n(W.domains_due?.due_soon) : 0, href: q('type:domain'), tone: 'warn' },
    { group: 'Risk', text: 'Contracts ending in 60 days', value: showContracts ? n(C.ending_60d) : 0, href: q('type:contract status:active'), tone: 'warn' },
    { group: 'Risk', text: 'Warranties ending in 30 days', value: showAssets ? n(W.warranties_ending_30d) : 0, href: q('type:asset'), tone: 'warn' },
  ];
  const attn = attnAll.filter((a) => (typeof a.value === 'number' ? a.value > 0 : true));
  const groups = (['Decisions', 'Money', 'Delivery', 'Risk'] as const).map((g) => ({ g, items: attn.filter((a) => a.group === g) })).filter((x) => x.items.length > 0);

  // ---------- 2. key figures ----------
  const stat = (l: string, v: React.ReactNode, small: string, href?: string, tone?: 'bad') => (
    <Link className="dash-stat" href={href ?? '#'} key={l} style={tone === 'bad' ? { borderTopColor: '#b0181e' } : undefined}>
      <span>{l}</span><strong>{v}</strong><small>{small}</small><b>Open →</b>
    </Link>
  );
  const stackMoney = (rows: MoneyRow[], empty = '—') => rows.length === 0 ? empty : rows.map((r) => <span key={r.currency} style={{ display: 'block', fontSize: rows.length > 1 ? '1.3rem' : undefined }}>{money(r.value, r.currency)}</span>);

  // ---------- 4. divisions ----------
  const divCount = (id: string, st?: string) => services.filter((s) => s.division_id === id && (!st || s.status === st)).length;
  const activeIn = (name: string) => ((PR.active_by_division ?? []) as any[]).find((d) => d.division === name)?.count ?? 0;

  const quick = [
    { href: '/search', t: 'Find a record', d: 'Search clients, projects, invoices, documents and more', show: true },
    { href: '/clients/new', t: 'New client', d: 'Check for an existing company, then create the client', show: canAnywhere(access, 'clients.create') },
    { href: '/services', t: 'Services and prices', d: 'Edit what each division sells and its prices', show: true },
    { href: '/quotes', t: 'Quotes', d: 'Priced proposals from the catalogue', show: showQuotes },
    { href: '/projects', t: 'Projects', d: 'Delivery, tasks and assignments', show: showProjects },
    { href: '/invoices', t: 'Invoices', d: 'Billing, payments and balances', show: showFin },
    { href: '/expenses', t: 'Expenses', d: 'Spending, approval and payment', show: showExpenses },
    { href: '/staff', t: 'Staff', d: 'People, roles and divisions', show: true },
  ].filter((x) => x.show);

  return (
    <>
      {/* heading */}
      <header className="dash-head">
        <p>{isExecutive ? 'Chief Executive · Organization-wide' : `${access.staff.position ?? 'ADA'}${access.staff.division_name ? ' · ' + access.staff.division_name : ''}`}</p>
        <h1>{greeting}, {first}</h1>
        <span>{dateLine} · {isExecutive ? 'Everything across ADA, in one place' : 'Your workspace'}</span>
      </header>

      {/* 1. needs attention */}
      <section className="dash-section" aria-label="Needs your attention">
        <div className="dash-title"><p>Priority</p><h2>Needs your attention</h2></div>
        {groups.length === 0 ? (
          <div className="dash-clear"><b>✓</b><div><strong>Nothing needs your attention right now.</strong><span>New approvals, overdue invoices, late projects and expiring items will appear here first.</span></div></div>
        ) : (
          <div className="dash-attn">
            {groups.map(({ g, items }) => (
              <div className="dash-attn-group" key={g}>
                <h3>{g}</h3>
                {items.map((a) => (
                  <Link className={`dash-attn-row ${a.tone}`} key={a.text} href={a.href ?? '#'}>
                    <span className="dot" aria-hidden="true" /><span className="t">{a.text}</span><strong>{a.value}</strong><b aria-hidden="true">→</b>
                  </Link>
                ))}
              </div>
            ))}
          </div>
        )}
      </section>

      {/* 2. key figures */}
      <section className="dash-section" aria-label="Key figures">
        <div className="dash-title"><p>Right now</p><h2>Key figures</h2></div>
        <div className="dash-stats">
          {showQuotes && stat('Open quotes', stackMoney([...byCur].map(([currency, value]) => ({ currency, value }))), 'Value of quotes not yet decided', '/quotes')}
          {showFin && stat('Outstanding receivables', stackMoney(outstanding), overdueMoney.length ? 'Some of it is overdue' : 'Nothing overdue', '/invoices', overdueMoney.length ? 'bad' : undefined)}
          {showProjects && stat('Live projects', sum(PR.by_status), `${n(PR.overdue)} overdue · ${n(PR.due_14d)} due in 14 days`, '/projects', n(PR.overdue) ? 'bad' : undefined)}
          {showTickets && stat('Open tickets', sum(T.open_by_priority), slaBreached ? `${slaBreached} past their target` : 'All within target', q('type:ticket'), slaBreached ? 'bad' : undefined)}
          {showContracts && stat('Active contracts', n(C.active), `${n(C.ending_60d)} end in 60 days`, q('type:contract status:active'))}
          {showClients && stat('Clients', clients?.count ?? 0, 'Clients you can see', '/clients')}
        </div>
      </section>

      {/* 3. quick access */}
      <section className="dash-section" aria-label="Quick access">
        <div className="dash-title"><p>Shortcuts</p><h2>Quick access</h2></div>
        <div className="dash-quick">
          {quick.map((x) => <Link key={x.href} href={x.href}><div><strong>{x.t}</strong><span>{x.d}</span></div><b>→</b></Link>)}
        </div>
      </section>

      {/* 4. divisions */}
      {divisions.length > 0 && (
        <section className="dash-section" aria-label="Divisions">
          <div className="dash-title"><p>Divisions</p><h2>Each division at a glance</h2></div>
          <div className="dash-areas">
            {divisions.map((d) => (
              <Link key={d.id} href={`/services/${d.key}`} className="dash-area">
                <div>
                  <span>{d.name}</span>
                  <h3>{divCount(d.id)} services</h3>
                  <p>{divCount(d.id, 'published')} published · {divCount(d.id, 'draft')} draft{showProjects ? ` · ${activeIn(d.name)} active projects` : ''}</p>
                </div>
                <b>→</b>
              </Link>
            ))}
          </div>
        </section>
      )}

      {/* 5. operational detail */}
      <section className="dash-section" aria-label="Operational detail">
        <div className="dash-title"><p>Detail</p><h2>Operational overview</h2></div>
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
        </div>
      </section>

      {/* 6. your own work */}
      <section className="dash-section" aria-label="Your own work">
        <div className="dash-title"><p>You</p><h2>Your own work</h2></div>
        <div className="grid g2">
          <section className="card">
            <h2>Your open tasks</h2>
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
      </section>
    </>
  );
}
