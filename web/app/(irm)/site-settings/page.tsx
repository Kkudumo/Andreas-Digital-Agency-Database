import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section, getDivisions } from '@/components/panels';
import { addSettingAction, saveSettingAction } from '../content/actions';

export default async function SiteSettingsPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const [{ data }, divisions] = await Promise.all([supabase.from('site_settings').select('*, division:divisions(name)').order('group_name').order('sort_order').order('key'), getDivisions()]);
  const rows = (data ?? []) as any[];
  const edit = canAnywhere(access, 'settings.update');
  const groups = [...new Set(rows.map((r) => r.group_name))];
  return (
    <>
      <PageHead title="Website facts and rules" sub="The contact details every website prints and the numbers the planners use. Change one here and the sites follow on their next refresh." />
      <Flash error={sp.error} ok={sp.ok} />
      {rows.length === 0 ? <section className="card"><Empty>No settings.</Empty></section> : groups.map((g) => (
        <section className="card" key={g}>
          <h2>{g.replace(/_/g, ' ')}</h2>
          <div className="scroll"><table>
            <thead><tr><th>Setting</th><th>For</th><th>Value</th>{edit && <th></th>}</tr></thead>
            <tbody>{rows.filter((r) => r.group_name === g).map((r) => (
              <tr key={r.id}>
                <td><b>{r.label}</b><div className="mono muted small">{r.key}</div></td><td>{r.division?.name ?? 'whole agency'}</td>
                {edit ? (
                  <td colSpan={2}><form action={saveSettingAction} className="row" style={{ gridTemplateColumns: '1fr auto auto', alignItems: 'center' }}>
                    <Return to="/site-settings" /><input type="hidden" name="id" value={r.id} />
                    <input name="value" defaultValue={r.value} required />
                    <label className="small"><input type="checkbox" name="is_public" defaultChecked={r.is_public} /> public</label>
                    <button className="link" type="submit">Save</button>
                  </form></td>
                ) : <td>{r.value}{r.is_public ? '' : ' (internal)'}</td>}
              </tr>
            ))}</tbody>
          </table></div>
        </section>
      ))}
      {edit && (
        <Section title="Add a setting">
          <form action={addSettingAction} className="stack">
            <Return to="/site-settings" />
            <div className="row"><label>Key (letters, digits, underscores and dots)<input name="key" required pattern="[a-z0-9_]+(\.[a-z0-9_]+)+" placeholder="company.opening_hours" /></label><label>Label<input name="label" required /></label></div>
            <div className="row"><label>Value<input name="value" required /></label><label>Type<select name="value_type">{['text', 'number', 'url', 'email', 'phone'].map((t) => <option key={t}>{t}</option>)}</select></label></div>
            <div className="row"><label>For<select name="division"><option value="">the whole agency</option>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label><label>Group<input name="group_name" defaultValue="general" /></label></div>
            <label className="small"><input type="checkbox" name="is_public" defaultChecked /> Public (returned to websites)</label>
            <button className="primary" type="submit">Add</button>
          </form>
        </Section>
      )}
    </>
  );
}
