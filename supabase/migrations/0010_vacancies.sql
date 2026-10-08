-- 0010_vacancies: a VACANCY is an opening for a POSITION. A position is an organizational role with a
-- headcount; many vacancies can exist for it over time. Status moves only through vacancy_transition().

create type vacancy_status  as enum ('draft', 'pending_approval', 'approved', 'published', 'closed', 'filled', 'cancelled');
create type employment_type as enum ('full_time', 'part_time', 'contract', 'internship');

create table vacancies (
  id              uuid primary key default gen_random_uuid(),
  ada_id          text not null unique,
  position_id     uuid not null references positions (id) on delete restrict,
  division_id     uuid not null references divisions (id) on delete restrict,
  title           text not null check (btrim(title) <> ''),
  summary         text,
  description     text,
  requirements    text,
  employment_type employment_type not null default 'full_time',
  salary_min      numeric(12,2) check (salary_min >= 0),
  salary_max      numeric(12,2) check (salary_max >= 0),
  salary_currency char(3) not null default 'NAD',
  salary_public   boolean not null default false,
  openings        integer not null default 1 check (openings >= 1),
  closing_date    date,
  status          vacancy_status not null default 'draft',
  requested_by    uuid references staff (id),
  approved_by     uuid references staff (id),
  approved_at     timestamptz,
  published_at    timestamptz,
  closed_at       timestamptz,
  status_reason   text,
  created_by      uuid references staff (id),
  deleted_at      timestamptz,
  deleted_by      uuid references staff (id),
  deletion_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (salary_max is null or salary_min is null or salary_max >= salary_min)
);
create index vacancies_position_idx on vacancies (position_id);
create index vacancies_status_idx   on vacancies (status) where deleted_at is null;
comment on table vacancies is 'Purpose: an opening for a position. Content is editable only in draft; status changes only via vacancy_transition(). Public exposure only when published, via the public API. [class: internal]';
do $$ begin perform attach_ada_id('vacancies', 'vacancy'); end $$;
create trigger vacancies_updated     before update on vacancies for each row execute function set_updated_at();
create trigger vacancies_soft_delete before update on vacancies for each row execute function soft_delete_guard('vacancies');

-- Derived position availability (no stored "filled" flag to drift out of sync).
create view position_availability with (security_invoker = true) as
select p.id as position_id, p.title, p.division_id, p.headcount,
       (select count(*) from staff s
         where s.position_id = p.id and s.deleted_at is null
           and s.employment_status in ('active', 'on_leave', 'contractor', 'suspended'))::integer as filled
from positions p;
comment on view position_availability is 'headcount vs current holders; vacant = headcount - filled.';
grant select on position_availability to authenticated;

-- Unfilled slots not already promised to another approved/published vacancy.
create function position_open_capacity(p_position uuid, p_exclude_vacancy uuid default null) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select p.headcount
       - (select count(*) from staff s where s.position_id = p.id and s.deleted_at is null
            and s.employment_status in ('active', 'on_leave', 'contractor', 'suspended'))::integer
       - coalesce((select sum(v.openings) from vacancies v
            where v.position_id = p.id and v.status in ('approved', 'published') and v.deleted_at is null
              and v.id is distinct from p_exclude_vacancy), 0)::integer
  from positions p where p.id = p_position
$$;
revoke execute on function position_open_capacity(uuid, uuid) from public, anon;
grant execute on function position_open_capacity(uuid, uuid) to authenticated;

create function can_view_vacancy_row(p_division uuid, p_deleted timestamptz) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select (p_deleted is null or has_permission('records.view_deleted')) and has_permission('vacancies.view', p_division)
$$;
revoke execute on function can_view_vacancy_row(uuid, timestamptz) from public, anon;
grant execute on function can_view_vacancy_row(uuid, timestamptz) to authenticated;

create function vacancies_guard() returns trigger
language plpgsql as $$
declare v_pos_division uuid;
begin
  if tg_op = 'INSERT' then
    select division_id into v_pos_division from positions where id = new.position_id;
    if v_pos_division is not null then new.division_id := v_pos_division; end if;
    new.created_by := current_staff_id();
    if is_untrusted_caller() and new.status <> 'draft' then
      raise exception 'vacancies are created as drafts' using errcode = '42501';
    end if;
    return new;
  end if;

  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.requested_by is distinct from old.requested_by
       or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at
       or new.published_at is distinct from old.published_at or new.closed_at is distinct from old.closed_at
       or new.status_reason is distinct from old.status_reason then
      raise exception 'vacancy status is changed only through vacancy_transition()' using errcode = '42501';
    end if;
    if new.position_id is distinct from old.position_id or new.division_id is distinct from old.division_id then
      raise exception 'position and division cannot be changed; cancel and create a new vacancy' using errcode = '42501';
    end if;
    if old.status <> 'draft' and (new.title, new.summary, new.description, new.requirements, new.employment_type,
         new.salary_min, new.salary_max, new.salary_currency, new.salary_public, new.openings, new.closing_date)
         is distinct from (old.title, old.summary, old.description, old.requirements, old.employment_type,
         old.salary_min, old.salary_max, old.salary_currency, old.salary_public, old.openings, old.closing_date) then
      raise exception 'vacancy content can only be edited while it is a draft' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger vacancies_guard_trg before insert or update on vacancies for each row execute function vacancies_guard();

-- The only way a vacancy changes status.
create function vacancy_transition(p_id uuid, p_to vacancy_status, p_reason text default null) returns vacancy_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v vacancies%rowtype;
  v_staff uuid := current_staff_id();
  v_manage boolean;
  v_edit boolean;
  v_event text;
begin
  select * into v from vacancies where id = p_id and deleted_at is null for update;
  if not found or not has_permission('vacancies.view', v.division_id) then
    raise exception 'vacancy not found' using errcode = 'P0002';
  end if;
  v_manage := has_permission('vacancies.publish');
  v_edit   := has_permission('vacancies.update', v.division_id);

  case
    when v.status = 'draft' and p_to = 'pending_approval' then
      if not v_edit then raise exception 'vacancies.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(v.description), '') = '' or coalesce(btrim(v.requirements), '') = '' then
        raise exception 'description and requirements are required before approval' using errcode = '23514';
      end if;
      if v.closing_date is not null and v.closing_date < current_date then
        raise exception 'closing date is in the past' using errcode = '23514';
      end if;
      update vacancies set status = p_to, requested_by = v_staff, status_reason = null where id = p_id;
      perform notify_holders('vacancies.publish', null, 'approval.required', 'Vacancy awaiting approval: ' || v.title,
                             null, 'vacancies', v.id, v.ada_id);
    when v.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_manage) then raise exception 'not permitted to return this vacancy' using errcode = '42501'; end if;
      update vacancies set status = p_to, status_reason = p_reason where id = p_id;
    when v.status = 'pending_approval' and p_to = 'approved' then
      if not v_manage then raise exception 'vacancies.publish is required to approve' using errcode = '42501'; end if;
      if v.openings > coalesce(position_open_capacity(v.position_id, v.id), 0) then
        raise exception 'position has only % unfilled slot(s) for the % opening(s) requested',
          greatest(coalesce(position_open_capacity(v.position_id, v.id), 0), 0), v.openings using errcode = '23514';
      end if;
      update vacancies set status = p_to, approved_by = v_staff, approved_at = now(), status_reason = null where id = p_id;
    when v.status = 'approved' and p_to = 'published' then
      if not v_manage then raise exception 'vacancies.publish is required to publish' using errcode = '42501'; end if;
      update vacancies set status = p_to, published_at = now() where id = p_id;
      v_event := 'vacancy.published';
    when v.status in ('approved', 'published') and p_to = 'draft' then
      if not v_manage then raise exception 'vacancies.publish is required' using errcode = '42501'; end if;
      update vacancies set status = p_to, approved_by = null, approved_at = null, published_at = null, status_reason = p_reason where id = p_id;
      if v.status = 'published' then v_event := 'vacancy.unpublished'; end if;
    when v.status = 'published' and p_to = 'closed' then
      if not v_manage then raise exception 'vacancies.publish is required to close' using errcode = '42501'; end if;
      update vacancies set status = p_to, closed_at = now(), status_reason = p_reason where id = p_id;
      v_event := 'vacancy.closed';
    when v.status = 'closed' and p_to = 'draft' then
      if not v_manage then raise exception 'vacancies.publish is required to reopen' using errcode = '42501'; end if;
      update vacancies set status = p_to, closed_at = null, approved_by = null, approved_at = null, published_at = null, status_reason = p_reason where id = p_id;
    when v.status in ('draft', 'pending_approval', 'approved', 'published', 'closed') and p_to = 'cancelled' then
      if not (v_manage or (v.status = 'draft' and v_edit)) then raise exception 'not permitted to cancel this vacancy' using errcode = '42501'; end if;
      if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required to cancel' using errcode = '23514'; end if;
      update vacancies set status = p_to, closed_at = now(), status_reason = p_reason where id = p_id;
      if v.status = 'published' then v_event := 'vacancy.closed'; end if;
    else
      raise exception 'invalid vacancy transition % -> %', v.status, p_to using errcode = '23514';
  end case;

  if v_event is not null then
    perform emit_event(v_event, 'vacancies', v.id, v.ada_id, jsonb_build_object('status', p_to));
  end if;
  return p_to;
end $$;
revoke execute on function vacancy_transition(uuid, vacancy_status, text) from public, anon;
grant execute on function vacancy_transition(uuid, vacancy_status, text) to authenticated;

alter table vacancies enable row level security;
revoke all on vacancies from anon, authenticated;
grant select, insert, update on vacancies to authenticated;
create policy vacancies_select on vacancies for select to authenticated using (can_view_vacancy_row(division_id, deleted_at));
create policy vacancies_insert on vacancies for insert to authenticated with check (has_permission('vacancies.create', division_id));
create policy vacancies_update on vacancies for update to authenticated
  using (has_permission('vacancies.update', division_id)) with check (has_permission('vacancies.update', division_id));

do $$ begin perform attach_audit('vacancies'); end $$;
