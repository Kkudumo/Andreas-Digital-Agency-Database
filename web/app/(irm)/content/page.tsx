import Link from 'next/link';
import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { Return, Section, getDivisions } from '@/components/panels';
import { createContentAction } from './actions';
import { ContentFields } from '@/components/content-fields';
import { fmtDate } from '@/lib/format';

const TABS = [{ k: 'post', label: 'News and updates', table: 'content_posts' }, { k: 'testimonial', label: 'Testimonials', table: 'testimonials' }, { k: 'faq', label: 'FAQs', table: 'faqs' }] as const;

export default async function ContentPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string; tab?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const tab = TABS.find((t) => t.k === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  const [{ data }, divisions, { data: services }] = await Promise.all([
    supabase.from(tab.table).select('*, division:divisions(name)').order('created_at', { ascending: false }).limit(200),
    getDivisions(),
    supabase.from('services').select('id, name').is('deleted_at', null).order('name'),
  ]);
  const rows = (data ?? []) as any[];
  const label = (r: any) => r.title ?? r.person_name ?? r.question;
  return (
    <>
      <PageHead title="Website content" sub="What the websites say, kept here like what they sell. Publishing is deliberate: nothing is public until it is approved and published." />
      <Flash error={sp.error} ok={sp.ok} />
      <nav className="row" style={{ gridTemplateColumns: 'repeat(3, 1fr)', marginBottom: '1rem' }}>
        {TABS.map((t) => <Link key={t.k} className={t.k === tab.k ? 'primary' : ''} href={`/content?tab=${t.k}`}>{t.label}</Link>)}
      </nav>
      <section className="card">
        {rows.length === 0 ? <Empty>Nothing here yet.</Empty> : (
          <div className="scroll"><table>
            <thead><tr><th>{tab.k === 'post' ? 'Title' : tab.k === 'testimonial' ? 'Person' : 'Question'}</th><th>For</th><th>Status</th><th>Published</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id}><td><Link href={`/content/${tab.k}/${r.id}`}><b>{label(r)}</b></Link><div className="mono muted small">{r.ada_id}{r.content_type ? ` · ${r.content_type}` : ''}</div></td>
                <td>{r.division?.name ?? 'whole agency'}</td><td><Badge v={r.status} /></td><td>{r.published_at ? fmtDate(r.published_at) : '—'}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </section>
      {canAnywhere(access, 'content.create') && (
        <Section title={`Add ${tab.k === 'post' ? 'a post' : tab.k === 'testimonial' ? 'a testimonial' : 'a question'}`}>
          <form action={createContentAction} className="stack">
            <Return to={`/content?tab=${tab.k}`} /><input type="hidden" name="kind" value={tab.k} />
            <ContentFields kind={tab.k} divisions={divisions} services={(services ?? []) as any[]} />
            <button className="primary" type="submit">Save as draft</button>
          </form>
        </Section>
      )}
    </>
  );
}
