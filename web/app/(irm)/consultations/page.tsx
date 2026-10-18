import { requireAccess, can, canAnywhere } from '@/lib/access';
import { createClient } from '@/lib/supabase/server';
import { Badge, Empty, Flash, PageHead } from '@/components/ui';
import { saveSettingsAction, addHoursAction, addBlockAction, removeAction, bookingAction } from './actions';

// Consultation booking: the switch, weekly hours and blocked dates, and the bookings made on the websites.
// All times are Namibia time (Africa/Windhoek). Nothing is offered to the public until booking is switched on AND hours exist.
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const WINDHOEK = 'Africa/Windhoek';
const when = (iso: string) => new Date(iso).toLocaleString('en-GB', { timeZone: WINDHOEK, weekday: 'short', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const t5 = (t: string) => t.slice(0, 5);

export default async function ConsultationsPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const access = await requireAccess(); const sp = await searchParams;
  const configure = can(access, 'consultations.configure');
  const manage = canAnywhere(access, 'consultations.manage');
  if (!canAnywhere(access, 'consultations.view')) return (<><PageHead title="Consultations" /><section className="card"><Empty>You do not have access to consultation bookings.</Empty></section></>);
  const supabase = await createClient();
  const [{ data: settings }, { data: hours }, { data: blocks }, { data: bookings }] = await Promise.all([
    supabase.from('consultation_settings').select('enabled, slot_minutes, min_notice_hours, max_days_ahead').maybeSingle(),
    supabase.from('consultation_hours').select('id, weekday, opens_at, closes_at').order('weekday').order('opens_at'),
    supabase.from('consultation_blocks').select('id, starts_on, ends_on, reason').order('starts_on'),
    supabase.from('consultations').select('id, reference, starts_at, status, customer_name, customer_email, customer_phone, topic, cancel_reason, reschedule_count').order('starts_at', { ascending: false }).limit(200),
  ]);
  const s = (settings ?? { enabled: false, slot_minutes: 30, min_notice_hours: 12, max_days_ahead: 45 }) as any;
  const now = Date.now();
  const rows = (bookings ?? []) as any[];
  const upcoming = rows.filter((b) => b.status === 'booked' && new Date(b.starts_at).getTime() >= now).reverse();
  const past = rows.filter((b) => !upcoming.includes(b));
  const openNow = s.enabled && (hours ?? []).length > 0;

  const table = (list: any[], actions: boolean) => (
    <div className="scroll"><table>
      <thead><tr><th>When (Namibia time)</th><th>Customer</th><th>Topic</th><th>Status</th>{actions && manage && <th></th>}</tr></thead>
      <tbody>{list.map((b) => (
        <tr key={b.id}>
          <td><b>{when(b.starts_at)}</b><div className="id">{b.reference}</div>{b.reschedule_count > 0 && <div className="muted small">Moved {b.reschedule_count}×</div>}</td>
          <td>{b.customer_name}<div className="muted small">{b.customer_email}</div><div className="muted small">{b.customer_phone}</div></td>
          <td className="small">{b.topic}{b.cancel_reason && <div className="muted">Reason: {b.cancel_reason}</div>}</td>
          <td><Badge v={b.status} /></td>
          {actions && manage && <td>{b.status === 'booked' && (
            <div className="stack">
              <form action={bookingAction}><input type="hidden" name="id" value={b.id} /><input type="hidden" name="action" value="completed" /><button type="submit">Mark done</button></form>
              <form action={bookingAction}><input type="hidden" name="id" value={b.id} /><input type="hidden" name="action" value="no_show" /><button type="submit">No-show</button></form>
              <form action={bookingAction} className="stack"><input type="hidden" name="id" value={b.id} /><input type="hidden" name="action" value="reschedule" />
                <label className="small">Move to (Namibia time)<input type="datetime-local" name="new_start" required /></label><button type="submit">Move</button></form>
              <form action={bookingAction} className="stack"><input type="hidden" name="id" value={b.id} /><input type="hidden" name="action" value="cancel" />
                <label className="small">Reason<input name="reason" maxLength={500} /></label><button type="submit">Cancel booking</button></form>
            </div>)}</td>}
        </tr>))}</tbody>
    </table></div>
  );

  return (
    <>
      <PageHead title="Consultations" sub="When customers can book a talk with ADA, and the bookings made on the websites. Times are Namibia time (Africa/Windhoek)." />
      <Flash error={sp.error} ok={sp.ok} />
      <section className="card">
        <h2>Booking is {openNow ? 'open on the websites' : 'closed'}</h2>
        <p className="muted small">{openNow ? 'Customers see the free times below, minus booked times and blocked dates.' :
          s.enabled ? 'Booking is switched on but no weekly hours exist, so no times are offered.' : 'Switched off. Websites show that online booking is not open. Also tick “Consultation booking” for the website under Websites.'}</p>
        {configure ? (
          <form action={saveSettingsAction} className="stack">
            <label><input type="checkbox" name="enabled" defaultChecked={s.enabled} /> Offer consultation booking on the websites</label>
            <label>Length of a consultation (minutes)<input type="number" name="slot_minutes" min={15} max={180} step={5} defaultValue={s.slot_minutes} required /></label>
            <label>Minimum notice (hours)<input type="number" name="min_notice_hours" min={0} max={168} defaultValue={s.min_notice_hours} required /></label>
            <label>How far ahead customers can book (days)<input type="number" name="max_days_ahead" min={1} max={180} defaultValue={s.max_days_ahead} required /></label>
            <button className="primary" type="submit">Save settings</button>
          </form>
        ) : <p className="small">{s.slot_minutes}-minute consultations · {s.min_notice_hours} h notice · {s.max_days_ahead} days ahead</p>}
      </section>

      <section className="card">
        <h2>Weekly hours</h2>
        {(hours ?? []).length === 0 ? <Empty>No hours set. Add the times each week when you are available.</Empty> : (
          <div className="scroll"><table><thead><tr><th>Day</th><th>From</th><th>Until</th>{configure && <th></th>}</tr></thead>
            <tbody>{(hours as any[]).map((h) => (
              <tr key={h.id}><td>{DAYS[h.weekday]}</td><td>{t5(h.opens_at)}</td><td>{t5(h.closes_at)}</td>
                {configure && <td><form action={removeAction}><input type="hidden" name="kind" value="hours" /><input type="hidden" name="id" value={h.id} /><button type="submit">Remove</button></form></td>}</tr>))}</tbody></table></div>
        )}
        {configure && (
          <form action={addHoursAction} className="stack">
            <fieldset><legend className="small">Add hours for</legend><div className="checks">{DAYS.map((d, i) => <label key={d} className="small"><input type="checkbox" name="weekday" value={i} /> {d}</label>)}</div></fieldset>
            <label>From<input type="time" name="opens_at" required /></label>
            <label>Until<input type="time" name="closes_at" required /></label>
            <button type="submit">Add hours</button>
          </form>
        )}
      </section>

      <section className="card">
        <h2>Blocked dates</h2>
        {(blocks ?? []).length === 0 ? <Empty>No blocked dates.</Empty> : (
          <div className="scroll"><table><thead><tr><th>From</th><th>To</th><th>Reason</th>{configure && <th></th>}</tr></thead>
            <tbody>{(blocks as any[]).map((b) => (
              <tr key={b.id}><td>{b.starts_on}</td><td>{b.ends_on}</td><td>{b.reason ?? '—'}</td>
                {configure && <td><form action={removeAction}><input type="hidden" name="kind" value="block" /><input type="hidden" name="id" value={b.id} /><button type="submit">Remove</button></form></td>}</tr>))}</tbody></table></div>
        )}
        {configure && (
          <form action={addBlockAction} className="stack">
            <label>From<input type="date" name="starts_on" required /></label>
            <label>To (leave empty for one day)<input type="date" name="ends_on" /></label>
            <label>Reason<input name="reason" maxLength={200} placeholder="Public holiday" /></label>
            <button type="submit">Block date</button>
          </form>
        )}
      </section>

      <section className="card">
        <h2>Upcoming consultations</h2>
        {upcoming.length === 0 ? <Empty>No upcoming consultations.</Empty> : table(upcoming, true)}
      </section>
      <section className="card">
        <h2>Past and cancelled</h2>
        {past.length === 0 ? <Empty>Nothing yet.</Empty> : table(past.slice(0, 50), false)}
      </section>
    </>
  );
}
