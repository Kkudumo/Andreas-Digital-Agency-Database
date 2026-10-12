import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section, getDivisions } from '@/components/panels';
import { IssueKey } from '@/components/issue-key';
import { registerWebsiteAction, setWebsiteStatusAction } from './actions';
import { CAPABILITIES } from '@/lib/website-capabilities';
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
