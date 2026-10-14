-- 0055_document_storage: where the FILES of the Documents module live.
-- The Documents module (0037) holds a file BY REFERENCE (storage_provider + storage_key + SHA-256). This migration provides the private place the reference
-- points to, and nothing else:
--   * one PRIVATE bucket, `documents` (no public URLs, only Word / Excel / PDF, 50 MB at most);
--   * an object may only be named  <document id>/<version id>.<docx|xlsx|pdf>  - the first part is the authoritative document, so the document's own rules
--     (document_can: division, classification, critical flag, archive state) decide who may put a file there and who may read it;
--   * objects are write-once: there is NO update and NO delete policy (an edit is a new version, as the module already requires; disposal stays with the
--     module's approved workflow and the storage service).
-- The module still logs every open and download (document_open); the interface calls it before it asks for a short-lived link.
-- On a server without Supabase Storage (a plain PostgreSQL test database without the storage stub) the bucket and policies are skipped with a notice.

create function document_storage_can(p_name text, p_action text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(docx|xlsx|pdf)$'
              then document_can(split_part(p_name, '/', 1)::uuid, p_action)
              else false end
$$;
comment on function document_storage_can(text, text) is 'Used by the storage policies: may the caller upload / read the file at this storage path? The first path segment is a document id; the answer is the Documents module''s own (document_can). Anything not shaped <document>/<version>.<docx|xlsx|pdf> is refused.';
revoke execute on function document_storage_can(text, text) from public, anon;
grant execute on function document_storage_can(text, text) to authenticated;

do $$
begin
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise notice '0055: storage schema not present - bucket and policies skipped';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('documents', 'documents', false, 52428800, array['application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/pdf'])
  on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
  drop policy if exists documents_files_read on storage.objects;
  drop policy if exists documents_files_add on storage.objects;
  create policy documents_files_read on storage.objects for select to authenticated using (bucket_id = 'documents' and document_storage_can(name, 'read'));
  create policy documents_files_add on storage.objects for insert to authenticated with check (bucket_id = 'documents' and document_storage_can(name, 'upload'));
end $$;
