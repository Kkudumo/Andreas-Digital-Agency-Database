import { notFound } from 'next/navigation';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Flash, PageHead } from '@/components/ui';
import { createStaff } from '../actions';

export default async function NewStaff({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const access = await requireAccess();
  if (!can(access, 'staff.create')) notFound();
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ data: divisions }, { data: positions }] = await Promise.all([
    supabase.from('divisions').select('id, name').eq('is_active', true).order('sort_order'),
    supabase.from('positions').select('id, title').eq('is_active', true).order('title'),
  ]);
  return (
    <>
      <PageHead title="Add staff member" sub="Creates the record only. A login is linked separately by an administrator." />
      <Flash error={sp.error} />
      <form action={createStaff} className="card stack">
        <label>Full name<input name="full_name" required /></label>
        <div className="row">
          <label>Work email<input name="email" type="email" required /></label>
          <label>Work phone<input name="work_phone" /></label>
        </div>
        <div className="row">
          <label>Position<select name="position_id" defaultValue=""><option value="">—</option>{(positions ?? []).map((p: any) => <option key={p.id} value={p.id}>{p.title}</option>)}</select></label>
          <label>Division<select name="primary_division_id" defaultValue=""><option value="">—</option>{(divisions ?? []).map((d: any) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
        </div>
        <label>Start date<input name="start_date" type="date" /></label>
        <div><button className="primary" type="submit">Create staff record</button></div>
      </form>
    </>
  );
}
