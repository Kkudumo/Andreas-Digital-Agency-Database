-- 0011_applications: people (one record per human, however many times they apply), applications with
-- source tracking, an enforced pipeline, review notes, offers and status history.
-- API users cannot INSERT/UPDATE applications directly; everything goes through the functions below.

create type application_status as enum
  ('submitted', 'screening', 'shortlisted', 'interview', 'final_review', 'offer', 'accepted', 'rejected', 'withdrawn', 'offer_declined');

create table people (
  id         uuid primary key default gen_random_uuid(),
  ada_id     text not null unique,
  full_name  text not null check (btrim(full_name) <> ''),
  email      text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index people_email_unique on people (lower(email));
comment on table people is 'Purpose: one record per human known to ADA (applicant, hire, former staff). Personal data. A person may apply many times. [class: confidential]';
do $$ begin perform attach_ada_id('people', 'person'); end $$;
create trigger people_updated before update on people for each row execute function set_updated_at();

create table applications (
  id                uuid primary key default gen_random_uuid(),
  ada_id            text not null unique,
  vacancy_id        uuid not null references vacancies (id) on delete restrict,
  person_id         uuid not null references people (id) on delete restrict,
  status            application_status not null default 'submitted',
  cover_letter      text check (length(cover_letter) <= 10000),
  cv_ref            text,
  source_website_id uuid references websites (id),
  source_page       text check (length(source_page) <= 500),
  referrer          text check (length(referrer) <= 500),
  utm_source        text check (length(utm_source) <= 200),
  utm_medium        text check (length(utm_medium) <= 200),
  utm_campaign      text check (length(utm_campaign) <= 200),
  utm_term          text check (length(utm_term) <= 200),
  utm_content       text check (length(utm_content) <= 200),
  submitted_at      timestamptz not null default now(),
  status_changed_at timestamptz not null default now(),
  status_reason     text,
  staff_id          uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (vacancy_id, person_id)
);
create index applications_vacancy_idx on applications (vacancy_id, status);
create index applications_person_idx  on applications (person_id);
comment on table applications is 'Purpose: a person''s application to a vacancy, with where it came from (website, page, UTM). Status moves only through application_transition()/make_offer()/accept_application(). [class: confidential]';
do $$ begin perform attach_ada_id('applications', 'application'); end $$;
create trigger applications_updated before update on applications for each row execute function set_updated_at();

create table application_status_history (
  id             bigint generated always as identity primary key,
  application_id uuid not null references applications (id) on delete restrict,
  from_status    application_status,
  to_status      application_status not null,
  changed_by     uuid references staff (id),
  reason         text,
  changed_at     timestamptz not null default now()
);
create index application_history_idx on application_status_history (application_id, changed_at);
comment on table application_status_history is 'Purpose: every pipeline step of every application (append-only). changed_by is null for applicant/system actions. [class: confidential]';

create table application_reviews (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references applications (id) on delete restrict,
  reviewer_id    uuid not null references staff (id),
  stage          application_status not null,
  score          smallint check (score between 1 and 5),
  notes          text not null check (btrim(notes) <> ''),
  created_at     timestamptz not null default now()
);
create index application_reviews_app_idx on application_reviews (application_id);
comment on table application_reviews is 'Purpose: interview notes and scores. Insert-only; never public. [class: confidential]';

create table application_offers (
  application_id uuid primary key references applications (id) on delete restrict,
  start_date     date not null,
  salary_amount  numeric(12,2) check (salary_amount >= 0),
  salary_currency char(3) not null default 'NAD',
  expires_on     date,
  terms          text,
  offered_by     uuid references staff (id),
  offered_at     timestamptz not null default now()
);
comment on table application_offers is 'Purpose: terms of the offer made to an applicant (salary is confidential). [class: confidential]';

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------
create function application_division(p_application uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select v.division_id from applications a join vacancies v on v.id = a.vacancy_id where a.id = p_application
$$;

create function can_view_application_row(p_vacancy uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(has_permission('applications.view', (select division_id from vacancies where id = p_vacancy)), false)
$$;

create function can_view_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('hr.view') or has_permission('applications.view')
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.view', v.division_id))
$$;
revoke execute on function application_division(uuid), can_view_application_row(uuid), can_view_person(uuid) from public, anon;
grant execute on function application_division(uuid), can_view_application_row(uuid), can_view_person(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Internal: create an application (used by the public API and by staff entry)
-- ---------------------------------------------------------------------------
create function create_application_internal(
  p_vacancy_ada_id text, p_name text, p_email text, p_phone text, p_cover text, p_cv_ref text,
  p_site uuid, p_page text, p_referrer text,
  p_utm_source text, p_utm_medium text, p_utm_campaign text, p_utm_term text, p_utm_content text
) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v vacancies%rowtype;
  v_person uuid;
  v_app applications%rowtype;
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then
    raise exception 'a valid name is required' using errcode = '22023';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'a valid email is required' using errcode = '22023';
  end if;
  select * into v from vacancies
   where ada_id = p_vacancy_ada_id and status = 'published' and deleted_at is null
     and (closing_date is null or closing_date >= current_date);
  if not found then
    raise exception 'this vacancy is not open for applications' using errcode = 'P0002';
  end if;

  -- Reuse the existing person; never overwrite details supplied by a different submission.
  insert into people (full_name, email, phone) values (btrim(p_name), v_email, nullif(btrim(coalesce(p_phone, '')), ''))
  on conflict (lower(email)) do update set phone = coalesce(people.phone, excluded.phone)
  returning id into v_person;

  begin
    insert into applications (vacancy_id, person_id, cover_letter, cv_ref, source_website_id, source_page, referrer,
                              utm_source, utm_medium, utm_campaign, utm_term, utm_content)
    values (v.id, v_person, nullif(p_cover, ''), p_cv_ref, p_site, p_page, p_referrer,
            p_utm_source, p_utm_medium, p_utm_campaign, p_utm_term, p_utm_content)
    returning * into v_app;
  exception when unique_violation then
    raise exception 'you have already applied for this vacancy' using errcode = '23505';
  end;

  insert into application_status_history (application_id, from_status, to_status, reason)
  values (v_app.id, null, 'submitted', case when p_site is null then 'entered by staff' else 'submitted from website' end);
  perform emit_event('application.submitted', 'applications', v_app.id, v_app.ada_id,
                     jsonb_build_object('vacancy', v.ada_id, 'status', 'submitted'));
  perform notify_holders('applications.review', v.division_id, 'application.submitted',
                         'New application for ' || v.title, null, 'applications', v_app.id, v_app.ada_id);
  return v_app.ada_id;
end $$;
revoke execute on function create_application_internal(text, text, text, text, text, text, uuid, text, text, text, text, text, text, text) from public, anon, authenticated;

-- Staff entry (e.g. a CV received by email). Same rules, source recorded as "entered by staff".
create function staff_record_application(p_vacancy_id uuid, p_name text, p_email text, p_phone text default null,
                                         p_cover text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v vacancies%rowtype;
begin
  select * into v from vacancies where id = p_vacancy_id and deleted_at is null;
  if not found or not has_permission('applications.review', v.division_id) then
    raise exception 'applications.review is required for this vacancy' using errcode = '42501';
  end if;
  return create_application_internal(v.ada_id, p_name, p_email, p_phone, p_cover, null, null, null, null, null, null, null, null, null);
end $$;
revoke execute on function staff_record_application(uuid, text, text, text, text) from public, anon;
grant execute on function staff_record_application(uuid, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Pipeline
-- ---------------------------------------------------------------------------
create function application_transition(p_id uuid, p_to application_status, p_reason text default null) returns application_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a applications%rowtype;
  v vacancies%rowtype;
  v_ok boolean;
  v_decide boolean;
begin
  select * into a from applications where id = p_id for update;
  if not found then raise exception 'application not found' using errcode = 'P0002'; end if;
  select * into v from vacancies where id = a.vacancy_id;
  if not has_permission('applications.view', v.division_id) then
    raise exception 'application not found' using errcode = 'P0002';
  end if;

  v_ok := (a.status, p_to) in (
    ('submitted', 'screening'), ('screening', 'shortlisted'), ('shortlisted', 'interview'), ('interview', 'final_review'),
    ('submitted', 'rejected'), ('screening', 'rejected'), ('shortlisted', 'rejected'), ('interview', 'rejected'), ('final_review', 'rejected'),
    ('submitted', 'withdrawn'), ('screening', 'withdrawn'), ('shortlisted', 'withdrawn'), ('interview', 'withdrawn'),
    ('final_review', 'withdrawn'), ('offer', 'withdrawn'), ('offer', 'offer_declined'));
  if not v_ok then
    raise exception 'invalid application transition % -> % (offers and acceptance use make_offer/accept_application)', a.status, p_to using errcode = '23514';
  end if;

  v_decide := (a.status = 'final_review' and p_to = 'rejected');
  if v_decide then
    if not has_permission('applications.decide') then raise exception 'applications.decide is required to reject at final review' using errcode = '42501'; end if;
  elsif not has_permission('applications.review', v.division_id) then
    raise exception 'applications.review is required' using errcode = '42501';
  end if;
  if p_to = 'rejected' and coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required to reject an application' using errcode = '23514';
  end if;

  update applications set status = p_to, status_changed_at = now(), status_reason = p_reason where id = p_id;
  insert into application_status_history (application_id, from_status, to_status, changed_by, reason)
  values (p_id, a.status, p_to, current_staff_id(), p_reason);
  perform emit_event('application.status_changed', 'applications', a.id, a.ada_id, jsonb_build_object('status', p_to));
  if p_to = 'final_review' then
    perform notify_holders('applications.decide', null, 'approval.required', 'Final review decision needed: ' || v.title,
                           null, 'applications', a.id, a.ada_id);
  end if;
  return p_to;
end $$;

create function make_offer(p_id uuid, p_start_date date, p_salary numeric default null, p_currency text default 'NAD',
                           p_expires_on date default null, p_terms text default null) returns application_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a applications%rowtype;
  v vacancies%rowtype;
begin
  if not has_permission('applications.decide') then
    raise exception 'applications.decide is required to make an offer' using errcode = '42501';
  end if;
  select * into a from applications where id = p_id for update;
  if not found then raise exception 'application not found' using errcode = 'P0002'; end if;
  select * into v from vacancies where id = a.vacancy_id for update;
  if a.status <> 'final_review' then
    raise exception 'an offer can only be made from final_review (currently %)', a.status using errcode = '23514';
  end if;
  if v.status in ('filled', 'cancelled') or v.deleted_at is not null then
    raise exception 'the vacancy is %', v.status using errcode = '23514';
  end if;
  if p_start_date is null then raise exception 'a start date is required' using errcode = '23514'; end if;

  insert into application_offers (application_id, start_date, salary_amount, salary_currency, expires_on, terms, offered_by)
  values (p_id, p_start_date, p_salary, upper(p_currency), p_expires_on, p_terms, current_staff_id())
  on conflict (application_id) do update set start_date = excluded.start_date, salary_amount = excluded.salary_amount,
    salary_currency = excluded.salary_currency, expires_on = excluded.expires_on, terms = excluded.terms,
    offered_by = excluded.offered_by, offered_at = now();
  update applications set status = 'offer', status_changed_at = now(), status_reason = null where id = p_id;
  insert into application_status_history (application_id, from_status, to_status, changed_by)
  values (p_id, 'final_review', 'offer', current_staff_id());
  perform emit_event('application.offer_made', 'applications', a.id, a.ada_id, jsonb_build_object('status', 'offer'));
  return 'offer';
end $$;
revoke execute on function application_transition(uuid, application_status, text), make_offer(uuid, date, numeric, text, date, text) from public, anon;
grant execute on function application_transition(uuid, application_status, text), make_offer(uuid, date, numeric, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Guards, grants and RLS
-- ---------------------------------------------------------------------------
create function application_reviews_guard() returns trigger
language plpgsql as $$
begin
  new.reviewer_id := current_staff_id();
  return new;
end $$;
create trigger application_reviews_guard_trg before insert on application_reviews for each row execute function application_reviews_guard();

create function append_only() returns trigger
language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end $$;
create trigger application_history_immutable before update or delete on application_status_history for each row execute function append_only();
create trigger application_reviews_immutable before update or delete on application_reviews for each row execute function append_only();

alter table people                     enable row level security;
alter table applications               enable row level security;
alter table application_status_history enable row level security;
alter table application_reviews        enable row level security;
alter table application_offers         enable row level security;
revoke all on people, applications, application_status_history, application_reviews, application_offers from anon, authenticated;
grant select on people, applications, application_status_history, application_offers to authenticated;
grant update (full_name, phone) on people to authenticated;
grant select, insert on application_reviews to authenticated;

create policy people_select on people for select to authenticated using (can_view_person(id));
create policy people_update on people for update to authenticated
  using (has_permission_anywhere('applications.review') and can_view_person(id))
  with check (has_permission_anywhere('applications.review') and can_view_person(id));
create policy applications_select on applications for select to authenticated using (can_view_application_row(vacancy_id));
create policy application_history_select on application_status_history for select to authenticated
  using (can_view_application_row((select vacancy_id from applications a where a.id = application_id)));
create policy application_reviews_select on application_reviews for select to authenticated
  using (has_permission('applications.review', application_division(application_id)));
create policy application_reviews_insert on application_reviews for insert to authenticated
  with check (has_permission('applications.review', application_division(application_id)));
create policy application_offers_select on application_offers for select to authenticated using (has_permission('applications.decide'));

do $$ begin perform attach_audit('people'); end $$;
do $$ begin perform attach_audit('applications'); end $$;
do $$ begin perform attach_audit('application_reviews'); end $$;
do $$ begin perform attach_audit('application_offers'); end $$;
