'use client';
import { useMemo, useState } from 'react';

type Section = { key: string; position: number; title: string; summary: string; tables: string[] };

// The arrangement of the database, with a filter: type part of a table or section name to find where something lives.
export function SectionIndex({ sections }: { sections: Section[] }) {
  const [q, setQ] = useState('');
  const needle = q.trim().toLowerCase();
  const shown = useMemo(() => sections.map((s) => {
    const hit = !needle || s.title.toLowerCase().includes(needle) || s.summary.toLowerCase().includes(needle);
    const tables = needle ? s.tables.filter((t) => t.includes(needle.replace(/\s+/g, '_')) || hit) : s.tables;
    return { ...s, tables, visible: hit || tables.length > 0 };
  }).filter((s) => s.visible), [sections, needle]);
  return (
    <>
      <label className="sec-filter">Find a table or section
        <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="e.g. invoice, price, vacancy" data-testid="section-filter" />
      </label>
      {shown.length === 0 && <section className="card"><div className="empty">Nothing matches “{q}”.</div></section>}
      {shown.map((s) => (
        <section className="card sec-card" key={s.key} data-section={s.key}>
          <h2><span className="n">{String(s.position).padStart(2, '0')}</span>{s.title} <span className="muted small">{s.tables.length} {s.tables.length === 1 ? 'table' : 'tables'}</span></h2>
          <p className="muted">{s.summary}</p>
          <div className="sec-tables">{s.tables.map((t) => <code key={t}>{t}</code>)}</div>
        </section>
      ))}
    </>
  );
}
