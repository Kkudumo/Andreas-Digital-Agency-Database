-- 0037_documents: the Documents module - an institutional records layer, not "upload -> filename -> download".
--  * Three things, kept apart:
--      IDENTITY  - a permanent institutional ID minted centrally through attach_entity (no document-specific generator, no user-chosen
--                  ID). It never changes when the document moves division / project / folder / storage / owner.
--      RECORD    - `documents`: type, title, classification, origin + current division, owner, creator, dates, status, retention,
--                  critical flag. Relationships live in document_links and REFERENCE registered entities by institutional ID.
--      CONTENT   - `document_versions`: the stored file, held by REFERENCE (provider + opaque key) with a SHA-256 of the bytes. The
--                  storage reference is never the identity and is never shown to metadata viewers or the public.
--  * Access is a decision, not a label: staff identity + permission in the owning division + classification + relationship + an
--    explicit grant, per action (view / read / download / upload / edit / comment / share / approve / publish / archive / dispose).
--    Entity visibility, metadata visibility, content access and modification rights are four different questions.
--  * Classification: the platform's four-level enum plus an explicit CRITICAL flag. Policy mapping of the L0-L5 examples:
--        L0 public -> public; L1 internal -> internal; L2 restricted -> restricted; L3 confidential -> confidential;
--        L4/L5 critical -> is_critical (visible only to the owner, to explicit grantees, and to documents.view_critical holders; absent
--        from search, counts, relationship lookups, 360 views, errors, audit and security records for everyone else).
--    A document inherits the highest classification of the entities it is linked to (a restricted client makes its documents restricted).
--  * Versions: controlled history draft -> review -> approved -> signed (or withdrawn). Content columns of a version are permanent for
--    every caller; approved and signed versions are frozen; an amendment is a NEW version that records which signed version it amends.
--  * Retention + legal holds; nothing is ever deleted automatically; disposal is requested, approved by a second person and blocked by
--    any legal hold. Disposed documents keep their identity, metadata, hashes and audit trail.
--  * Publication: publishable != published. A public projection (document_publications) points at the authoritative document, carries an
--    allow-listed public title / description under a random public reference, needs an explicit approval, and is withdrawn automatically
--    when the document stops being eligible. Nothing is public by default and storage paths never leave the database.
--  * The search index is only an accelerator; relationships exist in document_links, never only in an index.

insert into permissions (key, module, action, description, sensitivity) values
  ('documents.view', 'documents', 'view', 'Discover documents and read their metadata (own division; no content access)', 'internal'::data_classification),
  ('documents.read', 'documents', 'read', 'Read the content of documents (separate from metadata and from download)', 'restricted'::data_classification),
  ('documents.download', 'documents', 'download', 'Download documents', 'restricted'::data_classification),
  ('documents.create', 'documents', 'create', 'Register documents and upload new versions', 'internal'::data_classification),
  ('documents.update', 'documents', 'update', 'Edit document metadata and relationships', 'internal'::data_classification),
  ('documents.comment', 'documents', 'comment', 'Comment on documents', 'internal'::data_classification),
  ('documents.share', 'documents', 'share', 'Share a document with named people or divisions', 'restricted'::data_classification),
  ('documents.approve', 'documents', 'approve', 'Approve and sign off document versions', 'restricted'::data_classification),
  ('documents.publish', 'documents', 'publish', 'Publish documents publicly (after approval)', 'restricted'::data_classification),
  ('documents.archive', 'documents', 'archive', 'Archive and restore documents', 'restricted'::data_classification),
  ('documents.dispose', 'documents', 'dispose', 'Approve disposal of documents after retention', 'confidential'::data_classification),
  ('documents.view_critical', 'documents', 'view_critical', 'Open critical documents without an explicit grant', 'confidential'::data_classification),
  ('documents.legal_hold', 'documents', 'legal_hold', 'Place and release legal holds on documents', 'confidential'::data_classification),
  ('documents.configure', 'documents', 'configure', 'Manage document types and retention classes and run integrity checks', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'documents.view'),
  ('administration_officer', 'documents.view'),
  ('finance_officer', 'documents.view'),
  ('division_lead', 'documents.view'),
  ('division_staff', 'documents.view'),
  ('auditor', 'documents.view'),
  ('ceo', 'documents.read'),
  ('administration_officer', 'documents.read'),
  ('finance_officer', 'documents.read'),
  ('division_lead', 'documents.read'),
  ('division_staff', 'documents.read'),
  ('auditor', 'documents.read'),
  ('ceo', 'documents.download'),
  ('administration_officer', 'documents.download'),
  ('finance_officer', 'documents.download'),
  ('division_lead', 'documents.download'),
  ('division_staff', 'documents.download'),
  ('ceo', 'documents.create'),
  ('administration_officer', 'documents.create'),
  ('finance_officer', 'documents.create'),
  ('division_lead', 'documents.create'),
  ('division_staff', 'documents.create'),
  ('ceo', 'documents.update'),
  ('administration_officer', 'documents.update'),
  ('finance_officer', 'documents.update'),
  ('division_lead', 'documents.update'),
  ('ceo', 'documents.comment'),
  ('administration_officer', 'documents.comment'),
  ('finance_officer', 'documents.comment'),
  ('division_lead', 'documents.comment'),
  ('division_staff', 'documents.comment'),
  ('ceo', 'documents.share'),
  ('administration_officer', 'documents.share'),
  ('division_lead', 'documents.share'),
  ('ceo', 'documents.approve'),
  ('division_lead', 'documents.approve'),
  ('ceo', 'documents.publish'),
  ('ceo', 'documents.archive'),
  ('administration_officer', 'documents.archive'),
  ('division_lead', 'documents.archive'),
  ('ceo', 'documents.dispose'),
  ('ceo', 'documents.view_critical'),
  ('ceo', 'documents.legal_hold'),
  ('ceo', 'documents.configure'),
  ('administration_officer', 'documents.configure')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- Entity map: the document is now a built, registered entity type
-- ---------------------------------------------------------------------------
update entity_types set is_built = true, domain_table = 'documents', division_col = 'division_id', status_col = 'status',
       class_col = 'effective_classification', label_col = 'title', view_fn = 'document_360' where key = 'document';

create type document_status        as enum ('active', 'archived', 'disposed');
create type document_version_state as enum ('draft', 'review', 'approved', 'signed', 'withdrawn');

-- ---------------------------------------------------------------------------
-- Retention classes and document types (configuration, data not code)
-- ---------------------------------------------------------------------------
create table retention_classes (
  id            uuid primary key default gen_random_uuid(),
  key           text not null unique check (key ~ '^[a-z0-9_]+$'),
  name          text not null,
  period_months integer check (period_months > 0),
  description   text,
  is_active     boolean not null default true
);
comment on table retention_classes is 'Purpose: how long a class of record must be kept. period_months NULL = permanent (never disposed). A document takes a SNAPSHOT of the period when it is registered, so changing a class never silently shortens a record already held. [class: internal]';
insert into retention_classes (key, name, period_months, description) values
  ('permanent',    'Permanent record',        null, 'Kept for ever (founding, statutory and historical records)'),
  ('contract_10y', 'Contracts - 10 years',    120,  'Contracts and agreements, from the retention start date'),
  ('financial_7y', 'Financial - 7 years',     84,   'Invoices, receipts, statements'),
  ('hr_7y',        'Personnel - 7 years',     84,   'Employment and personnel records'),
  ('general_5y',   'General - 5 years',       60,   'Reports, proposals, correspondence'),
  ('transient_1y', 'Transient - 1 year',      12,   'Working copies and drafts');

create table document_types (
  id                     uuid primary key default gen_random_uuid(),
  key                    text not null unique check (key ~ '^[a-z0-9_]+$'),
  name                   text not null,
  default_classification data_classification not null default 'internal',
  default_critical       boolean not null default false,
  retention_class_id     uuid not null references retention_classes (id),
  publishable            boolean not null default false,
  is_active              boolean not null default true,
  sort_order             integer not null default 100
);
comment on table document_types is 'Purpose: what kind of record a document is, with the classification, retention class and publishability that follow from it. publishable=false means documents of this type can never have a public projection. [class: internal]';
insert into document_types (key, name, default_classification, retention_class_id, publishable, sort_order)
select v.key, v.name, v.cls::data_classification, rc.id, v.pub, v.so from (values
  ('contract',      'Contract',            'internal',   'contract_10y', false, 10),
  ('invoice',       'Invoice / receipt',   'internal',   'financial_7y', false, 20),
  ('proposal',      'Proposal',            'internal',   'general_5y',   true,  30),
  ('report',        'Report',              'internal',   'general_5y',   true,  40),
  ('deliverable',   'Project deliverable', 'internal',   'general_5y',   true,  50),
  ('requirements',  'Requirements / brief','internal',   'general_5y',   false, 60),
  ('minutes',       'Minutes',             'internal',   'general_5y',   false, 70),
  ('correspondence','Correspondence',      'internal',   'general_5y',   false, 80),
  ('policy',        'Policy / procedure',  'internal',   'permanent',    true,  90),
  ('legal',         'Legal document',      'restricted', 'permanent',    false, 100),
  ('id_document',   'Identity document',   'restricted', 'hr_7y',        false, 110),
  ('hr_record',     'Personnel record',    'confidential','hr_7y',       false, 120),
  ('other',         'Other',               'internal',   'general_5y',   false, 999)
) as v(key, name, cls, rc, pub, so) join retention_classes rc on rc.key = v.rc;

-- ---------------------------------------------------------------------------
-- The document record (identity + metadata; NO content, NO storage reference, NO copied entity details)
-- ---------------------------------------------------------------------------
create table documents (
  id                       uuid primary key default gen_random_uuid(),
  title                    text not null check (btrim(title) <> ''),
  document_type_id         uuid not null references document_types (id),
  description              text,
  division_id              uuid not null references divisions (id),
  owner_staff_id           uuid references staff (id),
  classification           data_classification not null default 'internal',
  effective_classification data_classification not null default 'internal',
  is_critical              boolean not null default false,
  client_deleted           boolean not null default false,
  status                   document_status not null default 'active',
  document_date            date not null default current_date,
  retention_class_id       uuid not null references retention_classes (id),
  retention_months         integer check (retention_months > 0),
  retention_start          date not null default current_date,
  review_date              date,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  archived_at              timestamptz,
  disposed_at              timestamptz
);
create index documents_division_idx on documents (division_id);
create index documents_type_idx on documents (document_type_id);
create index documents_date_idx on documents (document_date);
comment on table documents is 'Purpose: the institutional RECORD of a document: identity (registry), type, title, classification, owner, status, retention. Content is held by reference in document_versions; relationships in document_links. Registered through attach_entity (permanent institutional ID; origin division fixed at creation). [class: internal; inherits the highest classification of its linked entities]';
comment on column documents.division_id is 'CURRENT owning division. The ORIGIN division is fixed in the registry. Changes only through document_transfer.';
comment on column documents.effective_classification is 'Derived: the greater of the document''s own classification and that of every entity it is linked to. Authorization reads this column.';
comment on column documents.retention_months is 'SNAPSHOT: the class period when the document was registered or its retention was last set explicitly. NULL = permanent.';
do $$ begin perform attach_entity('documents', 'document'); end $$;
create trigger documents_updated before update on documents for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Versions: content by REFERENCE + cryptographic hash
-- ---------------------------------------------------------------------------
create table document_versions (
  id                 uuid primary key default gen_random_uuid(),
  document_id        uuid not null references documents (id) on delete restrict,
  version_no         integer not null check (version_no > 0),
  state              document_version_state not null default 'draft',
  label              text,
  change_note        text,
  amends_version_id  uuid references document_versions (id),
  storage_provider   text check (storage_provider ~ '^[a-z0-9_-]+$'),
  storage_key        text check (btrim(storage_key) <> ''),
  content_hash       text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  size_bytes         bigint not null check (size_bytes > 0),
  mime_type          text not null check (mime_type ~ '^[a-z]+/[a-z0-9.+-]+$'),
  original_filename  text,
  content_purged_at  timestamptz,
  uploaded_by        uuid references staff (id),
  uploaded_at        timestamptz not null default now(),
  requested_by       uuid references staff (id),
  approved_by        uuid references staff (id),
  approved_at        timestamptz,
  signed_by          uuid references staff (id),
  signed_at          timestamptz,
  signed_on          date,
  decision_note      text,
  unique (document_id, version_no),
  check ((content_purged_at is null) = (storage_key is not null and storage_provider is not null))
);
create index document_versions_doc_idx on document_versions (document_id, version_no);
create index document_versions_hash_idx on document_versions (content_hash);
comment on table document_versions is 'Purpose: one stored state of a document. The file is held by REFERENCE (storage_provider + opaque storage_key) - never an identity, never exposed to metadata viewers or the public (column-level grants) - together with the SHA-256 of its bytes. Content columns are permanent; approved and signed versions are frozen; an amendment is a new version. [class: inherits the document]';
comment on column document_versions.storage_key is 'Opaque pointer into whatever store holds the bytes. Not an identifier of the document. Readable only through document_open (which authorises and logs) and by the storage service.';
comment on column document_versions.original_filename is 'SNAPSHOT: the name of the file as uploaded. Not an identity field.';
comment on column document_versions.content_hash is 'SHA-256 (lower-case hex) of the stored bytes, supplied by the storage layer at upload. Permanent. Used by integrity checks.';

-- ---------------------------------------------------------------------------
-- Relationships (references to registered entities, by institutional ID)
-- ---------------------------------------------------------------------------
create table document_links (
  id                      uuid primary key default gen_random_uuid(),
  document_id             uuid not null references documents (id) on delete restrict,
  entity_institutional_id text not null references entity_registry (institutional_id),
  role                    text not null default 'subject' check (role in ('subject', 'supporting', 'signatory', 'evidence', 'reference', 'amends')),
  linked_by               uuid references staff (id) default current_staff_id(),
  linked_at               timestamptz not null default now(),
  removed_at              timestamptz,
  removed_by              uuid references staff (id),
  removal_reason          text
);
create unique index document_links_live_unique on document_links (document_id, entity_institutional_id, role) where removed_at is null;
create index document_links_entity_idx on document_links (entity_institutional_id) where removed_at is null;
create index document_links_history_idx on document_links (entity_institutional_id, linked_at);
comment on table document_links is 'Purpose: which authoritative entities a document relates to (client, project, contract, invoice, person, staff, asset, ticket, ... any registered entity). References by institutional ID only - no names, emails or titles are copied. Removal is soft so history ("what was attached then") is answerable. [class: inherits the document; a link is visible only if the document AND the target entity are visible]';

-- ---------------------------------------------------------------------------
-- Explicit access grants, legal holds, comments, integrity checks, disposals
-- ---------------------------------------------------------------------------
create table document_access (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents (id) on delete restrict,
  staff_id    uuid references staff (id),
  division_id uuid references divisions (id),
  actions     text[] not null check (actions <@ array['view', 'read', 'download', 'comment'] and cardinality(actions) > 0),
  reason      text,
  granted_by  uuid references staff (id),
  granted_at  timestamptz not null default now(),
  expires_at  timestamptz,
  revoked_at  timestamptz,
  revoked_by  uuid references staff (id),
  check ((staff_id is null) <> (division_id is null))
);
create index document_access_doc_idx on document_access (document_id) where revoked_at is null;
comment on table document_access is 'Purpose: explicit, named, expiring grants on one document (to a person or a division) for view / read / download / comment only. A grant adds to the permission model; it never overrides classification. [class: restricted]';

create table document_holds (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents (id) on delete restrict,
  reason      text not null check (btrim(reason) <> ''),
  placed_by   uuid references staff (id),
  placed_at   timestamptz not null default now(),
  released_by uuid references staff (id),
  released_at timestamptz,
  release_reason text
);
create index document_holds_doc_idx on document_holds (document_id) where released_at is null;
comment on table document_holds is 'Purpose: legal holds. While any hold is active the document cannot be disposed, whatever its retention says. [class: confidential]';

create table document_comments (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents (id) on delete restrict,
  version_id  uuid references document_versions (id),
  author_id   uuid references staff (id),
  body        text not null check (btrim(body) <> ''),
  created_at  timestamptz not null default now()
);
create index document_comments_doc_idx on document_comments (document_id, created_at);
comment on table document_comments is 'Purpose: review comments on a document or one of its versions. Append-only. [class: inherits the document]';
create trigger document_comments_immutable before update or delete on document_comments for each row execute function append_only();

create table document_integrity_checks (
  id            uuid primary key default gen_random_uuid(),
  seq           bigint generated always as identity,
  version_id    uuid not null references document_versions (id) on delete restrict,
  document_id   uuid not null references documents (id) on delete restrict,
  expected_hash text not null,
  observed_hash text,
  result        text not null check (result in ('match', 'mismatch', 'missing')),
  checked_by    uuid references staff (id),
  checked_at    timestamptz not null default now()
);
create index document_integrity_checks_idx on document_integrity_checks (version_id, seq desc);
comment on table document_integrity_checks is 'Purpose: each verification of stored bytes against the recorded SHA-256. Append-only. A mismatch also raises a security event (kind integrity). [class: inherits the document]';
create trigger document_integrity_checks_immutable before update or delete on document_integrity_checks for each row execute function append_only();

create table document_disposals (
  id             uuid primary key default gen_random_uuid(),
  document_id    uuid not null references documents (id) on delete restrict,
  state          text not null default 'requested' check (state in ('requested', 'rejected', 'approved', 'executed')),
  reason         text not null check (btrim(reason) <> ''),
  requested_by   uuid references staff (id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references staff (id),
  decided_at     timestamptz,
  decision_note  text,
  executed_at    timestamptz,
  purge_manifest jsonb
);
create unique index document_disposals_one_open on document_disposals (document_id) where state in ('requested', 'approved');
comment on table document_disposals is 'Purpose: disposal workflow. A person requests (only once retention has elapsed, no legal hold, document archived); a DIFFERENT person with documents.dispose approves; approval nulls the storage references of the versions and records them in purge_manifest for the storage service, which confirms physical deletion. Nothing is ever disposed automatically. [class: confidential]';
comment on column document_disposals.purge_manifest is 'The storage references that were detached, for the storage service only (not granted to API users).';

create table document_publications (
  id                 uuid primary key default gen_random_uuid(),
  document_id        uuid not null references documents (id) on delete restrict,
  version_id         uuid not null references document_versions (id),
  state              text not null default 'pending_approval' check (state in ('pending_approval', 'approved', 'published', 'unpublished', 'rejected')),
  public_ref         text not null unique default ('pd_' || encode(extensions.gen_random_bytes(10), 'hex')),
  public_title       text not null check (btrim(public_title) <> ''),
  public_description text,
  requested_by       uuid references staff (id),
  requested_at       timestamptz not null default now(),
  decided_by         uuid references staff (id),
  decided_at         timestamptz,
  decision_note      text,
  published_at       timestamptz,
  unpublished_at     timestamptz,
  unpublish_reason   text,
  updated_at         timestamptz not null default now()
);
create unique index document_publications_one_live on document_publications (document_id) where state in ('pending_approval', 'approved', 'published');
comment on table document_publications is 'Purpose: the PUBLIC PROJECTION of a document. Points at the authoritative document and one approved/signed version; exposes only the allow-listed public_title / public_description under a random public_ref (not the institutional ID). Requires explicit approval, is withdrawn automatically when the document stops being eligible, and never carries storage paths, uploader, internal classification, notes or other versions. [class: restricted until published]';
create trigger document_publications_updated before update on document_publications for each row execute function set_updated_at();

create table document_events (
  id          bigint generated always as identity primary key,
  document_id uuid not null references documents (id) on delete restrict,
  version_id  uuid references document_versions (id),
  kind        text not null check (kind in ('created', 'metadata', 'version_added', 'version_state', 'classification', 'link_added', 'link_removed', 'shared', 'unshared',
                                            'publication_requested', 'publication_decided', 'published', 'unpublished', 'archived', 'restored', 'transferred', 'retention',
                                            'hold_placed', 'hold_released', 'disposal_requested', 'disposal_decided', 'disposal_executed', 'opened', 'downloaded',
                                            'integrity', 'relocated', 'comment')),
  actor_staff_id uuid references staff (id),
  occurred_at timestamptz not null default now(),
  detail      jsonb not null default '{}'::jsonb
);
create index document_events_doc_idx on document_events (document_id, id);
create index document_events_version_idx on document_events (version_id, id) where version_id is not null;
comment on table document_events is 'Purpose: append-only history of everything that happens to a document - creation, metadata and classification changes, uploads, version transitions, sharing, approvals, publication, archive/restore/disposal, and every open/download - always with the acting staff identity. Cannot be edited or deleted. Readable only by those who can see the document (opens/downloads: auditors and approvers). [class: inherits the document]';
create trigger document_events_immutable before update or delete on document_events for each row execute function append_only();

create function document_log(p_doc uuid, p_version uuid, p_kind text, p_detail jsonb default '{}') returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into document_events (document_id, version_id, kind, actor_staff_id, detail) values (p_doc, p_version, p_kind, current_staff_id(), coalesce(p_detail, '{}'))
$$;
revoke execute on function document_log(uuid, uuid, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Authorization: one decision per ACTION
-- ---------------------------------------------------------------------------
-- discover / view metadata share one gate (a document is either part of what you can know exists, or it is not); read, download, upload,
-- edit, comment, share, approve, publish, archive, restore, request_disposal and dispose are each separate.
create function document_perm(p_action text) returns text
language sql immutable as $$
  select case p_action
    when 'view' then 'documents.view' when 'discover' then 'documents.view' when 'read' then 'documents.read' when 'download' then 'documents.download'
    when 'upload' then 'documents.create' when 'edit' then 'documents.update' when 'comment' then 'documents.comment' when 'share' then 'documents.share'
    when 'approve' then 'documents.approve' when 'publish' then 'documents.publish' when 'archive' then 'documents.archive' when 'restore' then 'documents.archive'
    when 'request_disposal' then 'documents.archive' when 'dispose' then 'documents.dispose' end
$$;

-- Staff identity + permission in the owning division (or ownership, or an explicit grant). Classification is applied separately and is
-- never a grant. Critical documents additionally need ownership, a grant, or documents.view_critical.
create function document_gate(p_doc uuid, p_owner uuid, p_division uuid, p_critical boolean, p_action text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_me uuid := current_staff_id(); v_perm text := document_perm(p_action); v_grant boolean; v_owner boolean;
begin
  if v_me is null or v_perm is null then return false; end if;
  select exists (select 1 from document_access a
                  where a.document_id = p_doc and a.revoked_at is null and (a.expires_at is null or a.expires_at > now()) and p_action = any (a.actions)
                    and (a.staff_id = v_me
                         or (a.division_id is not null and (exists (select 1 from staff_roles sr where sr.staff_id = v_me and sr.division_id = a.division_id)
                                                          or exists (select 1 from staff s where s.id = v_me and s.primary_division_id = a.division_id)))))
    into v_grant;
  v_owner := coalesce(p_owner = v_me, false) and p_action in ('view', 'discover', 'read', 'download', 'upload', 'edit', 'comment');
  if coalesce(v_grant, false) or v_owner then return true; end if;
  if p_critical then return coalesce(has_permission('documents.view_critical') and has_permission(v_perm, p_division), false); end if;
  return coalesce(has_permission(v_perm, p_division), false);
end $$;

create function document_can_row(p_doc uuid, p_owner uuid, p_division uuid, p_class data_classification, p_critical boolean, p_client_deleted boolean,
                                 p_status document_status, p_action text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  -- classification and soft-deleted clients apply to every action; every action also needs the right to know the document exists
  if not coalesce(classification_visible(p_class) and (not p_client_deleted or has_permission('records.view_deleted')), false) then return false; end if;
  if not document_gate(p_doc, p_owner, p_division, p_critical, 'view') then return false; end if;
  if p_action in ('view', 'discover') then return true; end if;
  if p_status = 'disposed' then return false; end if;
  if p_status = 'archived' and p_action not in ('read', 'download', 'restore', 'request_disposal', 'dispose') then return false; end if;
  if p_status = 'active' and p_action in ('restore', 'request_disposal', 'dispose') then return false; end if;
  return coalesce(document_gate(p_doc, p_owner, p_division, p_critical, p_action), false);
end $$;

create function document_can(p_doc uuid, p_action text default 'view') returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select document_can_row(d.id, d.owner_staff_id, d.division_id, d.effective_classification, d.is_critical, d.client_deleted, d.status, p_action)
                   from documents d where d.id = p_doc), false)
$$;

-- Loads and locks a document the caller may see. Hidden and missing documents are indistinguishable (same error).
create function document_require(p_doc uuid, p_action text default 'view') returns documents
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype;
begin
  select * into d from documents where id = p_doc for update;
  if not found or not document_can_row(d.id, d.owner_staff_id, d.division_id, d.effective_classification, d.is_critical, d.client_deleted, d.status, 'view') then
    raise exception 'document not found' using errcode = 'P0002';
  end if;
  if p_action not in ('view', 'discover') and not document_can_row(d.id, d.owner_staff_id, d.division_id, d.effective_classification, d.is_critical, d.client_deleted, d.status, p_action) then
    raise exception 'you are not permitted to % this document', replace(p_action, '_', ' ') using errcode = '42501';
  end if;
  return d;
end $$;

create function document_inst_id(p_doc uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select institutional_id from entity_registry where table_name = 'documents' and entity_id = p_doc
$$;

create function document_on_hold(p_doc uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select document_can(p_doc, 'view') and exists (select 1 from document_holds h where h.document_id = p_doc and h.released_at is null)
$$;

revoke execute on function document_perm(text), document_gate(uuid, uuid, uuid, boolean, text), document_require(uuid, text), document_inst_id(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Classification inheritance and the record's guards
-- ---------------------------------------------------------------------------
create function documents_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cls data_classification; v_del boolean;
begin
  select coalesce(max(r.classification), 'public'),
         coalesce(bool_or(case r.table_name when 'clients'  then exists (select 1 from clients c  where c.id = r.entity_id and c.deleted_at is not null)
                                            when 'projects' then exists (select 1 from projects p where p.id = r.entity_id and p.deleted_at is not null)
                                            else false end), false)
    into v_cls, v_del
    from document_links dl join entity_registry r on r.institutional_id = dl.entity_institutional_id
   where dl.document_id = new.id and dl.removed_at is null;
  new.effective_classification := greatest(new.classification, v_cls);
  new.client_deleted := v_del;
  return new;
end $$;
create trigger documents_inherit_trg before insert or update on documents for each row execute function documents_inherit();

create function documents_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'documents are never deleted; archive them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, current_staff_id());
    new.status := 'active';
    return new;
  end if;
  if old.status = 'disposed' and (to_jsonb(new) - array['updated_at', 'effective_classification', 'client_deleted']) is distinct from (to_jsonb(old) - array['updated_at', 'effective_classification', 'client_deleted']) then
    raise exception 'a disposed document is a closed record' using errcode = '42501';
  end if;
  if (new.created_at, new.created_by, new.document_type_id) is distinct from (old.created_at, old.created_by, old.document_type_id) then
    raise exception 'a document''s type, creator and creation time are permanent' using errcode = '42501';
  end if;
  if new.division_id is distinct from old.division_id and coalesce(current_setting('ada.document_transfer', true), '') <> 'on' then
    raise exception 'a document changes division only through document_transfer' using errcode = '42501';
  end if;
  if (new.retention_class_id, new.retention_months, new.retention_start) is distinct from (old.retention_class_id, old.retention_months, old.retention_start)
     and coalesce(current_setting('ada.document_retention', true), '') <> 'on' then
    raise exception 'retention is changed only through document_set_retention' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'active' and new.status = 'archived') or (old.status = 'archived' and new.status in ('active', 'disposed'))) then
      raise exception 'invalid document status change % -> %', old.status, new.status using errcode = '23514';
    end if;
    if new.status = 'disposed' then
      if coalesce(current_setting('ada.document_disposal', true), '') <> 'on' then raise exception 'a document is disposed only through an approved disposal' using errcode = '42501'; end if;
      if old.retention_months is null then raise exception 'a permanent record is never disposed' using errcode = '42501'; end if;
      if old.retention_start + make_interval(months => old.retention_months) > current_date then raise exception 'the retention period has not elapsed' using errcode = '42501'; end if;
      if exists (select 1 from document_holds h where h.document_id = old.id and h.released_at is null) then raise exception 'a legal hold prevents disposal' using errcode = '42501'; end if;
    end if;
    new.archived_at := case when new.status = 'archived' then now() when new.status = 'active' then null else old.archived_at end;
    new.disposed_at := case when new.status = 'disposed' then now() else old.disposed_at end;
  end if;
  return new;
end $$;
create trigger documents_guard_trg before insert or update or delete on documents for each row execute function documents_guard();

create function document_versions_guard() returns trigger
language plpgsql as $$
declare v_mode text := coalesce(current_setting('ada.document_storage', true), ''); v_status document_status;
begin
  if tg_op = 'DELETE' then raise exception 'versions are never deleted: withdraw them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    select status into v_status from documents where id = new.document_id;
    if v_status is distinct from 'active' then raise exception 'versions are added only to active documents' using errcode = '23514'; end if;
    if new.state <> 'draft' then raise exception 'a version starts as a draft' using errcode = '23514'; end if;
    new.uploaded_by := coalesce(new.uploaded_by, current_staff_id());
    new.uploaded_at := now();
    return new;
  end if;
  if (new.document_id, new.version_no, new.content_hash, new.size_bytes, new.mime_type, new.original_filename, new.uploaded_by, new.uploaded_at, new.amends_version_id)
     is distinct from (old.document_id, old.version_no, old.content_hash, old.size_bytes, old.mime_type, old.original_filename, old.uploaded_by, old.uploaded_at, old.amends_version_id) then
    raise exception 'the content and identity of a version are permanent' using errcode = '42501';
  end if;
  if (new.storage_provider, new.storage_key, new.content_purged_at) is distinct from (old.storage_provider, old.storage_key, old.content_purged_at) then
    if v_mode = 'relocate' and old.content_purged_at is null and new.content_purged_at is null and new.storage_key is not null then null;
    elsif v_mode = 'purge' and old.content_purged_at is null and new.content_purged_at is not null and new.storage_key is null then null;
    else raise exception 'the storage reference of a version changes only through relocation or an approved disposal' using errcode = '42501'; end if;
  end if;
  if old.state in ('signed', 'withdrawn') and (to_jsonb(new) - array['storage_provider', 'storage_key', 'content_purged_at']) is distinct from (to_jsonb(old) - array['storage_provider', 'storage_key', 'content_purged_at']) then
    raise exception 'a % version is immutable', old.state using errcode = '42501';
  end if;
  if new.state is distinct from old.state then
    if not ((old.state = 'draft' and new.state in ('review', 'withdrawn')) or (old.state = 'review' and new.state in ('draft', 'approved', 'withdrawn'))
         or (old.state = 'approved' and new.state in ('signed', 'withdrawn'))) then
      raise exception 'invalid version state change % -> %', old.state, new.state using errcode = '23514';
    end if;
    if new.state = 'signed' and (new.signed_by is null or new.signed_at is null or new.signed_on is null) then raise exception 'a signed version records who signed and when' using errcode = '23514'; end if;
    if new.state = 'approved' and (new.approved_by is null or new.approved_at is null) then raise exception 'an approved version records who approved it' using errcode = '23514'; end if;
  elsif old.state = 'approved' and (new.label, new.change_note) is distinct from (old.label, old.change_note) then
    raise exception 'an approved version is frozen' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger document_versions_guard_trg before insert or update or delete on document_versions for each row execute function document_versions_guard();

create function document_links_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'links are never deleted: they are removed with a reason, so history stays answerable' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.linked_by := coalesce(new.linked_by, current_staff_id());
    if new.removed_at is not null then raise exception 'a link starts live' using errcode = '23514'; end if;
    return new;
  end if;
  if (new.document_id, new.entity_institutional_id, new.role, new.linked_by, new.linked_at) is distinct from (old.document_id, old.entity_institutional_id, old.role, old.linked_by, old.linked_at)
     or old.removed_at is not null then
    raise exception 'a link is permanent; it can only be removed once, with a reason' using errcode = '42501';
  end if;
  if new.removed_at is not null and coalesce(btrim(new.removal_reason), '') = '' then raise exception 'a reason is required to remove a link' using errcode = '23514'; end if;
  return new;
end $$;
create trigger document_links_guard_trg before insert or update or delete on document_links for each row execute function document_links_guard();

-- A link changes the document's effective classification and deleted flag, and is part of its history
create function document_links_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update documents set classification = classification where id = new.document_id;
  perform document_log(new.document_id, null, case when tg_op = 'INSERT' then 'link_added' else 'link_removed' end,
                       jsonb_build_object('entity', new.entity_institutional_id, 'role', new.role, 'reason', new.removal_reason));
  return null;
end $$;
create trigger document_links_after_trg after insert or update on document_links for each row execute function document_links_after();

-- Dependents follow their entities (classification through the registry sync; deletion here)
create function documents_follow_entity() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update documents set classification = classification
   where id in (select dl.document_id from document_links dl join entity_registry r on r.institutional_id = dl.entity_institutional_id
                 where r.table_name = tg_table_name and r.entity_id = new.id and dl.removed_at is null);
  return null;
end $$;
create trigger documents_follow_client_trg after update of deleted_at on clients for each row execute function documents_follow_entity();
create trigger documents_follow_project_trg after update of deleted_at on projects for each row execute function documents_follow_entity();

-- The registry mirror also tells linked documents when an entity's classification changes (both directions)
create or replace function registry_sync_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t entity_types; a record; r entity_registry%rowtype;
begin
  select * into r from entity_registry where table_name = tg_table_name and entity_id = coalesce(new.id, old.id);
  if not found then return null; end if;
  if tg_op = 'DELETE' then
    update entity_registry set status = 'removed', routing_version = routing_version + 1 where institutional_id = r.institutional_id;
    return null;
  end if;
  select * into t from entity_types where key = r.entity_type;
  select * into a from registry_attrs(t, to_jsonb(new));
  if (a.division_id, a.location, a.status, a.classification, a.scope) is distinct from (r.current_division_id, r.current_location, r.status, r.classification, r.authorization_scope) then
    update entity_registry set current_division_id = a.division_id, current_location = a.location, status = a.status, classification = a.classification,
           authorization_scope = a.scope, routing_version = routing_version + 1 where institutional_id = r.institutional_id;
    if a.division_id is distinct from r.current_division_id or a.location is distinct from r.current_location then
      insert into entity_location_history (institutional_id, from_division_id, to_division_id, from_location, to_location, reason, changed_by)
      values (r.institutional_id, r.current_division_id, a.division_id, r.current_location, a.location, 'moved', current_staff_id());
    end if;
    if a.classification is distinct from r.classification then
      update documents set classification = classification
       where id in (select dl.document_id from document_links dl where dl.entity_institutional_id = r.institutional_id and dl.removed_at is null);
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Publication eligibility and automatic withdrawal
-- ---------------------------------------------------------------------------
create function document_publication_blockers(p_doc uuid, p_version uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v document_versions%rowtype; t document_types%rowtype;
begin
  select * into d from documents where id = p_doc;
  select * into v from document_versions where id = p_version;
  select * into t from document_types where id = d.document_type_id;
  if d.id is null or v.id is null then return 'not found'; end if;
  if d.status <> 'active' then return 'the document is not active'; end if;
  if d.is_critical then return 'critical documents are never published'; end if;
  if d.effective_classification <> 'public' then return 'only documents classified public can be published'; end if;
  if not t.publishable then return 'documents of this type are never published'; end if;
  if v.document_id <> d.id or v.state not in ('approved', 'signed') then return 'only an approved or signed version can be published'; end if;
  if v.content_purged_at is not null then return 'the content is no longer held'; end if;
  return null;
end $$;
revoke execute on function document_publication_blockers(uuid, uuid) from public, anon, authenticated;

create function document_publication_recheck(p_doc uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; v_block text;
begin
  for p in select * from document_publications where document_id = p_doc and state in ('pending_approval', 'approved', 'published') loop
    v_block := document_publication_blockers(p.document_id, p.version_id);
    if v_block is not null then
      update document_publications set state = 'unpublished', unpublished_at = now(), unpublish_reason = 'withdrawn automatically: ' || v_block where id = p.id;
      perform document_log(p.document_id, p.version_id, 'unpublished', jsonb_build_object('publication', p.id, 'automatic', true, 'reason', v_block));
      if p.state = 'published' then perform emit_event('document.unpublished', 'documents', p.document_id, null, jsonb_build_object('public_ref', p.public_ref)); end if;
    end if;
  end loop;
end $$;
revoke execute on function document_publication_recheck(uuid) from public, anon, authenticated;

create function documents_after_update() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform document_publication_recheck(new.id);
  return null;
end $$;
create trigger documents_after_update_trg after update on documents for each row execute function documents_after_update();
create function document_versions_after_update() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.state is distinct from old.state or new.content_purged_at is distinct from old.content_purged_at then perform document_publication_recheck(new.document_id); end if;
  return null;
end $$;
create trigger document_versions_after_update_trg after update on document_versions for each row execute function document_versions_after_update();

create function document_publications_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'publication records are never deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.state := 'pending_approval'; new.requested_by := coalesce(new.requested_by, current_staff_id()); return new;
  end if;
  if (new.document_id, new.version_id, new.public_ref, new.public_title, new.public_description, new.requested_by, new.requested_at)
     is distinct from (old.document_id, old.version_id, old.public_ref, old.public_title, old.public_description, old.requested_by, old.requested_at) then
    raise exception 'what is published is fixed: withdraw it and request a new publication' using errcode = '42501';
  end if;
  if new.state is distinct from old.state and not (
        (old.state = 'pending_approval' and new.state in ('approved', 'rejected', 'unpublished'))
     or (old.state = 'approved' and new.state in ('published', 'unpublished'))
     or (old.state = 'published' and new.state = 'unpublished')) then
    raise exception 'invalid publication state change % -> %', old.state, new.state using errcode = '23514';
  end if;
  if new.state = 'published' and (old.state <> 'approved' or document_publication_blockers(new.document_id, new.version_id) is not null) then
    raise exception 'only an approved, still-eligible publication can go live' using errcode = '42501';
  end if;
  if old.state in ('unpublished', 'rejected') and new.state is distinct from old.state then raise exception 'a closed publication cannot be reopened' using errcode = '42501'; end if;
  return new;
end $$;
create trigger document_publications_guard_trg before insert or update or delete on document_publications for each row execute function document_publications_guard();

-- ---------------------------------------------------------------------------
-- Security events: stored content that no longer matches its hash is an investigation matter (the existing model, one more kind)
-- ---------------------------------------------------------------------------
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'security_policies'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' loop
    execute format('alter table security_policies drop constraint %I', c);
  end loop;
  for c in select conname from pg_constraint where conrelid = 'security_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' loop
    execute format('alter table security_events drop constraint %I', c);
  end loop;
end $$;
alter table security_policies add constraint security_policies_kind_check check (kind in ('lookup', 'bypass', 'integrity'));
alter table security_events   add constraint security_events_kind_check   check (kind in ('lookup', 'bypass', 'integrity'));
insert into security_policies (kind, window_minutes, threshold, case_status, severity, note) values
  ('integrity', 1, 1, 'open', 'high', 'stored document content no longer matches its recorded hash: immediate case');

create or replace function security_evaluate(p_event bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e security_events%rowtype; p security_policies%rowtype; v_count integer; c security_cases%rowtype; v_new boolean := false;
        v_rank constant text[] := array['low', 'medium', 'high', 'critical'];
begin
  select * into e from security_events where id = p_event;
  select * into p from security_policies pl where pl.is_active and pl.kind = e.kind
   and (select count(*) from security_events x where x.kind = e.kind and coalesce(x.actor_staff_id, x.actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id)
          and x.occurred_at > e.occurred_at - make_interval(mins => pl.window_minutes)) >= pl.threshold
   order by array_position(v_rank, pl.severity) desc limit 1;
  if not found then return; end if;
  select count(*) into v_count from security_events x where x.kind = e.kind and coalesce(x.actor_staff_id, x.actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id)
     and x.occurred_at > e.occurred_at - make_interval(mins => p.window_minutes);
  select * into c from security_cases where coalesce(actor_staff_id, actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id) and status <> 'closed' for update;
  if not found then
    insert into security_cases (status, severity, actor_staff_id, actor_user_id, reason, event_count)
    values (p.case_status, p.severity, e.actor_staff_id, e.actor_user_id, case when e.kind = 'bypass' then 'attempt to bypass access controls' when e.kind = 'integrity' then 'stored content no longer matches its recorded hash' else v_count || ' denied or unresolved lookups within ' || p.window_minutes || ' minutes' end, 0)
    returning * into c;
    v_new := true;
  elsif array_position(v_rank, p.severity) > array_position(v_rank, c.severity) or (c.status = 'flagged' and p.case_status = 'open') then
    update security_cases set severity = case when array_position(v_rank, p.severity) > array_position(v_rank, severity) then p.severity else severity end,
           status = case when c.status = 'flagged' and p.case_status = 'open' then 'open' else status end where id = c.id returning * into c;
    v_new := true;
  end if;
  -- the case references the whole pattern, including the earlier related attempts in the window
  insert into security_case_events (case_id, event_id)
  select c.id, x.id from security_events x where x.kind = e.kind and coalesce(x.actor_staff_id, x.actor_user_id) is not distinct from coalesce(e.actor_staff_id, e.actor_user_id)
     and x.occurred_at > e.occurred_at - make_interval(mins => p.window_minutes) on conflict do nothing;
  update security_cases set event_count = (select count(*) from security_case_events where case_id = c.id), last_event_at = now() where id = c.id;
  if v_new then
    perform notify_holders('security.view', null, 'security.case', 'Security ' || case when c.status = 'flagged' then 'flag' else 'case' end || ' raised (' || c.severity || ')', null, 'security_cases', c.id, null);
  end if;
end $$;

-- A lookup that matches a CRITICAL document is recorded exactly like one that matched nothing: neither the investigators' records nor
-- anything else may show that a critical document exists to anyone but the people entitled to it.
create or replace function security_note_lookup(p_input text, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_in text := left(coalesce(p_input, ''), 64); r entity_registry%rowtype; v_found boolean;
begin
  select * into r from entity_registry where institutional_id = upper(btrim(v_in)) or ada_id = btrim(v_in);
  v_found := found;
  if v_found and r.entity_type = 'document' and exists (select 1 from documents d where d.id = r.entity_id and d.is_critical) then v_found := false; end if;
  insert into security_events (actor_user_id, actor_staff_id, kind, requested_action, requested_input, entity_exists, entity_class, session_ref, source_addr, reason)
  values (auth.uid(), current_staff_id(), 'lookup', left(coalesce(p_action, 'resolve'), 40), v_in, v_found, case when v_found then r.classification end,
          nullif(current_setting('request.jwt.claim.session_id', true), ''), inet_client_addr(),
          case when v_found then 'not authorized for this entity' else 'no such entity' end);
end $$;

-- The caller's own denied attempt on a document, recorded with the real identifier (investigators see it; the caller learns nothing)
create function document_note_denied(p_doc uuid, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform security_note_lookup(coalesce(document_inst_id(p_doc), p_doc::text), 'document.' || left(coalesce(p_action, 'open'), 24));
end $$;
revoke execute on function document_note_denied(uuid, text) from public, anon;
grant execute on function document_note_denied(uuid, text) to authenticated;

create function security_report_integrity(p_version uuid, p_expected text, p_observed text, p_result text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype;
begin
  select dd.* into d from documents dd join document_versions v on v.document_id = dd.id where v.id = p_version;
  insert into security_events (actor_user_id, actor_staff_id, kind, requested_action, requested_input, entity_exists, decision, reason)
  values (null, null, 'integrity', 'document.integrity', case when d.is_critical then null else document_inst_id(d.id) end, true, 'flagged',
          case p_result when 'missing' then 'stored content is missing' else 'stored content no longer matches its recorded hash' end);
end $$;
revoke execute on function security_report_integrity(uuid, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Commands: register, version, state, open
-- ---------------------------------------------------------------------------
create function document_register(p_title text, p_type text, p_division uuid, p_description text default null, p_document_date date default null,
                                  p_classification data_classification default null, p_critical boolean default null, p_retention_class text default null,
                                  p_owner uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t document_types%rowtype; rc retention_classes%rowtype; v_me uuid := current_staff_id(); v_cls data_classification; v_crit boolean; v_id uuid; v_owner uuid;
begin
  if v_me is null then raise exception 'only active staff register documents' using errcode = '42501'; end if;
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('documents.create', p_division) then raise exception 'documents.create is required in that division' using errcode = '42501'; end if;
  select * into t from document_types where key = p_type and is_active;
  if not found then raise exception 'unknown document type' using errcode = '23514'; end if;
  v_cls := coalesce(p_classification, t.default_classification);
  v_crit := coalesce(p_critical, t.default_critical);
  if (p_classification is not null and p_classification <> t.default_classification) and not has_permission('records.classify') then
    raise exception 'records.classify is required to set a classification other than the type''s default' using errcode = '42501';
  end if;
  if p_critical is not null and p_critical <> t.default_critical and not has_permission('documents.view_critical') then
    raise exception 'documents.view_critical is required to change whether a document is critical' using errcode = '42501';
  end if;
  if not classification_visible(v_cls) then raise exception 'you cannot register a document above your own classification clearance' using errcode = '42501'; end if;
  if p_retention_class is not null and not has_permission('documents.configure') then raise exception 'documents.configure is required to choose a retention class' using errcode = '42501'; end if;
  select * into rc from retention_classes where id = case when p_retention_class is null then t.retention_class_id else (select id from retention_classes where key = p_retention_class and is_active) end;
  if not found then raise exception 'unknown retention class' using errcode = '23514'; end if;
  v_owner := coalesce(p_owner, v_me);
  if not exists (select 1 from staff where id = v_owner and account_status = 'active' and deleted_at is null) then raise exception 'the owner must be an active staff member' using errcode = '23514'; end if;
  insert into documents (title, document_type_id, description, division_id, owner_staff_id, classification, is_critical, document_date, retention_class_id, retention_months, retention_start)
  values (p_title, t.id, p_description, p_division, v_owner, v_cls, v_crit, coalesce(p_document_date, current_date), rc.id, rc.period_months, current_date)
  returning id into v_id;
  perform document_log(v_id, null, 'created', jsonb_build_object('type', t.key, 'division', p_division));
  return jsonb_build_object('id', v_id, 'institutional_id', document_inst_id(v_id), 'type', t.key, 'status', 'active', 'origin_division_id', p_division, 'classification', v_cls);
end $$;

create function document_add_version(p_doc uuid, p_provider text, p_key text, p_hash text, p_size bigint, p_mime text, p_filename text default null,
                                     p_label text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v_no integer; v_id uuid; v_amends uuid; v_same integer;
begin
  d := document_require(p_doc, 'upload');
  select coalesce(max(version_no), 0) + 1 into v_no from document_versions where document_id = d.id;
  select version_no into v_same from document_versions where document_id = d.id and content_hash = p_hash and state <> 'withdrawn' order by version_no desc limit 1;
  if v_same is not null then raise exception 'this content is identical to version %', v_same using errcode = '23514'; end if;
  select id into v_amends from document_versions where document_id = d.id and state = 'signed' order by version_no desc limit 1;
  insert into document_versions (document_id, version_no, label, change_note, amends_version_id, storage_provider, storage_key, content_hash, size_bytes, mime_type, original_filename)
  values (d.id, v_no, p_label, p_note, v_amends, lower(p_provider), p_key, lower(p_hash), p_size, lower(p_mime), p_filename) returning id into v_id;
  perform document_log(d.id, v_id, 'version_added', jsonb_build_object('version_no', v_no, 'amends', (select version_no from document_versions where id = v_amends)));
  return jsonb_build_object('version_id', v_id, 'version_no', v_no, 'state', 'draft', 'amends_version_no', (select version_no from document_versions where id = v_amends));
end $$;

create function document_version_transition(p_version uuid, p_to document_version_state, p_note text default null, p_signed_on date default null) returns document_version_state
language plpgsql security definer set search_path = public, pg_temp as $$
declare v document_versions%rowtype; d documents%rowtype; v_gate text; v_me uuid := current_staff_id(); v_class data_classification;
begin
  select * into v from document_versions where id = p_version;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(v.document_id, 'view');
  select * into v from document_versions where id = p_version for update;
  v_class := case when d.is_critical then 'confidential'::data_classification else d.effective_classification end;
  if d.status <> 'active' then raise exception 'the document is % and its versions cannot change state', d.status using errcode = '23514'; end if;
  case
    when v.state = 'draft' and p_to = 'review' then
      perform document_require(d.id, 'upload');
      update document_versions set state = 'review', requested_by = v_me where id = v.id;
      perform approval_open('document_version', 'document_versions', v.id, null, d.division_id,
                            coalesce((approval_policy('document_version', d.division_id, null)).required_permission, 'documents.approve'),
                            'Document version ' || v.version_no, v_class);
      if not d.is_critical and d.effective_classification = 'internal' then
        perform notify_holders('documents.approve', d.division_id, 'approval.required', 'Document version awaiting approval', null, 'documents', d.id, null);
      end if;
    when v.state = 'review' and p_to = 'draft' then
      if document_can(d.id, 'approve') and v.requested_by is distinct from v_me then
        if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to send a version back' using errcode = '23514'; end if;
        perform approval_gate('document_version', 'document_versions', v.id, d.division_id, null, v.requested_by, 'documents.approve', false, p_note);
        update document_versions set state = 'draft', decision_note = p_note where id = v.id;
        perform approval_close('document_versions', v.id, 'rejected', p_note);
      else
        perform document_require(d.id, 'upload');
        update document_versions set state = 'draft', decision_note = p_note where id = v.id;
        perform approval_close('document_versions', v.id, 'cancelled', p_note);
      end if;
    when v.state = 'review' and p_to = 'approved' then
      perform document_require(d.id, 'approve');
      v_gate := approval_gate('document_version', 'document_versions', v.id, d.division_id, null, v.requested_by, 'documents.approve', true, p_note);
      if v_gate = 'pending' then return v.state; end if;
      update document_versions set state = 'approved', approved_by = v_me, approved_at = now(), decision_note = p_note where id = v.id;
      perform approval_close('document_versions', v.id, 'approved', p_note);
    when v.state = 'approved' and p_to = 'signed' then
      perform document_require(d.id, 'approve');
      if p_signed_on is null or p_signed_on > current_date then raise exception 'the date the version was signed is required and cannot be in the future' using errcode = '23514'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a note naming who signed is required' using errcode = '23514'; end if;
      update document_versions set state = 'signed', signed_by = v_me, signed_at = now(), signed_on = p_signed_on, decision_note = p_note where id = v.id;
    when v.state in ('draft', 'review', 'approved') and p_to = 'withdrawn' then
      perform document_require(d.id, case when v.state = 'approved' then 'approve' else 'upload' end);
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required to withdraw a version' using errcode = '23514'; end if;
      update document_versions set state = 'withdrawn', decision_note = p_note where id = v.id;
      if v.state = 'review' then perform approval_close('document_versions', v.id, 'cancelled', p_note); end if;
    else
      raise exception 'invalid version state change % -> %', v.state, p_to using errcode = '23514';
  end case;
  perform document_log(d.id, v.id, 'version_state', jsonb_build_object('version_no', v.version_no, 'from', v.state, 'to', p_to));
  return p_to;
end $$;

-- Authorises and LOGS every read and download. Returns the storage reference for the storage service to turn into a short-lived
-- delivery; NULL (and a security lookup event) for anyone not entitled - hidden and missing documents behave identically.
create function document_open(p_doc uuid, p_mode text default 'read', p_version integer default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v document_versions%rowtype; v_priv boolean; v_last text;
begin
  if p_mode not in ('read', 'download') then raise exception 'mode must be read or download' using errcode = '22023'; end if;
  select * into d from documents where id = p_doc;
  if not found or not document_can_row(d.id, d.owner_staff_id, d.division_id, d.effective_classification, d.is_critical, d.client_deleted, d.status, p_mode) then
    perform document_note_denied(p_doc, p_mode);
    return null;
  end if;
  v_priv := document_can(d.id, 'upload') or document_can(d.id, 'approve');
  select * into v from document_versions x
   where x.document_id = d.id and (p_version is null or x.version_no = p_version) and x.state <> 'withdrawn'
     and (x.state in ('approved', 'signed') or v_priv or x.uploaded_by is not distinct from current_staff_id())
   order by x.version_no desc limit 1;
  if not found then perform document_note_denied(p_doc, p_mode); return null; end if;
  if v.content_purged_at is not null then raise exception 'the content of this version is no longer held' using errcode = '55000'; end if;
  select result into v_last from document_integrity_checks where version_id = v.id order by seq desc limit 1;
  if v_last in ('mismatch', 'missing') then raise exception 'the stored content failed its integrity check and is withheld' using errcode = '55000'; end if;
  perform document_log(d.id, v.id, case p_mode when 'read' then 'opened' else 'downloaded' end, jsonb_build_object('version_no', v.version_no));
  return jsonb_build_object('document', document_inst_id(d.id), 'version_no', v.version_no, 'state', v.state, 'mode', p_mode, 'mime_type', v.mime_type, 'size_bytes', v.size_bytes,
                            'content_hash', v.content_hash, 'filename', v.original_filename, 'storage_provider', v.storage_provider, 'storage_key', v.storage_key);
end $$;

-- ---------------------------------------------------------------------------
-- Commands: metadata, classification, retention, ownership, archive
-- ---------------------------------------------------------------------------
create function document_update(p_doc uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; k text; v_allowed constant text[] := array['title', 'description', 'document_date', 'review_date', 'owner_staff_id']; v_keys text[];
begin
  d := document_require(p_doc, 'edit');
  select array_agg(x order by x) into v_keys from jsonb_object_keys(p_changes) x;
  if v_keys is null then raise exception 'nothing to change' using errcode = '23514'; end if;
  foreach k in array v_keys loop
    if not (k = any (v_allowed)) then raise exception 'cannot change % here', k using errcode = '23514'; end if;
  end loop;
  if p_changes ? 'owner_staff_id' and not exists (select 1 from staff where id = (p_changes ->> 'owner_staff_id')::uuid and account_status = 'active' and deleted_at is null) then
    raise exception 'the owner must be an active staff member' using errcode = '23514';
  end if;
  update documents set
    title = case when p_changes ? 'title' then p_changes ->> 'title' else title end,
    description = case when p_changes ? 'description' then p_changes ->> 'description' else description end,
    document_date = case when p_changes ? 'document_date' then (p_changes ->> 'document_date')::date else document_date end,
    review_date = case when p_changes ? 'review_date' then (p_changes ->> 'review_date')::date else review_date end,
    owner_staff_id = case when p_changes ? 'owner_staff_id' then (p_changes ->> 'owner_staff_id')::uuid else owner_staff_id end
   where id = d.id;
  perform document_log(d.id, null, 'metadata', jsonb_build_object('fields', to_jsonb(v_keys)));
end $$;

create function document_set_classification(p_doc uuid, p_class data_classification, p_critical boolean, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; e documents%rowtype;
begin
  d := document_require(p_doc, 'edit');
  if not has_permission('records.classify') then raise exception 'records.classify is required' using errcode = '42501'; end if;
  if p_critical is not null and p_critical is distinct from d.is_critical and not has_permission('documents.view_critical') then
    raise exception 'documents.view_critical is required to change whether a document is critical' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update documents set classification = p_class, is_critical = coalesce(p_critical, is_critical) where id = d.id returning * into e;
  if not classification_visible(e.effective_classification) then raise exception 'you cannot classify a document above your own clearance' using errcode = '42501'; end if;
  perform document_log(d.id, null, 'classification', jsonb_build_object('from', d.classification, 'to', p_class, 'critical_from', d.is_critical, 'critical_to', e.is_critical, 'reason', p_reason));
end $$;

create function document_set_retention(p_doc uuid, p_class text, p_start date, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; rc retention_classes%rowtype;
begin
  d := document_require(p_doc, 'view');
  if not has_permission('documents.configure', d.division_id) then raise exception 'documents.configure is required' using errcode = '42501'; end if;
  if d.status <> 'active' then raise exception 'the document is %', d.status using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into rc from retention_classes where key = p_class and is_active;
  if not found then raise exception 'unknown retention class' using errcode = '23514'; end if;
  perform set_config('ada.document_retention', 'on', true);
  update documents set retention_class_id = rc.id, retention_months = rc.period_months, retention_start = coalesce(p_start, retention_start) where id = d.id;
  perform set_config('ada.document_retention', 'off', true);
  perform document_log(d.id, null, 'retention', jsonb_build_object('class', rc.key, 'months', rc.period_months, 'start', coalesce(p_start, d.retention_start), 'reason', p_reason));
end $$;

-- Ownership moves to another division. The permanent ID and the ORIGIN division never change; the registry's current division follows.
create function document_transfer(p_doc uuid, p_division uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype;
begin
  d := document_require(p_doc, 'edit');
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('documents.update', p_division) and not has_permission('documents.create', p_division) then raise exception 'you cannot hand a document to a division where you have no document rights' using errcode = '42501'; end if;
  if p_division = d.division_id then raise exception 'the document is already with that division' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  perform set_config('ada.document_transfer', 'on', true);
  update documents set division_id = p_division where id = d.id;
  perform set_config('ada.document_transfer', 'off', true);
  perform document_log(d.id, null, 'transferred', jsonb_build_object('from', d.division_id, 'to', p_division, 'reason', p_reason));
end $$;

create function document_archive(p_doc uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype;
begin
  d := document_require(p_doc, 'archive');
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update documents set status = 'archived' where id = d.id;
  perform document_log(d.id, null, 'archived', jsonb_build_object('reason', p_reason));
end $$;
create function document_restore(p_doc uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype;
begin
  d := document_require(p_doc, 'restore');
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update documents set status = 'active' where id = d.id;
  perform document_log(d.id, null, 'restored', jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Commands: relationships, sharing, comments
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER: the insert runs under the CALLER's row security, so a target the caller cannot see (or that does not exist) is refused
-- identically - you cannot attach a document to something you could not otherwise know about.
create function document_link_add(p_doc uuid, p_entity text, p_role text default 'subject') returns uuid
language plpgsql set search_path = public, pg_temp as $$
declare v_inst text; v_id uuid;
begin
  if not document_can(p_doc, 'view') then raise exception 'document not found' using errcode = 'P0002'; end if;
  if not document_can(p_doc, 'edit') then raise exception 'you are not permitted to edit this document' using errcode = '42501'; end if;
  select institutional_id into v_inst from entity_registry where institutional_id = upper(btrim(p_entity)) or ada_id = btrim(p_entity);
  if v_inst is null then raise exception 'entity not found' using errcode = 'P0002'; end if;
  insert into document_links (document_id, entity_institutional_id, role) values (p_doc, v_inst, p_role) returning id into v_id;
  return v_id;
end $$;

create function document_link_remove(p_link uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l document_links%rowtype; d documents%rowtype;
begin
  select * into l from document_links where id = p_link;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(l.document_id, 'edit');
  if l.removed_at is not null then raise exception 'the link is already removed' using errcode = '23514'; end if;
  update document_links set removed_at = now(), removed_by = current_staff_id(), removal_reason = p_reason where id = l.id;
end $$;

create function document_share(p_doc uuid, p_staff uuid, p_division uuid, p_actions text[], p_expires timestamptz default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v_id uuid; v_actions text[];
begin
  d := document_require(p_doc, 'share');
  if (p_staff is null) = (p_division is null) then raise exception 'share with exactly one person or one division' using errcode = '23514'; end if;
  if p_staff is not null and not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then raise exception 'the recipient must be an active staff member' using errcode = '23514'; end if;
  if p_division is not null and not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if p_expires is not null and p_expires <= now() then raise exception 'the expiry must be in the future' using errcode = '23514'; end if;
  if d.is_critical and p_expires is null then raise exception 'sharing a critical document needs an expiry' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select array_agg(distinct x order by x) into v_actions from unnest(coalesce(p_actions, '{}') || array['view']) x;
  if not (v_actions <@ array['view', 'read', 'download', 'comment']) then raise exception 'a share can grant only view, read, download and comment' using errcode = '23514'; end if;
  insert into document_access (document_id, staff_id, division_id, actions, reason, granted_by, expires_at) values (d.id, p_staff, p_division, v_actions, p_reason, current_staff_id(), p_expires) returning id into v_id;
  perform document_log(d.id, null, 'shared', jsonb_build_object('grant', v_id, 'actions', to_jsonb(v_actions), 'expires', p_expires, 'to_division', p_division is not null));
  return v_id;
end $$;

create function document_unshare(p_grant uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g document_access%rowtype; d documents%rowtype;
begin
  select * into g from document_access where id = p_grant;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(g.document_id, 'share');
  update document_access set revoked_at = now(), revoked_by = current_staff_id() where id = g.id and revoked_at is null;
  perform document_log(d.id, null, 'unshared', jsonb_build_object('grant', g.id, 'reason', p_reason));
end $$;

create function document_comment_add(p_doc uuid, p_body text, p_version integer default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v_ver uuid; v_id uuid;
begin
  d := document_require(p_doc, 'comment');
  if p_version is not null then
    select id into v_ver from document_versions where document_id = d.id and version_no = p_version;
    if v_ver is null then raise exception 'version not found' using errcode = 'P0002'; end if;
  end if;
  insert into document_comments (document_id, version_id, author_id, body) values (d.id, v_ver, current_staff_id(), p_body) returning id into v_id;
  perform document_log(d.id, v_ver, 'comment', '{}');
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Commands: legal holds, integrity, relocation, disposal
-- ---------------------------------------------------------------------------
create function document_hold_place(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v_id uuid;
begin
  d := document_require(p_doc, 'view');
  if not has_permission('documents.legal_hold', d.division_id) then raise exception 'documents.legal_hold is required' using errcode = '42501'; end if;
  insert into document_holds (document_id, reason, placed_by) values (d.id, p_reason, current_staff_id()) returning id into v_id;
  perform document_log(d.id, null, 'hold_placed', jsonb_build_object('hold', v_id));
  return v_id;
end $$;
create function document_hold_release(p_hold uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare h document_holds%rowtype; d documents%rowtype;
begin
  select * into h from document_holds where id = p_hold;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(h.document_id, 'view');
  if not has_permission('documents.legal_hold', d.division_id) then raise exception 'documents.legal_hold is required' using errcode = '42501'; end if;
  if h.released_at is not null then raise exception 'the hold is already released' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update document_holds set released_at = now(), released_by = current_staff_id(), release_reason = p_reason where id = h.id;
  perform document_log(d.id, null, 'hold_released', jsonb_build_object('hold', h.id));
end $$;

-- Verifies stored bytes against the recorded hash. Two entry points over one routine: documents.configure holders (with the hash the storage layer
-- computed) and the storage service itself (service_role). A mismatch is permanent evidence AND a security event.
create function document_integrity_apply(p_version uuid, p_observed_hash text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v document_versions%rowtype; v_result text;
begin
  select * into v from document_versions where id = p_version;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  if v.content_purged_at is not null then raise exception 'the content of this version is no longer held' using errcode = '55000'; end if;
  v_result := case when p_observed_hash is null then 'missing' when lower(p_observed_hash) = v.content_hash then 'match' else 'mismatch' end;
  insert into document_integrity_checks (version_id, document_id, expected_hash, observed_hash, result, checked_by) values (v.id, v.document_id, v.content_hash, lower(p_observed_hash), v_result, current_staff_id());
  perform document_log(v.document_id, v.id, 'integrity', jsonb_build_object('result', v_result));
  if v_result <> 'match' then perform security_report_integrity(v.id, v.content_hash, lower(p_observed_hash), v_result); end if;
  return v_result;
end $$;
create function document_record_integrity_check(p_version uuid, p_observed_hash text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v document_versions%rowtype; d documents%rowtype;
begin
  select * into v from document_versions where id = p_version;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(v.document_id, 'view');
  if not has_permission('documents.configure', d.division_id) then raise exception 'documents.configure is required' using errcode = '42501'; end if;
  return document_integrity_apply(p_version, p_observed_hash);
end $$;
create function document_service_integrity_check(p_version uuid, p_observed_hash text) returns text
language sql security definer set search_path = public, pg_temp as $$ select document_integrity_apply(p_version, p_observed_hash) $$;

-- Moving the bytes to another store changes the REFERENCE only: the hash, identity and state stay. The new location is verified by the next check.
create function document_relocate_apply(p_version uuid, p_provider text, p_key text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v document_versions%rowtype;
begin
  select * into v from document_versions where id = p_version;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  perform set_config('ada.document_storage', 'relocate', true);
  update document_versions set storage_provider = lower(p_provider), storage_key = p_key where id = v.id;
  perform set_config('ada.document_storage', '', true);
  perform document_log(v.document_id, v.id, 'relocated', jsonb_build_object('provider', lower(p_provider)));
end $$;
create function document_relocate_content(p_version uuid, p_provider text, p_key text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v document_versions%rowtype; d documents%rowtype;
begin
  select * into v from document_versions where id = p_version;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(v.document_id, 'view');
  if not has_permission('documents.configure', d.division_id) then raise exception 'documents.configure is required' using errcode = '42501'; end if;
  perform document_relocate_apply(p_version, p_provider, p_key);
end $$;
create function document_service_relocate_content(p_version uuid, p_provider text, p_key text) returns void
language sql security definer set search_path = public, pg_temp as $$ select document_relocate_apply(p_version, p_provider, p_key) $$;
revoke execute on function document_integrity_apply(uuid, text), document_relocate_apply(uuid, text, text) from public, anon, authenticated;
revoke execute on function document_service_integrity_check(uuid, text), document_service_relocate_content(uuid, text, text) from public, anon, authenticated;
grant execute on function document_service_integrity_check(uuid, text), document_service_relocate_content(uuid, text, text) to service_role;

create function document_request_disposal(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v_id uuid;
begin
  d := document_require(p_doc, 'request_disposal');
  if d.retention_months is null then raise exception 'a permanent record is never disposed' using errcode = '23514'; end if;
  if d.retention_start + make_interval(months => d.retention_months) > current_date then raise exception 'the retention period has not elapsed (until %)', d.retention_start + make_interval(months => d.retention_months) using errcode = '23514'; end if;
  if exists (select 1 from document_holds h where h.document_id = d.id and h.released_at is null) then raise exception 'a legal hold prevents disposal' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  insert into document_disposals (document_id, reason, requested_by) values (d.id, p_reason, current_staff_id()) returning id into v_id;
  perform approval_open('document_disposal', 'document_disposals', v_id, null, d.division_id, 'documents.dispose', 'Disposal request',
                        case when d.is_critical then 'confidential'::data_classification else d.effective_classification end);
  perform document_log(d.id, null, 'disposal_requested', jsonb_build_object('disposal', v_id));
  return v_id;
end $$;

create function document_disposal_decide(p_disposal uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare x document_disposals%rowtype; d documents%rowtype; v_gate text; v_manifest jsonb;
begin
  select * into x from document_disposals where id = p_disposal;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(x.document_id, 'dispose');
  if x.state <> 'requested' then raise exception 'this disposal request is already %', x.state using errcode = '23514'; end if;
  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a disposal' using errcode = '23514'; end if;
    perform approval_gate('document_disposal', 'document_disposals', x.id, d.division_id, null, x.requested_by, 'documents.dispose', false, p_note);
    update document_disposals set state = 'rejected', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = x.id;
    perform approval_close('document_disposals', x.id, 'rejected', p_note);
    perform document_log(d.id, null, 'disposal_decided', jsonb_build_object('disposal', x.id, 'approved', false));
    return 'rejected';
  end if;
  if exists (select 1 from document_holds h where h.document_id = d.id and h.released_at is null) then raise exception 'a legal hold prevents disposal' using errcode = '23514'; end if;
  v_gate := approval_gate('document_disposal', 'document_disposals', x.id, d.division_id, null, x.requested_by, 'documents.dispose', true, p_note);
  if v_gate = 'pending' then return 'pending'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'provider', v.storage_provider, 'key', v.storage_key)), '[]') into v_manifest
    from document_versions v where v.document_id = d.id and v.content_purged_at is null;
  perform set_config('ada.document_storage', 'purge', true);
  update document_versions set storage_provider = null, storage_key = null, content_purged_at = now() where document_id = d.id and content_purged_at is null;
  perform set_config('ada.document_storage', '', true);
  perform set_config('ada.document_disposal', 'on', true);
  update documents set status = 'disposed' where id = d.id;
  perform set_config('ada.document_disposal', 'off', true);
  update document_disposals set state = 'approved', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note, purge_manifest = v_manifest where id = x.id;
  perform approval_close('document_disposals', x.id, 'approved', p_note);
  perform document_log(d.id, null, 'disposal_decided', jsonb_build_object('disposal', x.id, 'approved', true));
  return 'approved';
end $$;

-- The storage service confirms it has physically deleted the detached content
create function document_disposal_confirm(p_disposal uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x document_disposals%rowtype;
begin
  select * into x from document_disposals where id = p_disposal and state = 'approved';
  if not found then raise exception 'no approved disposal awaits confirmation' using errcode = 'P0002'; end if;
  update document_disposals set state = 'executed', executed_at = now() where id = x.id;
  perform document_log(x.document_id, null, 'disposal_executed', jsonb_build_object('disposal', x.id));
end $$;

-- ---------------------------------------------------------------------------
-- Commands: publication (publishable != published; an explicit, approved, revocable projection)
-- ---------------------------------------------------------------------------
create function document_publication_request(p_doc uuid, p_version integer, p_public_title text, p_public_description text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documents%rowtype; v document_versions%rowtype; v_block text; v_id uuid;
begin
  d := document_require(p_doc, 'publish');
  select * into v from document_versions where document_id = d.id and version_no = p_version;
  if not found then raise exception 'version not found' using errcode = 'P0002'; end if;
  v_block := document_publication_blockers(d.id, v.id);
  if v_block is not null then raise exception '%', v_block using errcode = '23514'; end if;
  if coalesce(btrim(p_public_title), '') = '' then raise exception 'the public title is required (the internal title is never published)' using errcode = '23514'; end if;
  if exists (select 1 from document_publications where document_id = d.id and state in ('pending_approval', 'approved', 'published')) then
    raise exception 'this document already has a live publication: withdraw it first' using errcode = '23514';
  end if;
  insert into document_publications (document_id, version_id, public_title, public_description, requested_by) values (d.id, v.id, p_public_title, p_public_description, current_staff_id()) returning id into v_id;
  perform approval_open('document_publication', 'document_publications', v_id, null, d.division_id,
                        coalesce((approval_policy('document_publication', d.division_id, null)).required_permission, 'documents.approve'), 'Publication request', d.effective_classification);
  perform notify_holders('documents.approve', d.division_id, 'approval.required', 'Document publication awaiting approval', null, 'documents', d.id, null);
  perform document_log(d.id, v.id, 'publication_requested', jsonb_build_object('publication', v_id));
  return v_id;
end $$;

create function document_publication_decide(p_publication uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare p document_publications%rowtype; d documents%rowtype; v_gate text;
begin
  select * into p from document_publications where id = p_publication;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(p.document_id, 'approve');
  if p.state <> 'pending_approval' then raise exception 'this publication is already %', p.state using errcode = '23514'; end if;
  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a publication' using errcode = '23514'; end if;
    perform approval_gate('document_publication', 'document_publications', p.id, d.division_id, null, p.requested_by, 'documents.approve', false, p_note);
    update document_publications set state = 'rejected', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = p.id;
    perform approval_close('document_publications', p.id, 'rejected', p_note);
    perform document_log(d.id, p.version_id, 'publication_decided', jsonb_build_object('publication', p.id, 'approved', false));
    return 'rejected';
  end if;
  if document_publication_blockers(d.id, p.version_id) is not null then raise exception '%', document_publication_blockers(d.id, p.version_id) using errcode = '23514'; end if;
  v_gate := approval_gate('document_publication', 'document_publications', p.id, d.division_id, null, p.requested_by, 'documents.approve', true, p_note);
  if v_gate = 'pending' then return 'pending'; end if;
  update document_publications set state = 'approved', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = p.id;
  perform approval_close('document_publications', p.id, 'approved', p_note);
  perform document_log(d.id, p.version_id, 'publication_decided', jsonb_build_object('publication', p.id, 'approved', true));
  return 'approved';
end $$;

create function document_publish(p_publication uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare p document_publications%rowtype; d documents%rowtype;
begin
  select * into p from document_publications where id = p_publication;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(p.document_id, 'publish');
  if p.state <> 'approved' then raise exception 'only an approved publication can be published (this one is %)', p.state using errcode = '23514'; end if;
  if document_publication_blockers(d.id, p.version_id) is not null then raise exception '%', document_publication_blockers(d.id, p.version_id) using errcode = '23514'; end if;
  update document_publications set state = 'published', published_at = now() where id = p.id;
  perform document_log(d.id, p.version_id, 'published', jsonb_build_object('publication', p.id));
  perform emit_event('document.published', 'documents', d.id, null, jsonb_build_object('public_ref', p.public_ref));
  return p.public_ref;
end $$;

create function document_unpublish(p_publication uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p document_publications%rowtype; d documents%rowtype;
begin
  select * into p from document_publications where id = p_publication;
  if not found then raise exception 'document not found' using errcode = 'P0002'; end if;
  d := document_require(p.document_id, 'publish');
  if p.state not in ('pending_approval', 'approved', 'published') then raise exception 'this publication is already %', p.state using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update document_publications set state = 'unpublished', unpublished_at = now(), unpublish_reason = p_reason where id = p.id;
  if p.state = 'pending_approval' then perform approval_close('document_publications', p.id, 'cancelled', p_reason); end if;
  perform document_log(d.id, p.version_id, 'unpublished', jsonb_build_object('publication', p.id, 'reason', p_reason));
  if p.state = 'published' then perform emit_event('document.unpublished', 'documents', d.id, null, jsonb_build_object('public_ref', p.public_ref)); end if;
end $$;

-- ---------------------------------------------------------------------------
-- Derived retention status (nothing here is stored, so it cannot go stale)
-- ---------------------------------------------------------------------------
create view document_retention_status with (security_invoker = true) as
  select d.id as document_id, rc.key as retention_class, d.retention_months, d.retention_start,
         (d.retention_start + make_interval(months => d.retention_months))::date as retention_ends_on,
         d.review_date, (d.review_date is not null and d.review_date <= current_date) as review_due,
         document_on_hold(d.id) as on_legal_hold,
         (d.status = 'archived' and d.retention_months is not null and d.retention_start + make_interval(months => d.retention_months) <= current_date and not document_on_hold(d.id)) as disposal_eligible,
         case when d.status = 'disposed' then 'disposed'
              when exists (select 1 from document_disposals x where x.document_id = d.id and x.state in ('requested', 'approved')) then 'disposal_pending'
              when d.status = 'archived' then 'archived' else 'retained' end as disposition
  from documents d join retention_classes rc on rc.id = d.retention_class_id;
comment on view document_retention_status is 'Purpose: derived retention position of each document - class, period, end date, review due, legal hold, disposal eligibility, disposition. Row access follows the document. Nothing is stored.';

create view document_version_integrity with (security_invoker = true) as
  select v.id as version_id, v.document_id, v.version_no,
         (select c.result from document_integrity_checks c where c.version_id = v.id order by c.seq desc limit 1) as last_result,
         (select c.checked_at from document_integrity_checks c where c.version_id = v.id order by c.seq desc limit 1) as last_checked_at
  from document_versions v;
comment on view document_version_integrity is 'Purpose: derived result of the latest integrity check of each version (NULL = never verified).';

-- ---------------------------------------------------------------------------
-- Retrieval: the 360 of a document, documents for any entity, and the state of a document at a point in time
-- ---------------------------------------------------------------------------
create function document_version_as_of(p_doc uuid, p_ts timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_ts timestamptz := coalesce(p_ts, now()); v_priv boolean; v_cur jsonb; v_sig jsonb;
begin
  if not document_can(p_doc, 'view') then return null; end if;
  v_priv := document_can(p_doc, 'upload') or document_can(p_doc, 'approve');
  with s as (
    select v.*, coalesce((select e.detail ->> 'to' from document_events e where e.version_id = v.id and e.kind = 'version_state' and e.occurred_at <= v_ts order by e.id desc limit 1), 'draft') as st
      from document_versions v where v.document_id = p_doc and v.uploaded_at <= v_ts),
  j as (
    select s.version_no, s.st, jsonb_build_object('version_no', s.version_no, 'state', s.st, 'label', s.label, 'mime_type', s.mime_type, 'size_bytes', s.size_bytes,
             'content_hash', s.content_hash, 'uploaded_at', s.uploaded_at, 'signed_on', case when s.st = 'signed' then s.signed_on end,
             'amends_version_no', (select a.version_no from document_versions a where a.id = s.amends_version_id)) as doc
      from s where s.st <> 'withdrawn' and (v_priv or s.st in ('approved', 'signed')))
  select (select doc from j order by version_no desc limit 1), (select doc from j where st = 'signed' order by version_no desc limit 1) into v_cur, v_sig;
  return jsonb_build_object('as_of', v_ts, 'current', v_cur, 'signed', v_sig);
end $$;

-- Documents attached to a set of registered entities (invoker: the caller's row security decides what exists for them).
create function documents_of(p_ids text[], p_from date default null, p_to date default null, p_as_of timestamptz default null, p_signed_only boolean default false) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.dd desc nulls last, x.title), '[]'::jsonb) from (
    select d.document_date as dd, d.title,
           jsonb_build_object('document', (select er.institutional_id from entity_registry er where er.table_name = 'documents' and er.entity_id = d.id),
                              'title', d.title, 'type', dt.key, 'status', d.status, 'document_date', d.document_date, 'classification', d.effective_classification,
                              'relationships', (select jsonb_agg(jsonb_build_object('entity', dl.entity_institutional_id, 'role', dl.role) order by dl.linked_at) from document_links dl
                                                 where dl.document_id = d.id and dl.entity_institutional_id = any (p_ids) and dl.linked_at <= coalesce(p_as_of, now()) and (dl.removed_at is null or dl.removed_at > coalesce(p_as_of, now()))),
                              'version', document_version_as_of(d.id, p_as_of)) as j
      from documents d join document_types dt on dt.id = d.document_type_id
     where exists (select 1 from document_links dl where dl.document_id = d.id and dl.entity_institutional_id = any (p_ids) and dl.linked_at <= coalesce(p_as_of, now())
                      and (dl.removed_at is null or dl.removed_at > coalesce(p_as_of, now())))
       and d.created_at <= coalesce(p_as_of, now())
       and (p_from is null or d.document_date >= p_from) and (p_to is null or d.document_date <= p_to)
       and (not p_signed_only or (document_version_as_of(d.id, p_as_of) -> 'signed') is not null and (document_version_as_of(d.id, p_as_of) -> 'signed') <> 'null'::jsonb)) x
$$;

-- The entities that belong to an entity, as the caller can see them (client -> projects, contracts, quotes, invoices, tickets, assets; project -> the same)
create function document_family_ids(p_registry_id text) returns text[]
language plpgsql stable set search_path = public, pg_temp as $$
declare r entity_registry%rowtype; v_ids text[] := '{}';
begin
  select * into r from entity_registry where institutional_id = p_registry_id;
  if not found then return '{}'; end if;
  v_ids := array[r.institutional_id];
  if r.table_name = 'clients' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'projects'  and er.entity_id in (select id from projects  where client_id = r.entity_id))
      or (er.table_name = 'contracts' and er.entity_id in (select id from contracts where client_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes    where client_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices  where client_id = r.entity_id))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets   where client_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets    where client_id = r.entity_id));
  elsif r.table_name = 'projects' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'contracts' and er.entity_id in (select contract_id from contract_projects where project_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes   where project_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices where project_id = r.entity_id))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets  where project_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets   where project_id = r.entity_id));
  end if;
  return v_ids;
end $$;

-- Request -> registry -> entity (-> its family) -> authorization -> documents. No table or blob scan: links are found by institutional ID.
create function documents_for_entity(p_entity text, p_from date default null, p_to date default null, p_as_of timestamptz default null,
                                     p_include_children boolean default false, p_signed_only boolean default false) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare r entity_registry%rowtype; v_ids text[];
begin
  select * into r from entity_registry where institutional_id = upper(btrim(coalesce(p_entity, ''))) or ada_id = btrim(coalesce(p_entity, ''));
  if not found then perform security_note_lookup(p_entity, 'documents_for_entity'); return null; end if;
  v_ids := case when p_include_children then document_family_ids(r.institutional_id) else array[r.institutional_id] end;
  return documents_of(v_ids, p_from, p_to, p_as_of, p_signed_only);
end $$;

-- Time expressions are interpreted here (a request is not a date range); the caller passes the result on
create function period_resolve(p_expr text, p_ref date default current_date) returns daterange
language sql immutable as $$
  select case lower(btrim(p_expr))
    when 'today' then daterange(p_ref, p_ref, '[]')
    when 'yesterday' then daterange(p_ref - 1, p_ref - 1, '[]')
    when 'this_week' then daterange(date_trunc('week', p_ref)::date, (date_trunc('week', p_ref) + interval '6 days')::date, '[]')
    when 'last_week' then daterange((date_trunc('week', p_ref) - interval '7 days')::date, (date_trunc('week', p_ref) - interval '1 day')::date, '[]')
    when 'this_month' then daterange(date_trunc('month', p_ref)::date, (date_trunc('month', p_ref) + interval '1 month - 1 day')::date, '[]')
    when 'last_month' then daterange((date_trunc('month', p_ref) - interval '1 month')::date, (date_trunc('month', p_ref) - interval '1 day')::date, '[]')
    when 'this_quarter' then daterange(date_trunc('quarter', p_ref)::date, (date_trunc('quarter', p_ref) + interval '3 months - 1 day')::date, '[]')
    when 'last_quarter' then daterange((date_trunc('quarter', p_ref) - interval '3 months')::date, (date_trunc('quarter', p_ref) - interval '1 day')::date, '[]')
    when 'this_year' then daterange(date_trunc('year', p_ref)::date, (date_trunc('year', p_ref) + interval '1 year - 1 day')::date, '[]')
    when 'last_year' then daterange((date_trunc('year', p_ref) - interval '1 year')::date, (date_trunc('year', p_ref) - interval '1 day')::date, '[]')
  end
$$;

-- One document, every slice (invoker: row security decides). Metadata only - never the storage reference.
create function document_360(p_doc uuid) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare d documents%rowtype;
begin
  select * into d from documents where id = p_doc;
  if not found then perform document_note_denied(p_doc, 'view'); return null; end if;
  return jsonb_build_object(
    'identity', (select jsonb_build_object('institutional_id', er.institutional_id, 'entity_type', er.entity_type, 'origin_division_id', er.origin_division_id, 'origin_year', er.origin_year,
                          'current_division_id', er.current_division_id, 'status', er.status) from entity_registry er where er.table_name = 'documents' and er.entity_id = d.id),
    'record', jsonb_build_object('title', d.title, 'type', (select key from document_types where id = d.document_type_id), 'description', d.description, 'status', d.status,
                          'classification', d.effective_classification, 'critical', d.is_critical, 'document_date', d.document_date,
                          'owner', (select ada_id from staff where id = d.owner_staff_id), 'created_by', (select ada_id from staff where id = d.created_by), 'created_at', d.created_at,
                          'archived_at', d.archived_at, 'disposed_at', d.disposed_at),
    'retention', (select to_jsonb(x) - 'document_id' from document_retention_status x where x.document_id = d.id),
    'versions', coalesce((select jsonb_agg(jsonb_build_object('version_no', v.version_no, 'state', v.state, 'label', v.label, 'change_note', v.change_note, 'mime_type', v.mime_type,
                          'size_bytes', v.size_bytes, 'content_hash', v.content_hash, 'uploaded_by', (select ada_id from staff where id = v.uploaded_by), 'uploaded_at', v.uploaded_at,
                          'approved_at', v.approved_at, 'signed_on', v.signed_on, 'amends_version_no', (select a.version_no from document_versions a where a.id = v.amends_version_id),
                          'content_held', v.content_purged_at is null, 'integrity', (select i.last_result from document_version_integrity i where i.version_id = v.id)) order by v.version_no)
                          from document_versions v where v.document_id = d.id), '[]'),
    'relationships', coalesce((select jsonb_agg(jsonb_build_object('entity', dl.entity_institutional_id, 'entity_type', er.entity_type, 'role', dl.role, 'since', dl.linked_at,
                          'removed_at', dl.removed_at) order by dl.linked_at)
                          from document_links dl join entity_registry er on er.institutional_id = dl.entity_institutional_id where dl.document_id = d.id), '[]'),
    'publication', (select jsonb_build_object('state', p.state, 'public_ref', case when document_can(d.id, 'publish') then p.public_ref end, 'published_at', p.published_at)
                      from document_publications p where p.document_id = d.id and p.state in ('pending_approval', 'approved', 'published')),
    'access', jsonb_build_object('can_read', document_can(d.id, 'read'), 'can_download', document_can(d.id, 'download'), 'can_upload', document_can(d.id, 'upload'),
                          'can_edit', document_can(d.id, 'edit'), 'can_comment', document_can(d.id, 'comment'), 'can_share', document_can(d.id, 'share'),
                          'can_approve', document_can(d.id, 'approve'), 'can_publish', document_can(d.id, 'publish'), 'can_archive', document_can(d.id, 'archive')),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'kind', e.kind, 'by', (select ada_id from staff where id = e.actor_staff_id), 'detail', e.detail) order by e.id desc)
                          from (select * from document_events where document_id = d.id order by id desc limit 50) e), '[]'));
end $$;

-- ---------------------------------------------------------------------------
-- 360 views: a Documents section in client, project, staff and asset (each section is independently authorized by the documents' own row security)
-- ---------------------------------------------------------------------------
create or replace function client_360(p_client uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  c record;
begin
  select cl.*, d.name as owner_division_name into c
    from clients cl left join divisions d on d.id = cl.owner_division_id where cl.id = p_client;
  if not found then return null; end if;                         -- RLS: also null when the caller may not see it

  return jsonb_build_object(
    'overview', jsonb_build_object(
      'id', c.ada_id, 'name', c.name, 'legal_name', c.legal_name, 'trading_name', c.trading_name, 'type', c.client_type, 'status', c.status,
      'industry', c.industry, 'registration_number', c.registration_number, 'email', c.email, 'phone', c.phone, 'website', c.website,
      'address', c.address, 'city', c.city, 'country', c.country, 'billing_address', c.billing_address, 'social_links', c.social_links,
      'classification', c.classification, 'created_at', c.created_at,
      'owner', (select jsonb_build_object('id', s.ada_id, 'name', s.full_name) from client_staff cs join staff s on s.id = cs.staff_id
                 where cs.client_id = p_client and cs.assignment_role = 'owner')),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('contact', cc.ada_id, 'person', pe.ada_id, 'name', pe.full_name, 'email', pe.email,
                 'phone', pe.phone, 'role', cc.role_title, 'primary', cc.is_primary, 'billing', cc.is_billing, 'active', cc.is_active) order by cc.is_primary desc, pe.full_name)
               from client_contacts cc join people pe on pe.id = cc.person_id where cc.client_id = p_client), '[]'),
    'relationship', jsonb_build_object(
      'divisions', coalesce((select jsonb_agg(jsonb_build_object('code', d.key, 'name', d.name, 'status', cd.relationship_status, 'since', cd.since) order by d.sort_order)
                  from client_divisions cd join divisions d on d.id = cd.division_id where cd.client_id = p_client), '[]'),
      'services_purchased', coalesce((select jsonb_agg(x order by x ->> 'service') from (
                  select jsonb_build_object('service', s.name, 'service_id', s.ada_id, 'division', dv.key, 'quantity', sum(ps.quantity), 'spent', sum(ps.line_total), 'currency', ps.currency) x
                  from project_services ps join projects p on p.id = ps.project_id join services s on s.id = ps.service_id join divisions dv on dv.id = s.division_id
                  where p.client_id = p_client and p.status <> 'cancelled' group by s.id, s.name, s.ada_id, dv.key, ps.currency) q), '[]')),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.ada_id, 'name', p.name, 'status', p.status, 'priority', p.priority, 'division', d.key,
                 'start_date', p.start_date, 'due_date', p.due_date, 'completed_at', p.completed_at) order by p.created_at)
               from projects p join divisions d on d.id = p.lead_division_id where p.client_id = p_client and p.deleted_at is null), '[]'),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total, 'currency', q.currency,
                 'valid_until', q.valid_until, 'project', (select ada_id from projects where id = q.project_id)) order by q.created_at)
               from quotes q where q.client_id = p_client), '[]'),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('id', l.ada_id, 'title', l.title, 'status', l.status, 'division', d.key,
                 'service', (select name from services where id = l.requested_service_id), 'enquiries', (select count(*) from enquiries e where e.lead_id = l.id),
                 'created_at', l.created_at) order by l.created_at)
               from leads l join divisions d on d.id = l.division_id where l.client_id = p_client), '[]'),
    'quote_summary', (select jsonb_build_object('pending', count(*) filter (where status in ('draft', 'pending_approval', 'approved', 'sent')),
                 'accepted', count(*) filter (where status = 'accepted'), 'rejected', count(*) filter (where status = 'rejected'),
                 'accepted_value', coalesce(sum(total) filter (where status = 'accepted'), 0)) from quotes where client_id = p_client),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'record', a.record_ada_id, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'clients' and record_id = p_client)
                        or (table_name = 'client_contacts' and (new_data ->> 'client_id')::uuid = p_client)
                        or (table_name = 'client_divisions' and (new_data ->> 'client_id')::uuid = p_client)
                     order by id desc limit 25) a), '[]'),
    -- finance: authorisation slices of the SAME records (empty unless the viewer holds contracts.view / invoices.view / payments.view)
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', ct.ada_id, 'title', ct.title, 'status', ct.status, 'version', ct.current_version_no, 'currency', ct.currency,
                 'total', ctt.total, 'start_date', ctt.start_date, 'end_date', ctt.end_date, 'auto_renew', ctt.auto_renew, 'quote', (select ada_id from quotes where id = ct.quote_id)) order by ct.created_at)
               from contracts ct left join lateral contract_terms(ct.id) ctt on true where ct.client_id = p_client), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.ada_id, 'status', i.status, 'currency', i.currency, 'total', i.total, 'issue_date', i.issue_date,
                 'due_date', i.due_date, 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id), 'contract', (select ada_id from contracts where id = i.contract_id)) order by i.created_at)
               from invoices i where i.client_id = p_client), '[]'),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', py.ada_id, 'status', py.status, 'currency', py.currency, 'amount', py.amount, 'received_on', py.received_on,
                 'method', py.method, 'reconciliation', py.reconciliation, 'credit', b.credit) order by py.received_on, py.created_at)
               from payments py join payment_balances b on b.payment_id = py.id where py.client_id = p_client), '[]'),
    'finance_summary', (select jsonb_build_object(
                 'invoiced', coalesce(sum(i.total) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'paid', coalesce(sum(invoice_paid(i.id)) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'outstanding', coalesce(sum(invoice_balance(i.id)) filter (where i.status in ('issued', 'partially_paid')), 0),
                 'overdue', coalesce(sum(invoice_balance(i.id)) filter (where i.status in ('issued', 'partially_paid') and i.due_date < current_date), 0),
                 'unallocated_credit', (select coalesce(sum(credit), 0) from payment_balances where client_id = p_client and status = 'received'))
               from invoices i where i.client_id = p_client),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition, 'category', (select name from asset_categories where id = ast.category_id),
                 'project', (select ada_id from projects where id = ast.project_id)) order by ast.created_at) from assets ast where ast.client_id = p_client), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority, 'asset', (select ada_id from assets where id = tk.asset_id)) order by tk.created_at)
               from tickets tk where tk.client_id = p_client), '[]'),
    'documents', documents_of(document_family_ids((select institutional_id from entity_registry where table_name = 'clients' and entity_id = p_client))),
    'pending', jsonb_build_array('domains', 'communications'));
end $$;

create or replace function project_360(p_project uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare p record;
begin
  select pr.*, cl.name as client_name, cl.ada_id as client_ada_id, d.name as division_name, d.key as division_key into p
    from projects pr join clients cl on cl.id = pr.client_id join divisions d on d.id = pr.lead_division_id where pr.id = p_project;
  if not found then return null; end if;
  return jsonb_build_object(
    'overview', jsonb_build_object('id', p.ada_id, 'name', p.name, 'description', p.description, 'status', p.status, 'priority', p.priority,
                 'type', p.project_type, 'start_date', p.start_date, 'due_date', p.due_date, 'completed_at', p.completed_at, 'division', p.division_key),
    'client', jsonb_build_object('id', p.client_ada_id, 'name', p.client_name),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('contact', cc.ada_id, 'name', pe.full_name, 'email', pe.email, 'role', pc.role))
               from project_contacts pc join client_contacts cc on cc.id = pc.contact_id join people pe on pe.id = cc.person_id where pc.project_id = p_project), '[]'),
    'divisions', coalesce((select jsonb_agg(d.key order by d.sort_order) from project_divisions pd join divisions d on d.id = pd.division_id where pd.project_id = p_project), '[]'),
    'services', coalesce((select jsonb_agg(jsonb_build_object('service', s.name, 'service_id', s.ada_id, 'quantity', ps.quantity, 'unit_price', ps.unit_price,
                 'discount', ps.discount_amount, 'total', ps.line_total, 'currency', ps.currency, 'catalogue_price_used', ps.price_id is not null,
                 'override_reason', ps.price_override_reason, 'quote', (select q.ada_id from quote_lines l join quotes q on q.id = l.quote_id where l.id = ps.quote_line_id)) order by s.name)
               from project_services ps join services s on s.id = ps.service_id where ps.project_id = p_project), '[]'),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('id', q.ada_id, 'title', q.title, 'status', q.status, 'total', q.total, 'lead', (select ada_id from leads where id = q.lead_id))) from quotes q where q.project_id = p_project), '[]'),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'role', pm.member_role)) from project_members pm join staff s on s.id = pm.staff_id where pm.project_id = p_project), '[]'),
    'milestones', coalesce((select jsonb_agg(jsonb_build_object('title', m.title, 'due_date', m.due_date, 'status', m.status) order by m.sort_order, m.due_date) from milestones m where m.project_id = p_project), '[]'),
    'tasks', jsonb_build_object(
      'open', (select count(*) from tasks where project_id = p_project and status in ('todo', 'in_progress', 'blocked')),
      'done', (select count(*) from tasks where project_id = p_project and status = 'done'),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', t.ada_id, 'title', t.title, 'status', t.status, 'due_date', t.due_date, 'assignee', (select full_name from staff where id = t.assignee_id)) order by t.created_at)
                 from tasks t where t.project_id = p_project), '[]')),
    'budget', (select to_jsonb(f) - 'project_id' from project_financials f where f.project_id = p_project),     -- empty unless finance.view
    'portfolio', (select jsonb_build_object('id', e.ada_id, 'status', e.status, 'consent', e.client_consent) from portfolio_entries e where e.project_id = p_project),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where (table_name = 'projects' and record_id = p_project) order by id desc limit 25) a), '[]'),
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'title', c.title, 'status', c.status, 'total', t.total, 'currency', c.currency) order by c.created_at)
               from contract_projects cp join contracts c on c.id = cp.contract_id left join lateral contract_terms(c.id) t on true where cp.project_id = p_project), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.ada_id, 'status', i.status, 'total', i.total, 'currency', i.currency, 'due_date', i.due_date,
                 'paid', invoice_paid(i.id), 'balance', invoice_balance(i.id)) order by i.created_at)
               from invoices i where i.project_id = p_project
                  or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)), '[]'),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition) order by ast.created_at) from assets ast where ast.project_id = p_project), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.project_id = p_project), '[]'),
    'documents', documents_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'pending', jsonb_build_array('expenses', 'domains', 'websites', 'deliverables'));
end $$;

create or replace function staff_360(p_staff uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare s record;
begin
  select st.*, pos.title as position_title, d.name as division_name into s
    from staff st left join positions pos on pos.id = st.position_id left join divisions d on d.id = st.primary_division_id where st.id = p_staff;
  if not found then return null; end if;
  return jsonb_build_object(
    'profile', jsonb_build_object('id', s.ada_id, 'name', s.full_name, 'email', s.email, 'work_phone', s.work_phone, 'position', s.position_title,
                 'division', s.division_name, 'employment_status', s.employment_status, 'account_status', s.account_status, 'start_date', s.start_date, 'end_date', s.end_date),
    'assignments', coalesce((select jsonb_agg(jsonb_build_object('position', pos.title, 'division', d.name, 'from', a.started_on, 'to', a.ended_on, 'reason', a.reason) order by a.started_on desc)
               from staff_assignments a left join positions pos on pos.id = a.position_id left join divisions d on d.id = a.division_id where a.staff_id = p_staff), '[]'),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('role', r.name, 'scope', coalesce(d.name, 'organization-wide')))
               from staff_roles sr join roles r on r.id = sr.role_id left join divisions d on d.id = sr.division_id where sr.staff_id = p_staff), '[]'),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.ada_id, 'name', p.name, 'status', p.status, 'role', pm.member_role))
               from project_members pm join projects p on p.id = pm.project_id where pm.staff_id = p_staff), '[]'),
    'clients_owned', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'name', c.name, 'role', cs.assignment_role))
               from client_staff cs join clients c on c.id = cs.client_id where cs.staff_id = p_staff), '[]'),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.ada_id, 'title', t.title, 'status', t.status, 'due_date', t.due_date) order by t.due_date nulls last)
               from tasks t where t.assignee_id = p_staff and t.status in ('todo', 'in_progress', 'blocked')), '[]'),
    'onboarding', coalesce((select jsonb_agg(jsonb_build_object('kind', o.kind, 'title', o.title, 'status', o.status, 'due_date', o.due_date) order by o.created_at)
               from onboarding_tasks o where o.staff_id = p_staff), '[]'),
    'public_profile', (select jsonb_build_object('id', sp.ada_id, 'status', sp.status) from staff_profiles sp where sp.staff_id = p_staff),
    'hr', (select jsonb_build_object('emergency_contact', sp.emergency_contact_name) from staff_private sp where sp.staff_id = p_staff),   -- only with hr.view or self
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.occurred_at, 'action', a.action, 'table', a.table_name, 'changed', a.changed_fields) order by a.id desc)
               from (select * from audit_log where table_name = 'staff' and record_id = p_staff order by id desc limit 25) a), '[]'),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'condition', ast.condition, 'since', asg.started_at) order by asg.started_at)
               from asset_assignments asg join assets ast on ast.id = asg.asset_id where asg.staff_id = p_staff and asg.ended_at is null), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at)
               from tickets tk where tk.assignee_staff_id = p_staff and tk.status in ('open', 'in_progress', 'waiting')), '[]'),
    'documents', documents_of(array[(select institutional_id from entity_registry where table_name = 'staff' and entity_id = p_staff)]),
    'pending', jsonb_build_array('performance'));
end $$;

create or replace function asset_360(p_asset uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare a record;
begin
  select ast.*, cat.name as category_name, d.name as division_name, d.key as division_key, sp.name as supplier_name into a
    from assets ast join asset_categories cat on cat.id = ast.category_id join divisions d on d.id = ast.division_id left join suppliers sp on sp.id = ast.supplier_id where ast.id = p_asset;
  if not found then return null; end if;
  return jsonb_build_object(
    'overview', jsonb_build_object('id', a.ada_id, 'name', a.name, 'category', a.category_name, 'manufacturer', a.manufacturer, 'model', a.model, 'serial_number', a.serial_number,
                 'asset_tag', a.asset_tag, 'condition', a.condition, 'status', a.status, 'location', a.current_location, 'division', a.division_key, 'classification', a.classification,
                 'supplier', a.supplier_name, 'acquisition', jsonb_build_object('method', a.acquisition_method, 'date', a.acquisition_date, 'cost', a.acquisition_cost, 'currency', a.acquisition_currency)),
    'holder', (select jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'division', dv.key, 'since', g.started_at)
                 from asset_assignments g left join staff s on s.id = g.staff_id join divisions dv on dv.id = g.division_id where g.asset_id = p_asset and g.ended_at is null),
    'assignment_history', coalesce((select jsonb_agg(jsonb_build_object('staff', s.ada_id, 'name', s.full_name, 'division', dv.key, 'from', g.started_at, 'to', g.ended_at, 'reason', g.end_reason) order by g.started_at)
                 from asset_assignments g left join staff s on s.id = g.staff_id join divisions dv on dv.id = g.division_id where g.asset_id = p_asset), '[]'),
    'client', (select jsonb_build_object('id', cl.ada_id, 'name', cl.name) from clients cl where cl.id = a.client_id),
    'project', (select jsonb_build_object('id', pr.ada_id, 'name', pr.name) from projects pr where pr.id = a.project_id),
    'parent', (select jsonb_build_object('id', pa.ada_id, 'name', pa.name) from assets pa where pa.id = a.parent_asset_id),
    'components', coalesce((select jsonb_agg(jsonb_build_object('id', ch.ada_id, 'name', ch.name, 'status', ch.status) order by ch.created_at) from assets ch where ch.parent_asset_id = p_asset), '[]'),
    'warranties', coalesce((select jsonb_agg(jsonb_build_object('from', w.starts_on, 'to', w.ends_on, 'provider', (select name from suppliers where id = w.provider_id), 'reference', w.reference, 'voided', w.voided_at is not null) order by w.ends_on) from asset_warranties w where w.asset_id = p_asset), '[]'),
    'maintenance', coalesce((select jsonb_agg(jsonb_build_object('kind', m.kind, 'status', m.status, 'scheduled_for', m.scheduled_for, 'completed_at', m.completed_at, 'description', m.description, 'outcome', m.outcome, 'ticket', (select ada_id from tickets where id = m.ticket_id)) order by m.created_at) from asset_maintenance m where m.asset_id = p_asset), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.asset_id = p_asset), '[]'),
    'document_records', documents_of(array[(select institutional_id from entity_registry where table_name = 'assets' and entity_id = p_asset)]),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('kind', dc.kind, 'title', dc.title, 'ref', dc.document_ref) order by dc.added_at) from asset_documents dc where dc.asset_id = p_asset and dc.voided_at is null), '[]'),
    'finance', coalesce((select jsonb_agg(jsonb_build_object('relation', f.relation, 'invoice', (select ada_id from invoices where id = f.invoice_id), 'payment', (select ada_id from payments where id = f.payment_id))) from asset_finance_links f where f.asset_id = p_asset), '[]'),
    'retirement', (select to_jsonb(r) - 'asset_id' from asset_retirements r where r.asset_id = p_asset),
    'possible_duplicates', coalesce((select jsonb_agg(jsonb_build_object('reason', fl.reason, 'status', fl.status, 'other', (select ada_id from assets where id = case when fl.asset_id = p_asset then fl.other_asset_id else fl.asset_id end)))
                 from asset_duplicate_flags fl where p_asset in (fl.asset_id, fl.other_asset_id)), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', h.created_at, 'kind', h.kind, 'field', h.field, 'from', h.from_value, 'to', h.to_value, 'note', h.note) order by h.id desc)
                 from (select * from asset_history where asset_id = p_asset order by id desc limit 50) h), '[]'));
end $$;


-- ---------------------------------------------------------------------------
-- Public API: the controlled projection. Allow-listed fields only; routed through the registry; state is re-checked on every read.
-- No institutional ID, storage reference, uploader, internal title, classification, notes, links or other versions ever appear.
-- ---------------------------------------------------------------------------
alter table websites drop constraint websites_capabilities_check;
alter table websites add constraint websites_capabilities_check
  check (capabilities <@ array['vacancies.read', 'team.read', 'divisions.read', 'statistics.read', 'applications.submit', 'services.read',
                               'portfolio.read', 'contact.read', 'leads.submit', 'enquiries.submit', 'documents.read']);

create view document_publication_live as
  select p.id as publication_id, p.public_ref, p.public_title, p.public_description, p.published_at, p.document_id, p.version_id, dt.name as type_name,
         d.document_date, v.mime_type, v.size_bytes, v.content_hash
    from document_publications p
    join documents d on d.id = p.document_id
    join document_versions v on v.id = p.version_id
    join document_types dt on dt.id = d.document_type_id
    join entity_registry er on er.table_name = 'documents' and er.entity_id = d.id and er.entity_type = 'document' and er.status = 'active'
   where p.state = 'published' and document_publication_blockers(p.document_id, p.version_id) is null;
comment on view document_publication_live is 'Purpose: internal helper for the public API: publications that are published AND still eligible, resolved through the registry. Not granted to any API role.';
revoke all on document_publication_live from public, anon, authenticated;

create function public_api.documents(p_key_hash text, p_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'documents.read');
  return coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('ref', l.public_ref, 'title', l.public_title, 'description', l.public_description, 'type', l.type_name,
                      'document_date', l.document_date, 'published_at', l.published_at,
                      'file', jsonb_build_object('mime_type', l.mime_type, 'size_bytes', l.size_bytes, 'sha256', l.content_hash))) order by l.published_at desc, l.public_title)
                   from document_publication_live l where p_type is null or lower(l.type_name) = lower(p_type)), '[]'::jsonb);
end $$;
create function public_api.document(p_key_hash text, p_ref text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare j jsonb;
begin
  perform public_api.authorize(p_key_hash, 'documents.read');
  select jsonb_strip_nulls(jsonb_build_object('ref', l.public_ref, 'title', l.public_title, 'description', l.public_description, 'type', l.type_name,
                      'document_date', l.document_date, 'published_at', l.published_at,
                      'file', jsonb_build_object('mime_type', l.mime_type, 'size_bytes', l.size_bytes, 'sha256', l.content_hash))) into j
    from document_publication_live l where l.public_ref = p_ref;
  return j;
end $$;
revoke all on function public_api.documents(text, text), public_api.document(text, text) from public, anon, authenticated;
grant execute on function public_api.documents(text, text), public_api.document(text, text) to ada_public_api;

-- For the storage / delivery service ONLY (service_role): turns a public reference into the storage reference to sign. Re-validates state.
create function document_public_content_ref(p_ref text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('provider', v.storage_provider, 'key', v.storage_key, 'sha256', v.content_hash, 'mime_type', v.mime_type)
    from document_publication_live l join document_versions v on v.id = l.version_id where l.public_ref = p_ref and v.content_purged_at is null
$$;
revoke execute on function document_public_content_ref(text) from public, anon, authenticated;
grant execute on function document_public_content_ref(text) to service_role;
revoke execute on function document_disposal_confirm(uuid) from public, anon, authenticated;
grant execute on function document_disposal_confirm(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Backup / recovery: a manifest that proves a restore preserved records, content references, versions, relationships, classification, audit
-- ---------------------------------------------------------------------------
create function document_backup_manifest() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'documents', (select count(*) from documents),
    'versions', (select count(*) from document_versions),
    'links', (select count(*) from document_links),
    'events', (select count(*) from document_events),
    'holds', (select count(*) from document_holds),
    'publications', (select count(*) from document_publications),
    'records_md5', (select md5(coalesce(string_agg(concat_ws('|', r.institutional_id, d.status, d.classification, d.effective_classification, d.is_critical, d.division_id, d.retention_months, d.retention_start, d.title), ';' order by r.institutional_id), ''))
                      from documents d join entity_registry r on r.table_name = 'documents' and r.entity_id = d.id),
    'versions_md5', (select md5(coalesce(string_agg(concat_ws('|', document_id, version_no, state, content_hash, coalesce(storage_key, '-'), coalesce(storage_provider, '-'), size_bytes, signed_on), ';' order by document_id, version_no), '')) from document_versions),
    'links_md5', (select md5(coalesce(string_agg(concat_ws('|', document_id, entity_institutional_id, role, removed_at is null), ';' order by document_id, entity_institutional_id, role, linked_at), '')) from document_links),
    'events_md5', (select md5(coalesce(string_agg(concat_ws('|', document_id, kind, actor_staff_id), ';' order by id), '')) from document_events),
    'registry_md5', (select md5(coalesce(string_agg(concat_ws('|', institutional_id, entity_id, origin_division_id, origin_year, classification, status), ';' order by institutional_id), '')) from entity_registry where table_name = 'documents'))
$$;
revoke execute on function document_backup_manifest() from public, anon, authenticated;
grant execute on function document_backup_manifest() to service_role;

-- ---------------------------------------------------------------------------
-- Approval policies: separation of duties by default
-- ---------------------------------------------------------------------------
insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note) values
  ('document_version',     'documents.approve', false, true, 1, 'default'),
  ('document_publication', 'documents.approve', false, true, 1, 'default'),
  ('document_disposal',    'documents.dispose', false, true, 1, 'default');

-- ---------------------------------------------------------------------------
-- Grants and row-level security
-- ---------------------------------------------------------------------------
alter table retention_classes enable row level security;
alter table document_types enable row level security;
alter table documents enable row level security;
alter table document_versions enable row level security;
alter table document_links enable row level security;
alter table document_access enable row level security;
alter table document_holds enable row level security;
alter table document_comments enable row level security;
alter table document_integrity_checks enable row level security;
alter table document_disposals enable row level security;
alter table document_publications enable row level security;
alter table document_events enable row level security;
revoke all on retention_classes, document_types, documents, document_versions, document_links, document_access, document_holds, document_comments,
  document_integrity_checks, document_disposals, document_publications, document_events, document_retention_status, document_version_integrity from anon, authenticated;

grant select on retention_classes, document_types, documents, document_links, document_access, document_holds, document_comments, document_integrity_checks, document_publications,
  document_events, document_retention_status, document_version_integrity to authenticated;
grant select (id, document_id, version_no, state, label, change_note, amends_version_id, content_hash, size_bytes, mime_type, original_filename, content_purged_at,
              uploaded_by, uploaded_at, requested_by, approved_by, approved_at, signed_by, signed_at, signed_on, decision_note) on document_versions to authenticated;
grant select (id, document_id, state, reason, requested_by, requested_at, decided_by, decided_at, decision_note, executed_at) on document_disposals to authenticated;
grant insert, update on retention_classes, document_types to authenticated;
grant insert (document_id, entity_institutional_id, role) on document_links to authenticated;

create policy retention_classes_select on retention_classes for select to authenticated using (has_permission_anywhere('documents.view'));
create policy retention_classes_insert on retention_classes for insert to authenticated with check (has_permission('documents.configure'));
create policy retention_classes_update on retention_classes for update to authenticated using (has_permission('documents.configure')) with check (has_permission('documents.configure'));
create policy document_types_select on document_types for select to authenticated using (has_permission_anywhere('documents.view'));
create policy document_types_insert on document_types for insert to authenticated with check (has_permission('documents.configure'));
create policy document_types_update on document_types for update to authenticated using (has_permission('documents.configure')) with check (has_permission('documents.configure'));

create policy documents_select on documents for select to authenticated
  using (document_can_row(id, owner_staff_id, division_id, effective_classification, is_critical, client_deleted, status, 'view'));
create policy document_versions_select on document_versions for select to authenticated
  using (document_can(document_id, 'view') and (state in ('approved', 'signed', 'withdrawn') or coalesce(uploaded_by = current_staff_id(), false) or document_can(document_id, 'upload') or document_can(document_id, 'approve')));
create policy document_links_select on document_links for select to authenticated
  using (document_can(document_id, 'view') and exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id));
create policy document_links_insert on document_links for insert to authenticated
  with check (document_can(document_id, 'edit') and exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id));
create policy document_access_select on document_access for select to authenticated using (document_can(document_id, 'share'));
create policy document_holds_select on document_holds for select to authenticated using (document_can(document_id, 'view') and has_permission_anywhere('documents.legal_hold'));
create policy document_comments_select on document_comments for select to authenticated using (document_can(document_id, 'view'));
create policy document_integrity_checks_select on document_integrity_checks for select to authenticated using (document_can(document_id, 'view') and has_permission_anywhere('documents.configure'));
create policy document_disposals_select on document_disposals for select to authenticated using (document_can(document_id, 'view') and (has_permission_anywhere('documents.dispose') or has_permission_anywhere('documents.archive')));
create policy document_publications_select on document_publications for select to authenticated using (document_can(document_id, 'publish') or document_can(document_id, 'approve'));
create policy document_events_select on document_events for select to authenticated
  using (document_can(document_id, 'view') and (kind not in ('opened', 'downloaded') or has_permission('audit.view') or document_can(document_id, 'approve')));

revoke execute on function document_can_row(uuid, uuid, uuid, data_classification, boolean, boolean, document_status, text), document_can(uuid, text), document_on_hold(uuid),
  document_register(text, text, uuid, text, date, data_classification, boolean, text, uuid), document_add_version(uuid, text, text, text, bigint, text, text, text, text),
  document_version_transition(uuid, document_version_state, text, date), document_open(uuid, text, integer), document_update(uuid, jsonb),
  document_set_classification(uuid, data_classification, boolean, text), document_set_retention(uuid, text, date, text), document_transfer(uuid, uuid, text),
  document_archive(uuid, text), document_restore(uuid, text), document_link_add(uuid, text, text), document_link_remove(uuid, text), document_share(uuid, uuid, uuid, text[], timestamptz, text),
  document_unshare(uuid, text), document_comment_add(uuid, text, integer), document_hold_place(uuid, text), document_hold_release(uuid, text),
  document_record_integrity_check(uuid, text), document_relocate_content(uuid, text, text), document_request_disposal(uuid, text), document_disposal_decide(uuid, boolean, text),
  document_publication_request(uuid, integer, text, text), document_publication_decide(uuid, boolean, text), document_publish(uuid), document_unpublish(uuid, text),
  document_version_as_of(uuid, timestamptz), documents_of(text[], date, date, timestamptz, boolean), document_family_ids(text), documents_for_entity(text, date, date, timestamptz, boolean, boolean),
  period_resolve(text, date), document_360(uuid) from public, anon;
grant execute on function document_can_row(uuid, uuid, uuid, data_classification, boolean, boolean, document_status, text), document_can(uuid, text), document_on_hold(uuid),
  document_register(text, text, uuid, text, date, data_classification, boolean, text, uuid), document_add_version(uuid, text, text, text, bigint, text, text, text, text),
  document_version_transition(uuid, document_version_state, text, date), document_open(uuid, text, integer), document_update(uuid, jsonb),
  document_set_classification(uuid, data_classification, boolean, text), document_set_retention(uuid, text, date, text), document_transfer(uuid, uuid, text),
  document_archive(uuid, text), document_restore(uuid, text), document_link_add(uuid, text, text), document_link_remove(uuid, text), document_share(uuid, uuid, uuid, text[], timestamptz, text),
  document_unshare(uuid, text), document_comment_add(uuid, text, integer), document_hold_place(uuid, text), document_hold_release(uuid, text),
  document_record_integrity_check(uuid, text), document_relocate_content(uuid, text, text), document_request_disposal(uuid, text), document_disposal_decide(uuid, boolean, text),
  document_publication_request(uuid, integer, text, text), document_publication_decide(uuid, boolean, text), document_publish(uuid), document_unpublish(uuid, text),
  document_version_as_of(uuid, timestamptz), documents_of(text[], date, date, timestamptz, boolean), document_family_ids(text), documents_for_entity(text, date, date, timestamptz, boolean, boolean),
  period_resolve(text, date), document_360(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Audit: every table; and the audit log itself must not become a side channel for documents the reader cannot see
-- ---------------------------------------------------------------------------
do $$ begin
  perform attach_audit('retention_classes'); perform attach_audit('document_types'); perform attach_audit('documents'); perform attach_audit('document_versions');
  perform attach_audit('document_links'); perform attach_audit('document_access'); perform attach_audit('document_holds'); perform attach_audit('document_comments');
  perform attach_audit('document_integrity_checks'); perform attach_audit('document_disposals'); perform attach_audit('document_publications');
end $$;

create function audit_document_visible(p_table text, p_record uuid, p_new jsonb, p_old jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_table = 'documents' then document_can(p_record, 'view')
    when p_table in ('document_versions', 'document_links', 'document_access', 'document_holds', 'document_comments', 'document_integrity_checks', 'document_disposals', 'document_publications')
      then document_can(nullif(coalesce(p_new, p_old) ->> 'document_id', '')::uuid, 'view')
    else true end
$$;
revoke execute on function audit_document_visible(text, uuid, jsonb, jsonb) from public, anon;
grant execute on function audit_document_visible(text, uuid, jsonb, jsonb) to authenticated;
drop policy audit_select on audit_log;
create policy audit_select on audit_log for select to authenticated using (has_permission('audit.view') and audit_document_visible(table_name, record_id, new_data, old_data));
