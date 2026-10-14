-- 0057_content: the Content section (journal, news, announcements, updates) and the careers fields the website's Administrator system had.
-- What this adds (all new; nothing existing is moved or renamed):
--   * content_posts: ONE table for posts of every kind, optionally owned by a division. A post is a registered entity (institutional ID through attach_entity),
--     written as a draft, published only through content_transition() (the same draft -> approval -> published discipline as services and vacancies),
--     audited, searchable, and read by the websites through public_api.posts / public_api.post (only PUBLISHED posts, never drafts).
--   * permissions content.view / create / update / publish / archive (the CEO publishes; division staff write for their own division).
--   * vacancies: the website's careers fields (slug, location, responsibilities, qualifications, experience, application instructions, featured).
--   * application_profiles: the applicant's own answers (education, links, motivation ...) as a child record of an application, written by
--     public_api.submit_application_profile right after the application, readable only by those who may read the application.
--   * the section registry gets a 14th section, "Content & website".
-- Nothing here stores a visitor's cookie or analytics data (those stay with the website).

insert into permissions (key, module, action, description, sensitivity) values
  ('content.view', 'content', 'view', 'View content posts (own division and agency-wide)', 'internal'::data_classification),
  ('content.create', 'content', 'create', 'Create content posts (journal news announcements updates)', 'internal'::data_classification),
  ('content.update', 'content', 'update', 'Edit content posts', 'internal'::data_classification),
  ('content.publish', 'content', 'publish', 'Approve, publish and unpublish content posts on the websites', 'restricted'::data_classification),
  ('content.archive', 'content', 'archive', 'Archive content posts', 'internal'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'content.view'),
  ('administration_officer', 'content.view'),
  ('division_lead', 'content.view'),
  ('division_staff', 'content.view'),
  ('auditor', 'content.view'),
  ('ceo', 'content.create'),
  ('administration_officer', 'content.create'),
  ('division_lead', 'content.create'),
  ('division_staff', 'content.create'),
  ('ceo', 'content.update'),
  ('administration_officer', 'content.update'),
  ('division_lead', 'content.update'),
  ('division_staff', 'content.update'),
  ('ceo', 'content.publish'),
  ('ceo', 'content.archive'),
  ('administration_officer', 'content.archive'),
  ('division_lead', 'content.archive')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;


-- ---------------------------------------------------------------------------
-- Entity type: a post is a registered entity
-- ---------------------------------------------------------------------------
insert into entity_types (key, prefix, family, is_built, domain_table, division_col, status_col, class_col, location_col, label_col, view_fn, description, id_code, publishable)
values ('post', 'PST', 'operations', true, 'content_posts', 'division_id', 'status', null, null, 'title', null, 'Content post (journal entry, news, announcement or update) for the websites', 'T7', true);
insert into id_codebook (version, kind, code, meaning, family, note)
select 1, 'type', id_code, key, family, description from entity_types where key = 'post';

-- ---------------------------------------------------------------------------
-- The post
-- ---------------------------------------------------------------------------
create table content_posts (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null default 'news' check (kind in ('journal', 'news', 'announcement', 'update')),
  slug             text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 120),
  title            text not null check (length(btrim(title)) between 2 and 200),
  excerpt          text check (excerpt is null or length(excerpt) <= 500),
  category         text check (category is null or length(category) <= 80),
  body             jsonb not null default '[]'::jsonb check (jsonb_typeof(body) = 'array' and jsonb_array_length(body) <= 500),
  cover_path       text check (cover_path is null or (cover_path ~ '^(/|https://)[^[:space:]]+$' and length(cover_path) <= 500)),
  external_url     text check (external_url is null or (external_url ~ '^https?://[^[:space:]]{3,}$' and length(external_url) <= 500)),
  featured         boolean not null default false,
  tags             text[] not null default '{}' check (cardinality(tags) <= 20),
  seo_title        text check (seo_title is null or length(seo_title) <= 120),
  seo_description  text check (seo_description is null or length(seo_description) <= 300),
  division_id      uuid references divisions (id) on delete restrict,
  status           publication_state not null default 'draft',
  display_date     timestamptz,
  approved_by      uuid references staff (id),
  approved_at      timestamptz,
  published_at     timestamptz,
  status_reason    text,
  author_staff_id  uuid references staff (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index content_posts_slug_unique on content_posts (slug) where status <> 'archived';
create index content_posts_division_status_idx on content_posts (division_id, status);
create index content_posts_public_idx on content_posts (kind, display_date desc) where status = 'published';
create index content_posts_author_idx on content_posts (author_staff_id);
create index content_posts_created_idx on content_posts (created_at desc);
comment on table content_posts is 'Purpose: posts for the websites - journal entries, news, announcements, updates - one table, optionally owned by a division (null = the whole agency). Written as drafts; published only through content_transition(); the websites read only published posts through public_api.posts. Body is a list of blocks {id, type, text}. Cover images are website paths or https URLs (the file itself is not stored here). [class: internal until published]';
comment on column content_posts.display_date is 'The date shown on the website (set when published; may be set earlier to keep an original date). published_at is when it actually went live.';
comment on column content_posts.division_id is 'Owning division; null = the whole agency. Does not change after creation.';
do $$ begin perform attach_entity('content_posts', 'post'); end $$;
select attach_audit('content_posts');
create trigger content_posts_updated before update on content_posts for each row execute function set_updated_at();
create trigger content_posts_approval_sync after insert or update on content_posts
  for each row execute function approval_sync('content_publication', 'content.publish', 'title', 'division_id');
create trigger content_posts_publication_events after update on content_posts for each row execute function publication_events('post');

create function can_view_post(p_division uuid, p_author uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(has_permission('content.view', p_division) or (p_division is null and has_permission_anywhere('content.view')) or p_author = current_staff_id(), false)
$$;
revoke execute on function can_view_post(uuid, uuid) from public, anon;
grant execute on function can_view_post(uuid, uuid) to authenticated;

create function content_posts_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.author_staff_id := current_staff_id();
    if is_untrusted_caller() and (new.status <> 'draft' or new.approved_by is not null or new.published_at is not null) then
      raise exception 'posts are created as drafts' using errcode = '42501';
    end if;
    return new;
  end if;
  if is_untrusted_caller() then
    new.author_staff_id := old.author_staff_id;
    if new.status is distinct from old.status or new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at
       or new.published_at is distinct from old.published_at or new.status_reason is distinct from old.status_reason then
      raise exception 'post status is changed only through content_transition()' using errcode = '42501';
    end if;
    if new.division_id is distinct from old.division_id then
      raise exception 'a post cannot move between divisions; create it in the right one' using errcode = '42501';
    end if;
    if old.status = 'published' and new.slug is distinct from old.slug then
      raise exception 'unpublish the post before changing its web address' using errcode = '23514';
    end if;
    -- editing public content invalidates an earlier approval, unless the editor is allowed to publish
    if old.status in ('pending_approval', 'approved', 'published')
       and (new.kind, new.slug, new.title, new.excerpt, new.category, new.body, new.cover_path, new.external_url, new.tags, new.seo_title, new.seo_description, new.display_date)
           is distinct from (old.kind, old.slug, old.title, old.excerpt, old.category, old.body, old.cover_path, old.external_url, old.tags, old.seo_title, old.seo_description, old.display_date)
       and not has_permission('content.publish') then
      new.status := 'draft'; new.approved_by := null; new.approved_at := null; new.published_at := null;
      new.status_reason := 'edited after approval; needs re-approval';
    end if;
  end if;
  return new;
end $$;
create trigger content_posts_guard_trg before insert or update on content_posts for each row execute function content_posts_guard();

-- Row-level security: the authority. Staff read the posts of their division (and agency-wide ones); authors always read their own; nobody deletes.
alter table content_posts enable row level security;
revoke all on content_posts from public, anon, authenticated;
grant select, insert, update on content_posts to authenticated;
create policy content_posts_select on content_posts for select to authenticated using (can_view_post(division_id, author_staff_id));
create policy content_posts_insert on content_posts for insert to authenticated with check (has_permission('content.create', division_id));
create policy content_posts_update on content_posts for update to authenticated
  using (can_view_post(division_id, author_staff_id) and (has_permission('content.update', division_id) or author_staff_id = current_staff_id()))
  with check (has_permission('content.update', division_id) or author_staff_id = current_staff_id());

-- The one way a post's status changes
create function content_transition(p_id uuid, p_to publication_state, p_reason text default null) returns publication_state
language plpgsql security definer set search_path = public, pg_temp as $$
declare s content_posts%rowtype; v_edit boolean; v_pub boolean; v_arch boolean; v_me uuid := current_staff_id();
begin
  select * into s from content_posts where id = p_id for update;
  if not found or not can_view_post(s.division_id, s.author_staff_id) then raise exception 'post not found' using errcode = 'P0002'; end if;
  v_edit := has_permission('content.update', s.division_id) or s.author_staff_id = v_me;
  v_pub := has_permission('content.publish');
  v_arch := has_permission('content.archive', s.division_id) or v_pub;
  if s.status = 'archived' then raise exception 'an archived post cannot change state' using errcode = '23514'; end if;
  case
    when s.status in ('draft', 'unpublished') and p_to = 'pending_approval' then
      if not v_edit then raise exception 'content.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(s.excerpt), '') = '' or jsonb_array_length(s.body) = 0 then
        raise exception 'an excerpt and some content are required before approval' using errcode = '23514';
      end if;
      update content_posts set status = p_to, status_reason = null where id = p_id;
      perform notify_holders('content.publish', null, 'approval.required', 'Post awaiting approval: ' || s.title, null, 'content_posts', s.id, null);
    when s.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_pub) then raise exception 'not permitted' using errcode = '42501'; end if;
      update content_posts set status = p_to, status_reason = p_reason where id = p_id;
    when s.status = 'pending_approval' and p_to = 'approved' then
      if not v_pub then raise exception 'content.publish is required to approve' using errcode = '42501'; end if;
      update content_posts set status = p_to, approved_by = v_me, approved_at = now(), status_reason = null where id = p_id;
    when s.status in ('draft', 'unpublished', 'pending_approval', 'approved') and p_to = 'published' then
      if not v_pub then raise exception 'content.publish is required to publish' using errcode = '42501'; end if;
      if coalesce(btrim(s.excerpt), '') = '' or jsonb_array_length(s.body) = 0 then
        raise exception 'an excerpt and some content are required before publishing' using errcode = '23514';
      end if;
      update content_posts set status = p_to, approved_by = coalesce(approved_by, v_me), approved_at = coalesce(approved_at, now()), published_at = now(),
             display_date = coalesce(display_date, now()), status_reason = null where id = p_id;
    when s.status = 'published' and p_to = 'unpublished' then
      if not v_pub then raise exception 'content.publish is required to unpublish' using errcode = '42501'; end if;
      update content_posts set status = p_to, published_at = null, status_reason = p_reason where id = p_id;
    when p_to = 'archived' then
      if not v_arch then raise exception 'content.archive is required to archive' using errcode = '42501'; end if;
      update content_posts set status = p_to, published_at = null, status_reason = p_reason where id = p_id;
    else
      raise exception 'a % post cannot become %', s.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;
revoke execute on function content_transition(uuid, publication_state, text) from public, anon;
grant execute on function content_transition(uuid, publication_state, text) to authenticated;
comment on function content_transition(uuid, publication_state, text) is 'The only way a content post changes status: draft -> pending approval -> approved -> published -> unpublished / archived. A holder of content.publish may publish straight from draft (approval is recorded as theirs).';

-- Search: posts are findable by title, address and category (metadata only; never the body)
insert into search_sources (entity_type, label_expr, attribute_exprs, note) values
  ('post', 'x.title', array['x.slug', 'x.category', 'x.kind'], 'METADATA only: title, web address, category, kind; never the body')
on conflict (entity_type) do nothing;
select attach_search('public.content_posts'::regclass);

-- ---------------------------------------------------------------------------
-- Websites: the read capability and the two public functions (published posts only)
-- ---------------------------------------------------------------------------
alter table websites drop constraint websites_capabilities_check;
alter table websites add constraint websites_capabilities_check check (capabilities <@ array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read', 'applications.submit', 'services.read',
  'portfolio.read', 'contact.read', 'leads.submit', 'enquiries.submit', 'documents.read', 'content.read']);

create function public_api.post_dto(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'slug', p.slug, 'kind', p.kind, 'title', p.title, 'excerpt', p.excerpt, 'category', p.category, 'body', p.body, 'cover', p.cover_path,
    'external_url', p.external_url, 'featured', p.featured, 'tags', to_jsonb(p.tags), 'seo_title', p.seo_title, 'seo_description', p.seo_description,
    'published_at', coalesce(p.display_date, p.published_at),
    'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end))
  from content_posts p left join divisions d on d.id = p.division_id where p.id = p_id
$$;
revoke all on function public_api.post_dto(uuid) from public, anon, authenticated;

create function public_api.posts(p_key_hash text, p_kind text default null, p_division text default null, p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'content.read');
  return coalesce((select jsonb_agg(public_api.post_dto(x.id) order by x.sort_date desc)
    from (select p.id, coalesce(p.display_date, p.published_at) as sort_date
            from content_posts p left join divisions d on d.id = p.division_id
           where p.status = 'published' and (p.division_id is null or d.public_state = 'published')
             and (p_kind is null or p.kind = p_kind) and (p_division is null or d.key = p_division)
           order by coalesce(p.display_date, p.published_at) desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) x), '[]'::jsonb);
end $$;
create function public_api.post(p_key_hash text, p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform public_api.authorize(p_key_hash, 'content.read');
  select p.id into v_id from content_posts p left join divisions d on d.id = p.division_id
   where p.slug = p_slug and p.status = 'published' and (p.division_id is null or d.public_state = 'published');
  return case when v_id is null then null else public_api.post_dto(v_id) end;
end $$;
revoke all on function public_api.posts(text, text, text, integer), public_api.post(text, text) from public, anon, authenticated;
grant execute on function public_api.posts(text, text, text, integer), public_api.post(text, text) to ada_public_api;

-- ---------------------------------------------------------------------------
-- Careers: the website's vacancy fields
-- ---------------------------------------------------------------------------
alter table vacancies
  add column slug text check (slug is null or (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 120)),
  add column location text check (location is null or length(location) <= 200),
  add column responsibilities text,
  add column qualifications text,
  add column experience text,
  add column application_instructions text,
  add column featured boolean not null default false;
create unique index vacancies_slug_unique on vacancies (slug) where slug is not null and deleted_at is null;
comment on column vacancies.slug is 'The vacancy''s web address on the careers pages.';

create or replace function vacancies_guard() returns trigger
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
         new.salary_min, new.salary_max, new.salary_currency, new.salary_public, new.openings, new.closing_date,
         new.slug, new.location, new.responsibilities, new.qualifications, new.experience, new.application_instructions)
         is distinct from (old.title, old.summary, old.description, old.requirements, old.employment_type,
         old.salary_min, old.salary_max, old.salary_currency, old.salary_public, old.openings, old.closing_date,
         old.slug, old.location, old.responsibilities, old.qualifications, old.experience, old.application_instructions) then
      raise exception 'vacancy content can only be edited while it is a draft' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create or replace function public_api.vacancy_dto(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', v.ada_id, 'slug', v.slug, 'title', v.title, 'summary', v.summary, 'description', v.description, 'requirements', v.requirements,
    'responsibilities', v.responsibilities, 'qualifications', v.qualifications, 'experience', v.experience,
    'application_instructions', v.application_instructions, 'location', v.location, 'featured', case when v.featured then true end,
    'employment_type', v.employment_type, 'closing_date', v.closing_date, 'published_at', v.published_at,
    'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end,
    'salary', case when v.salary_public then jsonb_build_object('min', v.salary_min, 'max', v.salary_max, 'currency', v.salary_currency) end))
  from vacancies v join divisions d on d.id = v.division_id where v.id = p_id
$$;

-- ---------------------------------------------------------------------------
-- The applicant's own answers: a child record of the application
-- ---------------------------------------------------------------------------
create table application_profiles (
  application_id         uuid primary key references applications (id) on delete restrict,
  application_type       text check (application_type in ('employment', 'internship', 'registering_interest')),
  nationality            text check (length(nationality) <= 100),
  location               text check (length(location) <= 200),
  availability           text check (length(availability) <= 200),
  highest_qualification  text check (length(highest_qualification) <= 200),
  institution            text check (length(institution) <= 200),
  field_of_study         text check (length(field_of_study) <= 200),
  completion_year        integer check (completion_year between 1950 and 2100),
  current_or_recent_role text check (length(current_or_recent_role) <= 200),
  years_experience       text check (length(years_experience) <= 100),
  skills                 text check (length(skills) <= 2000),
  portfolio_url          text check (portfolio_url is null or (portfolio_url ~ '^https?://[^[:space:]]{3,}$' and length(portfolio_url) <= 500)),
  github_url             text check (github_url is null or (github_url ~ '^https?://[^[:space:]]{3,}$' and length(github_url) <= 500)),
  linkedin_url           text check (linkedin_url is null or (linkedin_url ~ '^https?://[^[:space:]]{3,}$' and length(linkedin_url) <= 500)),
  motivation             text check (length(motivation) <= 5000),
  contribution           text check (length(contribution) <= 5000),
  achievement            text check (length(achievement) <= 5000),
  created_at             timestamptz not null default now()
);
comment on table application_profiles is 'Purpose: what the applicant said about themselves on the application form (education, links, motivation ...). One row per application, written once by the website through public_api.submit_application_profile; identity (name, email, phone) stays in people. Readable exactly as the application is. [class: confidential]';
alter table application_profiles enable row level security;
revoke all on application_profiles from public, anon, authenticated;
grant select on application_profiles to authenticated;
create policy application_profiles_select on application_profiles for select to authenticated
  using (can_view_application_row((select a.vacancy_id from applications a where a.id = application_id)));
select attach_audit('application_profiles', array['nationality', 'location', 'skills', 'motivation', 'contribution', 'achievement', 'portfolio_url', 'github_url', 'linkedin_url']);

create function public_api.submit_application_profile(p_key_hash text, p_reference text, p_profile jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_site uuid := public_api.authorize(p_key_hash, 'applications.submit'); v_app uuid;
        v_txt text[] := array['nationality', 'location', 'availability', 'highest_qualification', 'institution', 'field_of_study', 'current_or_recent_role', 'years_experience', 'skills',
                              'portfolio_url', 'github_url', 'linkedin_url', 'motivation', 'contribution', 'achievement', 'application_type'];
        k text;
begin
  if jsonb_typeof(p_profile) is distinct from 'object' then raise exception 'profile must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_profile) loop
    if not (k = any (v_txt) or k = 'completion_year') then raise exception 'unknown field %', k using errcode = '22023'; end if;
  end loop;
  -- only the website that took the application, within an hour of it, once; anything else looks like "no such application"
  select a.id into v_app from applications a
   where a.ada_id = p_reference and a.source_website_id = v_site and a.created_at > now() - interval '1 hour'
     and not exists (select 1 from application_profiles pr where pr.application_id = a.id);
  if v_app is null then raise exception 'application not found' using errcode = 'P0002'; end if;
  insert into application_profiles (application_id, application_type, nationality, location, availability, highest_qualification, institution, field_of_study, completion_year,
    current_or_recent_role, years_experience, skills, portfolio_url, github_url, linkedin_url, motivation, contribution, achievement)
  values (v_app, nullif(btrim(p_profile ->> 'application_type'), ''), nullif(btrim(p_profile ->> 'nationality'), ''), nullif(btrim(p_profile ->> 'location'), ''), nullif(btrim(p_profile ->> 'availability'), ''),
    nullif(btrim(p_profile ->> 'highest_qualification'), ''), nullif(btrim(p_profile ->> 'institution'), ''), nullif(btrim(p_profile ->> 'field_of_study'), ''), nullif(p_profile ->> 'completion_year', '')::integer,
    nullif(btrim(p_profile ->> 'current_or_recent_role'), ''), nullif(btrim(p_profile ->> 'years_experience'), ''), nullif(btrim(p_profile ->> 'skills'), ''),
    nullif(btrim(p_profile ->> 'portfolio_url'), ''), nullif(btrim(p_profile ->> 'github_url'), ''), nullif(btrim(p_profile ->> 'linkedin_url'), ''),
    nullif(btrim(p_profile ->> 'motivation'), ''), nullif(btrim(p_profile ->> 'contribution'), ''), nullif(btrim(p_profile ->> 'achievement'), ''));
  return jsonb_build_object('reference', p_reference);
end $$;
revoke all on function public_api.submit_application_profile(text, text, jsonb) from public, anon, authenticated;
grant execute on function public_api.submit_application_profile(text, text, jsonb) to ada_public_api;

-- ---------------------------------------------------------------------------
-- The arrangement: a 14th section
-- ---------------------------------------------------------------------------
insert into db_sections (key, position, title, summary) values ('content', 14, 'Content & website', 'Posts for the websites (journal, news, announcements, updates): written here, published through approval, read live by the websites.');
insert into db_section_tables (table_name, section_key) values ('content_posts', 'content'), ('application_profiles', 'people_careers');
