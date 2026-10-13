// Shared form fields for adding and editing a service. Used inside a <form> by the pages.
type Initial = { name?: string; category?: string | null; summary?: string | null; description?: string | null; pricing_model?: string; billing_unit?: string; show_price?: boolean; is_active?: boolean };

export const CATEGORIES = [
  { v: 'service', t: 'Service' }, { v: 'package', t: 'Package' }, { v: 'plan', t: 'Monthly plan' }, { v: 'add-on', t: 'Add-on' }, { v: 'fee', t: 'Fee' },
];
export const MODELS = [
  { v: 'fixed', t: 'Fixed price' }, { v: 'monthly', t: 'Monthly' }, { v: 'hourly', t: 'Hourly' }, { v: 'per_unit', t: 'Per unit' }, { v: 'quote_based', t: 'Price on request (quoted)' },
];
export const UNITS = ['project', 'month', 'hour', 'device', 'campaign', 'unit'];

export function ServiceFields({ s, editing }: { s?: Initial; editing?: boolean }) {
  return (
    <>
      <div className="row">
        <label>Name<input name="name" defaultValue={s?.name ?? ''} required /></label>
        <label>Type
          <select name="category" defaultValue={s?.category ?? 'service'}>
            {CATEGORIES.map((c) => <option key={c.v} value={c.v}>{c.t}</option>)}
          </select>
        </label>
      </div>
      <div className="row">
        <label>How it is priced
          <select name="pricing_model" defaultValue={s?.pricing_model ?? 'fixed'}>
            {MODELS.map((m) => <option key={m.v} value={m.v}>{m.t}</option>)}
          </select>
        </label>
        <label>Billed per
          <select name="billing_unit" defaultValue={s?.billing_unit ?? 'project'}>
            {UNITS.map((u) => <option key={u} value={u}>{u}</option>)}
          </select>
        </label>
      </div>
      <label>Summary (one line, shown on the website)<input name="summary" defaultValue={s?.summary ?? ''} /></label>
      <label>Description (what is included)<textarea name="description" rows={4} defaultValue={s?.description ?? ''} /></label>
      <label className="row" style={{ alignItems: 'center', gap: '.5rem' }}>
        <input type="checkbox" name="show_price" defaultChecked={s?.show_price ?? true} style={{ width: 'auto' }} /> Show the price on the website
      </label>
      {editing && (
        <label className="row" style={{ alignItems: 'center', gap: '.5rem' }}>
          <input type="checkbox" name="is_active" defaultChecked={s?.is_active ?? true} style={{ width: 'auto' }} /> Active (untick to stop offering it)
        </label>
      )}
    </>
  );
}
