import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { money } from '@/lib/db';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { createServiceAction } from '../actions';
import { ServiceFields } from '../service-fields';

const TYPE_ORDER = ['package', 'service', 'plan', 'add-on', 'fee'];
const TYPE_TITLE: Record<string, string> = { package: 'Packages', service: 'Services', plan: 'Monthly plans', 'add-on': 'Add-ons', fee: 'Fees' };

// Step 2: every service of one division, with its current price, and a form to add a new service or add-on.
export default async function DivisionServices({ params, searchParams }: { params: Promise<{ division: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const { division: key } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: div } = await supabase.from('divisions').select('id, key, name').eq('key', key).eq('is_active', true).maybeSingle();
  if (!div) notFound();

  const { data: svc } = await supabase.from('services')
    .select('id, ada_id, name, category, pricing_model, billing_unit, status, is_active, show_price')
    .eq('division_id', div.id).is('deleted_at', null).order('name').limit(500);
  const services = (svc ?? []) as any[];
  const ids = services.map((s) => s.id);
  const { data: pr } = ids.length
    ? await supabase.from('service_prices').select('id, service_id, amount, currency, effective_from, effective_to, status').in('service_id', ids).in('status', ['approved', 'pending_approval'])
    : { data: [] as any[] };
  const prices = (pr ?? []) as any[];
  const today = new Date().toISOString().slice(0, 10);
  const current = (id: string) => prices.find((p) => p.service_id === id && p.status === 'approved' && p.effective_from <= today && (!p.effective_to || p.effective_to >= today));
  const pending = (id: string) => prices.find((p) => p.service_id === id && p.status === 'pending_approval');

  const base = `/services/${div.key}`;
  const groups = TYPE_ORDER.map((t) => ({ t, rows: services.filter((s) => (s.category ?? 'service') === t) })).filter((g) => g.rows.length > 0);
  const other = services.filter((s) => !TYPE_ORDER.includes(s.category ?? 'service'));
  if (other.length) groups.push({ t: 'other', rows: other });

  return (
    <>
      <PageHead title={`${div.name} services`} sub={`${services.length} in the catalogue. Open one to edit it or change its price.`} />
      <Flash error={sp.error} ok={sp.ok} />
      <p className="muted small"><Link href="/services">← All divisions</Link></p>

      {services.length === 0 ? <section className="card"><Empty>No services yet. Add the first one below.</Empty></section> : groups.map((g) => (
        <section className="card" key={g.t}>
          <h2>{TYPE_TITLE[g.t] ?? 'Other'}</h2>
          <div className="scroll"><table>
            <thead><tr><th>ADA ID</th><th>Name</th><th>Price</th><th>Billed</th><th>Status</th></tr></thead>
            <tbody>{g.rows.map((s) => {
              const c = current(s.id); const p = pending(s.id);
              return (
                <tr key={s.id}>
                  <td className="mono">{s.ada_id}</td>
                  <td><Link href={`${base}/${s.id}`}><b>{s.name}</b></Link>{!s.is_active && <> <span className="muted small">(inactive)</span></>}</td>
                  <td>
                    {s.pricing_model === 'quote_based' ? 'Price on request' : c ? money(c.amount, c.currency) : <span className="muted">No price yet</span>}
                    {p && <div className="small"><Badge v="pending_approval" /> {p.amount === null ? 'on request' : money(p.amount, p.currency)}</div>}
                  </td>
                  <td>{s.pricing_model.replace(/_/g, ' ')} · per {s.billing_unit}</td>
                  <td><Badge v={s.status} /></td>
                </tr>
              );
            })}</tbody>
          </table></div>
        </section>
      ))}

      {can(access, 'services.create', div.id) && (
        <section className="card">
          <h2>Add a service or add-on</h2>
          <form action={createServiceAction} className="stack">
            <input type="hidden" name="division" value={div.id} />
            <input type="hidden" name="return" value={base} />
            <ServiceFields />
            <button className="primary" type="submit">Add to {div.name}</button>
          </form>
          <p className="muted small">It is created as a draft. Add its price on the next page; nothing appears on a website until it is approved and published.</p>
        </section>
      )}
    </>
  );
}
