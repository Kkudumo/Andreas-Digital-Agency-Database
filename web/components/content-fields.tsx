import type { Division } from '@/components/panels';

/** The editable fields of one content kind, used for both "add" and "edit". */
export function ContentFields({ kind, divisions, services, v = {} }: { kind: string; divisions: Division[]; services: { id: string; name: string }[]; v?: Record<string, any> }) {
  const division = (
    <label>For<select name="division" defaultValue={v.division_id ?? ''}><option value="">the whole agency</option>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
  );
  const service = (
    <label>About a service (optional)<select name="service" defaultValue={v.service_id ?? ''}><option value="">—</option>{services.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
  );
  if (kind === 'testimonial') return (
    <>
      <label>Quote<textarea name="quote" rows={3} maxLength={1200} required defaultValue={v.quote ?? ''} /></label>
      <div className="row"><label>Person<input name="person_name" required defaultValue={v.person_name ?? ''} /></label><label>Role<input name="person_role" defaultValue={v.person_role ?? ''} /></label></div>
      <div className="row"><label>Organisation<input name="organization_name" defaultValue={v.organization_name ?? ''} /></label>{division}</div>
      <div className="row">{service}<label>Order (lowest first)<input name="sort_order" type="number" defaultValue={v.sort_order ?? 100} /></label></div>
      <fieldset><legend className="muted small">Consent (required before it can be published)</legend>
        <label className="small"><input type="checkbox" name="consent_confirmed" defaultChecked={!!v.consent_confirmed} /> The person agreed to this being published</label>
        <label>How consent was given<input name="consent_note" defaultValue={v.consent_note ?? ''} placeholder="e.g. written consent by email, 3 Oct 2026" /></label>
      </fieldset>
    </>
  );
  if (kind === 'faq') return (
    <>
      <label>Question<input name="question" required defaultValue={v.question ?? ''} /></label>
      <label>Answer<textarea name="answer" rows={4} required defaultValue={v.answer ?? ''} /></label>
      <div className="row">{division}<label>Category<input name="category" defaultValue={v.category ?? ''} /></label></div>
      <div className="row">{service}<label>Order (lowest first)<input name="sort_order" type="number" defaultValue={v.sort_order ?? 100} /></label></div>
    </>
  );
  return (
    <>
      <div className="row">
        <label>Type<select name="content_type" defaultValue={v.content_type ?? 'news'}><option value="news">News</option><option value="announcement">Announcement</option><option value="update">Update</option></select></label>
        {division}
      </div>
      <label>Title<input name="title" required defaultValue={v.title ?? ''} /></label>
      <label>Address (leave blank to make one from the title)<input name="slug" defaultValue={v.slug ?? ''} pattern="[a-z0-9]+(-[a-z0-9]+)*" /></label>
      <label>Short summary<textarea name="summary" rows={2} maxLength={600} required defaultValue={v.summary ?? ''} /></label>
      <label>Full text<textarea name="body" rows={10} defaultValue={v.body ?? ''} /></label>
      <div className="row"><label>Cover image (https address)<input name="cover_image_url" type="url" defaultValue={v.cover_image_url ?? ''} /></label><label>Image description<input name="image_alt_text" defaultValue={v.image_alt_text ?? ''} /></label></div>
      <div className="row"><label>Author<input name="author_name" defaultValue={v.author_name ?? ''} /></label><label>Source<input name="source_label" defaultValue={v.source_label ?? ''} /></label></div>
      <label className="small"><input type="checkbox" name="featured" defaultChecked={!!v.featured} /> Feature prominently</label>
    </>
  );
}
