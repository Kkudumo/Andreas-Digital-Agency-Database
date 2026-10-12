import Link from 'next/link';
import { requireAccess, divisionsFor } from '@/lib/access';
import { call, rid, type Rec } from '@/lib/db';
import { getDivisions } from '@/components/panels';
import { Flash, PageHead } from '@/components/ui';
import { createClientAction } from '../../actions';

// Step 1: search for the company. Step 2: reuse it, or (only if nothing matches) create it. One organization, whichever division asks.
export default async function NewClient({ searchParams }: { searchParams: Promise<{ name?: string; ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const name = (sp.name ?? '').trim();
  const allowed = divisionsFor(access, 'clients.create');   // null = every division
  const divisions = (await getDivisions()).filter((d) => allowed === null || allowed.includes(d.id));
  let matches: Rec[] = [];
  if (name.length >= 2) {
    const r = await call<Rec[]>('client_lookup', { p_name: name });
    matches = r.data ?? [];
  }
  return (
    <>
      <PageHead title="New client" sub="Check whether ADA already works with this company before creating anything" />
      <Flash error={sp.error} ok={sp.ok} />
      <form action="/clients/new" method="get" className="card">
        <label>Company name<input name="name" defaultValue={name} required minLength={2} autoFocus /></label>
        <div style={{ marginTop: '.6rem' }}><button className="primary" type="submit">Check for an existing client</button></div>
      </form>

      {name.length >= 2 && (
        <>
          <section className="card">
            <h2>{matches.length > 0 ? 'ADA already knows these companies' : 'No existing client found'}</h2>
            {matches.length > 0 ? (
              <div className="scroll"><table>
                <thead><tr><th>Client</th><th>Match</th><th>Status</th><th></th></tr></thead>
                <tbody>{matches.map((m) => (
                  <tr key={m.client}>
                    <td><Link href={rid(m.client)}><b>{m.name}</b></Link> <span className="mono muted small">{m.client}</span></td>
                    <td>{String(m.match).replace(/_/g, ' ')}</td><td>{m.status}</td>
                    <td><Link href={rid(m.client)}>Use this client</Link></td>
                  </tr>
                ))}</tbody>
              </table></div>
            ) : <div className="muted small">Restricted clients are never shown or hinted at here.</div>}
          </section>

          <section className="card">
            <h2>{matches.length > 0 ? 'Create a different company with a similar name' : 'Create the client'}</h2>
            {matches.length > 0 && <div className="flash error" role="note">Only do this if it is genuinely a different legal entity. Explain why below; the database records the decision.</div>}
            <form action={createClientAction} className="stack">
              <input type="hidden" name="name" value={name} />
              <div className="row">
                <label>Originating division<select name="division" required>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
                <label>Registration number<input name="registration" /></label>
              </div>
              <div className="row"><label>Email<input name="email" type="email" /></label><label>Phone<input name="phone" /></label></div>
              {matches.length > 0 && <label>Why is this a different company?<input name="distinct_reason" required /></label>}
              <button className="primary" type="submit">Create “{name}”</button>
            </form>
            <p className="muted small">The organization is registered once for the whole of ADA. Other divisions join this client; they never create it again.</p>
          </section>
        </>
      )}
    </>
  );
}
