-- 0012_hiring: controlled hire (accept_application), onboarding/offboarding tasks, public staff profiles
-- with an approval workflow, and staff departure. Internal staff data and public profile data are
-- separate tables; the public API only ever reads published profiles.

alter table staff add column person_id uuid unique references people (id);
alter table applications add constraint applications_staff_fk foreign key (staff_id) references staff (id);
comment on column staff.person_id is 'The person record this staff member originated from (one staff record per person, ever).';

-- ---------------------------------------------------------------------------
-- Onboarding / offboarding tasks
-- ---------------------------------------------------------------------------
create table onboarding_tasks (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid not null references staff (id) on delete restrict,
  application_id uuid references applications (id),
  kind           text not null check (kind in ('onboarding', 'offboarding')),
  title          text not null,
  description    text,
  assignee_id    uuid references staff (id),
  due_date       date,
  status         text not null default 'todo' check (status in ('todo', 'done', 'cancelled')),
  completed_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index onboarding_tasks_staff_idx on onboarding_tasks (staff_id);
comment on table onboarding_tasks is 'Purpose: checklist generated when someone is hired or leaves. [class: restricted]';
create trigger onboarding_tasks_updated before update on onboarding_tasks for each row execute function set_updated_at();

create function onboarding_tasks_guard() returns trigger
language plpgsql as $$
begin
  if new.status = 'done' and old.status <> 'done' then new.completed_at := now();
  elsif new.status <> 'done' then new.completed_at := null; end if;
  -- an assignee may only change status; reassigning or rescheduling needs onboarding.manage
  if is_untrusted_caller() and not has_permission('onboarding.manage')
     and (new.assignee_id is distinct from old.assignee_id or new.due_date is distinct from old.due_date) then
    raise exception 'onboarding.manage is required to reassign or reschedule tasks' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger onboarding_tasks_guard_trg before update on onboarding_tasks for each row execute function onboarding_tasks_guard();

alter table onboarding_tasks enable row level security;
revoke all on onboarding_tasks from anon, authenticated;
grant select on onboarding_tasks to authenticated;
grant update (status, assignee_id, due_date) on onboarding_tasks to authenticated;
create policy onboarding_select on onboarding_tasks for select to authenticated
  using (has_permission('onboarding.manage') or assignee_id = current_staff_id() or staff_id = current_staff_id());
create policy onboarding_update on onboarding_tasks for update to authenticated
  using (has_permission('onboarding.manage') or assignee_id = current_staff_id())
  with check (has_permission('onboarding.manage') or assignee_id = current_staff_id());

-- ---------------------------------------------------------------------------
-- Public staff profiles (separate from staff; require approval before publication)
-- ---------------------------------------------------------------------------
create table staff_profiles (
  id             uuid primary key default gen_random_uuid(),
  ada_id         text not null unique,
  staff_id       uuid not null unique references staff (id) on delete restrict,
  public_name    text not null check (btrim(public_name) <> ''),
  public_title   text,
  bio            text check (length(bio) <= 1500),
  photo_ref      text,
  public_email   text check (public_email is null or public_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status         publication_state not null default 'draft',
  approved_by    uuid references staff (id),
  approved_at    timestamptz,
  published_at   timestamptz,
  unpublished_at timestamptz,
  status_reason  text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table staff_profiles is 'Purpose: the only staff data eligible for the public site. Exposed only when status = published AND the staff member is currently employed. Editing a non-draft profile returns it to draft. [class: internal; public when published]';
do $$ begin perform attach_ada_id('staff_profiles', 'profile'); end $$;
create trigger staff_profiles_updated before update on staff_profiles for each row execute function set_updated_at();

create function staff_profiles_guard() returns trigger
language plpgsql as $$
begin
  if is_untrusted_caller() then
    if new.status is distinct from old.status or new.approved_by is distinct from old.approved_by
       or new.approved_at is distinct from old.approved_at or new.published_at is distinct from old.published_at
       or new.unpublished_at is distinct from old.unpublished_at or new.status_reason is distinct from old.status_reason
       or new.staff_id is distinct from old.staff_id then
      raise exception 'profile status is changed only through profile_transition()' using errcode = '42501';
    end if;
    -- Any content edit invalidates earlier approval.
    if (new.public_name, new.public_title, new.bio, new.photo_ref, new.public_email)
       is distinct from (old.public_name, old.public_title, old.bio, old.photo_ref, old.public_email)
       and old.status in ('pending_approval', 'approved', 'published') then
      new.status := 'draft'; new.approved_by := null; new.approved_at := null;
      new.published_at := null; new.status_reason := 'edited after approval; needs re-approval';
    end if;
  end if;
  return new;
end $$;
create trigger staff_profiles_guard_trg before update on staff_profiles for each row execute function staff_profiles_guard();

-- Events fire on any path that publishes or unpublishes a profile.
create function staff_profiles_events() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'published' and old.status <> 'published' then
    perform emit_event('profile.published', 'staff_profiles', new.id, new.ada_id, jsonb_build_object('status', 'published'));
  elsif old.status = 'published' and new.status <> 'published' then
    perform emit_event('profile.unpublished', 'staff_profiles', new.id, new.ada_id, jsonb_build_object('status', new.status));
  end if;
  return null;
end $$;
create trigger staff_profiles_events_trg after update of status on staff_profiles for each row execute function staff_profiles_events();

create function profile_transition(p_id uuid, p_to publication_state, p_reason text default null) returns publication_state
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p staff_profiles%rowtype;
  s staff%rowtype;
  v_me uuid := current_staff_id();
  v_owner boolean;
  v_edit boolean;
  v_pub boolean;
begin
  select * into p from staff_profiles where id = p_id for update;
  if not found then raise exception 'profile not found' using errcode = 'P0002'; end if;
  select * into s from staff where id = p.staff_id;
  v_owner := (p.staff_id = v_me);
  v_edit := v_owner or has_permission('profiles.edit');
  v_pub := has_permission('profiles.publish');
  if not (v_edit or v_pub or has_permission('profiles.view')) then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;

  case
    when p.status in ('draft', 'unpublished') and p_to = 'pending_approval' then
      if not v_edit then raise exception 'not permitted to submit this profile' using errcode = '42501'; end if;
      if coalesce(btrim(p.public_title), '') = '' then raise exception 'a public title is required' using errcode = '23514'; end if;
      update staff_profiles set status = p_to, status_reason = null where id = p_id;
      perform notify_holders('profiles.publish', null, 'approval.required', 'Profile awaiting approval: ' || p.public_name, null, 'staff_profiles', p.id, p.ada_id);
    when p.status = 'pending_approval' and p_to = 'draft' then
      if not (v_owner or v_pub) then raise exception 'not permitted' using errcode = '42501'; end if;
      if v_pub and not v_owner and coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required when returning a profile' using errcode = '23514'; end if;
      update staff_profiles set status = p_to, status_reason = p_reason where id = p_id;
    when p.status = 'pending_approval' and p_to = 'approved' then
      if not v_pub then raise exception 'profiles.publish is required to approve' using errcode = '42501'; end if;
      update staff_profiles set status = p_to, approved_by = v_me, approved_at = now(), status_reason = null where id = p_id;
    when p.status = 'approved' and p_to = 'published' then
      if not v_pub then raise exception 'profiles.publish is required to publish' using errcode = '42501'; end if;
      if s.employment_status not in ('active', 'on_leave', 'contractor') or s.deleted_at is not null then
        raise exception 'only current staff can have a published profile' using errcode = '23514';
      end if;
      update staff_profiles set status = p_to, published_at = now(), unpublished_at = null where id = p_id;
    when p.status = 'published' and p_to = 'unpublished' then
      if not v_pub then raise exception 'profiles.publish is required to unpublish' using errcode = '42501'; end if;
      update staff_profiles set status = p_to, unpublished_at = now(), published_at = null, status_reason = p_reason where id = p_id;
    when p.status <> 'archived' and p_to = 'archived' then
      if not v_pub then raise exception 'profiles.publish is required to archive' using errcode = '42501'; end if;
      update staff_profiles set status = p_to, published_at = null, status_reason = p_reason where id = p_id;
    else
      raise exception 'invalid profile transition % -> %', p.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;
revoke execute on function profile_transition(uuid, publication_state, text) from public, anon;
grant execute on function profile_transition(uuid, publication_state, text) to authenticated;

alter table staff_profiles enable row level security;
revoke all on staff_profiles from anon, authenticated;
grant select on staff_profiles to authenticated;
grant update (public_name, public_title, bio, photo_ref, public_email) on staff_profiles to authenticated;
create policy staff_profiles_select on staff_profiles for select to authenticated
  using (staff_id = current_staff_id() or has_permission('profiles.view') or has_permission('profiles.publish'));
create policy staff_profiles_update on staff_profiles for update to authenticated
  using (staff_id = current_staff_id() or has_permission('profiles.edit'))
  with check (staff_id = current_staff_id() or has_permission('profiles.edit'));

-- ---------------------------------------------------------------------------
-- Controlled hire
-- ---------------------------------------------------------------------------
create function accept_application(p_id uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a applications%rowtype;
  v vacancies%rowtype;
  o application_offers%rowtype;
  per people%rowtype;
  s staff%rowtype;
  v_staff uuid;
  v_title text;
  v_holders integer;
  v_headcount integer;
  v_hired integer;
begin
  if not has_permission('applications.hire') then
    raise exception 'applications.hire is required' using errcode = '42501';
  end if;
  select * into a from applications where id = p_id for update;
  if not found then raise exception 'application not found' using errcode = 'P0002'; end if;
  if a.status = 'accepted' and a.staff_id is not null then
    return a.staff_id;                                   -- idempotent: never hires twice
  end if;
  if a.status <> 'offer' then
    raise exception 'only an application with an open offer can be accepted (currently %)', a.status using errcode = '23514';
  end if;
  select * into o from application_offers where application_id = p_id;
  if not found then raise exception 'no offer on record' using errcode = '23514'; end if;
  if o.expires_on is not null and o.expires_on < current_date then
    raise exception 'the offer expired on %', o.expires_on using errcode = '23514';
  end if;
  select * into v from vacancies where id = a.vacancy_id for update;
  select * into per from people where id = a.person_id;
  select title, headcount into v_title, v_headcount from positions where id = v.position_id;

  select count(*) into v_holders from staff
   where position_id = v.position_id and deleted_at is null and person_id is distinct from per.id
     and employment_status in ('active', 'on_leave', 'contractor', 'suspended');
  if v_holders >= v_headcount then
    raise exception 'the position "%" is already filled (headcount %)', v_title, v_headcount using errcode = '23514';
  end if;

  select * into s from staff where person_id = per.id;
  if found then
    if s.employment_status <> 'terminated' and s.deleted_at is null then
      raise exception 'this person is already ADA staff (%)', s.ada_id using errcode = '23505';
    end if;
    update staff set employment_status = 'active', account_status = 'invited', end_date = null, start_date = o.start_date,
                     position_id = v.position_id, primary_division_id = v.division_id, deleted_at = null, deleted_by = null, deletion_reason = null
     where id = s.id;
    v_staff := s.id;
  else
    if exists (select 1 from staff where lower(email) = lower(per.email) and deleted_at is null) then
      raise exception 'a different staff record already uses %', per.email using errcode = '23505';
    end if;
    insert into staff (person_id, full_name, email, work_phone, position_id, primary_division_id,
                       employment_status, account_status, start_date)
    values (per.id, per.full_name, per.email, per.phone, v.position_id, v.division_id, 'active', 'invited', o.start_date)
    returning id into v_staff;
  end if;

  update applications set status = 'accepted', staff_id = v_staff, status_changed_at = now(), status_reason = null where id = p_id;
  insert into application_status_history (application_id, from_status, to_status, changed_by, reason)
  values (p_id, 'offer', 'accepted', current_staff_id(), 'offer accepted; staff record ' || (select ada_id from staff where id = v_staff));

  insert into staff_profiles (staff_id, public_name, public_title)
  values (v_staff, per.full_name, v_title)
  on conflict (staff_id) do nothing;

  insert into onboarding_tasks (staff_id, application_id, kind, title, description, due_date)
  select v_staff, p_id, 'onboarding', t.title, t.description, o.start_date
  from (values
    ('Create ADA login and link it to the staff record', 'Invite the user in Authentication, then link the account.'),
    ('Sign employment contract and file it', 'Contract is stored with the staff documents.'),
    ('Issue equipment and record assets', 'Assign laptop and other assets to the new staff member.'),
    ('Induction and division briefing', 'Introduce policies, tools and the division team.'),
    ('Review and submit public profile draft', 'The draft profile needs management approval before it appears on ADA websites.')
  ) as t(title, description);

  -- Close the vacancy once every opening is filled.
  select count(*) into v_hired from applications where vacancy_id = v.id and status = 'accepted';
  if v_hired >= v.openings and v.status in ('published', 'approved', 'closed') then
    update vacancies set status = 'filled', closed_at = now(), status_reason = 'all openings filled' where id = v.id;
    if v.status = 'published' then
      perform emit_event('vacancy.closed', 'vacancies', v.id, v.ada_id, jsonb_build_object('status', 'filled'));
    end if;
  end if;

  perform emit_event('application.accepted', 'applications', a.id, a.ada_id, jsonb_build_object('status', 'accepted'));
  perform emit_event('staff.created', 'staff', v_staff, (select ada_id from staff where id = v_staff), jsonb_build_object('employment_status', 'active'));
  perform notify_holders('onboarding.manage', null, 'onboarding.task', 'New hire to onboard: ' || (select ada_id from staff where id = v_staff),
                         v_title || ' · starts ' || o.start_date, 'staff', v_staff, (select ada_id from staff where id = v_staff));
  return v_staff;
end $$;
revoke execute on function accept_application(uuid) from public, anon;
grant execute on function accept_application(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff departure
-- ---------------------------------------------------------------------------
create function terminate_staff(p_staff uuid, p_end_date date, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s staff%rowtype;
  v_title text;
  v_vacant integer;
begin
  if not has_permission('staff.offboard') then
    raise exception 'staff.offboard is required' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = '23514';
  end if;
  select * into s from staff where id = p_staff and deleted_at is null for update;
  if not found then raise exception 'staff member not found' using errcode = 'P0002'; end if;
  if s.id = current_staff_id() then raise exception 'you cannot offboard yourself' using errcode = '42501'; end if;
  if s.employment_status = 'terminated' then return; end if;      -- idempotent
  if s.start_date is not null and coalesce(p_end_date, current_date) < s.start_date then
    raise exception 'the end date % is before the start date %; use a date on or after the start date', coalesce(p_end_date, current_date), s.start_date
      using errcode = '23514';
  end if;

  -- Access is revoked by the trigger on employment_status (account becomes disabled).
  update staff set employment_status = 'terminated', end_date = coalesce(p_end_date, current_date) where id = p_staff;
  update staff_profiles set status = 'unpublished', unpublished_at = now(), published_at = null, status_reason = 'staff left ADA'
   where staff_id = p_staff and status = 'published';
  update staff_profiles set status = 'archived', status_reason = 'staff left ADA'
   where staff_id = p_staff and status in ('draft', 'pending_approval', 'approved');

  insert into onboarding_tasks (staff_id, kind, title, description, due_date)
  select p_staff, 'offboarding', t.title, t.description, coalesce(p_end_date, current_date)
  from (values
    ('Disable the login at the identity provider', 'Revoke sessions and API tokens for this person.'),
    ('Recover equipment and update asset records', 'Return laptops, keys and other assets.'),
    ('Hand over projects, clients and tickets', 'Reassign open work before the last day.'),
    ('Review shared accounts and rotate credentials', 'Rotate any shared secrets they could access.')
  ) as t(title, description);

  perform emit_event('staff.deactivated', 'staff', s.id, s.ada_id, jsonb_build_object('employment_status', 'terminated'));
  select title, headcount - (select count(*) from staff x where x.position_id = positions.id and x.deleted_at is null
                              and x.employment_status in ('active', 'on_leave', 'contractor', 'suspended'))
    into v_title, v_vacant from positions where id = s.position_id;
  perform notify_holders('onboarding.manage', null, 'offboarding.task', 'Offboarding started: ' || s.ada_id,
                         'Reason: ' || p_reason, 'staff', s.id, s.ada_id);
  if v_title is not null and v_vacant > 0 then
    perform notify_holders('vacancies.publish', null, 'position.vacant', 'Position now vacant: ' || v_title,
                           'Open a vacancy if a replacement is wanted. None has been created.', 'staff', s.id, s.ada_id);
  end if;
end $$;
revoke execute on function terminate_staff(uuid, date, text) from public, anon;
grant execute on function terminate_staff(uuid, date, text) to authenticated;

do $$ begin perform attach_audit('onboarding_tasks'); end $$;
do $$ begin perform attach_audit('staff_profiles'); end $$;
