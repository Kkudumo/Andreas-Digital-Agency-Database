-- 0015_people_clients: ONE person record, ONE client record.
--  * people becomes the universal identity table. A client contact is a *relationship* of a person to a
--    client (client_contacts), not a second copy of that person. The same John can be an applicant, a
--    contact of two clients and a project contact without being re-typed anywhere.
--  * Relationships do not share secrets: seeing a person as a client contact does not reveal their
--    applications, and being an applicant does not make them public or visible to client teams.
--  * The full client profile lives on clients; "owner" is the client_staff row with role 'owner'.
--  * Duplicate clients are prevented across divisions even though row security hides other divisions' clients:
--    client_lookup() finds matches safely and claim_client_for_division() joins the existing record.

-- ---------------------------------------------------------------------------
-- people: email optional (a contact may only have a phone); still unique when present
-- ---------------------------------------------------------------------------
alter table people alter column email drop not null;
alter table people drop constraint people_email_check;
alter table people add constraint people_email_format check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$');
drop index people_email_unique;
create unique index people_email_unique on people (lower(email)) where email is not null;
comment on table people is 'Purpose: ONE record per human known to ADA, whatever their relationships (applicant, staff, client contact). Relationship tables decide who may see it; this table holds identity only. [class: confidential]';

-- ---------------------------------------------------------------------------
-- client_contacts: relationship of a person to a client (migrates existing rows)
-- ---------------------------------------------------------------------------
alter table client_contacts add column person_id uuid references people (id) on delete restrict,
                            add column is_billing boolean not null default false;
do $$
declare r record; v_person uuid;
begin
  for r in select id, full_name, email, phone from client_contacts loop
    if r.email is not null then
      insert into people (full_name, email, phone) values (r.full_name, lower(btrim(r.email)), r.phone)
      on conflict (lower(email)) where email is not null do update set phone = coalesce(people.phone, excluded.phone)
      returning id into v_person;
    else
      insert into people (full_name, phone) values (r.full_name, r.phone) returning id into v_person;
    end if;
    update client_contacts set person_id = v_person where id = r.id;
  end loop;
end $$;
delete from client_contacts a using client_contacts b
 where a.client_id = b.client_id and a.person_id = b.person_id and a.ctid > b.ctid;
alter table client_contacts alter column person_id set not null;
alter table client_contacts drop column full_name, drop column email, drop column phone;
alter table client_contacts add constraint client_contacts_unique unique (client_id, person_id);
create unique index client_contacts_one_primary on client_contacts (client_id) where is_primary and is_active;
create index client_contacts_person_idx on client_contacts (person_id);
comment on table client_contacts is 'Purpose: a person''s role at a client (one row per client+person). Projects reference this row, so the same contact serves every project. Identity (name, email, phone) lives in people. [class: internal]';

-- ---------------------------------------------------------------------------
-- Full client profile
-- ---------------------------------------------------------------------------
create function client_name_key(p text) returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(lower(coalesce(p, '')), '\m(pty|ltd|limited|cc|inc|llc|proprietary|co|company|corp|corporation)\M', '', 'g'),
           '[^a-z0-9]+', '', 'g')
$$;

alter table clients
  add column legal_name      text,
  add column trading_name    text,
  add column industry        text,
  add column billing_address text,
  add column social_links    jsonb not null default '{}' check (jsonb_typeof(social_links) = 'object'),
  add column name_key        text generated always as (client_name_key(name)) stored;
alter table clients add constraint clients_name_key_nonempty check (name_key <> '');
create unique index clients_name_key_unique on clients (name_key) where deleted_at is null;
create unique index clients_registration_unique on clients (lower(btrim(registration_number)))
  where registration_number is not null and btrim(registration_number) <> '' and deleted_at is null;
comment on column clients.name is 'How ADA refers to the client. Uniqueness is on a normalised key (case, punctuation and legal suffixes ignored): "ABC Co." and "ABC Pty Ltd" are the same client.';
comment on column clients.status is 'Account status: prospect, active, inactive, archived.';
comment on column clients.billing_address is 'Null means the billing address is the physical address.';

create unique index client_staff_one_owner on client_staff (client_id) where assignment_role = 'owner';

-- ---------------------------------------------------------------------------
-- Duplicate prevention that respects privacy
-- ---------------------------------------------------------------------------
create function client_duplicate_message(p_name text, p_reg text, p_self uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not has_permission_anywhere('clients.create') then null     -- only people who can create clients may probe
              when c.classification in ('public', 'internal')
           then format('a client "%s" already exists (%s); link your division to it with claim_client_for_division() instead of creating a second record', c.name, c.ada_id)
           else 'a matching client already exists but is restricted; ask management to share it with your division' end
  from clients c
  where c.deleted_at is null and c.id is distinct from p_self
    and (c.name_key = client_name_key(p_name)
         or (p_reg is not null and btrim(p_reg) <> '' and lower(btrim(c.registration_number)) = lower(btrim(p_reg))))
  order by c.created_at limit 1
$$;
revoke execute on function client_duplicate_message(text, text, uuid) from public, anon;
grant execute on function client_duplicate_message(text, text, uuid) to authenticated;   -- called by the clients trigger as the invoker

create function clients_duplicate_guard() returns trigger
language plpgsql as $$
declare v_msg text;
begin
  if is_untrusted_caller() then
    v_msg := client_duplicate_message(new.name, new.registration_number, case when tg_op = 'UPDATE' then new.id end);
    if v_msg is not null then
      raise exception '%', v_msg using errcode = '23505';
    end if;
  end if;
  return new;
end $$;
create trigger clients_duplicate_guard_trg before insert or update of name, registration_number on clients
  for each row execute function clients_duplicate_guard();

-- Safe search before creating: returns what the caller may know about existing matches.
create function client_lookup(p_name text default null, p_registration text default null, p_email text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_permission_anywhere('clients.create') then
    raise exception 'clients.create is required' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'client', case when c.classification in ('public', 'internal') then c.ada_id end,
             'name',   case when c.classification in ('public', 'internal') then c.name end,
             'status', case when c.classification in ('public', 'internal') then c.status::text end,
             'match',  m.reason,
             'shareable', c.classification in ('public', 'internal'))))
    from clients c
    cross join lateral (select case
        when p_name is not null and c.name_key = client_name_key(p_name) then 'name'
        when p_registration is not null and btrim(p_registration) <> '' and lower(btrim(c.registration_number)) = lower(btrim(p_registration)) then 'registration_number'
        when p_email is not null and exists (select 1 from client_contacts cc join people pe on pe.id = cc.person_id
                                             where cc.client_id = c.id and cc.is_active and lower(pe.email) = lower(btrim(p_email))) then 'contact_email'
      end as reason) m
    where c.deleted_at is null and m.reason is not null), '[]'::jsonb);
end $$;

-- Start working with an existing client: your division joins the same record (and the owner is told).
create function claim_client_for_division(p_client uuid, p_division uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clients%rowtype;
begin
  if not has_permission('clients.create', p_division) then
    raise exception 'clients.create is required in that division' using errcode = '42501';
  end if;
  select * into c from clients where id = p_client and deleted_at is null;
  if not found or c.classification not in ('public', 'internal') then
    raise exception 'client not found or not shareable; ask management to share it' using errcode = 'P0002';
  end if;
  insert into client_divisions (client_id, division_id, relationship_status, since)
  values (p_client, p_division, 'active', current_date)
  on conflict (client_id, division_id) do update set relationship_status = 'active';
  perform notify_holders('clients.update', c.owner_division_id, 'client.shared',
                         (select name from divisions where id = p_division) || ' started working with ' || c.name,
                         null, 'clients', c.id, c.ada_id);
end $$;

create function set_client_owner(p_client uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not can_edit_client(p_client) then
    raise exception 'you cannot edit this client' using errcode = '42501';
  end if;
  if not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then
    raise exception 'the owner must be active staff' using errcode = '23514';
  end if;
  delete from client_staff where client_id = p_client and assignment_role = 'owner';
  insert into client_staff (client_id, staff_id, assignment_role) values (p_client, p_staff, 'owner')
  on conflict (client_id, staff_id) do update set assignment_role = 'owner';
end $$;

-- ---------------------------------------------------------------------------
-- Contacts: find-or-create the person, then link them to the client
-- ---------------------------------------------------------------------------
create function add_client_contact(p_client uuid, p_name text, p_email text default null, p_phone text default null,
                                   p_role_title text default null, p_primary boolean default false, p_billing boolean default false) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_person uuid;
  v_contact uuid;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if not can_edit_client(p_client) then
    raise exception 'you cannot edit this client' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then
    raise exception 'a valid name is required' using errcode = '22023';
  end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'a valid email is required' using errcode = '22023';
  end if;
  if v_email is not null then
    -- Reuse the existing person (never overwrite their stored identity from a client-side entry).
    insert into people (full_name, email, phone) values (btrim(p_name), v_email, nullif(btrim(coalesce(p_phone, '')), ''))
    on conflict (lower(email)) where email is not null do update set phone = coalesce(people.phone, excluded.phone)
    returning id into v_person;
  else
    insert into people (full_name, phone) values (btrim(p_name), nullif(btrim(coalesce(p_phone, '')), '')) returning id into v_person;
  end if;
  if p_primary then
    update client_contacts set is_primary = false where client_id = p_client and is_primary;
  end if;
  insert into client_contacts (client_id, person_id, role_title, is_primary, is_billing)
  values (p_client, v_person, p_role_title, p_primary, p_billing)
  on conflict (client_id, person_id) do update
    set is_active = true, role_title = coalesce(excluded.role_title, client_contacts.role_title),
        is_primary = client_contacts.is_primary or excluded.is_primary, is_billing = client_contacts.is_billing or excluded.is_billing
  returning id into v_contact;
  return v_contact;
end $$;

-- ---------------------------------------------------------------------------
-- Who may see / edit a person: by RELATIONSHIP, never by the identity row alone
-- ---------------------------------------------------------------------------
create or replace function can_view_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('hr.view') or has_permission('applications.view')
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.view', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_view_client(cc.client_id))
$$;

create function can_edit_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('hr.update')
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.review', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_edit_client(cc.client_id))
$$;
revoke execute on function can_edit_person(uuid) from public, anon;
grant execute on function can_edit_person(uuid) to authenticated;

drop policy people_update on people;
create policy people_update on people for update to authenticated
  using (can_edit_person(id) and can_view_person(id)) with check (can_edit_person(id) and can_view_person(id));

-- The application intake function must infer the (now partial) unique index.
create or replace function create_application_internal(
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

  insert into people (full_name, email, phone) values (btrim(p_name), v_email, nullif(btrim(coalesce(p_phone, '')), ''))
  on conflict (lower(email)) where email is not null do update set phone = coalesce(people.phone, excluded.phone)
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

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke insert on client_contacts from authenticated;
revoke update on client_contacts from authenticated;
grant update (role_title, is_primary, is_billing, is_active) on client_contacts to authenticated;
drop policy contacts_insert on client_contacts;

revoke execute on function client_lookup(text, text, text), claim_client_for_division(uuid, uuid), set_client_owner(uuid, uuid),
  add_client_contact(uuid, text, text, text, text, boolean, boolean) from public, anon;
grant execute on function client_lookup(text, text, text), claim_client_for_division(uuid, uuid), set_client_owner(uuid, uuid),
  add_client_contact(uuid, text, text, text, text, boolean, boolean) to authenticated;
revoke execute on function client_name_key(text) from public, anon;
grant execute on function client_name_key(text) to authenticated;
