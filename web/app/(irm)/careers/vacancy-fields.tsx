// The vacancy form fields, shared by "new vacancy" and the vacancy page. Disabled once the vacancy has left draft
// (the database freezes its content then, too).
export function VacancyFields({ v, disabled }: { v?: Record<string, any>; disabled?: boolean }) {
  const d = v ?? {};
  const area = (name: string, label: string, hint?: string, rows = 4) => (
    <label>{label}{hint && <span className="muted small"> {hint}</span>}
      <textarea name={name} rows={rows} defaultValue={d[name] ?? ''} disabled={disabled} /></label>
  );
  return (
    <>
      <label>Title<input name="title" required defaultValue={d.title ?? ''} disabled={disabled} placeholder="Web Developer (Internship)" /></label>
      <div className="grid g2">
        <label>Web address<span className="muted small"> (careers/…)</span><input name="slug" defaultValue={d.slug ?? ''} disabled={disabled} placeholder="web-developer-internship" /></label>
        <label>Location<input name="location" defaultValue={d.location ?? 'Rundu, Namibia'} disabled={disabled} /></label>
        <label>Type<select name="employment_type" defaultValue={d.employment_type ?? 'full_time'} disabled={disabled}>
          <option value="full_time">Full time</option><option value="part_time">Part time</option>
          <option value="contract">Contract</option><option value="internship">Internship</option>
        </select></label>
        <label>Openings<input name="openings" type="number" min={1} defaultValue={d.openings ?? 1} disabled={disabled} /></label>
        <label>Closing date<input name="closing_date" type="date" defaultValue={d.closing_date ?? ''} disabled={disabled} /></label>
        <label className="small"><input type="checkbox" name="featured" defaultChecked={!!d.featured} disabled={disabled} /> Feature it at the top of the careers page</label>
      </div>
      {area('summary', 'Summary', '(one or two sentences for the list)', 2)}
      {area('description', 'Description', '(required before approval)')}
      {area('responsibilities', 'Responsibilities')}
      {area('requirements', 'Requirements', '(required before approval)')}
      {area('qualifications', 'Qualifications', undefined, 3)}
      {area('experience', 'Experience', undefined, 2)}
      {area('application_instructions', 'How to apply', '(shown on the vacancy page)', 2)}
      <div className="grid g2">
        <label>Salary from (NAD)<input name="salary_min" type="number" min={0} step="0.01" defaultValue={d.salary_min ?? ''} disabled={disabled} /></label>
        <label>Salary to (NAD)<input name="salary_max" type="number" min={0} step="0.01" defaultValue={d.salary_max ?? ''} disabled={disabled} /></label>
      </div>
      <label className="small"><input type="checkbox" name="salary_public" defaultChecked={!!d.salary_public} disabled={disabled} /> Show the salary on the website</label>
    </>
  );
}
