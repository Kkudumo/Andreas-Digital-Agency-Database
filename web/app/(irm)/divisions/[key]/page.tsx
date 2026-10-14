import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { PageHead } from '@/components/ui';

const q = (s: string) => `/search?q=${encodeURIComponent(s)}`;

export default async function DivisionPage({ params }: { params: Promise<{ key: string }> }) {
  const access = await requireAccess(); const { key } = await params;
  if (!/^[a-z_]+$/.test(key)) notFound();
  const supabase = await createClient();
  const { data: d } = await supabase.from('divisions').select('id, key, name, description').eq('key', key).maybeSingle();
  if (!d) notFound();
  const count = async (table: string, col: string) => {
    const r = await supabase.from(table).select('*', { count: 'exact', head: true }).eq(col, d.id);
    return r.error ? null : r.count ?? 0;
  };
  // Each card is one part of the division's work: its number is what the signed-in person may see, and it opens the same records in Search.
  const [services, projects, clients, staff, vacancies, documents, quotes, invoices, tickets, assets] = await Promise.all([
    count('services', 'division_id'), count('projects', 'lead_division_id'), count('client_divisions', 'division_id'), count('staff', 'primary_division_id'),
    count('vacancies', 'division_id'), count('documents', 'division_id'), count('quotes', 'division_id'), count('invoices', 'division_id'), count('tickets', 'division_id'), count('assets', 'division_id'),
  ]);
  const cards: { title: string; n: number | null; text: string; href: string | null; show: boolean }[] = [
    { title: 'Services & prices', n: services, text: 'The catalogue entries of this division and the price in force for each.', href: q(`type:service division:${d.key}`), show: true },
    { title: 'Packages', n: null, text: 'Not in the database yet: packages arrive with the Content section.', href: null, show: true },
    { title: 'Projects', n: projects, text: 'Projects this division leads.', href: q(`type:project division:${d.key}`), show: canAnywhere(access, 'projects.view') },
    { title: 'Clients', n: clients, text: 'Clients this division works with.', href: q(`type:client division:${d.key}`), show: canAnywhere(access, 'clients.view') },
    { title: 'Quotes', n: quotes, text: 'Quotes prepared by this division.', href: q(`type:quote division:${d.key}`), show: canAnywhere(access, 'quotes.view') },
    { title: 'Invoices', n: invoices, text: 'Invoices raised for this division.', href: q(`type:invoice division:${d.key}`), show: canAnywhere(access, 'invoices.view') },
    { title: 'Team', n: staff, text: 'Staff whose home division this is.', href: q(`type:staff division:${d.key}`), show: true },
    { title: 'Vacancies', n: vacancies, text: 'Openings in this division.', href: q(`type:vacancy division:${d.key}`), show: canAnywhere(access, 'vacancies.view') },
    { title: 'Documents', n: documents, text: 'Word, Excel and PDF files of this division.', href: q(`type:document division:${d.key}`), show: canAnywhere(access, 'documents.view') },
    { title: 'Support tickets', n: tickets, text: 'Tickets raised for this division.', href: q(`type:ticket division:${d.key}`), show: canAnywhere(access, 'tickets.view') },
    { title: 'Assets', n: assets, text: 'Equipment held by this division.', href: q(`type:asset division:${d.key}`), show: canAnywhere(access, 'assets.view') },
  ];
  return (
    <>
      <PageHead title={d.name} sub={d.description ?? 'Division workspace'} eyebrow="ADA Hub / Divisions" />
      <p className="small"><Link href="/divisions">← All divisions</Link></p>
      <div className="grid g4" data-division-page={d.key}>
        {cards.filter((c) => c.show).map((c) => {
          const body = <><div className="l">{c.title}</div><div className="n">{c.n === null ? '—' : c.n}</div><div className="d">{c.text}</div>{c.href && <div className="open">Open →</div>}</>;
          return c.href ? <Link key={c.title} className="stat" href={c.href}>{body}</Link> : <div key={c.title} className="stat">{body}</div>;
        })}
      </div>
      <section className="card" style={{ marginTop: 14 }}>
        <h2>Add to this division</h2>
        <p className="small muted">New records start from their own page; the division is chosen there.</p>
        <p>
          {canAnywhere(access, 'clients.create') && <Link className="head-action" href="/clients/new">New client +</Link>}{' '}
          {canAnywhere(access, 'documents.create') && <Link className="head-action" href="/documents/new">New document +</Link>}
        </p>
      </section>
    </>
  );
}
