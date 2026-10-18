-- 0060_consultations: real consultation booking for the ADA websites (Africa/Windhoek).
--
-- The agency (an administrator) sets the weekly hours and blocks dates; the public API offers only slots that are genuinely free
-- and books one atomically. NO hours are configured by this migration and booking is OFF until an administrator turns it on:
-- until then the website shows "no times available" instead of invented availability.
--
-- Safeguards: a database exclusion constraint makes two booked consultations that overlap impossible (concurrent bookings of the
-- same slot cannot both succeed); the customer's cancel code is stored only as a SHA-256 hash; customers never read rows -
-- they act through public_api functions with the reference + cancel code. Staff read bookings by permission.
-- Time zone: all slot arithmetic is in Africa/Windhoek (CAT, UTC+2, no daylight saving).

create table consultation_settings (
  id                 uuid primary key default gen_random_uuid(),
  single_row         boolean not null default true unique check (single_row),   -- only one settings row can exist
  enabled            boolean not null default false,
  division_id        uuid references divisions (id) on delete restrict,
  slot_minutes       integer not null default 30 check (slot_minutes between 15 and 180),
  min_notice_hours   integer not null default 12 check (min_notice_hours between 0 and 168),
  max_days_ahead     integer not null default 45 check (max_days_ahead between 1 and 180),
  updated_at         timestamptz not null default now()
);
comment on table consultation_settings is 'Purpose: single-row switch and rules for public consultation booking (off by default). [class: internal]';
insert into consultation_settings (division_id) select id from divisions where key = 'web';

create table consultation_hours (
  id          uuid primary key default gen_random_uuid(),
  weekday     smallint not null check (weekday between 0 and 6),            -- 0 = Sunday ... 6 = Saturday (Windhoek local)
  opens_at    time not null,
  closes_at   time not null,
  check (closes_at > opens_at),
  unique (weekday, opens_at)
);
comment on table consultation_hours is 'Purpose: weekly windows (Windhoek local time) in which consultations can be booked; none are preconfigured. [class: internal]';

create table consultation_blocks (
  id          uuid primary key default gen_random_uuid(),
  starts_on   date not null,
  ends_on     date not null,
  reason      text,
  created_by  uuid references staff (id),
  created_at  timestamptz not null default now(),
  check (ends_on >= starts_on)
);
comment on table consultation_blocks is 'Purpose: dates (Windhoek local, inclusive) on which no consultation can be booked. [class: internal]';

create table consultations (
  id                uuid primary key default gen_random_uuid(),
  reference         text not null unique,
  website_id        uuid references websites (id),
  division_id       uuid references divisions (id),
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  status            text not null default 'booked' check (status in ('booked', 'cancelled', 'completed', 'no_show')),
  customer_name     text not null check (length(btrim(customer_name)) between 2 and 120),
  customer_email    text not null check (customer_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(customer_email) <= 200),
  customer_phone    text not null check (length(btrim(customer_phone)) between 5 and 40),
  topic             text not null check (length(btrim(topic)) between 5 and 2000),
  cancel_code_hash  text not null,
  cancelled_by      text check (cancelled_by in ('customer', 'staff')),
  cancel_reason     text,
  reschedule_count  integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (ends_at > starts_at),
  constraint consultations_no_overlap exclude using gist (tstzrange(starts_at, ends_at) with &&) where (status = 'booked')
);
comment on table consultations is 'Purpose: consultation bookings made on the websites. customer_* are SNAPSHOTS of what was typed. Customers never read this table; staff read it by permission. [class: confidential]';
comment on column consultations.customer_name  is 'SNAPSHOT: the name exactly as typed by the customer when booking.';
comment on column consultations.customer_email is 'SNAPSHOT: the email exactly as typed by the customer when booking (stored lower-case).';
comment on column consultations.customer_phone is 'SNAPSHOT: the phone number exactly as typed by the customer when booking.';
create index consultations_starts_idx on consultations (starts_at) where status = 'booked';
create index consultations_division_idx on consultations (division_id);
create index consultations_website_idx on consultations (website_id);
create index consultation_settings_division_idx on consultation_settings (division_id);
create index consultations_email_idx on consultations (lower(customer_email)) where status = 'booked';

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------
insert into permissions (key, module, action, description, sensitivity) values
  ('consultations.view', 'consultations', 'view', 'See booked consultations and the booking settings', 'confidential'::data_classification),
  ('consultations.manage', 'consultations', 'manage', 'Cancel, reschedule and close consultations', 'confidential'::data_classification),
  ('consultations.configure', 'consultations', 'configure', 'Switch booking on or off; set weekly hours, slot length and blocked dates', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'consultations.view'), ('administration_officer', 'consultations.view'), ('division_lead', 'consultations.view'),
  ('division_staff', 'consultations.view'), ('auditor', 'consultations.view'),
  ('ceo', 'consultations.manage'), ('administration_officer', 'consultations.manage'), ('division_lead', 'consultations.manage'),
  ('ceo', 'consultations.configure'), ('administration_officer', 'consultations.configure')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- RLS: staff only; configuration writes by configure; bookings change only through the functions below
-- ---------------------------------------------------------------------------
alter table consultation_settings enable row level security;
alter table consultation_hours enable row level security;
alter table consultation_blocks enable row level security;
alter table consultations enable row level security;
revoke all on consultation_settings, consultation_hours, consultation_blocks, consultations from public, anon, authenticated;
grant select on consultation_settings, consultation_hours, consultation_blocks to authenticated;
grant update (enabled, slot_minutes, min_notice_hours, max_days_ahead, updated_at) on consultation_settings to authenticated;
grant insert, update on consultation_hours, consultation_blocks to authenticated;
grant select (id, reference, website_id, division_id, starts_at, ends_at, status, customer_name, customer_email, customer_phone, topic,
              cancelled_by, cancel_reason, reschedule_count, created_at, updated_at) on consultations to authenticated;

create policy consultation_settings_select on consultation_settings for select to authenticated using (has_permission('consultations.view'));
create policy consultation_settings_update on consultation_settings for update to authenticated
  using (has_permission('consultations.configure')) with check (has_permission('consultations.configure'));
create policy consultation_hours_select on consultation_hours for select to authenticated using (has_permission('consultations.view'));
create policy consultation_hours_insert on consultation_hours for insert to authenticated with check (has_permission('consultations.configure'));
create policy consultation_hours_update on consultation_hours for update to authenticated
  using (has_permission('consultations.configure')) with check (has_permission('consultations.configure'));
create policy consultation_blocks_select on consultation_blocks for select to authenticated using (has_permission('consultations.view'));
create policy consultation_blocks_insert on consultation_blocks for insert to authenticated with check (has_permission('consultations.configure'));
create policy consultation_blocks_update on consultation_blocks for update to authenticated
  using (has_permission('consultations.configure')) with check (has_permission('consultations.configure'));
create policy consultations_select on consultations for select to authenticated using (has_permission('consultations.view'));

create trigger consultation_settings_updated before update on consultation_settings for each row execute function set_updated_at();
create trigger consultations_updated before update on consultations for each row execute function set_updated_at();

do $$ begin perform attach_audit('consultation_settings'); end $$;
do $$ begin perform attach_audit('consultation_hours'); end $$;
do $$ begin perform attach_audit('consultation_blocks'); end $$;
do $$ begin perform attach_audit('consultations', array['customer_name', 'customer_email', 'customer_phone', 'topic', 'cancel_code_hash']); end $$;
insert into db_section_tables (table_name, section_key) values
  ('consultation_settings', 'content'), ('consultation_hours', 'content'), ('consultation_blocks', 'content'), ('consultations', 'content');

-- ---------------------------------------------------------------------------
-- Slot generation (internal): free slots between two Windhoek dates
-- ---------------------------------------------------------------------------
create function consultation_free_slots(p_from date, p_to date) returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  with s as (select * from consultation_settings where enabled),
  days as (
    select d::date as day from s, generate_series(greatest(p_from, (now() at time zone 'Africa/Windhoek')::date),
                                                  least(p_to, (now() at time zone 'Africa/Windhoek')::date + s.max_days_ahead), interval '1 day') d
  ),
  slots as (
    select ((days.day + t.t) at time zone 'Africa/Windhoek') as st,
           ((days.day + t.t) at time zone 'Africa/Windhoek') + make_interval(mins => s.slot_minutes) as en
    from s
    cross join days
    join consultation_hours h on h.weekday = extract(dow from days.day)::int
    cross join lateral generate_series(0, (extract(epoch from (h.closes_at - h.opens_at)) / 60)::int - s.slot_minutes, s.slot_minutes) as g(m)
    cross join lateral (select h.opens_at + make_interval(mins => g.m) as t) t
    where not exists (select 1 from consultation_blocks b where days.day between b.starts_on and b.ends_on)
  )
  select slots.st, slots.en from slots, s
  where slots.st >= now() + make_interval(hours => s.min_notice_hours)
    and not exists (select 1 from consultations c where c.status = 'booked' and tstzrange(c.starts_at, c.ends_at) && tstzrange(slots.st, slots.en))
  order by slots.st
$$;
revoke execute on function consultation_free_slots(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
alter table websites drop constraint websites_capabilities_check;
alter table websites add constraint websites_capabilities_check check (capabilities <@ array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read', 'applications.submit', 'services.read',
  'portfolio.read', 'contact.read', 'leads.submit', 'enquiries.submit', 'documents.read', 'content.read', 'consultations.book']);

create function public_api.consultation_slots(p_key_hash text, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_from date := coalesce(p_from, (now() at time zone 'Africa/Windhoek')::date);
        v_to date := coalesce(p_to, coalesce(p_from, (now() at time zone 'Africa/Windhoek')::date) + 14);
        s consultation_settings;
begin
  perform public_api.authorize(p_key_hash, 'consultations.book');
  if v_to < v_from or v_to - v_from > 62 then raise exception 'date range must be 0 to 62 days' using errcode = '22023'; end if;
  select * into s from consultation_settings;
  return jsonb_build_object('timezone', 'Africa/Windhoek', 'enabled', s.enabled, 'slot_minutes', s.slot_minutes,
    'slots', coalesce((select jsonb_agg(jsonb_build_object('start', to_char(f.starts_at at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'),
                                                          'end', to_char(f.ends_at at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"')) order by f.starts_at)
                       from consultation_free_slots(v_from, v_to) f), '[]'::jsonb));
end $$;

create function public_api.book_consultation(p_key_hash text, p_starts_at timestamptz, p_name text, p_email text, p_phone text, p_topic text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_site uuid := public_api.authorize(p_key_hash, 'consultations.book');
        s consultation_settings; v_end timestamptz; v_ref text; v_code text; v_id uuid;
begin
  select * into s from consultation_settings;
  if not s.enabled then raise exception 'consultation booking is not open' using errcode = 'P0001'; end if;
  if not exists (select 1 from consultation_free_slots((p_starts_at at time zone 'Africa/Windhoek')::date, (p_starts_at at time zone 'Africa/Windhoek')::date) f
                 where f.starts_at = p_starts_at) then
    raise exception 'that time is not available' using errcode = '23P01';
  end if;
  if (select count(*) from consultations where status = 'booked' and starts_at > now() and lower(customer_email) = lower(btrim(p_email))) >= 2 then
    raise exception 'this email already has two upcoming consultations' using errcode = '54000';
  end if;
  v_end := p_starts_at + make_interval(mins => s.slot_minutes);
  v_ref := 'ADA-BKG-' || upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 8));
  v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));
  insert into consultations (reference, website_id, division_id, starts_at, ends_at, customer_name, customer_email, customer_phone, topic, cancel_code_hash)
  values (v_ref, v_site, s.division_id, p_starts_at, v_end, btrim(p_name), lower(btrim(p_email)), btrim(p_phone), btrim(p_topic), encode(digest(v_code, 'sha256'), 'hex'))
  returning id into v_id;     -- the exclusion constraint raises 23P01 if a concurrent booking took the slot
  return jsonb_build_object('reference', v_ref, 'cancel_code', v_code, 'timezone', 'Africa/Windhoek', 'status', 'booked',
    'start', to_char(p_starts_at at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'),
    'end', to_char(v_end at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'));
end $$;

-- Looks up one booking by reference + cancel code (constant failure for either being wrong)
create function consultation_find(p_ref text, p_code text) returns consultations
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare c consultations;
begin
  select * into c from consultations where reference = upper(btrim(p_ref)) and cancel_code_hash = encode(digest(upper(btrim(p_code)), 'sha256'), 'hex');
  if c.id is null then raise exception 'booking not found' using errcode = 'P0002'; end if;
  return c;
end $$;
revoke execute on function consultation_find(text, text) from public, anon, authenticated;

create function public_api.consultation_status(p_key_hash text, p_reference text, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c consultations;
begin
  perform public_api.authorize(p_key_hash, 'consultations.book');
  c := consultation_find(p_reference, p_code);
  return jsonb_build_object('reference', c.reference, 'status', c.status, 'timezone', 'Africa/Windhoek',
    'start', to_char(c.starts_at at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'),
    'end', to_char(c.ends_at at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'));
end $$;

create function public_api.cancel_consultation(p_key_hash text, p_reference text, p_code text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c consultations;
begin
  perform public_api.authorize(p_key_hash, 'consultations.book');
  c := consultation_find(p_reference, p_code);
  if c.status <> 'booked' then raise exception 'this booking is already %', c.status using errcode = 'P0001'; end if;
  update consultations set status = 'cancelled', cancelled_by = 'customer', cancel_reason = left(nullif(btrim(p_reason), ''), 500) where id = c.id;
  return jsonb_build_object('reference', c.reference, 'status', 'cancelled');
end $$;

create function public_api.reschedule_consultation(p_key_hash text, p_reference text, p_code text, p_new_start timestamptz) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c consultations; s consultation_settings; v_end timestamptz;
begin
  perform public_api.authorize(p_key_hash, 'consultations.book');
  c := consultation_find(p_reference, p_code);
  if c.status <> 'booked' then raise exception 'this booking is already %', c.status using errcode = 'P0001'; end if;
  if c.reschedule_count >= 2 then raise exception 'this booking has already been moved twice; please cancel and book again' using errcode = '54000'; end if;
  select * into s from consultation_settings;
  if not s.enabled then raise exception 'consultation booking is not open' using errcode = 'P0001'; end if;
  if not exists (select 1 from consultation_free_slots((p_new_start at time zone 'Africa/Windhoek')::date, (p_new_start at time zone 'Africa/Windhoek')::date) f
                 where f.starts_at = p_new_start) then
    raise exception 'that time is not available' using errcode = '23P01';
  end if;
  v_end := p_new_start + make_interval(mins => s.slot_minutes);
  update consultations set starts_at = p_new_start, ends_at = v_end, reschedule_count = reschedule_count + 1 where id = c.id;
  return jsonb_build_object('reference', c.reference, 'status', 'booked', 'timezone', 'Africa/Windhoek',
    'start', to_char(p_new_start at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'),
    'end', to_char(v_end at time zone 'Africa/Windhoek', 'YYYY-MM-DD"T"HH24:MI:SS"+02:00"'));
end $$;

revoke all on function public_api.consultation_slots(text, date, date), public_api.book_consultation(text, timestamptz, text, text, text, text),
  public_api.consultation_status(text, text, text), public_api.cancel_consultation(text, text, text, text),
  public_api.reschedule_consultation(text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public_api.consultation_slots(text, date, date), public_api.book_consultation(text, timestamptz, text, text, text, text),
  public_api.consultation_status(text, text, text), public_api.cancel_consultation(text, text, text, text),
  public_api.reschedule_consultation(text, text, text, timestamptz) to ada_public_api;

-- ---------------------------------------------------------------------------
-- Staff actions: cancel, reschedule, close
-- ---------------------------------------------------------------------------
create function consultation_staff_action(p_id uuid, p_action text, p_new_start timestamptz default null, p_reason text default null) returns consultations
language plpgsql security definer set search_path = public, pg_temp as $$
declare c consultations; s consultation_settings;
begin
  select * into c from consultations where id = p_id;
  if c.id is null then raise exception 'booking not found' using errcode = 'P0002'; end if;
  if not has_permission('consultations.manage', c.division_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_action = 'cancel' then
    if c.status <> 'booked' then raise exception 'only a booked consultation can be cancelled' using errcode = 'P0001'; end if;
    update consultations set status = 'cancelled', cancelled_by = 'staff', cancel_reason = left(nullif(btrim(p_reason), ''), 500) where id = p_id returning * into c;
  elsif p_action in ('completed', 'no_show') then
    if c.status <> 'booked' then raise exception 'only a booked consultation can be closed' using errcode = 'P0001'; end if;
    update consultations set status = p_action where id = p_id returning * into c;
  elsif p_action = 'reschedule' then
    if c.status <> 'booked' then raise exception 'only a booked consultation can be moved' using errcode = 'P0001'; end if;
    select * into s from consultation_settings;
    -- staff may move to any time that does not overlap another booking (they may go outside the published hours)
    update consultations set starts_at = p_new_start, ends_at = p_new_start + make_interval(mins => s.slot_minutes), reschedule_count = reschedule_count + 1
      where id = p_id returning * into c;
  else
    raise exception 'unknown action %', p_action using errcode = '22023';
  end if;
  return c;
end $$;
revoke execute on function consultation_staff_action(uuid, text, timestamptz, text) from public, anon;
grant execute on function consultation_staff_action(uuid, text, timestamptz, text) to authenticated;

-- Removing an hours window or a blocked date goes through a function (the API role has no DELETE on tables other than link tables)
create function consultation_remove(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_permission('consultations.configure') then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_kind = 'hours' then delete from consultation_hours where id = p_id;
  elsif p_kind = 'block' then delete from consultation_blocks where id = p_id;
  else raise exception 'unknown kind %', p_kind using errcode = '22023'; end if;
end $$;
revoke execute on function consultation_remove(text, uuid) from public, anon;
grant execute on function consultation_remove(text, uuid) to authenticated;
