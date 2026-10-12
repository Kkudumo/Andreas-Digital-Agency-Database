import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { call, rid, type Rec } from '@/lib/db';
import { Badge, Empty, PageHead } from '@/components/ui';

const HINTS: [string, string][] = [
  ['Zeta', 'any name, ID, registration number or reference'],
  ['type:client Zeta', 'only clients (also project, quote, contract, ticket, asset, document, domain, communication…)'],
  ['related:<institutional-id>', 'everything connected to a record: its projects, contracts, documents, tickets, assets…'],
  ['status:active division:web', 'filters can be combined with text'],
];

export default async function SearchPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  await requireAccess();
  const q = ((await searchParams).q ?? '').trim();
  let res: Rec | null = null;
  let suggestions: Rec[] = [];
  let failed = false;
  if (q) {
    const r = await call<Rec>('search', { p_query: q, p_limit: 50, p_offset: 0, p_facets: true });
    if (r.error) failed = true; else res = r.data;
    if ((res?.total ?? 0) === 0 && q.length >= 2 && !q.includes(':')) {
      const s = await call<Rec[]>('search_suggest', { p_prefix: q });
      suggestions = s.data ?? [];
    }
  }
  const results: Rec[] = res?.results ?? [];
  const types: Record<string, number> = res?.facets?.entity_type ?? {};
  const bare = q.replace(/\btype:\S+\s*/g, '').trim();

  return (
    <>
      <PageHead title="Search ADA Hub" sub="Everything you are authorised to see, found by name, institutional ID or relationship" />
      <form action="/search" method="get" className="card" role="search">
        <label>Search<input name="q" defaultValue={q} placeholder="Zeta · type:client Zeta · related:J8HTCAQF5" autoFocus /></label>
        <div style={{ marginTop: '.6rem' }}><button className="primary" type="submit">Search</button></div>
      </form>

      {!q && (
        <section className="card">
          <h2>How to search</h2>
          <dl className="kv">{HINTS.map(([k, v]) => <div key={k} style={{ display: 'contents' }}><dt><code>{k}</code></dt><dd>{v}</dd></div>)}</dl>
        </section>
      )}

      {q && failed && <div className="flash error" role="alert">The search could not be run.</div>}
      {q && res && (
        <section className="card">
          <h2>{res.total} result{res.total === 1 ? '' : 's'}{res.capped ? ' (capped)' : ''} <span className="muted small">for “{q}”</span></h2>
          {Object.keys(types).length > 0 && (
            <div className="small" style={{ marginBottom: '.7rem' }}>
              {Object.entries(types).map(([t, n]) => (
                <Link key={t} className="badge" style={{ marginRight: '.4rem' }} href={`/search?q=${encodeURIComponent(`type:${t} ${bare}`.trim())}`}>{t.replace(/_/g, ' ')} · {n}</Link>
              ))}
            </div>
          )}
          {results.length === 0 ? <Empty>Nothing found. Records you may not see are not counted or hinted at.</Empty> : (
            <div className="scroll"><table>
              <thead><tr><th>Record</th><th>Type</th><th>Status</th><th>Institutional ID</th><th></th></tr></thead>
              <tbody>{results.map((r) => (
                <tr key={r.institutional_id}>
                  <td><Link href={rid(r.institutional_id)}><b>{r.label}</b></Link></td>
                  <td>{String(r.entity_type).replace(/_/g, ' ')}</td>
                  <td><Badge v={r.status && r.status !== '-' ? r.status : null} /></td>
                  <td className="mono">{r.institutional_id}</td>
                  <td><Link className="small" href={`/search?q=${encodeURIComponent('related:' + r.institutional_id)}`}>related</Link></td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
          {suggestions.length > 0 && (
            <div className="small" style={{ marginTop: '.8rem' }}>Did you mean: {suggestions.map((s: any, i) => (
              <span key={i}><Link href={`/search?q=${encodeURIComponent(s.label ?? s)}`}>{s.label ?? String(s)}</Link>{i < suggestions.length - 1 ? ', ' : ''}</span>
            ))}</div>
          )}
        </section>
      )}
    </>
  );
}
