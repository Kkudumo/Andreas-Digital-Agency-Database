import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { money } from '@/lib/db';
import { fmtDate } from '@/lib/format';
import { Badge, Flash, PageHead } from '@/components/ui';
import { decidePriceAction, proposePriceAction, serviceStatusAction, updateServiceAction, withdrawPriceAction } from '../../actions';
import { ServiceFields } from '../../service-fields';

// Step 3: one service. Edit its details, set or change its price, and move it through approval and publication.
export default async function ServicePage({ params, searchParams }: { params: Promise<{ division: string; id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const { division: key, id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: s } = await supabase.from('services').select('*, division:divisions!division_id(id, key, name)').eq('id', id).is('deleted_at', null).maybeSingle();
  if (!s || s.division?.key !== key) notFound();
  const { data: pr } = await supabase.from('service_prices').select('*').eq('service_id', id).order('version', { ascending: false });
  const prices = (pr ?? []) as any[];

  const path = `/services/${key}/${id}`;
  const today = new Date().toISOString().slice(0, 10);
  const current = prices.find((p) => p.status === 'approved' && p.effective_from <= today && (!p.effective_to || p.effective_to >= today));
  const pending = prices.find((p) => p.status === 'pending_approval');
  const canEdit = can(access, 'services.update', s.division_id);
  const canPropose = can(access, 'pricing.propose', s.division_id);
  const canApprove = can(access, 'pricing.approve');
  const canPublish = can(access, 'services.publish');

  const next: { to: string; label: string; show: boolean }[] = [
    { to: 'pending_approval', label: 'Submit for approval', show: canEdit && ['draft', 'unpublished'].includes(s.status) },
    { to: 'approved', label: 'Approve', show: canPublish && s.status === 'pending_approval' },
    { to: 'draft', label: 'Send back to draft', show: (canEdit || canPublish) && s.status === 'pending_approval' },
    { to: 'published', label: 'Publish on websites', show: canPublish && s.status === 'approved' },
    { to: 'unpublished', label: 'Unpublish', show: canPublish && s.status === 'published' },
    { to: 'archived', label: 'Archive', show: canPublish && s.status !== 'archived' },
  ].filter((n) => n.show);

  return (
    <>
      <PageHead title={s.name} sub={`${s.division.name} · ${s.ada_id}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <p className="muted small"><Link href={`/services/${key}`}>← {s.division.name} services</Link></p>

      <section className="card">
        <h2>Status</h2>
        <p><Badge v={s.status} /> {s.status_reason && <span className="muted small">{s.status_reason}</span>}</p>
        {next.length > 0 && (
          <div className="row">
            {next.map((n) => (
              <form action={serviceStatusAction} key={n.to}>
                <input type="hidden" name="id" value={s.id} /><input type="hidden" name="to" value={n.to} /><input type="hidden" name="return" value={path} />
                <button className={n.to === 'published' || n.to === 'approved' ? 'primary' : ''} type="submit">{n.label}</button>
              </form>
            ))}
          </div>
        )}
        <p className="muted small">A service needs a summary and a description before it can be submitted. Only approved and published services appear on a website.</p>
      </section>

      <section className="card">
        <h2>Price</h2>
        <p>
          {s.pricing_model === 'quote_based' ? <b>Price on request</b> : current ? <b>{money(current.amount, current.currency)}</b> : <span className="muted">No approved price yet</span>}
          {current && <span className="muted small"> · in force since {fmtDate(current.effective_from)}</span>}
        </p>
        {pending && (
          <div className="flash error" role="note">
            <b>Awaiting approval:</b> {pending.amount === null ? 'price on request' : money(pending.amount, pending.currency)} from {fmtDate(pending.effective_from)} — {pending.reason}
            <div className="row" style={{ marginTop: '.5rem' }}>
              {canApprove && (
                <form action={decidePriceAction} className="row">
                  <input type="hidden" name="price" value={pending.id} /><input type="hidden" name="return" value={path} />
                  <input name="note" placeholder="Note (required to reject)" />
                  <button className="primary" name="decision" value="approve" type="submit">Approve price</button>
                  <button name="decision" value="reject" type="submit">Reject</button>
                </form>
              )}
              {pending.proposed_by === access.staff.id && (
                <form action={withdrawPriceAction}>
                  <input type="hidden" name="price" value={pending.id} /><input type="hidden" name="return" value={path} />
                  <button type="submit">Withdraw</button>
                </form>
              )}
            </div>
          </div>
        )}
        {canPropose && !pending && (
          <form action={proposePriceAction} className="stack">
            <input type="hidden" name="id" value={s.id} /><input type="hidden" name="return" value={path} />
            <div className="row">
              {s.pricing_model !== 'quote_based' && <label>New price (NAD)<input name="amount" type="number" step="0.01" min="0" required /></label>}
              <label>Takes effect<input name="effective_from" type="date" defaultValue={today} min={today} required /></label>
            </div>
            <label>Reason<input name="reason" required placeholder="e.g. Price as published on the website, 5 October 2026" /></label>
            <button className="primary" type="submit">{current ? 'Propose a new price' : 'Add price'}</button>
          </form>
        )}
        {!canPropose && !pending && <p className="muted small">You do not have permission to change prices for this division.</p>}

        {prices.length > 0 && (
          <div className="scroll"><table>
            <thead><tr><th>Version</th><th>Price</th><th>From</th><th>To</th><th>Status</th><th>Reason</th></tr></thead>
            <tbody>{prices.map((p) => (
              <tr key={p.id}><td>{p.version}</td><td>{p.amount === null ? 'On request' : money(p.amount, p.currency)}</td><td>{fmtDate(p.effective_from)}</td><td>{fmtDate(p.effective_to)}</td><td><Badge v={p.status} /></td><td>{p.reason}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>

      {canEdit ? (
        <section className="card">
          <h2>Details</h2>
          <form action={updateServiceAction} className="stack">
            <input type="hidden" name="id" value={s.id} /><input type="hidden" name="return" value={path} />
            <ServiceFields s={s} editing />
            <button className="primary" type="submit">Save changes</button>
          </form>
          <p className="muted small">Editing the name, wording or pricing model of an approved or published service sends it back to draft for approval again. Prices are never edited: propose a new one instead, so history is kept.</p>
        </section>
      ) : (
        <section className="card"><h2>Details</h2><p>{s.summary ?? '—'}</p><p className="muted">{s.description}</p></section>
      )}
    </>
  );
}
