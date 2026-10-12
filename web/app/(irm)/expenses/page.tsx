import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { money } from '@/lib/db';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section, getDivisions } from '@/components/panels';
import { createExpenseAction } from '../actions';
import { fmtDate } from '@/lib/format';

export default async function ExpensesPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const [{ data }, { data: cats }, { data: sups }, { data: projects }, divisions, { data: payables }] = await Promise.all([
    supabase.from('expenses').select('id, ada_id, description, expense_date, total, currency, status, category:expense_categories(name), project:projects(name)').order('created_at', { ascending: false }).limit(300),
    supabase.from('expense_categories').select('key, name').order('name'),
    supabase.from('suppliers').select('id, name').order('name'),
    supabase.from('projects').select('id, name').is('deleted_at', null).order('name'),
    getDivisions(),
    supabase.from('expense_payables').select('currency, bills, owed'),
  ]);
  const rows = (data ?? []) as any[];
  const owed = new Map<string, { bills: number; owed: number }>();
  for (const p of (payables ?? []) as any[]) { const o = owed.get(p.currency) ?? { bills: 0, owed: 0 }; o.bills += p.bills; o.owed += Number(p.owed); owed.set(p.currency, o); }
  return (
    <>
      <PageHead title="Expenses" sub="What ADA spends: supplier bills, approved before they are paid" />
      <Flash error={sp.error} ok={sp.ok} />
      {owed.size > 0 && (
        <div className="grid g4" style={{ marginBottom: '1rem' }}>
          {[...owed].map(([cur, o]) => <div className="stat" key={cur}><div className="n">{money(o.owed, cur)}</div><div className="l">approved, unpaid · {o.bills} bill(s)</div></div>)}
        </div>
      )}
      <Section title="Record an expense">
        <form action={createExpenseAction} className="stack">
          <Return to="/expenses" />
          <div className="row">
            <label>Division<select name="division">{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
            <label>Category<select name="category">{(cats ?? []).map((c: any) => <option key={c.key} value={c.key}>{c.name}</option>)}</select></label>
          </div>
          <label>Description<input name="description" required /></label>
          <div className="row">
            <label>Amount (excluding tax)<input name="amount" type="number" step="0.01" min="0.01" required /></label>
            <label>Tax<input name="tax" type="number" step="0.01" min="0" defaultValue="0" /></label>
          </div>
          <div className="row">
            <label>Supplier<select name="supplier"><option value="">— none —</option>{(sups ?? []).map((s: any) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
            <label>Supplier bill / reference<input name="supplier_reference" /></label>
          </div>
          <div className="row">
            <label>Project (optional)<select name="project"><option value="">— overhead —</option>{(projects ?? []).map((p: any) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
            <label>Date<input name="expense_date" type="date" /></label>
          </div>
          <button className="primary" type="submit">Record as draft</button>
        </form>
      </Section>
      <section className="card">
        {rows.length === 0 ? <Empty>No expenses visible to you.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>ID</th><th>Description</th><th>Category</th><th>Project</th><th>Date</th><th>Total</th><th>Status</th></tr></thead>
            <tbody>{rows.map((e) => (
              <tr key={e.id}><td className="mono">{e.ada_id}</td><td><Link href={`/expenses/${e.id}`}><b>{e.description}</b></Link></td><td>{e.category?.name ?? '—'}</td><td>{e.project?.name ?? 'overhead'}</td>
                <td>{fmtDate(e.expense_date)}</td><td>{money(e.total, e.currency)}</td><td><Badge v={e.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
    </>
  );
}
