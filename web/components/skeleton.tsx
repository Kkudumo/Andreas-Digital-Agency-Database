// Loading placeholders in the Hub's own look (flat, square). Shown instantly while a page's data is read.
export function PageSkeleton({ tiles = 0, rows = 6, title = true }: { tiles?: number; rows?: number; title?: boolean }) {
  return (
    <div aria-busy="true" aria-live="polite" data-testid="page-skeleton">
      <span className="sr-only">Loading…</span>
      {title && <div className="head"><div><div className="sk sk-eyebrow" /><div className="sk sk-title" /><div className="sk sk-sub" /></div></div>}
      {tiles > 0 && <div className="grid g4" style={{ marginBottom: 14 }}>{Array.from({ length: tiles }, (_, i) => <div className="stat" key={i}><div className="sk sk-eyebrow" /><div className="sk sk-number" /></div>)}</div>}
      {rows > 0 && <section className="card">{Array.from({ length: rows }, (_, i) => <div className="sk sk-row" key={i} style={{ width: `${96 - (i % 3) * 9}%` }} />)}</section>}
    </div>
  );
}
