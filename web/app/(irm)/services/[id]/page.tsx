import { notFound } from 'next/navigation';
import { requireAccess, can, canAnywhere } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, LinkTable, Return, Section } from '@/components/panels';
import { decidePriceAction, proposePriceAction, publishServiceAction, saveServiceAction, serviceTransitionAction } from '../actions';
import { fmtDate } from '@/lib/format';

export default async function ServicePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess();
  const { id } = await params; const sp = await searchParams;
  const supabase = await createClient();
  const { data: s } = await supabase.from('services').select('*, division:divisions(id, name)').eq('id', id).is('deleted_at', null).maybeSingle();
  if (!s) notFound();
  const here = `/services/${id}`;
  const today = new Date().toISOString().slice(0, 10);
  const { data: prices } = await supabase.from('service_prices').select('*').eq('service_id', id).order('version', { ascending: false });
  const list = (prices ?? []) as any[];
  const current = list.find((p) => p.status === 'approved' && p.effective_from <= today && (!p.effective_to || p.effective_to >= today));
  const upcoming = list.find((p) => p.status === 'approved' && p.effective_from > today);
  const pending = list.find((p) => p.status === 'pending_approval');
  const latestApproved = list.find((p) => p.status === 'approved');
  // A new version must start after the latest approved one: today if that began before today, otherwise the day after it.
  const nextDate = (() => { const d = latestApproved && latestApproved.effective_from >= today ? new Date(latestApproved.effective_from) : new Date(today); if (latestApproved && latestApproved.effective_from >= today) d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); })();
  const edit = can(access, 'services.update', s.division_id);
  const propose = can(access, 'pricing.propose', s.division_id);
  const approvePrice = canAnywhere(access, 'pricing.approve');
  const publish = canAnywhere(access, 'services.publish');
  const quoted = s.pricing_model === 'quote_based';

  const NEXT: Record<string, string[]> = { draft: ['pending_approval', 'archived'], pending_approval: ['approved', 'draft'], approved: ['published', 'draft'], published: ['unpublished'], unpublished: ['pending_approval', 'archived'], archived: [] };

  return (
    <>
      <PageHead title={s.name} sub={`${s.division?.name} · ${s.ada_id}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <div className="grid g4" style={{ marginBottom: '1rem' }}>
        <div className="stat"><div className="n">{quoted ? 'Quoted' : current ? <>{current.is_starting_price && <span style={{ fontSize: '1rem' }}>from </span>}{money(current.amount, current.currency)}</> : '—'}</div><div className="l">{quoted ? 'no list price' : current ? `price now · since ${fmtDate(current.effective_from)}` : 'no price in force'}</div></div>
        <div className="stat"><div className="n" style={{ fontSize: '1.4rem' }}><Badge v={s.status} /></div><div className="l">on the websites: {s.status === 'published' ? 'yes' : 'no'}</div></div>
      </div>
      {pending && <div className="flash ok" role="status">A new price of {money(pending.amount, pending.currency)} is waiting for approval.</div>}
      {upcoming && <div className="flash ok" role="status">{money(upcoming.amount, upcoming.currency)} takes effect on {fmtDate(upcoming.effective_from)}.</div>}

      {!quoted && propose && (
        <Section title="Change the price">
          <form action={proposePriceAction} className="stack">
            <Return to={here} /><input type="hidden" name="service" value={id} />
            <div className="row">
              <label>New price (NAD)<input name="amount" type="number" step="0.01" min="0" required defaultValue={current?.amount ?? ''} /></label>
              <label>Takes effect<input name="effective_from" type="date" min={nextDate} defaultValue={nextDate} /></label>
            </div>
            <label className="small"><input type="checkbox" name="starting" defaultChecked={!!current?.is_starting_price} /> This is a starting price — websites show it as “from”</label>
            <label>Reason<input name="reason" placeholder="why the price changes" /></label>
            <button className="primary" type="submit">{approvePrice ? 'Save price (takes effect on the date above)' : 'Propose price for approval'}</button>
            <div className="muted small">Old prices are never edited: each change is a new version with its own date, so quotes and invoices keep the price they were made at. {approvePrice ? 'You can approve prices, so this is approved when you save.' : 'Someone who can approve prices will see it in their inbox.'}</div>
          </form>
        </Section>
      )}

      {edit && (
        <Section title="Details shown on the websites">
          <form action={saveServiceAction} className="stack">
            <Return to={here} /><input type="hidden" name="service" value={id} />
            <div className="row">
              <label>Name<input name="name" defaultValue={s.name} required /></label>
              <label>Category<input name="category" defaultValue={s.category ?? ''} /></label>
            </div>
            <label>Summary<input name="summary" defaultValue={s.summary ?? ''} maxLength={500} required /></label>
            <label>Description<textarea name="description" rows={4} defaultValue={s.description ?? ''} /></label>
            <div className="row">
              <label>Billing unit<input name="billing_unit" defaultValue={s.billing_unit} /></label>
              <div>
                <label className="small"><input type="checkbox" name="show_price" defaultChecked={s.show_price} disabled={quoted} /> Show the price on websites</label><br />
                <label className="small"><input type="checkbox" name="is_active" defaultChecked={s.is_active} /> Available to quote today</label>
                {s.status === 'published' && publish && <><br /><label className="small"><input type="checkbox" name="keep_published" defaultChecked /> Keep it published after saving</label></>}
              </div>
            </div>
            <button className="primary" type="submit">Save details</button>
            {s.status === 'published' && <div className="muted small">Changing the wording of a published service takes it back to draft until it is approved again{publish ? '; “keep it published” does that for you.' : '.'}</div>}
          </form>
        </Section>
      )}

      <Section title="Publication">
        <KV rows={[['Status', <Badge key="s" v={s.status} />], ['Published', s.published_at ? fmtDate(s.published_at) : '—'], ['Note', s.status_reason]]} />
        <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap', marginTop: '.8rem' }}>
          {s.status !== 'published' && s.status !== 'archived' && (
            <form action={publishServiceAction}><Return to={here} /><input type="hidden" name="service" value={id} /><button className="primary" type="submit">Publish to the websites</button></form>
          )}
          {s.status === 'published' && (
            <form action={serviceTransitionAction}><Return to={here} /><input type="hidden" name="service" value={id} /><input type="hidden" name="to" value="unpublished" /><button type="submit">Take off the websites</button></form>
          )}
        </div>
        {!publish && <div className="muted small" style={{ marginTop: '.5rem' }}>Publishing needs services.publish; without it, the service waits for approval.</div>}
      </Section>

      <Section title="Price history" count={list.length}>
        <LinkTable rows={list} cols={[
          { head: 'Version', key: 'version' }, { head: 'Price', render: (p) => p.amount === null ? '—' : <>{p.is_starting_price && <span className="muted small">from </span>}{money(p.amount, p.currency)}</> },
          { head: 'From', render: (p) => fmtDate(p.effective_from) }, { head: 'To', render: (p) => p.effective_to ? fmtDate(p.effective_to) : '—' },
          { head: 'Status', render: (p) => <Badge v={p.status} /> }, { head: 'Reason', render: (p) => <span className="small">{p.reason}</span> },
          { head: '', render: (p) => p.status === 'pending_approval' && approvePrice ? (
            <form action={decidePriceAction} className="row" style={{ gridTemplateColumns: 'auto auto auto', alignItems: 'end' }}><Return to={here} /><input type="hidden" name="price" value={p.id} />
              <button className="link" name="decision" value="approve" type="submit">Approve</button><input name="note" placeholder="note (needed to reject)" /><button className="link" name="decision" value="reject" type="submit">Reject</button></form>) : null },
        ]} />
      </Section>
    </>
  );
}
