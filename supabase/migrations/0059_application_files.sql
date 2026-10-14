-- 0059_application_files: CVs and supporting documents sent with a job application.
--
-- How a file arrives (no file passes through a website's server, so 10 MB files work on Vercel):
--   1. the website's server submits the application through the public API and then calls
--      public_api.open_application_upload(): ADA Core answers with a one-time upload pass (valid 30 minutes, for this
--      application only, at most one CV and one supporting document);
--   2. the visitor's browser sends each file with that pass to the Edge Function `application-file`, which runs inside
--      ADA Core with the service role: it asks application_upload_begin() for the storage path, stores the file in the
--      PRIVATE bucket `applications`, then records it with application_upload_done().
-- Only the pass's SHA-256 hash is stored. A pass cannot be reused for a kind already uploaded, and expires by itself.
--
-- Who can read a file: exactly those who can read the application (can_view_application_row - recruitment permissions,
-- division-scoped). Files are write-once; there is no update or delete policy for signed-in users.

create table application_files (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references applications (id) on delete restrict,
  kind           text not null check (kind in ('cv', 'supporting')),
  storage_key    text not null unique,
  file_name      text not null check (length(file_name) between 1 and 200),
  content_type   text not null check (content_type in ('application/pdf', 'application/msword',
                   'application/vnd.openxmlformats-officedocument.wordprocessingml.document')),
  size_bytes     integer not null check (size_bytes between 1 and 10485760),
  uploaded_at    timestamptz not null default now(),
  unique (application_id, kind)
);
comment on table application_files is 'Purpose: the CV and supporting document an applicant sent, stored in the private bucket applications at storage_key. Written only by the application-file Edge Function through application_upload_done(); readable exactly as the application is. [class: confidential]';
alter table application_files enable row level security;
revoke all on application_files from public, anon, authenticated;
grant select on application_files to authenticated;
create policy application_files_select on application_files for select to authenticated
  using (can_view_application_row((select a.vacancy_id from applications a where a.id = application_id)));
select attach_audit('application_files');

create table application_upload_passes (
  token_hash     text primary key,
  application_id uuid not null references applications (id) on delete cascade,
  expires_at     timestamptz not null,
  created_at     timestamptz not null default now()
);
create index application_upload_passes_app_idx on application_upload_passes (application_id);
comment on table application_upload_passes is 'Purpose: one-time upload passes for application files (SHA-256 of the pass only; the pass itself is never stored). Used by the application-file Edge Function. [class: restricted]';
alter table application_upload_passes enable row level security;
revoke all on application_upload_passes from public, anon, authenticated;
select attach_audit('application_upload_passes');

insert into db_section_tables (table_name, section_key) values ('application_files', 'people_careers'), ('application_upload_passes', 'people_careers');

-- Step 1 (website, through the public API): a pass for an application this website took within the last hour.
create function public_api.open_application_upload(p_key_hash text, p_reference text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_site uuid := public_api.authorize(p_key_hash, 'applications.submit'); v_app uuid; v_token text;
begin
  select a.id into v_app from applications a
   where a.ada_id = p_reference and a.source_website_id = v_site and a.created_at > now() - interval '1 hour';
  if v_app is null then raise exception 'application not found' using errcode = 'P0002'; end if;
  delete from application_upload_passes where application_id = v_app or expires_at < now();
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into application_upload_passes (token_hash, application_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), v_app, now() + interval '30 minutes');
  return jsonb_build_object('reference', p_reference, 'upload_pass', v_token, 'expires_in_seconds', 1800);
end $$;
revoke all on function public_api.open_application_upload(text, text) from public, anon, authenticated;
grant execute on function public_api.open_application_upload(text, text) to ada_public_api;

-- Step 2a (Edge Function, service role): check the pass and say where the file goes.
create function application_upload_begin(p_pass text, p_kind text, p_file_name text, p_content_type text, p_size integer) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_app uuid; v_ext text;
begin
  select p.application_id into v_app from application_upload_passes p
   where p.token_hash = encode(digest(coalesce(p_pass, ''), 'sha256'), 'hex') and p.expires_at > now();
  if v_app is null then raise exception 'upload pass not valid' using errcode = '42501'; end if;
  if p_kind not in ('cv', 'supporting') then raise exception 'unknown kind' using errcode = '22023'; end if;
  if exists (select 1 from application_files where application_id = v_app and kind = p_kind) then
    raise exception 'this file was already sent' using errcode = '23505';
  end if;
  v_ext := case p_content_type when 'application/pdf' then 'pdf' when 'application/msword' then 'doc'
             when 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' then 'docx' end;
  if v_ext is null then raise exception 'only PDF or Word files' using errcode = '22023'; end if;
  if p_size is null or p_size < 1 or p_size > 10485760 then raise exception 'file must be 10 MB or smaller' using errcode = '22023'; end if;
  return jsonb_build_object('path', v_app::text || '/' || p_kind || '-' || gen_random_uuid()::text || '.' || v_ext);
end $$;

-- Step 2b (Edge Function, service role): record the stored file; a CV also becomes the application's cv_ref.
create function application_upload_done(p_pass text, p_kind text, p_path text, p_file_name text, p_content_type text, p_size integer) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_app uuid;
begin
  select p.application_id into v_app from application_upload_passes p
   where p.token_hash = encode(digest(coalesce(p_pass, ''), 'sha256'), 'hex') and p.expires_at > now();
  if v_app is null then raise exception 'upload pass not valid' using errcode = '42501'; end if;
  if split_part(p_path, '/', 1) <> v_app::text or p_path !~ ('^[0-9a-f-]{36}/' || p_kind || '-[0-9a-f-]{36}\.(pdf|doc|docx)$') then
    raise exception 'path does not belong to this application' using errcode = '42501';
  end if;
  insert into application_files (application_id, kind, storage_key, file_name, content_type, size_bytes)
  values (v_app, p_kind, p_path, left(regexp_replace(coalesce(p_file_name, 'file'), '[^[:alnum:] ._()-]', '_', 'g'), 200), p_content_type, p_size);
  if p_kind = 'cv' then update applications set cv_ref = 'storage:applications/' || p_path where id = v_app; end if;
  return jsonb_build_object('stored', p_kind);
end $$;
revoke all on function application_upload_begin(text, text, text, text, integer), application_upload_done(text, text, text, text, text, integer) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function application_upload_begin(text, text, text, text, integer), application_upload_done(text, text, text, text, text, integer) to service_role;
  end if;
end $$;

-- Storage: a private bucket; signed-in staff may read a file only if they may read its application.
create function application_storage_can_read(p_name text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
              then coalesce((select can_view_application_row(a.vacancy_id) from applications a where a.id = split_part(p_name, '/', 1)::uuid), false)
              else false end
$$;
revoke execute on function application_storage_can_read(text) from public, anon;
grant execute on function application_storage_can_read(text) to authenticated;

do $$
begin
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise notice '0059: storage schema not present - bucket and policy skipped';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('applications', 'applications', false, 10485760, array['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
  on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
  drop policy if exists applications_files_read on storage.objects;
  create policy applications_files_read on storage.objects for select to authenticated using (bucket_id = 'applications' and application_storage_can_read(name));
end $$;
