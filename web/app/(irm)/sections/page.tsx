import { requireAccess, can } from '@/lib/access';
import { call } from '@/lib/db';
import { PageHead } from '@/components/ui';
import { SectionIndex } from '@/components/section-index';

export default async function SectionsPage() {
  const access = await requireAccess();
  if (!can(access, 'roles.view')) return <><PageHead title="Database index" /><div className="flash error" role="alert">You do not have permission to view the database index.</div></>;
  const { data, error } = await call<any[]>('database_sections');
  const sections = (data ?? []) as any[];
  return (
    <>
      <PageHead title="Database index" sub="How ADA Core is arranged: every table belongs to exactly one section. Nothing is duplicated between sections." />
      {error ? <div className="flash error" role="alert">The index could not be read.</div> : <SectionIndex sections={sections} />}
    </>
  );
}
