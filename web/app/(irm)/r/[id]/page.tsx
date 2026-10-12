import { redirect } from 'next/navigation';
import Link from 'next/link';
import { requireAccess } from '@/lib/access';
import { call, pathFor, type Rec } from '@/lib/db';
import { PageHead } from '@/components/ui';

// Any institutional ID or legacy ADA ID resolves here. "Not found" and "not allowed" are the same answer.
export default async function Resolve({ params }: { params: Promise<{ id: string }> }) {
  await requireAccess();
  const { id } = await params;
  const { data } = await call<Rec>('entity_resolve', { p_id: decodeURIComponent(id) });
  if (data?.authoritative_domain && data?.authoritative_record_key) {
    redirect(pathFor(data.authoritative_domain, data.authoritative_record_key, data.institutional_id));
  }
  return (
    <>
      <PageHead title="Record not found" sub="There is no record with that ID that you are allowed to see." />
      <Link className="primary" href="/search">Back to search</Link>
    </>
  );
}
