import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { rid } from '@/lib/db';
import { fmtDateTime, label } from '@/lib/format';
import { Empty, PageHead } from '@/components/ui';

// One queue for everything the approval engine is holding. Reads approval_requests under the signed-in
// user's RLS, so each person sees only what they may see. Deciding happens on the record itself.
export default async function ApprovalsPage() {
  const access = await requireAccess();
  const supabase = await createClient();
  const { data } = await supabase.from('approval_requests')
    .select('id, kind, entity_ada_id, summary, requested_at, requested_by, required_permission')
    .eq('status', 'pending').order('requested_at');
  const rows = (data ?? []) as any[];
  const mine = rows.filter((r) => r.requested_by === access.staff.id);
  const theirs = rows.filter((r) => r.requested_by !== access.staff.id);
  const table = (list: any[]) => (
    <div className="scroll"><table>
      <thead><tr><th>Record</th><th>Type</th><th>What</th><th>Requested</th></tr></thead>
      <tbody>{list.map((r) => (
        <tr key={r.id}><td className="mono"><Link href={rid(r.entity_ada_id)}>{r.entity_ada_id}</Link></td><td>{label(r.kind)}</td><td>{r.summary}</td><td>{fmtDateTime(r.requested_at)}</td></tr>
      ))}</tbody>
    </table></div>
  );
  return (
    <>
      <PageHead title="Approvals" sub="Everything waiting for a decision. Open the record to approve or reject." />
      <section className="card"><h2>Waiting for you ({theirs.length})</h2>{theirs.length ? table(theirs) : <Empty>Nothing is waiting for your decision.</Empty>}</section>
      <section className="card"><h2>Your requests still pending ({mine.length})</h2>{mine.length ? table(mine) : <Empty>You have no pending requests.</Empty>}</section>
    </>
  );
}
