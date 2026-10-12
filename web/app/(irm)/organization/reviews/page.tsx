import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Empty, Flash, PageHead } from '@/components/ui';
import { Return } from '@/components/panels';
import { resolveOrganizationReviewAction } from '../../actions';
import { fmtDate } from '@/lib/format';

export default async function OrganizationReviewsPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('organization_reviews').select('id, left_org_id, right_org_id, reason, score, created_at').eq('status', 'open').order('created_at');
  const rows = (data ?? []) as any[];
  const ids = [...new Set(rows.flatMap((r) => [r.left_org_id, r.right_org_id]))];
  const { data: orgs } = ids.length ? await supabase.from('organizations').select('id, name, registration_number, email, phone, city').in('id', ids) : { data: [] as any[] };
  const byId = new Map(((orgs ?? []) as any[]).map((o) => [o.id, o]));
  const card = (o: any) => o ? <div><b>{o.name}</b><div className="muted small">{[o.registration_number, o.email, o.phone, o.city].filter(Boolean).join(' · ') || 'no further details'}</div></div> : <span className="muted">not visible</span>;
  return (
    <>
      <PageHead title="Possible duplicate organizations" sub="Nothing is merged automatically. Merging keeps one organization, re-points every role to it, and leaves the other as a tombstone so its old IDs still resolve." />
      <Flash error={sp.error} ok={sp.ok} />
      {rows.length === 0 ? <section className="card"><Empty>No open reviews (or you do not have matching.review).</Empty></section> : rows.map((r) => (
        <section className="card" key={r.id}>
          <div className="row">{card(byId.get(r.left_org_id))}{card(byId.get(r.right_org_id))}</div>
          <p className="muted small">Why: {r.reason}{r.score ? ` (similarity ${Number(r.score).toFixed(2)})` : ''} · raised {fmtDate(r.created_at)}</p>
          <form action={resolveOrganizationReviewAction} className="row" style={{ gridTemplateColumns: '1fr 2fr auto', alignItems: 'end' }}>
            <Return to="/organization/reviews" />
            <input type="hidden" name="review" value={r.id} /><input type="hidden" name="left" value={r.left_org_id} /><input type="hidden" name="right" value={r.right_org_id} />
            <label>Decision<select name="outcome">
              <option value="same_left">Same — keep the left one</option><option value="same_right">Same — keep the right one</option>
              <option value="distinct">Different organizations</option><option value="dismissed">Dismiss</option></select></label>
            <label>Note (required)<input name="note" required /></label>
            <button className="primary" type="submit">Resolve</button>
          </form>
        </section>
      ))}
    </>
  );
}
