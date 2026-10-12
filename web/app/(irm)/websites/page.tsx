import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { LinkTable, Return, Section, getDivisions } from '@/components/panels';
import { IssueKey } from '@/components/issue-key';
import { addSubscriptionAction, registerWebsiteAction, setSubscriptionActiveAction, setWebsiteStatusAction } from './actions';
import { CAPABILITIES, EVENT_TYPES } from '@/lib/website-capabilities';
import { fmtDate } from '@/lib/format';

export default async function WebsitesPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const manage = can(access, 'websites.manage');
  const supabase = await createClient();
  const [{ data }, divisions] = await Promise.all([
    supabase.from('websites').select('id, ada_id, name, domain, status, capabilities, api_key_prefix, key_issued_at, division:divisions(name)').order('name'),
    getDivisions(),
  ]);
  const rows = (data ?? []) as any[];
  const { data: subs } = await supabase.from('event_subscriptions').select('id, website_id, url, secret_ref, event_types, is_active').order('created_at');
  const hostOf = (u: string) => { try { return new URL(u).host; } catch { return 'invalid'; } };   // the address itself can be a secret (a deploy hook): only the host is shown
  const { data: pending } = await supabase.from('event_deliveries').select('status');
  const count = (st: string) => ((pending ?? []) as any[]).filter((d) => d.status === st).length;
  return (
    <>
      <PageHead title="Connected websites" sub="Each website reads ADA Core through the public API with its own key, and can only do what is ticked here" />
      <Flash error={sp.error} ok={sp.ok} />
      {manage && (
        <Section title="Register a website">
          <form action={registerWebsiteAction} className="stack">
            <Return to="/websites" />
            <div className="row">
              <label>Name<input name="name" required placeholder="ADA Tech website" /></label>
              <label>Domain<input name="domain" required placeholder="tech.andreasdigitalagency.com" pattern="[A-Za-z0-9.\-]+" /></label>
            </div>
            <label>Division (optional)<select name="division"><option value="">— the whole agency —</option>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
            <fieldset><legend className="muted small">What this website may do</legend>
              <div className="row" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
                {CAPABILITIES.map((c) => <label key={c} className="small"><input type="checkbox" name={`cap:${c}`} defaultChecked={['divisions.read', 'services.read'].includes(c)} /> {c}</label>)}
              </div>
            </fieldset>
            <button className="primary" type="submit">Register</button>
          </form>
        </Section>
      )}
      {manage && rows.length > 0 && (
        <Section title="Tell a website when things change">
          <p className="muted small">Pending deliveries: {count('pending')} · delivered: {count('delivered')} · given up: {count('failed')}. A burst of changes is sent as one request. The address is a secret if it is a deploy hook, so only its host is shown after saving.</p>
          <LinkTable rows={((subs ?? []) as any[]).map((x) => ({ ...x, site: rows.find((w) => w.id === x.website_id)?.name }))} cols={[
            { head: 'Website', key: 'site' }, { head: 'Calls', render: (x) => <span className="mono">{hostOf(x.url)}</span> }, { head: 'Signed with', render: (x) => x.secret_ref ?? <span className="muted">not signed</span> },
            { head: 'When', render: (x) => <span className="small">{(x.event_types as string[]).join(', ')}</span> }, { head: 'Status', render: (x) => <Badge v={x.is_active ? 'active' : 'disabled'} /> },
            { head: '', render: (x) => <form action={setSubscriptionActiveAction}><input type="hidden" name="subscription" value={x.id} /><input type="hidden" name="active" value={x.is_active ? '0' : '1'} /><button className="link" type="submit">{x.is_active ? 'Pause' : 'Resume'}</button></form> },
          ]} />
          <form action={addSubscriptionAction} className="stack" style={{ marginTop: '.8rem' }}>
            <div className="row">
              <label>Website<select name="website">{rows.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
              <label>Address to call (https; e.g. a Vercel deploy hook)<input name="url" type="url" required pattern="https://.*" /></label>
            </div>
            <label>Name of the signing secret (optional; the secret itself is set in the dispatcher's environment)<input name="secret_ref" pattern="[A-Z][A-Z0-9_]{2,60}" placeholder="WEBHOOK_SECRET_TECH" /></label>
            <fieldset><legend className="muted small">Tell it about (none ticked = everything)</legend>
              <div className="row" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>{EVENT_TYPES.map((t) => <label key={t} className="small"><input type="checkbox" name={`ev:${t}`} defaultChecked={['service.published', 'service.unpublished', 'price.changed'].includes(t)} /> {t}</label>)}</div>
            </fieldset>
            <button className="primary" type="submit">Add notification</button>
          </form>
        </Section>
      )}
      <section className="card">
        {rows.length === 0 ? <Empty>No websites are registered (or you cannot view the registry).</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>Website</th><th>Domain</th><th>Status</th><th>May</th><th>Key</th>{manage && <th></th>}</tr></thead>
            <tbody>{rows.map((w) => (
              <tr key={w.id}>
                <td><b>{w.name}</b><div className="mono muted small">{w.ada_id}</div></td>
                <td className="mono">{w.domain}</td>
                <td><Badge v={w.status} /></td>
                <td className="small">{(w.capabilities as string[]).join(', ') || '—'}</td>
                <td className="small">{w.api_key_prefix ? <><span className="mono">{w.api_key_prefix}…</span><div className="muted">issued {fmtDate(w.key_issued_at)}</div></> : 'no key yet'}</td>
                {manage && <td>
                  <IssueKey id={w.id} hasKey={!!w.api_key_prefix} />
                  <form action={setWebsiteStatusAction} className="row" style={{ gridTemplateColumns: '1fr auto', marginTop: '.4rem' }}>
                    <input type="hidden" name="website" value={w.id} />
                    <select name="status" defaultValue={w.status}>{['planned', 'active', 'suspended', 'retired'].map((s) => <option key={s}>{s}</option>)}</select>
                    <button className="link" type="submit">Set</button>
                  </form>
                </td>}
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
