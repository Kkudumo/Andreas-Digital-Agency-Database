import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { PageHead } from '@/components/ui';
import NewDocument from '@/components/office/new-document';

export default async function NewDocumentPage({ searchParams }: { searchParams: Promise<{ link?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from('divisions').select('id, name').order('name');
  const divisions = (data ?? []) as { id: string; name: string }[];
  if (!canAnywhere(access, 'documents.create')) return <><PageHead title="New document" /><div className="flash error" role="alert">You do not have permission to create documents.</div></>;
  return <><PageHead title="New document" sub="Write it here, start a spreadsheet, or upload a file you already have" /><NewDocument divisions={divisions} defaultDivision={access.staff.division_id ?? undefined} link={sp.link} /></>;
}
