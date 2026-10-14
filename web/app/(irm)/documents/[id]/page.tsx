import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireAccess, can } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, PageHead } from '@/components/ui';
import { rid } from '@/lib/db';
import DocumentWorkspace from '@/components/office/workspace';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function DocumentPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requireAccess(); const { id } = await params;
  if (!UUID.test(id)) notFound();
  const supabase = await createClient();
  const { data: d } = await supabase.from('documents').select('id, title, description, status, effective_classification, is_critical, division_id, owner_staff_id, created_at, document_type:document_types(name), division:divisions!division_id(name)').eq('id', id).maybeSingle();
  if (!d) notFound();                                  // hidden and missing look the same
  const [{ data: versions }, { data: links }, { data: reg }] = await Promise.all([
    supabase.from('document_versions').select('version_no, state, label, original_filename, uploaded_at, size_bytes').eq('document_id', id).order('version_no'),
    supabase.from('document_links').select('entity_institutional_id, role').eq('document_id', id).is('removed_at', null),
    supabase.from('entity_registry').select('institutional_id').eq('table_name', 'documents').eq('entity_id', id).maybeSingle(),
  ]);
  const doc: any = d;
  const canEdit = doc.status === 'active' && (can(access, 'documents.create', doc.division_id) || doc.owner_staff_id === access.staff.id);
  return (
    <>
      <PageHead title={doc.title} sub={`${doc.document_type?.name ?? 'Document'} · ${doc.division?.name ?? ''}${reg?.institutional_id ? ' · ' + reg.institutional_id : ''}`} />
      <p><Badge v={doc.status} /> {doc.effective_classification !== 'internal' && <Badge v={doc.effective_classification} />} {doc.is_critical && <span className="badge warn">critical</span>}
        {(links ?? []).length > 0 && <> · Attached to: {(links as any[]).map((l, i) => <span key={i}>{i ? ', ' : ''}<Link href={rid(l.entity_institutional_id)}>{l.entity_institutional_id}</Link></span>)}</>}</p>
      <section className="card">
        <DocumentWorkspace doc={id} title={doc.title} versions={(versions ?? []) as any[]} canEdit={canEdit} />
      </section>
      <p><Link href="/documents">← All documents</Link></p>
    </>
  );
}
