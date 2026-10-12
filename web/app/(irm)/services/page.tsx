import Link from 'next/link';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section, getDivisions } from '@/components/panels';
import { createServiceAction } from './actions';

export default async function ServicesPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string; division?: string; q?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const [{ data: svc }, { data: prices }, divisions] = await Promise.all([
    supabase.from('services').select('id, ada_id, name, category, status, pricing_model, billing_unit, is_active, show_price, division_id, division:divisions(name)').is('deleted_at', null).order('name'),
    supabase.from('service_prices').select('service_id, amount, currency, effective_from, effective_to, is_starting_price').eq('status', 'approved').lte('effective_from', today).order('effective_from', { ascending: false }),
    getDivisions(),
  ]);
  const price = new Map<string, any>();
  for (const p of (prices ?? []) as any[]) if (!price.has(p.service_id) && (!p.effective_to || p.effective_to >= today)) price.set(p.service_id, p);
  const q = (sp.q ?? '').toLowerCase();
  const rows = ((svc ?? []) as any[]).filter((s) => (!sp.division || s.division_id === sp.division) && (!q || `${s.name} ${s.category ?? ''}`.toLowerCase().includes(q)));
  const canCreate = canAnywhere(access, 'services.create');
  return (
    <>
      <PageHead title="Services and prices" sub="The one catalogue. Change a price here and the websites follow; nothing is edited in page files." />
      <Flash error={sp.error} ok={sp.ok} />
      <form method="get" className="row" style={{ gridTemplateColumns: '1fr 2fr auto', alignItems: 'end', marginBottom: '1rem' }}>
        <label>Division<select name="division" defaultValue={sp.division ?? ''}><option value="">All divisions</option>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
        <label>Search<input name="q" defaultValue={sp.q ?? ''} placeholder="a service or category" /></label>
        <button type="submit">Filter</button>
      </form>
      <section className="card">
        {rows.length === 0 ? <Empty>No services match.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Service</th><th>Division</th><th>Category</th><th style={{ textAlign: 'right' }}>Price now</th><th>Status</th></tr></thead>
            <tbody>{rows.map((s) => {
              const p = price.get(s.id);
              return (
                <tr key={s.id}>
                  <td><Link href={`/services/${s.id}`}><b>{s.name}</b></Link>{!s.is_active && <> <Badge v="disabled" /></>}</td>
                  <td>{s.division?.name}</td><td className="muted">{s.category ?? '—'}</td>
                  <td style={{ textAlign: 'right' }}>{s.pricing_model === 'quote_based' ? <span className="muted">quoted</span> : p ? <>{p.is_starting_price && <span className="muted small">from </span>}{money(p.amount, p.currency)}{s.pricing_model === 'monthly' && <span className="muted small"> /month</span>}</> : <span className="muted">no price</span>}</td>
                  <td><Badge v={s.status} /></td>
                </tr>
              );
            })}</tbody>
          </table></div>
        )}
      </section>
      {canCreate && (
        <Section title="Add a service">
          <form action={createServiceAction} className="stack">
            <Return to="/services" />
            <div className="row">
              <label>Division<select name="division">{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
              <label>Name<input name="name" required /></label>
            </div>
            <div className="row">
              <label>Category<input name="category" /></label>
              <label>Sold as<select name="pricing_model" defaultValue="fixed"><option value="fixed">a fixed price</option><option value="monthly">a monthly price</option><option value="per_unit">a price per unit</option><option value="hourly">an hourly price</option><option value="quote_based">quoted each time (no list price)</option></select></label>
            </div>
            <div className="row">
              <label>Billing unit<input name="billing_unit" defaultValue="project" placeholder="job, month, page…" /></label>
              <label>Summary (shown on websites)<input name="summary" required maxLength={500} /></label>
            </div>
            <label>Description<textarea name="description" rows={3} /></label>
            <button className="primary" type="submit">Create as draft</button>
          </form>
        </Section>
      )}
    </>
  );
}
