-- 0023_leads_enquiries: from "someone wrote to us" to "a qualified lead on an existing client".
--
--   ENQUIRY  the raw inbound message from a connected website (or phone/email/walk-in), with its source tracking.
--   LEAD     the unit of sales work. An enquiry attaches to an open lead of the same person, or opens a new one.
--   MATCH    the system resolves the person (by email) and looks for an existing client - automatically only when
--            the match is confident and discoverable; otherwise it leaves the question to a human.
--   QUALIFY  a human links/creates the client and contact through the controlled paths; the lead is then ready for a quote.
--
-- Not every enquiry becomes a client. An enquiry may come from an existing client, a new person, a new organization
-- or an anonymous prospect, and each case is a valid state.
--
-- SNAPSHOT columns: enquiries.submitted_* store what the sender typed, because a stranger has no central record yet.
-- They are history ("what was submitted"), never the live identity: operations use person_id / client_id once resolved.
-- Restricted clients are never revealed here: they are never auto-linked, never shown as candidates to the handler,
-- and an enquiry that happens to match one looks exactly like an enquiry that matches nothing.

alter table websites drop constraint websites_capabilities_check;
alter table websites add constraint websites_capabilities_check
  check (capabilities <@ array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read', 'applications.submit', 'services.read',
                               'portfolio.read', 'contact.read', 'leads.submit', 'enquiries.submit']);

create type enquiry_channel as enum ('website', 'phone', 'email', 'walk_in', 'referral', 'other');
create type enquiry_status  as enum ('received', 'processed', 'needs_review', 'closed', 'spam');
create type lead_status     as enum ('new', 'contacted', 'qualified', 'unqualified', 'lost', 'converted');

create table leads (
  id                   uuid primary key default gen_random_uuid(),
  ada_id               text not null unique,
  division_id          uuid not null references divisions (id),
  title                text not null check (btrim(title) <> ''),
  status               lead_status not null default 'new',
  person_id            uuid references people (id),
  client_id            uuid references clients (id),
  contact_id           uuid references client_contacts (id),
  requested_service_id uuid references services (id),
  estimated_value      numeric(14,2) check (estimated_value >= 0),
  currency             char(3) not null default 'NAD',
  assigned_staff_id    uuid references staff (id),
  follow_up_on         date,
  qualification_note   text,
  lost_reason          text,
  qualified_at         timestamptz,
  converted_at         timestamptz,
  created_by           uuid references staff (id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index leads_division_idx on leads (division_id, status);
create index leads_person_idx   on leads (person_id) where person_id is not null;
create index leads_client_idx   on leads (client_id) where client_id is not null;
comment on table leads is 'Purpose: sales work from first enquiry to quote. References the central person, client and contact; never copies them. The title never contains personal data. [class: confidential]';
do $$ begin perform attach_ada_id('leads', 'lead'); end $$;
create trigger leads_updated before update on leads for each row execute function set_updated_at();

create table enquiries (
  id                     uuid primary key default gen_random_uuid(),
  ada_id                 text not null unique,
  channel                enquiry_channel not null default 'website',
  source_website_id      uuid references websites (id),
  source_division_id     uuid references divisions (id),
  division_id            uuid not null references divisions (id),
  source_page            text check (length(source_page) <= 500),
  referrer               text check (length(referrer) <= 500),
  utm_source             text check (length(utm_source) <= 200),
  utm_medium             text check (length(utm_medium) <= 200),
  utm_campaign           text check (length(utm_campaign) <= 200),
  utm_term               text check (length(utm_term) <= 200),
  utm_content            text check (length(utm_content) <= 200),
  submitted_name         text check (length(submitted_name) <= 200),
  submitted_email        text check (length(submitted_email) <= 254),
  submitted_phone        text check (length(submitted_phone) <= 60),
  submitted_organization text check (length(submitted_organization) <= 200),
  message                text check (length(message) <= 5000),
  requested_service_id   uuid references services (id),
  requested_service_text text check (length(requested_service_text) <= 200),
  budget_amount          numeric(14,2) check (budget_amount >= 0),
  budget_currency        char(3),
  submitted_at           timestamptz not null default now(),
  status                 enquiry_status not null default 'received',
  person_id              uuid references people (id),
  client_id              uuid references clients (id),
  lead_id                uuid references leads (id),
  match_summary          text,
  assigned_staff_id      uuid references staff (id),
  created_by             uuid references staff (id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  check (coalesce(submitted_email, '') <> '' or coalesce(submitted_phone, '') <> '' or coalesce(message, '') <> '')
);
create index enquiries_division_idx on enquiries (division_id, status);
create index enquiries_lead_idx on enquiries (lead_id);
comment on table enquiries is 'Purpose: one inbound enquiry with its full source tracking (website, page, referrer, campaign). Resolved to central person/client/lead records; the central records, not this row, are the source of truth. [class: confidential]';
comment on column enquiries.submitted_name         is 'SNAPSHOT: the name exactly as typed by the sender. History only; use person_id for identity.';
comment on column enquiries.submitted_email        is 'SNAPSHOT: the email exactly as typed by the sender. History only; use person_id for identity.';
comment on column enquiries.submitted_phone        is 'SNAPSHOT: the phone number exactly as typed by the sender. History only; use person_id for identity.';
comment on column enquiries.submitted_organization is 'SNAPSHOT: the organization name exactly as typed by the sender. History only; use client_id for identity.';
do $$ begin perform attach_ada_id('enquiries', 'enquiry'); end $$;
create trigger enquiries_updated before update on enquiries for each row execute function set_updated_at();

create table enquiry_candidates (
  id          uuid primary key default gen_random_uuid(),
  enquiry_id  uuid not null references enquiries (id) on delete restrict,
  client_id   uuid not null references clients (id),
  reason      text not null,
  score       real,
  hidden      boolean not null,
  decision    text check (decision in ('linked', 'rejected')),
  decided_by  uuid references staff (id),
  decided_at  timestamptz,
  unique (enquiry_id, client_id)
);
comment on table enquiry_candidates is 'Purpose: possible existing clients for an enquiry that could not be matched confidently. Rows for restricted clients are hidden=true and visible only to matching.review, so the handler cannot tell they exist. [class: restricted]';

-- ---------------------------------------------------------------------------
-- People visibility/edit now include the lead relationship (and nothing else is added)
-- ---------------------------------------------------------------------------
create or replace function can_view_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  -- Strictly by RELATIONSHIP. No permission lets you read every person: HR sees the people who are staff,
  -- recruiters see applicants, client teams see their contacts, lead handlers see their prospects.
  select exists (select 1 from staff s where s.person_id = p_id and has_permission('hr.view'))
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.view', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_view_client(cc.client_id))
      or exists (select 1 from leads l where l.person_id = p_id and has_permission('leads.view', l.division_id))
$$;
create or replace function can_edit_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from staff s where s.person_id = p_id and has_permission('hr.update'))
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.review', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_edit_client(cc.client_id))
      or exists (select 1 from leads l where l.person_id = p_id and has_permission('leads.update', l.division_id))
$$;

-- ---------------------------------------------------------------------------
-- Resolution: person, client candidates, lead
-- ---------------------------------------------------------------------------
create function enquiry_process(p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  e enquiries%rowtype;
  v_person uuid;
  v_client uuid;
  v_n integer;
  v_lead uuid;
  v_new_lead boolean := false;
  v_title text;
  v_status enquiry_status;
  v_summary text[] := '{}';
  v_ada text;
begin
  select * into e from enquiries where id = p_id for update;

  -- PERSON: only an email gives a confident identity. No email = anonymous prospect (no person record is invented).
  if e.submitted_email is not null then
    select id into v_person from people where lower(email) = lower(e.submitted_email);
    if v_person is null then
      insert into people (full_name, email, phone)
      values (coalesce(nullif(btrim(e.submitted_name), ''), split_part(e.submitted_email, '@', 1)), lower(e.submitted_email), nullif(btrim(coalesce(e.submitted_phone, '')), ''))
      returning id into v_person;
    elsif e.submitted_phone is not null then
      update people set phone = coalesce(phone, nullif(btrim(e.submitted_phone), '')) where id = v_person;
    end if;
    v_summary := array_append(v_summary, 'person recorded'::text);   -- deliberately neutral: whether the email was already known is not disclosed to the handler
  else
    v_summary := array_append(v_summary, 'anonymous prospect'::text);
  end if;

  -- CLIENT: automatic link only on a confident, DISCOVERABLE match. Restricted clients are never auto-linked.
  if e.submitted_organization is not null then
    select client_id into v_client from client_candidates(e.submitted_organization, null, e.submitted_email, v_person)
     where reason = 'exact_name' and discoverable limit 1;
  else
    select count(distinct client_id) into v_n from client_candidates(null, null, e.submitted_email, v_person) where reason = 'person_is_contact' and discoverable;
    if v_n = 1 then
      select client_id into v_client from client_candidates(null, null, e.submitted_email, v_person) where reason = 'person_is_contact' and discoverable limit 1;
    end if;
  end if;

  if v_client is not null then
    v_summary := array_append(v_summary, 'client matched'::text);
  else
    -- ambiguity: record candidates. Hidden ones (restricted) are stored for management only and do not change what the handler sees.
    insert into enquiry_candidates (enquiry_id, client_id, reason, score, hidden)
    select p_id, x.client_id, x.reason, x.score, not x.discoverable
      from (select distinct on (client_id) client_id, reason, score, discoverable
              from client_candidates(e.submitted_organization, null, e.submitted_email, v_person) order by client_id, score desc) x
    on conflict do nothing;
  end if;
  select count(*) into v_n from enquiry_candidates where enquiry_id = p_id and not hidden;
  v_status := case when v_client is null and v_n > 0 then 'needs_review' else 'processed' end;
  if v_status = 'needs_review' then v_summary := array_append(v_summary, 'possible existing client: review needed'::text); end if;

  -- LEAD: attach to this person's open lead in the same division, otherwise open one.
  if v_person is not null then
    select id into v_lead from leads
     where person_id = v_person and division_id = e.division_id and status in ('new', 'contacted', 'qualified')
       and created_at > now() - interval '30 days' order by created_at desc limit 1;
  end if;
  if v_lead is null then
    v_title := case when e.requested_service_id is not null then 'Enquiry about ' || (select name from services where id = e.requested_service_id)
                    when e.requested_service_text is not null then 'Enquiry about ' || e.requested_service_text else 'General enquiry' end;
    insert into leads (division_id, title, person_id, client_id, requested_service_id, created_by)
    values (e.division_id, v_title, v_person, v_client, e.requested_service_id, e.created_by) returning id, ada_id into v_lead, v_ada;
    v_new_lead := true;
  else
    update leads set client_id = coalesce(client_id, v_client) where id = v_lead;
  end if;

  update enquiries set person_id = v_person, client_id = v_client, lead_id = v_lead, status = v_status, match_summary = array_to_string(v_summary, '; ') where id = p_id;

  perform emit_event('enquiry.received', 'enquiries', e.id, e.ada_id, jsonb_build_object('channel', e.channel, 'status', v_status));
  if v_new_lead then
    perform emit_event('lead.created', 'leads', v_lead, v_ada, jsonb_build_object('status', 'new'));
  end if;
  perform notify_holders('leads.update', e.division_id, case when v_new_lead then 'lead.new' else 'lead.updated' end,
                         case when v_new_lead then 'New enquiry ' else 'Follow-up enquiry ' end || e.ada_id,
                         null, 'enquiries', e.id, e.ada_id);
end $$;

create function create_enquiry_internal(
  p_channel enquiry_channel, p_site uuid, p_division uuid, p_created_by uuid,
  p_page text, p_referrer text, p_utm_source text, p_utm_medium text, p_utm_campaign text, p_utm_term text, p_utm_content text,
  p_name text, p_email text, p_phone text, p_org text, p_service text, p_service_text text, p_message text, p_budget numeric, p_currency text
) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  w websites%rowtype;
  s services%rowtype;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_div uuid;
  v_id uuid;
  v_ada text;
  v_service_found boolean := false;
begin
  if v_email is not null and (v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254) then
    raise exception 'a valid email is required' using errcode = '22023';
  end if;
  if v_email is null and nullif(btrim(coalesce(p_phone, '')), '') is null and nullif(btrim(coalesce(p_message, '')), '') is null then
    raise exception 'an email, phone number or message is required' using errcode = '22023';
  end if;
  if p_site is not null then select * into w from websites where id = p_site; end if;
  if p_service is not null then
    select * into s from services where ada_id = p_service and status = 'published' and is_active and deleted_at is null;
    v_service_found := found;
  end if;
  v_div := coalesce(case when v_service_found then s.division_id end, w.division_id, p_division,
                    (select id from divisions where key = 'management'));
  insert into enquiries (channel, source_website_id, source_division_id, division_id, source_page, referrer,
                         utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                         submitted_name, submitted_email, submitted_phone, submitted_organization, message,
                         requested_service_id, requested_service_text, budget_amount, budget_currency, created_by)
  values (p_channel, p_site, w.division_id, v_div, left(p_page, 500), left(p_referrer, 500),
          left(p_utm_source, 200), left(p_utm_medium, 200), left(p_utm_campaign, 200), left(p_utm_term, 200), left(p_utm_content, 200),
          nullif(btrim(coalesce(p_name, '')), ''), v_email, nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_org, '')), ''), nullif(btrim(coalesce(p_message, '')), ''),
          case when v_service_found then s.id end, left(coalesce(p_service_text, case when not v_service_found then p_service end), 200),
          p_budget, case when p_budget is not null then upper(coalesce(p_currency, 'NAD')) end, p_created_by)
  returning id, ada_id into v_id, v_ada;
  perform enquiry_process(v_id);
  return v_ada;
end $$;
revoke execute on function enquiry_process(uuid), create_enquiry_internal(enquiry_channel, uuid, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, text, text, numeric, text)
  from public, anon, authenticated;

-- Staff record an enquiry received by phone, email or in person.
create function enquiry_record(p_division uuid, p_channel enquiry_channel, p_name text, p_email text, p_phone text,
                               p_organization text, p_service uuid, p_message text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_permission('leads.create', p_division) then
    raise exception 'leads.create is required in that division' using errcode = '42501';
  end if;
  if p_channel = 'website' then raise exception 'website enquiries arrive through the website, not by hand' using errcode = '22023'; end if;
  return create_enquiry_internal(p_channel, null, p_division, current_staff_id(), null, null, null, null, null, null, null,
                                 p_name, p_email, p_phone, p_organization, (select ada_id from services where id = p_service), null, p_message, null, null);
end $$;

-- A human settles an ambiguous client match.
create function enquiry_resolve_candidate(p_enquiry uuid, p_client uuid, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e enquiries%rowtype;
begin
  select * into e from enquiries where id = p_enquiry for update;
  if not found or not has_permission('leads.view', e.division_id) then raise exception 'enquiry not found' using errcode = 'P0002'; end if;
  if not has_permission('leads.update', e.division_id) then raise exception 'leads.update is required' using errcode = '42501'; end if;
  if p_action = 'link' then
    if not exists (select 1 from enquiry_candidates where enquiry_id = p_enquiry and client_id = p_client and not hidden and decision is null) then
      raise exception 'candidate not found' using errcode = 'P0002';        -- identical for hidden and non-existent candidates
    end if;
    update enquiry_candidates set decision = case when client_id = p_client then 'linked' else 'rejected' end, decided_by = current_staff_id(), decided_at = now()
     where enquiry_id = p_enquiry and not hidden and decision is null;
    update enquiries set client_id = p_client, status = 'processed' where id = p_enquiry;
    update leads set client_id = coalesce(client_id, p_client) where id = e.lead_id;
  elsif p_action = 'none' then
    update enquiry_candidates set decision = 'rejected', decided_by = current_staff_id(), decided_at = now()
     where enquiry_id = p_enquiry and not hidden and decision is null;
    update enquiries set status = 'processed' where id = p_enquiry;
  else
    raise exception 'action must be link or none' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Lead commands
-- ---------------------------------------------------------------------------
create function lead_assign(p_lead uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l leads%rowtype;
begin
  select * into l from leads where id = p_lead for update;
  if not found or not has_permission('leads.view', l.division_id) then raise exception 'lead not found' using errcode = 'P0002'; end if;
  if not has_permission('leads.update', l.division_id) then raise exception 'leads.update is required' using errcode = '42501'; end if;
  if not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then
    raise exception 'the assignee must be active staff' using errcode = '23514';
  end if;
  update leads set assigned_staff_id = p_staff where id = p_lead;
  update enquiries set assigned_staff_id = p_staff where lead_id = p_lead;
  insert into notifications (recipient_staff_id, type, title, entity_table, entity_id, entity_ada_id)
  values (p_staff, 'lead.assigned', 'Lead assigned to you: ' || l.ada_id, 'leads', l.id, l.ada_id);
end $$;

create function lead_transition(p_lead uuid, p_to lead_status, p_note text default null) returns lead_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare l leads%rowtype;
begin
  select * into l from leads where id = p_lead for update;
  if not found or not has_permission('leads.view', l.division_id) then raise exception 'lead not found' using errcode = 'P0002'; end if;
  if not has_permission('leads.update', l.division_id) then raise exception 'leads.update is required' using errcode = '42501'; end if;
  if (l.status, p_to) not in (('new', 'contacted'), ('new', 'unqualified'), ('new', 'lost'), ('contacted', 'unqualified'), ('contacted', 'lost'),
                              ('qualified', 'lost'), ('lost', 'contacted'), ('unqualified', 'contacted')) then
    raise exception 'invalid lead transition % -> % (qualification and conversion have their own commands)', l.status, p_to using errcode = '23514';
  end if;
  if p_to in ('lost', 'unqualified') and coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update leads set status = p_to, lost_reason = case when p_to in ('lost', 'unqualified') then p_note else null end where id = p_lead;
  return p_to;
end $$;

-- Attach (or correct) the prospect's identity once a human has it: find-or-create the person, never duplicate.
create function lead_set_person(p_lead uuid, p_name text, p_email text, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare l leads%rowtype; v_person uuid; v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  select * into l from leads where id = p_lead for update;
  if not found or not has_permission('leads.view', l.division_id) then raise exception 'lead not found' using errcode = 'P0002'; end if;
  if not has_permission('leads.update', l.division_id) then raise exception 'leads.update is required' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then raise exception 'a valid name is required' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'a valid email is required' using errcode = '22023'; end if;
  if v_email is not null then
    insert into people (full_name, email, phone) values (btrim(p_name), v_email, nullif(btrim(coalesce(p_phone, '')), ''))
    on conflict (lower(email)) where email is not null do update set phone = coalesce(people.phone, excluded.phone) returning id into v_person;
  else
    insert into people (full_name, phone) values (btrim(p_name), nullif(btrim(coalesce(p_phone, '')), '')) returning id into v_person;
  end if;
  update leads set person_id = v_person where id = p_lead;
  update enquiries set person_id = v_person where lead_id = p_lead and person_id is null;
  return v_person;
end $$;

-- Qualification: settle the client and contact through the controlled paths, then the lead is ready for a quote.
create function lead_qualify(p_lead uuid, p_client uuid default null, p_new_client_name text default null, p_client_type client_type default 'company',
                             p_distinct_reason text default null, p_note text default null, p_estimated_value numeric default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  l leads%rowtype;
  v_client uuid;
  v_contact uuid;
  r jsonb;
begin
  select * into l from leads where id = p_lead for update;
  if not found or not has_permission('leads.view', l.division_id) then raise exception 'lead not found' using errcode = 'P0002'; end if;
  if not (has_permission('leads.update', l.division_id) and has_permission('clients.create', l.division_id)) then
    raise exception 'leads.update and clients.create are required in the lead''s division' using errcode = '42501';
  end if;
  if l.status = 'qualified' then return jsonb_build_object('status', 'qualified', 'client', (select ada_id from clients where id = l.client_id)); end if;
  if l.status not in ('new', 'contacted') then raise exception 'a % lead cannot be qualified', l.status using errcode = '23514'; end if;
  if l.person_id is null then raise exception 'attach the prospect''s contact details first (lead_set_person)' using errcode = '23514'; end if;

  if l.client_id is not null then
    v_client := l.client_id;
  elsif p_client is not null then
    v_client := p_client;
  elsif nullif(btrim(coalesce(p_new_client_name, '')), '') is not null then
    r := client_create(p_new_client_name, l.division_id, p_client_type, null, null, null, p_distinct_reason);
    if r ->> 'status' = 'similar' then
      raise exception 'similar clients exist (%); link one of them or give p_distinct_reason', (select string_agg(e ->> 'name', ', ') from jsonb_array_elements(r -> 'candidates') e) using errcode = '23514';
    end if;
    v_client := case when r ->> 'status' = 'created' then (r ->> 'id')::uuid else (select id from clients where ada_id = r ->> 'client') end;
  else
    raise exception 'a client is required: link an existing one or name a new one' using errcode = '23514';
  end if;

  -- Joining an existing client is only possible for discoverable ones; hidden or missing look identical.
  if not exists (select 1 from clients where id = v_client and deleted_at is null and (classification in ('public', 'internal') or owner_division_id = l.division_id)) then
    raise exception 'client not found or not shareable; ask management to share it' using errcode = 'P0002';
  end if;
  insert into client_divisions (client_id, division_id, relationship_status) values (v_client, l.division_id, 'active')
  on conflict (client_id, division_id) do update set relationship_status = 'active';

  insert into client_contacts (client_id, person_id, role_title) values (v_client, l.person_id, 'enquiry contact')
  on conflict (client_id, person_id) do update set is_active = true returning id into v_contact;

  update leads set client_id = v_client, contact_id = v_contact, status = 'qualified', qualified_at = now(),
         qualification_note = coalesce(p_note, qualification_note), estimated_value = coalesce(p_estimated_value, estimated_value) where id = p_lead;
  update enquiries set client_id = v_client, status = case when status = 'needs_review' then 'processed' else status end where lead_id = p_lead and client_id is null;
  perform emit_event('lead.qualified', 'leads', l.id, l.ada_id, jsonb_build_object('status', 'qualified'));
  return jsonb_build_object('status', 'qualified', 'client', (select ada_id from clients where id = v_client));
end $$;

-- ---------------------------------------------------------------------------
-- Public API: a website submits an enquiry. The response never depends on what the system already knows.
-- ---------------------------------------------------------------------------
create function public_api.submit_enquiry(p_key_hash text, p_name text, p_email text, p_phone text, p_organization text, p_service text,
                                          p_message text, p_page text default null, p_referrer text default null, p_utm jsonb default '{}',
                                          p_budget numeric default null, p_currency text default 'NAD') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_site uuid := public_api.authorize(p_key_hash, 'enquiries.submit');
begin
  return jsonb_build_object('reference', create_enquiry_internal('website', v_site, null, null, p_page, p_referrer,
    p_utm ->> 'utm_source', p_utm ->> 'utm_medium', p_utm ->> 'utm_campaign', p_utm ->> 'utm_term', p_utm ->> 'utm_content',
    p_name, p_email, p_phone, p_organization, p_service, null, p_message, p_budget, p_currency));
end $$;
revoke all on function public_api.submit_enquiry(text, text, text, text, text, text, text, text, text, jsonb, numeric, text) from public, anon, authenticated;
grant execute on function public_api.submit_enquiry(text, text, text, text, text, text, text, text, text, jsonb, numeric, text) to ada_public_api;

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table leads             enable row level security;
alter table enquiries         enable row level security;
alter table enquiry_candidates enable row level security;
revoke all on leads, enquiries, enquiry_candidates from anon, authenticated;
grant select on leads, enquiries, enquiry_candidates to authenticated;
grant update (title, follow_up_on, estimated_value, currency, qualification_note) on leads to authenticated;

create policy leads_select on leads for select to authenticated using (has_permission('leads.view', division_id));
create policy leads_update on leads for update to authenticated
  using (has_permission('leads.update', division_id)) with check (has_permission('leads.update', division_id));
create policy enquiries_select on enquiries for select to authenticated using (has_permission('leads.view', division_id));
create policy enquiry_candidates_select on enquiry_candidates for select to authenticated
  using ((not hidden and exists (select 1 from enquiries e where e.id = enquiry_id)) or has_permission('matching.review'));

revoke execute on function enquiry_record(uuid, enquiry_channel, text, text, text, text, uuid, text), enquiry_resolve_candidate(uuid, uuid, text),
  lead_assign(uuid, uuid), lead_transition(uuid, lead_status, text), lead_set_person(uuid, text, text, text),
  lead_qualify(uuid, uuid, text, client_type, text, text, numeric) from public, anon;
grant execute on function enquiry_record(uuid, enquiry_channel, text, text, text, text, uuid, text), enquiry_resolve_candidate(uuid, uuid, text),
  lead_assign(uuid, uuid), lead_transition(uuid, lead_status, text), lead_set_person(uuid, text, text, text),
  lead_qualify(uuid, uuid, text, client_type, text, text, numeric) to authenticated;

do $$ begin perform attach_audit('leads'); end $$;
do $$ begin perform attach_audit('enquiries', array['submitted_name', 'submitted_email', 'submitted_phone', 'submitted_organization', 'message']); end $$;
do $$ begin perform attach_audit('enquiry_candidates'); end $$;
