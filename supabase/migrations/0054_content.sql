-- 0054_content: what the websites SAY, kept in the database like what they SELL.
--  * content_posts (news, announcements, updates), testimonials and faqs: editorial records with the same publication workflow as services
--    (draft -> pending_approval -> approved -> published -> unpublished/archived). Editing the public wording of a published record sends it back to draft.
--    Writes by staff go through row-level security + guard triggers; status changes only through content_transition().
--  * site_settings: the company facts every footer shows (phones, emails, place) and the marketing planner's policy numbers, one value per key (optionally per
--    division). A setting is public or internal; changing one needs settings.update; every change is audited.
--  * Public API: public_api.posts / post / testimonials / faqs (capability content.read) and public_api.settings (capability settings.read): explicit DTOs of
--    published records only. Publishing, unpublishing and archiving emit events so subscribed websites refresh.
--  * Testimonials need the person's consent recorded before they can be published (the same rule as portfolio entries).

-- ---------------------------------------------------------------------------
-- 1. Permissions, entity types
-- ---------------------------------------------------------------------------
insert into permissions (key, module, action, description, sensitivity) values
  ('content.create', 'content', 'create', 'Create news, announcements, testimonials and FAQs', 'internal'::data_classification),
  ('content.update', 'content', 'update', 'Edit and submit news, announcements, testimonials and FAQs', 'internal'::data_classification),
  ('content.publish', 'content', 'publish', 'Approve, publish and unpublish website content', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'content.create'), ('ceo', 'content.update'), ('ceo', 'content.publish'),
  ('administration_officer', 'content.create'), ('administration_officer', 'content.update'),
  ('division_lead', 'content.create'), ('division_lead', 'content.update')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- publishable = false: that flag is for the registry-based publication layer (documents ...); editorial records have their own publication workflow below.
-- Legacy-style IDs only (ADA-NWS-2026-0001): editorial records are not part of the institutional registry (no 9-character ID, no search entry), but their
-- types are in the type map and the coding standard so the codes are never reused.
insert into entity_types (key, prefix, family, publishable, description, id_code) values
  ('content_post', 'NWS', 'operations', false, 'News, announcement or update shown on the websites', 'NP'),
  ('testimonial',  'TST', 'operations', false, 'Client testimonial shown on the websites', 'TT'),
  ('faq',          'FAQ', 'operations', false, 'Frequently asked question shown on the websites', 'FA');
insert into id_codebook (version, kind, code, meaning, family, note)
select 1, 'type', id_code, key, family, description from entity_types where key in ('content_post', 'testimonial', 'faq');

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create type content_kind as enum ('news', 'announcement', 'update');

create table content_posts (
  id              uuid primary key default gen_random_uuid(),
  ada_id          text not null unique,
  division_id     uuid references divisions (id),                      -- null = the whole agency
  content_type    content_kind not null default 'news',
  title           text not null check (btrim(title) <> ''),
  slug            text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) <= 120),
  summary         text not null check (btrim(summary) <> '' and length(summary) <= 600),
  body            text not null default '',
  cover_image_url text check (cover_image_url is null or cover_image_url ~ '^https://'),
  image_alt_text  text,
  author_name     text,
  source_label    text,
  featured        boolean not null default false,
  status          publication_state not null default 'draft',
  approved_by     uuid references staff (id),
  approved_at     timestamptz,
  published_at    timestamptz,
  status_reason   text,
  created_by      uuid references staff (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index content_posts_public_idx on content_posts (status, published_at desc);
comment on table content_posts is 'Purpose: news, announcements and updates for the websites. Public only when status = published (through public_api.posts). Editing the public wording of an approved/published post returns it to draft. [class: internal]';

create table testimonials (
  id                uuid primary key default gen_random_uuid(),
  ada_id            text not null unique,
  division_id       uuid references divisions (id),
  service_id        uuid references services (id),
  quote             text not null check (btrim(quote) <> '' and length(quote) <= 1200),
  person_name       text not null check (btrim(person_name) <> ''),
  person_role       text,
  organization_name text,
  consent_confirmed boolean not null default false,
  consent_note      text,
  sort_order        integer not null default 100,
  status            publication_state not null default 'draft',
  approved_by       uuid references staff (id),
  approved_at       timestamptz,
  published_at      timestamptz,
  status_reason     text,
  created_by        uuid references staff (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (not consent_confirmed or coalesce(btrim(consent_note), '') <> '')
);
comment on table testimonials is 'Purpose: client testimonials. Cannot be published until the person''s consent is recorded (and a note says how it was given). [class: internal]';

create table faqs (
  id            uuid primary key default gen_random_uuid(),
  ada_id        text not null unique,
  division_id   uuid references divisions (id),
  service_id    uuid references services (id),
  category      text,
  question      text not null check (btrim(question) <> ''),
  answer        text not null check (btrim(answer) <> ''),
  sort_order    integer not null default 100,
  status        publication_state not null default 'draft',
  approved_by   uuid references staff (id),
  approved_at   timestamptz,
  published_at  timestamptz,
  status_reason text,
  created_by    uuid references staff (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on column testimonials.person_name is 'SNAPSHOT: the name as the person agreed to be shown on the website; not linked to a person or contact record.';
comment on column testimonials.organization_name is 'SNAPSHOT: the organisation name as shown on the website; not linked to a client record.';
comment on table faqs is 'Purpose: frequently asked questions for the websites, agency-wide or per division / service. [class: internal]';

do $$ begin
  perform attach_ada_id('content_posts', 'content_post');
  perform attach_ada_id('testimonials', 'testimonial');
  perform attach_ada_id('faqs', 'faq');
end $$;
create trigger content_posts_updated before update on content_posts for each row execute function set_updated_at();
create trigger testimonials_updated  before update on testimonials  for each row execute function set_updated_at();
create trigger faqs_updated          before update on faqs          for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Guards: creation is always draft; status moves only through content_transition(); editing public wording reopens approval
-- ---------------------------------------------------------------------------
create function content_posts_slug() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare v_base text; v_try text; n integer := 1;
begin
  if tg_op = 'UPDATE' then
    if new.slug is distinct from old.slug and old.status in ('approved', 'published') and is_untrusted_caller() then
      raise exception 'the address of a published post cannot change (it would break links); unpublish it first' using errcode = '42501';
    end if;
    return new;
  end if;
  v_base := left(coalesce(nullif(regexp_replace(regexp_replace(lower(btrim(coalesce(nullif(btrim(new.slug), ''), new.title))), '[^a-z0-9]+', '-', 'g'), '(^-+|-+$)', '', 'g'), ''), 'post'), 100);
  v_try := v_base;
  while exists (select 1 from content_posts where slug = v_try) loop n := n + 1; v_try := left(v_base, 110) || '-' || n; end loop;
  new.slug := v_try;
  return new;
end $$;
create trigger content_posts_slug_trg before insert or update on content_posts for each row execute function content_posts_slug();

create function content_guard() returns trigger
language plpgsql as $$
declare
  bookkeeping text[] := array['id', 'ada_id', 'status', 'approved_by', 'approved_at', 'published_at', 'status_reason', 'created_by', 'created_at', 'updated_at'];
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if is_untrusted_caller() and new.status <> 'draft' then
      raise exception 'content is created as a draft' using errcode = '42501';
    end if;
    return new;
  end if;
  if is_untrusted_caller() then
    new.created_by := old.created_by;
    if new.status is distinct from old.status or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at
       or new.published_at is distinct from old.published_at or new.status_reason is distinct from old.status_reason then
      raise exception 'content status is changed only through content_transition()' using errcode = '42501';
    end if;
    if (to_jsonb(new) - bookkeeping) is distinct from (to_jsonb(old) - bookkeeping) and old.status in ('pending_approval', 'approved', 'published') then
      new.status := 'draft'; new.approved_by := null; new.approved_at := null; new.published_at := null;
      new.status_reason := 'edited after approval; needs re-approval';
    end if;
  end if;
  return new;
end $$;
create trigger content_posts_guard_trg before insert or update on content_posts for each row execute function content_guard();
create trigger testimonials_guard_trg  before insert or update on testimonials  for each row execute function content_guard();
create trigger faqs_guard_trg          before insert or update on faqs          for each row execute function content_guard();

create trigger content_posts_approval_trg after insert or update on content_posts for each row execute function approval_sync('content_publication', 'content.publish', 'title', 'division_id');
create trigger testimonials_approval_trg  after insert or update on testimonials  for each row execute function approval_sync('content_publication', 'content.publish', 'person_name', 'division_id');
create trigger faqs_approval_trg          after insert or update on faqs          for each row execute function approval_sync('content_publication', 'content.publish', 'question', 'division_id');

create trigger content_posts_events_trg after update on content_posts for each row execute function publication_events('content_post');
create trigger testimonials_events_trg  after update on testimonials  for each row execute function publication_events('testimonial');
create trigger faqs_events_trg          after update on faqs          for each row execute function publication_events('faq');

-- ---------------------------------------------------------------------------
-- 4. Workflow
-- ---------------------------------------------------------------------------
create function content_transition(p_kind text, p_id uuid, p_to publication_state, p_reason text default null) returns publication_state
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_table text; j jsonb; v_status publication_state; v_div uuid; v_edit boolean; v_pub boolean;
begin
  v_table := case p_kind when 'post' then 'content_posts' when 'testimonial' then 'testimonials' when 'faq' then 'faqs' end;
  if v_table is null then raise exception 'unknown content kind' using errcode = '22023'; end if;
  execute format('select to_jsonb(t) from %I t where id = $1 for update', v_table) into j using p_id;
  if j is null then raise exception 'content not found' using errcode = 'P0002'; end if;
  v_status := (j ->> 'status')::publication_state;
  v_div := nullif(j ->> 'division_id', '')::uuid;
  v_edit := has_permission('content.update', v_div);
  v_pub := has_permission('content.publish');

  case
    when v_status in ('draft', 'unpublished') and p_to = 'pending_approval' then
      if not v_edit then raise exception 'content.update is required' using errcode = '42501'; end if;
      execute format('update %I set status = $2, status_reason = null where id = $1', v_table) using p_id, p_to;
      perform notify_holders('content.publish', null, 'approval.required', 'Content awaiting approval: ' || coalesce(j ->> 'title', j ->> 'person_name', j ->> 'question'), null, v_table, p_id, j ->> 'ada_id');
    when v_status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_pub) then raise exception 'not permitted' using errcode = '42501'; end if;
      execute format('update %I set status = $2, status_reason = $3 where id = $1', v_table) using p_id, p_to, p_reason;
    when v_status = 'pending_approval' and p_to = 'approved' then
      if not v_pub then raise exception 'content.publish is required to approve' using errcode = '42501'; end if;
      execute format('update %I set status = $2, approved_by = current_staff_id(), approved_at = now(), status_reason = null where id = $1', v_table) using p_id, p_to;
    when v_status = 'approved' and p_to = 'published' then
      if not v_pub then raise exception 'content.publish is required to publish' using errcode = '42501'; end if;
      if p_kind = 'testimonial' and not coalesce((j ->> 'consent_confirmed')::boolean, false) then
        raise exception 'a testimonial cannot be published until the person''s consent is recorded' using errcode = '23514';
      end if;
      execute format('update %I set status = $2, published_at = coalesce(published_at, clock_timestamp()) where id = $1', v_table) using p_id, p_to;
    when v_status = 'published' and p_to = 'unpublished' then
      if not v_pub then raise exception 'content.publish is required to unpublish' using errcode = '42501'; end if;
      execute format('update %I set status = $2, published_at = null, status_reason = $3 where id = $1', v_table) using p_id, p_to, p_reason;
    when v_status <> 'archived' and p_to = 'archived' then
      if not v_pub then raise exception 'content.publish is required to archive' using errcode = '42501'; end if;
      execute format('update %I set status = $2, published_at = null, status_reason = $3 where id = $1', v_table) using p_id, p_to, p_reason;
    else
      raise exception 'invalid content transition % -> %', v_status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Site settings
-- ---------------------------------------------------------------------------
create table site_settings (
  id          uuid primary key default gen_random_uuid(),
  division_id uuid references divisions (id),                          -- null = the whole agency
  key         text not null check (key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$'),
  label       text not null,
  value       text not null,
  value_type  text not null default 'text' check (value_type in ('text', 'number', 'url', 'email', 'phone')),
  group_name  text not null default 'general',
  is_public   boolean not null default true,
  sort_order  integer not null default 100,
  updated_by  uuid references staff (id),
  updated_at  timestamptz not null default now(),
  check (value_type <> 'number' or value ~ '^-?[0-9]+(\.[0-9]+)?$'),
  check (value_type <> 'email' or value ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  check (value_type <> 'url' or value ~ '^https://'),
  check (value_type <> 'phone' or value ~ '^\+?[0-9 ]{6,20}$')
);
create unique index site_settings_key_unique on site_settings (key, coalesce(division_id, '00000000-0000-0000-0000-000000000000'::uuid));
comment on table site_settings is 'Purpose: facts the websites print (contact details, place) and business rules the planners use (marketing budget split). Public settings are returned by public_api.settings. Changed only by settings.update; every change is audited. [class: internal]';

create function site_settings_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and (new.key is distinct from old.key or new.division_id is distinct from old.division_id) then
    raise exception 'a setting''s key and division cannot change; add a new one' using errcode = '42501';
  end if;
  new.updated_by := current_staff_id();
  new.updated_at := now();
  if tg_op = 'UPDATE' and new.value is distinct from old.value then
    perform emit_event('settings.changed', 'site_settings', new.id, null, jsonb_build_object('key', new.key));
  end if;
  return new;
end $$;
create trigger site_settings_updated before update on site_settings for each row execute function set_updated_at();
create trigger site_settings_guard_trg before insert or update on site_settings for each row execute function site_settings_guard();

-- The facts the four division sites and the main site print today (taken from their published pages, October 2026)
insert into site_settings (division_id, key, label, value, value_type, group_name, sort_order)
select null, v.key, v.label, v.value, v.vt, 'company', v.n from (values
  ('company.name', 'Company name', 'Andreas Digital Agency', 'text', 10),
  ('company.main_url', 'Main website', 'https://www.andreasdigitalagency.com', 'url', 20),
  ('company.phone', 'Phone and WhatsApp', '+264 81 803 2641', 'phone', 30),
  ('company.line', 'Company line', '+264 83 677 5783', 'phone', 40),
  ('company.place', 'Where we are', 'Rundu, Kavango East, Namibia', 'text', 50)
) as v(key, label, value, vt, n);
insert into site_settings (division_id, key, label, value, value_type, group_name, sort_order)
select d.id, 'division.email', 'Division email', v.email, 'email', 'division', 10
  from (values ('web', 'web@andreasdigitalagency.com'), ('tech', 'tech@andreasdigitalagency.com'),
               ('marketing', 'marketing@andreasdigitalagency.com'), ('consulting', 'consulting@andreasdigitalagency.com')) as v(key, email)
  join divisions d on d.key = v.key;
-- ADA Marketing's budget rule (published on its pricing page): the smallest campaign, the monthly thresholds, ADA's share per level, adverts per level
insert into site_settings (division_id, key, label, value, value_type, group_name, sort_order)
select (select id from divisions where key = 'marketing'), v.key, v.label, v.value, 'number', 'marketing_policy', v.n from (values
  ('marketing.min_budget', 'Smallest campaign budget (N$)', '1499.99', 10),
  ('marketing.grow_from', 'Monthly budget at which the Grow level starts (N$)', '5000', 20),
  ('marketing.scale_from', 'Monthly budget at which the Scale level starts (N$)', '15000', 30),
  ('marketing.ada_share_test', 'ADA''s share of the budget, Test level (%)', '40', 40),
  ('marketing.ada_share_grow', 'ADA''s share of the budget, Grow level (%)', '35', 50),
  ('marketing.ada_share_scale', 'ADA''s share of the budget, Scale level (%)', '30', 60)
) as v(key, label, value, n);

-- ---------------------------------------------------------------------------
-- 6. Access (row-level security; staff write only through the policies and functions above)
-- ---------------------------------------------------------------------------
alter table content_posts enable row level security;
alter table testimonials  enable row level security;
alter table faqs          enable row level security;
alter table site_settings enable row level security;
revoke all on content_posts, testimonials, faqs, site_settings from anon, authenticated;
grant select, insert, update on content_posts, testimonials, faqs to authenticated;
grant select, insert, update on site_settings to authenticated;

create policy content_posts_select on content_posts for select to authenticated using (is_active_staff());
create policy content_posts_insert on content_posts for insert to authenticated with check (has_permission('content.create', division_id));
create policy content_posts_update on content_posts for update to authenticated using (has_permission('content.update', division_id)) with check (has_permission('content.update', division_id));
create policy testimonials_select on testimonials for select to authenticated using (is_active_staff());
create policy testimonials_insert on testimonials for insert to authenticated with check (has_permission('content.create', division_id));
create policy testimonials_update on testimonials for update to authenticated using (has_permission('content.update', division_id)) with check (has_permission('content.update', division_id));
create policy faqs_select on faqs for select to authenticated using (is_active_staff());
create policy faqs_insert on faqs for insert to authenticated with check (has_permission('content.create', division_id));
create policy faqs_update on faqs for update to authenticated using (has_permission('content.update', division_id)) with check (has_permission('content.update', division_id));
create policy site_settings_select on site_settings for select to authenticated using (is_active_staff());
create policy site_settings_insert on site_settings for insert to authenticated with check (has_permission('settings.update'));
create policy site_settings_update on site_settings for update to authenticated using (has_permission('settings.update')) with check (has_permission('settings.update'));

revoke execute on function content_transition(text, uuid, publication_state, text) from public, anon;
grant execute on function content_transition(text, uuid, publication_state, text) to authenticated;
revoke execute on function content_guard(), content_posts_slug(), site_settings_guard() from public, anon, authenticated;

do $$ begin
  perform attach_audit('content_posts');
  perform attach_audit('testimonials');
  perform attach_audit('faqs');
  perform attach_audit('site_settings');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Public API
-- ---------------------------------------------------------------------------
alter table websites drop constraint if exists websites_capabilities_check;
alter table websites add constraint websites_capabilities_check check (capabilities <@ array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read',
  'applications.submit', 'services.read', 'portfolio.read', 'contact.read', 'leads.submit', 'enquiries.submit', 'documents.read', 'content.read', 'settings.read']);

create function public_api.division_dto(p_division uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end from divisions d where d.id = p_division
$$;

create function public_api.posts(p_key_hash text, p_type text default null, p_division text default null, p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'content.read');
  return coalesce((
    select jsonb_agg(public_api.post_dto(p.id) order by p.featured desc, p.published_at desc)
    from (select * from content_posts where status = 'published'
            and (p_type is null or content_type::text = p_type)
            and (p_division is null or division_id is null or division_id = (select id from divisions where key = p_division))
          order by featured desc, published_at desc limit least(greatest(coalesce(p_limit, 30), 1), 100)) p), '[]'::jsonb);
end $$;

create function public_api.post_dto(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object('id', p.ada_id, 'type', p.content_type, 'title', p.title, 'slug', p.slug, 'summary', p.summary, 'content', p.body,
           'cover_image_url', p.cover_image_url, 'image_alt_text', p.image_alt_text, 'author_name', p.author_name, 'source_label', p.source_label,
           'featured', p.featured, 'published_at', p.published_at, 'division', public_api.division_dto(p.division_id)))
  from content_posts p where p.id = p_id and p.status = 'published'
$$;

create function public_api.post(p_key_hash text, p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'content.read');
  return (select public_api.post_dto(id) from content_posts where slug = p_slug and status = 'published');
end $$;

create function public_api.testimonials(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'content.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', t.ada_id, 'quote', t.quote, 'person_name', t.person_name, 'person_role', t.person_role,
             'organization_name', t.organization_name, 'service', (select s.name from services s where s.id = t.service_id and s.status = 'published'),
             'division', public_api.division_dto(t.division_id))) order by t.sort_order, t.published_at desc)
    from testimonials t where t.status = 'published' and t.consent_confirmed
      and (p_division is null or t.division_id is null or t.division_id = (select id from divisions where key = p_division))), '[]'::jsonb);
end $$;

create function public_api.faqs(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'content.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', f.ada_id, 'question', f.question, 'answer', f.answer, 'category', f.category,
             'service', (select s.name from services s where s.id = f.service_id and s.status = 'published'), 'division', public_api.division_dto(f.division_id)))
             order by f.sort_order, f.published_at)
    from faqs f where f.status = 'published'
      and (p_division is null or f.division_id is null or f.division_id = (select id from divisions where key = p_division))), '[]'::jsonb);
end $$;

create function public_api.settings(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'settings.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('key', s.key, 'label', s.label, 'value', s.value, 'type', s.value_type, 'group', s.group_name,
             'division', public_api.division_dto(s.division_id))) order by s.group_name, s.sort_order, s.key)
    from site_settings s where s.is_public
      and (s.division_id is null or (p_division is not null and s.division_id = (select id from divisions where key = p_division)))), '[]'::jsonb);
end $$;

revoke all on function public_api.division_dto(uuid), public_api.post_dto(uuid) from public, anon, authenticated, ada_public_api;
revoke all on function public_api.posts(text, text, text, integer), public_api.post(text, text), public_api.testimonials(text, text), public_api.faqs(text, text),
  public_api.settings(text, text) from public, anon, authenticated;
grant execute on function public_api.posts(text, text, text, integer), public_api.post(text, text), public_api.testimonials(text, text), public_api.faqs(text, text),
  public_api.settings(text, text) to ada_public_api;
