import { notFound } from 'next/navigation';
import { requireAccess, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Flash, PageHead } from '@/components/ui';
import { KV, Return, Section } from '@/components/panels';
import { getDivisions } from '@/components/panels';
import { ContentFields } from '@/components/content-fields';
import { contentTransitionAction, publishContentAction, saveContentAction } from '../../actions';
import { fmtDate } from '@/lib/format';

const TABLE: Record<string, string> = { post: 'content_posts', testimonial: 'testimonials', faq: 'faqs' };

export default async function ContentItemPage({ params, searchParams }: { params: Promise<{ kind: string; id: string }>; searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess();
  const { kind, id } = await params; const sp = await searchParams;
  if (!TABLE[kind]) notFound();
  const supabase = await createClient();
  const { data: r } = await supabase.from(TABLE[kind]).select('*').eq('id', id).maybeSingle();
  if (!r) notFound();
  const [divisions, { data: services }] = await Promise.all([getDivisions(), supabase.from('services').select('id, name').is('deleted_at', null).order('name')]);
  const here = `/content/${kind}/${id}`;
  const edit = canAnywhere(access, 'content.update'); const publish = canAnywhere(access, 'content.publish');
  const title = r.title ?? r.person_name ?? r.question;
  return (
    <>
      <PageHead title={title} sub={`${r.ada_id}${r.content_type ? ' · ' + r.content_type : ''}`} />
      <Flash error={sp.error} ok={sp.ok} />
      <Section title="Publication">
        <KV rows={[['Status', <Badge key="s" v={r.status} />], ['Published', r.published_at ? fmtDate(r.published_at) : '—'], ['Note', r.status_reason], ...(r.slug ? [['Address', <span key="a" className="mono">/{r.slug}</span>] as [string, React.ReactNode]] : [])]} />
        <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap', marginTop: '.8rem' }}>
          {r.status !== 'published' && r.status !== 'archived' && <form action={publishContentAction}><Return to={here} /><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><button className="primary" type="submit">Publish to the websites</button></form>}
          {r.status === 'published' && <form action={contentTransitionAction}><Return to={here} /><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="to" value="unpublished" /><button type="submit">Take off the websites</button></form>}
          {r.status !== 'archived' && publish && <form action={contentTransitionAction}><Return to={here} /><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="to" value="archived" /><input name="note" placeholder="reason" /><button type="submit">Archive</button></form>}
        </div>
        {!publish && <div className="muted small" style={{ marginTop: '.5rem' }}>Publishing needs content.publish; without it, the item waits for approval.</div>}
      </Section>
      {edit && (
        <Section title="Edit">
          <form action={saveContentAction} className="stack">
            <Return to={here} /><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} />
            <ContentFields kind={kind} divisions={divisions} services={(services ?? []) as any[]} v={r} />
            {r.status === 'published' && publish && <label className="small"><input type="checkbox" name="keep_published" defaultChecked /> Keep it published after saving</label>}
            <button className="primary" type="submit">Save</button>
            {r.status === 'published' && <div className="muted small">Changing the wording of a published item takes it back to draft until it is approved again{publish ? '; “keep it published” does that for you.' : '.'}</div>}
          </form>
        </Section>
      )}
    </>
  );
}
