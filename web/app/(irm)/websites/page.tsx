import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { fmtDateTime } from '@/lib/format';
import { CAPABILITIES } from '@/lib/websites';
import { registerWebsiteAction, updateWebsiteAction } from './actions';
import { KeyButton } from './key-button';

// The websites allowed to read from ADA Core through the public API (api.andreasdigitalagency.com),
// what each may read or send, and their access keys. Only a hash of each key is stored.
const SUGGESTED = ['divisions.read', 'services.read', 'statistics.read', 'enquiries.submit'];

export default async function WebsitesPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const manage = can(access, 'websites.manage');
  const supabase = await createClient();
  const [{ data: sites }, { data: divs }] = await Promise.all([
    supabase.from('websites').select('id, ada_id, name, domain, division_id, status, capabilities, api_key_prefix, key_issued_at').order('name'),
    supabase.from('divisions').select('id, name').eq('is_active', true).order('sort_order'),
  ]);
  const divName = (id: string | null) => (divs ?? []).find((d: any) => d.id === id)?.name ?? 'Whole company';
  const rows = (sites ?? []) as any[];

  return (
    <>
      <PageHead title="Websites" sub="Which websites may read from ADA Core, what they may read or send, and their access keys" />
      <Flash error={sp.error} ok={sp.ok} />
      {!can(access, 'websites.view') && !manage ? <section className="card"><Empty>You do not have access to the website registry.</Empty></section> : (
        <section className="card">
          {rows.length === 0 ? <Empty>No websites registered yet.</Empty> : (
            <div className="scroll"><table>
              <thead><tr><th>Website</th><th>Status</th><th>May read or send</th><th>Key</th>{manage && <th></th>}</tr></thead>
              <tbody>{rows.map((w) => (
                <tr key={w.id}>
                  <td><b>{w.name}</b><div className="muted small">{w.domain} · {divName(w.division_id)}</div><div className="id">{w.ada_id}</div></td>
                  <td><Badge v={w.status} /></td>
                  <td>{manage ? (
                    <form action={updateWebsiteAction} className="stack">
                      <input type="hidden" name="id" value={w.id} />
                      <div className="checks">{CAPABILITIES.map((c) => (
                        <label key={c.key} className="small"><input type="checkbox" name="capability" value={c.key} defaultChecked={(w.capabilities ?? []).includes(c.key)} /> {c.label}</label>
                      ))}</div>
                      <label className="small">Status <select name="status" defaultValue={w.status}>
                        {['planned', 'active', 'suspended', 'retired'].map((s) => <option key={s} value={s}>{s}</option>)}
                      </select></label>
                      <button type="submit">Save</button>
                    </form>
                  ) : <span className="small">{(w.capabilities ?? []).join(', ') || '—'}</span>}</td>
                  <td>{w.api_key_prefix ? <><code>{w.api_key_prefix}…</code><div className="muted small">{fmtDateTime(w.key_issued_at)}</div></> : <span className="muted">No key yet</span>}</td>
                  {manage && <td><KeyButton id={w.id} site={w.name} hasKey={!!w.api_key_prefix} /></td>}
                </tr>
              ))}</tbody>
            </table></div>
          )}
        </section>
      )}
      {manage && (
        <section className="card">
          <h2>Register a website</h2>
          <form action={registerWebsiteAction} className="stack">
            <label>Name<input name="name" placeholder="ADA Web Division" required /></label>
            <label>Domain<input name="domain" placeholder="web.andreasdigitalagency.com" required /></label>
            <label>Division<select name="division" defaultValue="">
              <option value="">Whole company</option>
              {(divs ?? []).map((d: any) => <option key={d.id} value={d.id}>{d.name}</option>)}
            </select></label>
            <fieldset><legend className="small">May read or send</legend><div className="checks">{CAPABILITIES.map((c) => (
              <label key={c.key} className="small"><input type="checkbox" name="capability" value={c.key} defaultChecked={SUGGESTED.includes(c.key)} /> {c.label}</label>
            ))}</div></fieldset>
            <button className="primary" type="submit">Register website</button>
          </form>
        </section>
      )}
    </>
  );
}
