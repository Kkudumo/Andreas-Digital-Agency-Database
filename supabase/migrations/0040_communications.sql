-- 0040_communications: the Communications module - an institutional communication RECORDS layer (not a mail server, not a messaging platform).
--  * Nothing here sends, receives or synchronises anything: no SMTP/IMAP, no WhatsApp/SMS gateway, no mailbox sync, no templates, no notifications.
--    A person records that an email arrived, a call took place or a meeting was held. `source_system` / `source_reference` on a message exist so a
--    future connector can record idempotently WITHOUT redesigning identity; they are not used by anything today.
--  * Identity: a THREAD (type `communication`) and every MESSAGE in it (type `communication_message`) are separate registered entities, minted only
--    through attach_entity. IDs are never chosen by a user, never change when the thread moves, are never reused. Nothing is ever deleted.
--  * Structure: thread -> messages (gap-free `seq`, assigned under the thread lock; `occurred_at` is when it happened, `recorded_at` when it was recorded).
--    Messages are IMMUTABLE for every caller; a body can only be purged by an approved disposal (its SHA-256 stays as evidence of what was held).
--  * Relationships are REFERENCES to registered entities (client, project, ticket, domain, contract, person, organization, staff, document ...):
--    thread-level `communication_links` (with linked/removed history), per-message `communication_participants` (a registered person / organization /
--    staff - or, only where the party is not yet a registered entity, an explicitly named SNAPSHOT of the address as typed) and `communication_attachments`
--    (a DOCUMENT reference: the file, its hash, versions, retention and holds all live in the Documents module).
--  * METADATA is not CONTENT. Seeing that "a communication exists around Project X" (type, dates, status, linked entities, counts) is `communications.view`.
--    Subject, participants, bodies, notes and the hash of a body are CONTENT: they are never granted to table readers (column privileges) and reach the
--    caller only through communication_read (which authorises and logs every read). Opening an attachment needs the communication right AND the
--    document's own right. Entity visibility, metadata, content, attachment and modification rights are five different questions.
--  * Classification: a thread inherits the strictest classification of everything it is linked to - linked entities, participants, attached documents
--    (a critical attached document makes the thread critical). Classification is applied IN ADDITION to authorization, never instead of it.
--  * Retention and legal holds reuse the Documents framework (retention_classes; the same hold semantics; the same two-person disposal approval);
--    a legal hold on the thread - or on any attached document - blocks disposal. Disposal removes content only (subject, bodies, notes, address snapshots);
--    identity, metadata, relationships, hashes and the event history stay.
--  * Not publishable. No public API, no public projection.
--  * The registry label is deliberately empty (a subject is content): Search finds communications by ID and metadata, and only reads content after
--    communication_read has authorised the caller.

insert into permissions (key, module, action, description, sensitivity) values
  ('communications.view', 'communications', 'view', 'Discover communication threads and read their metadata (own division; no message content, subject or participants)', 'internal'::data_classification),
  ('communications.read', 'communications', 'read', 'Read message content, subject and participants of communications (separate from metadata)', 'restricted'::data_classification),
  ('communications.attachments', 'communications', 'attachments', 'Open attachments of communications (the attachment''s own document rights also apply)', 'restricted'::data_classification),
  ('communications.create', 'communications', 'create', 'Start communication threads', 'internal'::data_classification),
  ('communications.append', 'communications', 'append', 'Record messages in a thread and attach documents', 'internal'::data_classification),
  ('communications.update', 'communications', 'update', 'Edit thread details and relationships; close and reopen threads', 'internal'::data_classification),
  ('communications.comment', 'communications', 'comment', 'Add internal notes to a communication', 'internal'::data_classification),
  ('communications.share', 'communications', 'share', 'Share a communication with named people or divisions', 'restricted'::data_classification),
  ('communications.archive', 'communications', 'archive', 'Archive and restore communications', 'restricted'::data_classification),
  ('communications.dispose', 'communications', 'dispose', 'Approve disposal of communications after retention', 'confidential'::data_classification),
  ('communications.view_critical', 'communications', 'view_critical', 'Open critical communications without an explicit grant', 'confidential'::data_classification),
  ('communications.legal_hold', 'communications', 'legal_hold', 'Place and release legal holds on communications', 'confidential'::data_classification),
  ('communications.configure', 'communications', 'configure', 'Manage communication types', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'communications.view'), ('administration_officer', 'communications.view'), ('finance_officer', 'communications.view'),
  ('division_lead', 'communications.view'), ('division_staff', 'communications.view'), ('auditor', 'communications.view'),
  ('ceo', 'communications.read'), ('administration_officer', 'communications.read'), ('division_lead', 'communications.read'), ('division_staff', 'communications.read'),
  ('ceo', 'communications.attachments'), ('administration_officer', 'communications.attachments'), ('division_lead', 'communications.attachments'), ('division_staff', 'communications.attachments'),
  ('ceo', 'communications.create'), ('administration_officer', 'communications.create'), ('division_lead', 'communications.create'), ('division_staff', 'communications.create'),
  ('ceo', 'communications.append'), ('administration_officer', 'communications.append'), ('division_lead', 'communications.append'), ('division_staff', 'communications.append'),
  ('ceo', 'communications.update'), ('administration_officer', 'communications.update'), ('division_lead', 'communications.update'),
  ('ceo', 'communications.comment'), ('administration_officer', 'communications.comment'), ('division_lead', 'communications.comment'), ('division_staff', 'communications.comment'),
  ('ceo', 'communications.share'), ('administration_officer', 'communications.share'), ('division_lead', 'communications.share'),
  ('ceo', 'communications.archive'), ('administration_officer', 'communications.archive'), ('division_lead', 'communications.archive'),
  ('ceo', 'communications.dispose'), ('ceo', 'communications.view_critical'), ('ceo', 'communications.legal_hold'),
  ('ceo', 'communications.configure'), ('administration_officer', 'communications.configure')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- Entity types: the thread is the (previously reserved) `communication`; each message gets its own type and code
-- ---------------------------------------------------------------------------
update entity_types set is_built = true, domain_table = 'communication_threads', division_col = 'division_id', status_col = 'status', class_col = 'effective_classification',
       label_col = null, view_fn = 'communication_360', description = 'Communication thread (a conversation: emails, calls, meetings, messages)' where key = 'communication';
insert into entity_types (key, prefix, family, is_built, domain_table, division_col, status_col, class_col, location_col, label_col, view_fn, description, id_code, publishable)
values ('communication_message', 'CMG', 'operations', true, 'communication_messages', 'division_id', 'status', 'effective_classification', null, null, null,
        'One recorded message / call / meeting inside a communication thread', 'CM', false);
insert into id_codebook (version, kind, code, meaning, family, note)
select 1, 'type', id_code, key, family, description from entity_types where key = 'communication_message';

create type communication_status as enum ('open', 'closed', 'archived', 'disposed');

-- Retention classes are the Documents framework's; Communications adds DATA to it, not a second mechanism
insert into retention_classes (key, name, period_months, description) values
  ('communications_standard', 'Communications - 5 years', 60, 'Routine business correspondence, calls and meetings'),
  ('communications_contractual_10y', 'Communications - 10 years', 120, 'Correspondence forming part of a contractual or legal record');

-- ---------------------------------------------------------------------------
-- Communication types (approved kinds of communication; configuration, data not code)
-- ---------------------------------------------------------------------------
create table communication_types (
  id                     uuid primary key default gen_random_uuid(),
  key                    text not null unique check (key ~ '^[a-z0-9_]+$'),
  name                   text not null,
  body_required          boolean not null default true,
  default_classification data_classification not null default 'internal',
  is_active              boolean not null default true,
  sort_order             integer not null default 100
);
comment on table communication_types is 'Purpose: the approved kinds of communication (email, phone call, meeting, SMS, instant message, letter ...). body_required says whether a message of this kind must carry content (a call may be recorded with its facts only). A new kind is data, added by communications.configure. [class: internal]';
insert into communication_types (key, name, body_required, sort_order) values
  ('email', 'Email', true, 10), ('phone_call', 'Phone call', false, 20), ('meeting', 'Meeting', false, 30), ('video_call', 'Video call', false, 35),
  ('sms', 'SMS', true, 40), ('instant_message', 'Instant message', true, 50), ('letter', 'Letter', true, 60), ('other', 'Other', false, 999);

-- ---------------------------------------------------------------------------
-- The thread: identity + metadata. Subject is CONTENT (column privileges keep it from metadata readers).
-- ---------------------------------------------------------------------------
create table communication_threads (
  id                       uuid primary key default gen_random_uuid(),
  subject                  text check (subject is null or btrim(subject) <> ''),
  subject_purged_at        timestamptz,
  division_id              uuid not null references divisions (id),
  owner_staff_id           uuid references staff (id),
  classification           data_classification not null default 'internal',
  effective_classification data_classification not null default 'internal',
  is_critical              boolean not null default false,
  effective_critical       boolean not null default false,
  client_deleted           boolean not null default false,
  status                   communication_status not null default 'open',
  retention_class_id       uuid not null references retention_classes (id),
  retention_months         integer check (retention_months > 0),
  retention_start          date not null default current_date,
  review_date              date,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  last_activity_at         timestamptz not null default now(),
  closed_at                timestamptz,
  archived_at              timestamptz,
  disposed_at              timestamptz
);
create index communication_threads_division_idx on communication_threads (division_id);
create index communication_threads_activity_idx on communication_threads (last_activity_at);
comment on table communication_threads is 'Purpose: the institutional RECORD of a conversation: permanent identity (registry), owning division, classification, status, retention. The subject is content and is readable only through communication_read. Relationships live in communication_links / participants / attachments and REFERENCE registered entities. Registered through attach_entity. [class: internal; inherits the strictest classification of everything it is linked to]';
comment on column communication_threads.subject is 'CONTENT: readable only through communication_read (column privileges withhold it from metadata readers; the registry carries no label). Purged by an approved disposal.';
comment on column communication_threads.division_id is 'CURRENT owning division. The ORIGIN division is fixed in the registry. Changes only through communication_transfer.';
comment on column communication_threads.effective_classification is 'Derived: the greater of the thread''s own classification and that of every live link, participant and attached document. Authorization reads this column.';
comment on column communication_threads.effective_critical is 'Derived: the thread is critical itself, or a linked / attached document is. Critical threads are invisible to everyone but the owner, explicit grantees and communications.view_critical holders.';
comment on column communication_threads.retention_months is 'SNAPSHOT: the class period when the thread was started or its retention was last set explicitly. NULL = permanent.';
do $$ begin perform attach_entity('communication_threads', 'communication'); end $$;
create trigger communication_threads_updated before update on communication_threads for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Messages: append-only. seq is gap-free per thread. The body (CONTENT) is hash-sealed.
-- ---------------------------------------------------------------------------
create table communication_messages (
  id                       uuid primary key default gen_random_uuid(),
  thread_id                uuid not null references communication_threads (id) on delete restrict,
  seq                      integer not null check (seq > 0),
  type_key                 text not null references communication_types (key),
  direction                text not null check (direction in ('inbound', 'outbound', 'internal', 'mutual')),
  occurred_at              timestamptz not null,
  ended_at                 timestamptz,
  recorded_at              timestamptz not null default now(),
  recorded_by              uuid references staff (id),
  recorded_txid            bigint not null default txid_current(),
  in_reply_to_message_id   uuid references communication_messages (id),
  body                     text,
  body_hash                text not null check (body_hash ~ '^[0-9a-f]{64}$'),
  body_purged_at           timestamptz,
  source_system            text check (source_system is null or source_system ~ '^[a-z0-9_.-]+$'),
  source_reference         text check (source_reference is null or btrim(source_reference) <> ''),
  division_id              uuid not null references divisions (id),
  effective_classification data_classification not null default 'internal',
  status                   text not null default 'recorded' check (status in ('recorded', 'purged')),
  unique (thread_id, seq),
  check (ended_at is null or ended_at >= occurred_at),
  check ((source_system is null) = (source_reference is null)),
  check (body is null or length(body) <= 200000),
  check (body_purged_at is null or body is null)
);
create unique index communication_messages_source_unique on communication_messages (thread_id, source_system, source_reference) where source_reference is not null;
create index communication_messages_thread_idx on communication_messages (thread_id, seq);
create index communication_messages_occurred_idx on communication_messages (thread_id, occurred_at);
comment on table communication_messages is 'Purpose: one recorded email / call / meeting / message. Append-only for every caller: only a mirror of the thread''s division / classification / status and an approved disposal''s body purge ever change a row. Registered through attach_entity (its own permanent institutional ID). [class: inherits the thread]';
comment on column communication_messages.body is 'CONTENT: readable only through communication_read. NULL = none recorded, or purged by an approved disposal (body_purged_at).';
comment on column communication_messages.body_hash is 'CONTENT-adjacent: SHA-256 of (message id || body) computed by the database at recording time. Permanent evidence of what was held. Withheld from metadata readers (a hash of a short body is a guessing oracle).';
comment on column communication_messages.occurred_at is 'When the communication happened (as stated by the person recording it). recorded_at is when it was recorded; seq is the order of recording.';
comment on column communication_messages.source_reference is 'For a future connector: an external message reference (idempotent per thread and source). Unused by anything today. Withheld from metadata readers.';
comment on column communication_messages.recorded_txid is 'The transaction that recorded the message; participants can be added only inside it.';
do $$ begin perform attach_entity('communication_messages', 'communication_message'); end $$;

-- ---------------------------------------------------------------------------
-- Participants: REFERENCES to registered entities. Only where a party is not (yet) a registered entity is the address kept, explicitly as a snapshot.
-- ---------------------------------------------------------------------------
create table communication_participants (
  id                      uuid primary key default gen_random_uuid(),
  message_id              uuid not null references communication_messages (id) on delete restrict,
  thread_id               uuid not null references communication_threads (id) on delete restrict,
  role                    text not null check (role in ('from', 'to', 'cc', 'bcc', 'caller', 'callee', 'organizer', 'attendee', 'other')),
  entity_institutional_id text references entity_registry (institutional_id),
  address_snapshot        text check (address_snapshot is null or btrim(address_snapshot) <> ''),
  address_purged_at       timestamptz,
  check (entity_institutional_id is not null or address_snapshot is not null or address_purged_at is not null)
);
create index communication_participants_message_idx on communication_participants (message_id);
create index communication_participants_entity_idx on communication_participants (entity_institutional_id) where entity_institutional_id is not null;
comment on table communication_participants is 'Purpose: who took part in a message, by REFERENCE to the registered person / organization / client / staff record. Names, e-mail addresses and phone numbers are not copied from those records. CONTENT: no table access for API users; reachable only through communication_read and the participant search. [class: inherits the thread]';
comment on column communication_participants.address_snapshot is 'SNAPSHOT: the address or number exactly as given for a party that is not (yet) a registered entity (a stranger''s email address). Never used as the live identity once a registered entity exists. Purged by an approved disposal.';

-- ---------------------------------------------------------------------------
-- Relationships, attachments, grants, holds, notes, disposals, events
-- ---------------------------------------------------------------------------
create table communication_links (
  id                      uuid primary key default gen_random_uuid(),
  thread_id               uuid not null references communication_threads (id) on delete restrict,
  entity_institutional_id text not null references entity_registry (institutional_id),
  role                    text not null default 'subject' check (role in ('subject', 'related', 'context')),
  linked_by               uuid references staff (id) default current_staff_id(),
  linked_at               timestamptz not null default now(),
  removed_at              timestamptz,
  removed_by              uuid references staff (id),
  removal_reason          text
);
create unique index communication_links_live_unique on communication_links (thread_id, entity_institutional_id, role) where removed_at is null;
create index communication_links_entity_idx on communication_links (entity_institutional_id) where removed_at is null;
create index communication_links_history_idx on communication_links (entity_institutional_id, linked_at);
comment on table communication_links is 'Purpose: which authoritative entities a thread concerns (client, project, ticket, domain, contract, person, organization, staff, document ... any registered entity except another communication). References by institutional ID only. Removal is soft so "what was this thread about then" stays answerable. [class: inherits the thread; a link is visible only if the thread AND the target are visible to the caller]';

create table communication_attachments (
  id             uuid primary key default gen_random_uuid(),
  thread_id      uuid not null references communication_threads (id) on delete restrict,
  message_id     uuid not null references communication_messages (id) on delete restrict,
  document_id    uuid not null references documents (id) on delete restrict,
  attached_by    uuid references staff (id) default current_staff_id(),
  attached_at    timestamptz not null default now(),
  removed_at     timestamptz,
  removed_by     uuid references staff (id),
  removal_reason text
);
create unique index communication_attachments_live_unique on communication_attachments (message_id, document_id) where removed_at is null;
create index communication_attachments_document_idx on communication_attachments (document_id) where removed_at is null;
create index communication_attachments_history_idx on communication_attachments (document_id, attached_at);
comment on table communication_attachments is 'Purpose: an attachment IS a Document. This row only references it: the file, its SHA-256, versions, classification, retention and legal holds all stay in the Documents module, and opening the file goes through document_open. Removal is soft. [class: inherits the thread; visible only to callers who can also see the document]';

create table communication_access (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references communication_threads (id) on delete restrict,
  staff_id    uuid references staff (id),
  division_id uuid references divisions (id),
  actions     text[] not null check (actions <@ array['view', 'read', 'attachment', 'comment'] and cardinality(actions) > 0),
  reason      text,
  granted_by  uuid references staff (id),
  granted_at  timestamptz not null default now(),
  expires_at  timestamptz,
  revoked_at  timestamptz,
  revoked_by  uuid references staff (id),
  check ((staff_id is null) <> (division_id is null))
);
create index communication_access_thread_idx on communication_access (thread_id) where revoked_at is null;
comment on table communication_access is 'Purpose: explicit, named, expiring grants on one thread (to a person or a division) for view / read / attachment / comment only. A grant adds to the permission model; it never overrides classification. [class: restricted]';

create table communication_holds (
  id             uuid primary key default gen_random_uuid(),
  thread_id      uuid not null references communication_threads (id) on delete restrict,
  reason         text not null check (btrim(reason) <> ''),
  placed_by      uuid references staff (id),
  placed_at      timestamptz not null default now(),
  released_by    uuid references staff (id),
  released_at    timestamptz,
  release_reason text
);
create index communication_holds_thread_idx on communication_holds (thread_id) where released_at is null;
comment on table communication_holds is 'Purpose: legal holds. While any hold is active the thread cannot be disposed, whatever its retention says. [class: confidential]';

create table communication_comments (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references communication_threads (id) on delete restrict,
  message_id uuid references communication_messages (id),
  author_id  uuid references staff (id),
  body       text check (body is null or btrim(body) <> ''),
  purged_at  timestamptz,
  created_at timestamptz not null default now(),
  check (body is not null or purged_at is not null)
);
create index communication_comments_thread_idx on communication_comments (thread_id, created_at);
comment on table communication_comments is 'Purpose: internal notes on a thread or one of its messages (not part of the communication itself). CONTENT: readable only through communication_read. Append-only; body purged only by an approved disposal. [class: inherits the thread]';

create table communication_disposals (
  id            uuid primary key default gen_random_uuid(),
  thread_id     uuid not null references communication_threads (id) on delete restrict,
  state         text not null default 'requested' check (state in ('requested', 'rejected', 'executed')),
  reason        text not null check (btrim(reason) <> ''),
  requested_by  uuid references staff (id),
  requested_at  timestamptz not null default now(),
  decided_by    uuid references staff (id),
  decided_at    timestamptz,
  decision_note text,
  purge_summary jsonb
);
create unique index communication_disposals_one_open on communication_disposals (thread_id) where state = 'requested';
comment on table communication_disposals is 'Purpose: disposal workflow. A person requests (once retention has elapsed, no legal hold on the thread or any attached document, thread archived); a DIFFERENT person with communications.dispose approves; approval removes the content (subject, bodies, notes, address snapshots) and records how much was removed. Identity, metadata, relationships, hashes and history remain. [class: confidential]';

create table communication_events (
  id             bigint generated always as identity primary key,
  thread_id      uuid not null references communication_threads (id) on delete restrict,
  message_id     uuid references communication_messages (id),
  kind           text not null check (kind in ('created', 'metadata', 'message_recorded', 'classification', 'classification_effective', 'link_added', 'link_removed',
                                               'attachment_added', 'attachment_removed', 'attachment_opened', 'shared', 'unshared', 'closed', 'reopened', 'archived',
                                               'restored', 'transferred', 'retention', 'hold_placed', 'hold_released', 'disposal_requested', 'disposal_decided', 'read', 'comment')),
  actor_staff_id uuid references staff (id),
  occurred_at    timestamptz not null default now(),
  detail         jsonb not null default '{}'::jsonb
);
create index communication_events_thread_idx on communication_events (thread_id, id);
comment on table communication_events is 'Purpose: append-only history of everything that happens to a thread - creation, each recorded message, metadata and classification changes (explicit and inherited), relationships, attachments, sharing, status changes, retention, holds, disposal and every READ of content - always with the acting staff member. Carries no content. [class: inherits the thread]';
create trigger communication_events_immutable before update or delete on communication_events for each row execute function append_only();
create trigger communication_comments_immutable_trg before delete on communication_comments for each row execute function append_only();

create function communication_log(p_thread uuid, p_message uuid, p_kind text, p_detail jsonb default '{}') returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into communication_events (thread_id, message_id, kind, actor_staff_id, detail) values (p_thread, p_message, p_kind, current_staff_id(), coalesce(p_detail, '{}'))
$$;
revoke execute on function communication_log(uuid, uuid, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Authorization: one decision per ACTION (metadata, content, attachments, writing and administration are different questions)
-- ---------------------------------------------------------------------------
create function communication_perm(p_action text) returns text
language sql immutable as $$
  select case p_action
    when 'view' then 'communications.view' when 'discover' then 'communications.view' when 'read' then 'communications.read'
    when 'attachment' then 'communications.attachments' when 'create' then 'communications.create' when 'append' then 'communications.append'
    when 'edit' then 'communications.update' when 'close' then 'communications.update' when 'reopen' then 'communications.update'
    when 'comment' then 'communications.comment' when 'share' then 'communications.share'
    when 'archive' then 'communications.archive' when 'restore' then 'communications.archive' when 'request_disposal' then 'communications.archive'
    when 'dispose' then 'communications.dispose' end
$$;

-- Staff identity + permission in the owning division (or ownership, or an explicit grant). Classification is applied separately and is never a
-- grant. Critical threads additionally need ownership, a grant, or communications.view_critical.
create function communication_gate(p_thread uuid, p_owner uuid, p_division uuid, p_critical boolean, p_action text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_me uuid := current_staff_id(); v_perm text := communication_perm(p_action); v_grant boolean; v_owner boolean;
begin
  if v_me is null or v_perm is null then return false; end if;
  select exists (select 1 from communication_access a
                  where a.thread_id = p_thread and a.revoked_at is null and (a.expires_at is null or a.expires_at > now()) and p_action = any (a.actions)
                    and (a.staff_id = v_me
                         or (a.division_id is not null and (exists (select 1 from staff_roles sr where sr.staff_id = v_me and sr.division_id = a.division_id)
                                                          or exists (select 1 from staff s where s.id = v_me and s.primary_division_id = a.division_id)))))
    into v_grant;
  v_owner := coalesce(p_owner = v_me, false) and p_action in ('view', 'discover', 'read', 'attachment', 'append', 'edit', 'close', 'reopen', 'comment');
  if coalesce(v_grant, false) or v_owner then return true; end if;
  if p_critical then return coalesce(has_permission('communications.view_critical') and has_permission(v_perm, p_division), false); end if;
  return coalesce(has_permission(v_perm, p_division), false);
end $$;

create function communication_can_row(p_thread uuid, p_owner uuid, p_division uuid, p_class data_classification, p_critical boolean, p_client_deleted boolean,
                                      p_status communication_status, p_action text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  -- classification and soft-deleted clients apply to every action; every action also needs the right to know the thread exists
  if not coalesce(classification_visible(p_class) and (not p_client_deleted or has_permission('records.view_deleted')), false) then return false; end if;
  if not coalesce(communication_gate(p_thread, p_owner, p_division, p_critical, 'view'), false) then return false; end if;
  if p_action in ('view', 'discover') then return true; end if;
  if p_status = 'disposed' then return false; end if;
  if p_status = 'archived' and p_action not in ('read', 'attachment', 'restore', 'request_disposal', 'dispose') then return false; end if;
  if p_status <> 'archived' and p_action in ('restore', 'request_disposal', 'dispose') then return false; end if;
  if p_status <> 'open' and p_action in ('append', 'close') then return false; end if;
  if p_status <> 'closed' and p_action = 'reopen' then return false; end if;
  return coalesce(communication_gate(p_thread, p_owner, p_division, p_critical, p_action), false);
end $$;

create function communication_can(p_thread uuid, p_action text default 'view') returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select communication_can_row(t.id, t.owner_staff_id, t.division_id, t.effective_classification, t.effective_critical, t.client_deleted, t.status, p_action)
                   from communication_threads t where t.id = p_thread), false)
$$;

-- Loads and locks a thread the caller may see. Hidden and missing threads are indistinguishable (same error).
create function communication_require(p_thread uuid, p_action text default 'view') returns communication_threads
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype;
begin
  select * into t from communication_threads where id = p_thread for update;
  if not found or not communication_can_row(t.id, t.owner_staff_id, t.division_id, t.effective_classification, t.effective_critical, t.client_deleted, t.status, 'view') then
    raise exception 'communication not found' using errcode = 'P0002';
  end if;
  if p_action not in ('view', 'discover') and not communication_can_row(t.id, t.owner_staff_id, t.division_id, t.effective_classification, t.effective_critical, t.client_deleted, t.status, p_action) then
    raise exception 'you are not permitted to % this communication', replace(p_action, '_', ' ') using errcode = '42501';
  end if;
  return t;
end $$;

create function communication_inst_id(p_thread uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select institutional_id from entity_registry where table_name = 'communication_threads' and entity_id = p_thread
$$;

create function communication_on_hold(p_thread uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select communication_can(p_thread, 'view') and exists (select 1 from communication_holds h where h.thread_id = p_thread and h.released_at is null)
$$;

-- The caller's own denied attempt, recorded with the real identifier (investigators see it; the caller learns nothing)
create function communication_note_denied(p_thread uuid, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform security_note_lookup(coalesce(communication_inst_id(p_thread), p_thread::text), 'communication.' || left(coalesce(p_action, 'view'), 24)); end $$;
revoke execute on function communication_note_denied(uuid, text) from public, anon;
grant execute on function communication_note_denied(uuid, text) to authenticated;

revoke execute on function communication_perm(text), communication_gate(uuid, uuid, uuid, boolean, text), communication_require(uuid, text), communication_inst_id(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Classification inheritance
-- ---------------------------------------------------------------------------
create function communication_threads_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cls data_classification := 'public'; v_pcls data_classification; v_crit boolean := false; v_del boolean := false; x record;
begin
  -- live links (entities, including documents linked as entities)
  for x in select r.classification, r.table_name, r.entity_id from communication_links l join entity_registry r on r.institutional_id = l.entity_institutional_id
            where l.thread_id = new.id and l.removed_at is null loop
    v_cls := greatest(v_cls, x.classification);
    if x.table_name = 'clients' then v_del := v_del or exists (select 1 from clients c where c.id = x.entity_id and c.deleted_at is not null);
    elsif x.table_name = 'projects' then v_del := v_del or exists (select 1 from projects p where p.id = x.entity_id and p.deleted_at is not null);
    elsif x.table_name = 'documents' then
      v_crit := v_crit or exists (select 1 from documents d where d.id = x.entity_id and d.is_critical);
      v_del := v_del or exists (select 1 from documents d where d.id = x.entity_id and d.client_deleted);
    end if;
  end loop;
  -- participants that are registered entities
  select coalesce(max(r.classification), 'public'), v_del or coalesce(bool_or(case r.table_name when 'clients' then exists (select 1 from clients c where c.id = r.entity_id and c.deleted_at is not null)
                                                                                               when 'projects' then exists (select 1 from projects p where p.id = r.entity_id and p.deleted_at is not null) else false end), false)
    into v_pcls, v_del
    from communication_participants cp join entity_registry r on r.institutional_id = cp.entity_institutional_id where cp.thread_id = new.id;
  v_cls := greatest(v_cls, v_pcls);
  -- live attachments are documents: the thread can never be a weaker path than any of them
  select greatest(v_cls, coalesce(max(d.effective_classification), 'public')), v_crit or coalesce(bool_or(d.is_critical), false), v_del or coalesce(bool_or(d.client_deleted), false)
    into v_cls, v_crit, v_del
    from communication_attachments a join documents d on d.id = a.document_id where a.thread_id = new.id and a.removed_at is null;
  new.effective_classification := greatest(new.classification, v_cls);
  new.effective_critical := new.is_critical or v_crit;
  new.client_deleted := v_del;
  return new;
end $$;
create trigger communication_threads_inherit_trg before insert or update on communication_threads for each row execute function communication_threads_inherit();

-- ---------------------------------------------------------------------------
-- Guards: the record's rules hold for every caller (including the database owner and the service role)
-- ---------------------------------------------------------------------------
create function communication_threads_guard() returns trigger
language plpgsql as $$
declare v_attached_hold boolean;
begin
  if tg_op = 'DELETE' then raise exception 'communications are never deleted; archive them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    if coalesce(current_setting('ada.communication_start', true), '') <> 'on' then raise exception 'a communication is started only through communication_start' using errcode = '42501'; end if;
    new.created_by := coalesce(new.created_by, current_staff_id());
    new.status := 'open';
    new.last_activity_at := now();
    return new;
  end if;
  if old.status = 'disposed' and (to_jsonb(new) - array['updated_at', 'effective_classification', 'effective_critical', 'client_deleted']) is distinct from (to_jsonb(old) - array['updated_at', 'effective_classification', 'effective_critical', 'client_deleted']) then
    raise exception 'a disposed communication is a closed record' using errcode = '42501';
  end if;
  if (new.created_at, new.created_by) is distinct from (old.created_at, old.created_by) then
    raise exception 'a communication''s creator and creation time are permanent' using errcode = '42501';
  end if;
  if new.division_id is distinct from old.division_id and coalesce(current_setting('ada.communication_transfer', true), '') <> 'on' then
    raise exception 'a communication changes division only through communication_transfer' using errcode = '42501';
  end if;
  if (new.retention_class_id, new.retention_months, new.retention_start) is distinct from (old.retention_class_id, old.retention_months, old.retention_start)
     and coalesce(current_setting('ada.communication_retention', true), '') <> 'on' then
    raise exception 'retention is changed only through communication_set_retention' using errcode = '42501';
  end if;
  if (new.subject_purged_at is distinct from old.subject_purged_at or (new.subject is null and old.subject is not null))
     and coalesce(current_setting('ada.communication_disposal', true), '') <> 'on' then
    raise exception 'the subject is removed only by an approved disposal' using errcode = '42501';
  end if;
  if new.last_activity_at is distinct from old.last_activity_at and coalesce(current_setting('ada.communication_record', true), '') <> 'on' then
    raise exception 'last activity follows recorded messages' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'open' and new.status in ('closed', 'archived')) or (old.status = 'closed' and new.status in ('open', 'archived'))
         or (old.status = 'archived' and new.status in ('closed', 'disposed'))) then
      raise exception 'invalid communication status change % -> %', old.status, new.status using errcode = '23514';
    end if;
    if new.status = 'disposed' then
      if coalesce(current_setting('ada.communication_disposal', true), '') <> 'on' then raise exception 'a communication is disposed only through an approved disposal' using errcode = '42501'; end if;
      if old.retention_months is null then raise exception 'a permanent record is never disposed' using errcode = '42501'; end if;
      if old.retention_start + make_interval(months => old.retention_months) > current_date then raise exception 'the retention period has not elapsed' using errcode = '42501'; end if;
      if exists (select 1 from communication_holds h where h.thread_id = old.id and h.released_at is null) then raise exception 'a legal hold prevents disposal' using errcode = '42501'; end if;
      select exists (select 1 from communication_attachments a join document_holds h on h.document_id = a.document_id and h.released_at is null where a.thread_id = old.id and a.removed_at is null) into v_attached_hold;
      if v_attached_hold then raise exception 'a legal hold on an attached document prevents disposal' using errcode = '42501'; end if;
    end if;
    new.closed_at := case when new.status = 'closed' then now() when new.status = 'open' then null else old.closed_at end;
    new.archived_at := case when new.status = 'archived' then now() when new.status in ('closed', 'open') then null else old.archived_at end;
    new.disposed_at := case when new.status = 'disposed' then now() else old.disposed_at end;
  end if;
  return new;
end $$;
create trigger communication_threads_guard_trg before insert or update or delete on communication_threads for each row execute function communication_threads_guard();

-- Messages: recorded only by communication_message_record, gap-free numbering under the thread lock, immutable afterwards
create function communication_messages_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; v_next integer;
begin
  if tg_op = 'DELETE' then raise exception 'messages are never deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    if coalesce(current_setting('ada.communication_record', true), '') <> 'on' then raise exception 'a message is recorded only through communication_message_add' using errcode = '42501'; end if;
    select * into t from communication_threads where id = new.thread_id for update;
    select coalesce(max(seq), 0) + 1 into v_next from communication_messages where thread_id = new.thread_id;
    new.seq := v_next;
    new.recorded_at := now();
    new.recorded_txid := txid_current();
    new.recorded_by := coalesce(new.recorded_by, current_staff_id());
    new.division_id := t.division_id;
    new.effective_classification := t.effective_classification;
    new.status := 'recorded';
    new.body_purged_at := null;
    new.body_hash := encode(extensions.digest(convert_to(new.id::text || '|' || coalesce(new.body, ''), 'UTF8'), 'sha256'), 'hex');
    return new;
  end if;
  if (new.id, new.thread_id, new.seq, new.type_key, new.direction, new.occurred_at, new.ended_at, new.recorded_at, new.recorded_by, new.recorded_txid, new.in_reply_to_message_id,
      new.body_hash, new.source_system, new.source_reference)
     is distinct from (old.id, old.thread_id, old.seq, old.type_key, old.direction, old.occurred_at, old.ended_at, old.recorded_at, old.recorded_by, old.recorded_txid, old.in_reply_to_message_id,
      old.body_hash, old.source_system, old.source_reference) then
    raise exception 'a recorded message is permanent' using errcode = '42501';
  end if;
  if (new.body, new.body_purged_at) is distinct from (old.body, old.body_purged_at) then
    if not (coalesce(current_setting('ada.communication_disposal', true), '') = 'on' and old.body_purged_at is null and new.body is null and new.body_purged_at is not null) then
      raise exception 'a message body is removed only by an approved disposal' using errcode = '42501';
    end if;
  end if;
  if (new.division_id, new.effective_classification) is distinct from (old.division_id, old.effective_classification) and coalesce(current_setting('ada.communication_mirror', true), '') <> 'on' then
    raise exception 'a message follows its thread''s division and classification' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (new.status = 'purged' and old.status = 'recorded' and new.body_purged_at is not null) then
    raise exception 'invalid message status change' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger communication_messages_guard_trg before insert or update or delete on communication_messages for each row execute function communication_messages_guard();

-- Participants: only inside the transaction that recorded the message (and only by reference or as a named snapshot); otherwise permanent
create function communication_participants_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare m communication_messages%rowtype;
begin
  if tg_op = 'DELETE' then raise exception 'participants are never deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    -- the same refusal whether the message is missing, hidden or recorded earlier: nothing about it is revealed
    select * into m from communication_messages where id = new.message_id and recorded_txid = txid_current();
    if not found then raise exception 'participants are added only when a message is recorded' using errcode = '42501'; end if;
    new.thread_id := m.thread_id;
    new.address_purged_at := null;
    return new;
  end if;
  if (new.id, new.message_id, new.thread_id, new.role, new.entity_institutional_id) is distinct from (old.id, old.message_id, old.thread_id, old.role, old.entity_institutional_id)
     or (new.address_snapshot is distinct from old.address_snapshot and not (coalesce(current_setting('ada.communication_disposal', true), '') = 'on' and new.address_snapshot is null and new.address_purged_at is not null)) then
    raise exception 'a participant is permanent; an address is removed only by an approved disposal' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger communication_participants_guard_trg before insert or update or delete on communication_participants for each row execute function communication_participants_guard();

-- a participant must be a registered party, never another communication; checked AFTER the row-security check (it concerns only visible data)
create function communication_participants_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.entity_institutional_id is not null and exists (select 1 from entity_registry r where r.institutional_id = new.entity_institutional_id and r.entity_type in ('communication', 'communication_message')) then
    raise exception 'a communication cannot be a participant' using errcode = '23514';
  end if;
  update communication_threads set classification = classification where id = new.thread_id;
  return null;
end $$;
create trigger communication_participants_after_trg after insert on communication_participants for each row execute function communication_participants_after();

create function communication_comments_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    if (new.id, new.thread_id, new.message_id, new.author_id, new.created_at) is distinct from (old.id, old.thread_id, old.message_id, old.author_id, old.created_at)
       or not (coalesce(current_setting('ada.communication_disposal', true), '') = 'on' and new.body is null and new.purged_at is not null and old.purged_at is null) then
      raise exception 'notes are permanent; a body is removed only by an approved disposal' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger communication_comments_guard_trg before update on communication_comments for each row execute function communication_comments_guard();

create function communication_links_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'links are never deleted: they are removed with a reason, so history stays answerable' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.linked_by := coalesce(new.linked_by, current_staff_id());
    if new.removed_at is not null then raise exception 'a link starts live' using errcode = '23514'; end if;
    return new;
  end if;
  if (new.thread_id, new.entity_institutional_id, new.role, new.linked_by, new.linked_at) is distinct from (old.thread_id, old.entity_institutional_id, old.role, old.linked_by, old.linked_at)
     or old.removed_at is not null then
    raise exception 'a link is permanent; it can only be removed once, with a reason' using errcode = '42501';
  end if;
  if new.removed_at is not null and coalesce(btrim(new.removal_reason), '') = '' then raise exception 'a reason is required to remove a link' using errcode = '23514'; end if;
  return new;
end $$;
create trigger communication_links_guard_trg before insert or update or delete on communication_links for each row execute function communication_links_guard();

create function communication_links_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.entity_institutional_id is not null and exists (select 1 from entity_registry r where r.institutional_id = new.entity_institutional_id and r.entity_type in ('communication', 'communication_message')) then
    raise exception 'a communication cannot be linked to another communication' using errcode = '23514';
  end if;
  update communication_threads set classification = classification where id = new.thread_id;
  perform communication_log(new.thread_id, null, case when tg_op = 'INSERT' then 'link_added' else 'link_removed' end,
                            jsonb_build_object('entity', new.entity_institutional_id, 'role', new.role, 'reason', new.removal_reason));
  return null;
end $$;
create trigger communication_links_after_trg after insert or update on communication_links for each row execute function communication_links_after();

create function communication_attachments_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare m communication_messages%rowtype;
begin
  if tg_op = 'DELETE' then raise exception 'attachments are never deleted: they are removed with a reason' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    select * into m from communication_messages where id = new.message_id;
    if found then new.thread_id := m.thread_id; end if;       -- a missing or foreign message simply leaves nothing for the row-security check to approve
    new.attached_by := coalesce(new.attached_by, current_staff_id());
    if new.removed_at is not null then raise exception 'an attachment starts live' using errcode = '23514'; end if;
    return new;
  end if;
  if (new.thread_id, new.message_id, new.document_id, new.attached_by, new.attached_at) is distinct from (old.thread_id, old.message_id, old.document_id, old.attached_by, old.attached_at)
     or old.removed_at is not null then
    raise exception 'an attachment is permanent; it can only be removed once, with a reason' using errcode = '42501';
  end if;
  if new.removed_at is not null and coalesce(btrim(new.removal_reason), '') = '' then raise exception 'a reason is required to remove an attachment' using errcode = '23514'; end if;
  return new;
end $$;
create trigger communication_attachments_guard_trg before insert or update or delete on communication_attachments for each row execute function communication_attachments_guard();

create function communication_attachments_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update communication_threads set classification = classification where id = new.thread_id;
  perform communication_log(new.thread_id, new.message_id, case when tg_op = 'INSERT' then 'attachment_added' else 'attachment_removed' end,
                            jsonb_build_object('document', (select institutional_id from entity_registry where table_name = 'documents' and entity_id = new.document_id), 'reason', new.removal_reason));
  return null;
end $$;
create trigger communication_attachments_after_trg after insert or update on communication_attachments for each row execute function communication_attachments_after();

create function communication_access_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'grants are never deleted: they are revoked' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and ((new.thread_id, new.staff_id, new.division_id, new.actions, new.granted_by, new.granted_at, new.expires_at)
                           is distinct from (old.thread_id, old.staff_id, old.division_id, old.actions, old.granted_by, old.granted_at, old.expires_at) or old.revoked_at is not null) then
    raise exception 'a grant can only be revoked' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger communication_access_guard_trg before update or delete on communication_access for each row execute function communication_access_guard();

create function communication_holds_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'holds are never deleted: they are released' using errcode = '42501'; end if;
  if (new.thread_id, new.reason, new.placed_by, new.placed_at) is distinct from (old.thread_id, old.reason, old.placed_by, old.placed_at) or old.released_at is not null then
    raise exception 'a hold can only be released, once' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger communication_holds_guard_trg before update or delete on communication_holds for each row execute function communication_holds_guard();

create function communication_disposals_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'disposal records are permanent' using errcode = '42501'; end if;
  if (new.thread_id, new.reason, new.requested_by, new.requested_at) is distinct from (old.thread_id, old.reason, old.requested_by, old.requested_at) or old.state <> 'requested' then
    raise exception 'a decided disposal is permanent' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger communication_disposals_guard_trg before update or delete on communication_disposals for each row execute function communication_disposals_guard();

-- Consequences of a thread change: messages mirror division / classification / status; effective classification changes are part of the history
create function communication_threads_after_update() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (new.division_id, new.effective_classification) is distinct from (old.division_id, old.effective_classification) then
    perform set_config('ada.communication_mirror', 'on', true);
    update communication_messages set division_id = new.division_id, effective_classification = new.effective_classification where thread_id = new.id;
    perform set_config('ada.communication_mirror', 'off', true);
  end if;
  if new.effective_classification is distinct from old.effective_classification or new.effective_critical is distinct from old.effective_critical then
    perform communication_log(new.id, null, 'classification_effective', jsonb_build_object('from', old.effective_classification, 'to', new.effective_classification,
                                                                                         'critical_from', old.effective_critical, 'critical_to', new.effective_critical));
  end if;
  return null;
end $$;
create trigger communication_threads_after_update_trg after update on communication_threads for each row execute function communication_threads_after_update();

-- Dependents follow their entities (classification through the registry sync and the documents trigger; deletion here)
create function communications_follow_entity() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update communication_threads set classification = classification
   where id in (select l.thread_id from communication_links l join entity_registry r on r.institutional_id = l.entity_institutional_id
                 where r.table_name = tg_table_name and r.entity_id = new.id and l.removed_at is null
                union
                select cp.thread_id from communication_participants cp join entity_registry r on r.institutional_id = cp.entity_institutional_id
                 where r.table_name = tg_table_name and r.entity_id = new.id);
  return null;
end $$;
create trigger communications_follow_client_trg after update of deleted_at on clients for each row execute function communications_follow_entity();
create trigger communications_follow_project_trg after update of deleted_at on projects for each row execute function communications_follow_entity();

create function communications_follow_document() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update communication_threads set classification = classification
   where id in (select a.thread_id from communication_attachments a where a.document_id = new.id and a.removed_at is null
                union
                select l.thread_id from communication_links l join entity_registry r on r.institutional_id = l.entity_institutional_id
                 where r.table_name = 'documents' and r.entity_id = new.id and l.removed_at is null);
  return null;
end $$;
create trigger communications_follow_document_trg after update of effective_classification, is_critical, client_deleted on documents for each row execute function communications_follow_document();

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
      update domains set classification = classification
       where id in (select dr.domain_id from domain_relations dr where dr.entity_institutional_id = r.institutional_id and dr.valid_to is null);
      update communication_threads set classification = classification
       where id in (select l.thread_id from communication_links l where l.entity_institutional_id = r.institutional_id and l.removed_at is null
                    union select cp.thread_id from communication_participants cp where cp.entity_institutional_id = r.institutional_id);
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Commands: start a thread, record a message, read, open an attachment
-- ---------------------------------------------------------------------------
create function communication_start(p_division uuid, p_subject text default null, p_classification data_classification default null, p_critical boolean default null,
                                    p_retention_class text default null, p_owner uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare rc retention_classes%rowtype; v_me uuid := current_staff_id(); v_cls data_classification; v_crit boolean; v_id uuid; v_owner uuid; e communication_threads%rowtype;
begin
  if v_me is null then raise exception 'only active staff start communications' using errcode = '42501'; end if;
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('communications.create', p_division) then raise exception 'communications.create is required in that division' using errcode = '42501'; end if;
  v_cls := coalesce(p_classification, 'internal');
  v_crit := coalesce(p_critical, false);
  if v_cls <> 'internal' and not has_permission('records.classify') then raise exception 'records.classify is required to set a classification other than internal' using errcode = '42501'; end if;
  if v_crit and not has_permission('communications.view_critical') then raise exception 'communications.view_critical is required to start a critical communication' using errcode = '42501'; end if;
  if not classification_visible(v_cls) then raise exception 'you cannot start a communication above your own classification clearance' using errcode = '42501'; end if;
  if p_retention_class is not null and not has_permission('communications.configure') then raise exception 'communications.configure is required to choose a retention class' using errcode = '42501'; end if;
  select * into rc from retention_classes where key = coalesce(p_retention_class, 'communications_standard') and is_active;
  if not found then raise exception 'unknown retention class' using errcode = '23514'; end if;
  v_owner := coalesce(p_owner, v_me);
  if not exists (select 1 from staff where id = v_owner and account_status = 'active' and deleted_at is null) then raise exception 'the owner must be an active staff member' using errcode = '23514'; end if;
  perform set_config('ada.communication_start', 'on', true);
  insert into communication_threads (subject, division_id, owner_staff_id, classification, is_critical, retention_class_id, retention_months, retention_start)
  values (nullif(btrim(p_subject), ''), p_division, v_owner, v_cls, v_crit, rc.id, rc.period_months, current_date) returning * into e;
  perform set_config('ada.communication_start', 'off', true);
  perform communication_log(e.id, null, 'created', jsonb_build_object('division', p_division, 'retention', rc.key));
  return jsonb_build_object('id', e.id, 'institutional_id', communication_inst_id(e.id), 'status', 'open', 'origin_division_id', p_division, 'classification', e.effective_classification);
end $$;

-- Records ONE message (no participants, no attachments - communication_message_add adds those under the caller's own row security)
create function communication_message_record(p_thread uuid, p_type text, p_direction text, p_occurred_at timestamptz, p_body text default null, p_ended_at timestamptz default null,
                                             p_reply_to uuid default null, p_source_system text default null, p_source_reference text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; ty communication_types%rowtype; m communication_messages%rowtype; v_id uuid;
begin
  t := communication_require(p_thread, 'view');
  if t.status <> 'open' then
    if not communication_can_row(t.id, t.owner_staff_id, t.division_id, t.effective_classification, t.effective_critical, t.client_deleted, t.status, 'edit') then
      raise exception 'you are not permitted to append to this communication' using errcode = '42501';
    end if;
    raise exception 'the communication is % - reopen it to record more' , t.status using errcode = '23514';
  end if;
  t := communication_require(p_thread, 'append');
  select * into ty from communication_types where key = p_type and is_active;
  if not found then raise exception 'unknown communication type' using errcode = '23514'; end if;
  if p_direction is null or p_direction not in ('inbound', 'outbound', 'internal', 'mutual') then raise exception 'direction must be inbound, outbound, internal or mutual' using errcode = '23514'; end if;
  if p_occurred_at is null then raise exception 'when it happened is required' using errcode = '23514'; end if;
  if p_occurred_at > now() + interval '5 minutes' then raise exception 'a communication cannot have happened in the future' using errcode = '23514'; end if;
  if p_ended_at is not null and p_ended_at < p_occurred_at then raise exception 'it cannot end before it began' using errcode = '23514'; end if;
  if ty.body_required and coalesce(btrim(p_body), '') = '' then raise exception 'a % needs its content' , ty.name using errcode = '23514'; end if;
  if (p_source_system is null) <> (p_source_reference is null) then raise exception 'a source needs both a system and a reference' using errcode = '23514'; end if;
  if p_source_reference is not null then
    select * into m from communication_messages where thread_id = t.id and source_system = p_source_system and source_reference = p_source_reference;
    if found then
      return jsonb_build_object('message_id', m.id, 'institutional_id', (select institutional_id from entity_registry where table_name = 'communication_messages' and entity_id = m.id),
                                'thread', t.id, 'seq', m.seq, 'duplicate', true);
    end if;
  end if;
  if p_reply_to is not null and not exists (select 1 from communication_messages where id = p_reply_to and thread_id = t.id) then
    raise exception 'the message being replied to is not in this communication' using errcode = '23514';
  end if;
  v_id := gen_random_uuid();
  perform set_config('ada.communication_record', 'on', true);
  insert into communication_messages (id, thread_id, seq, type_key, direction, occurred_at, ended_at, in_reply_to_message_id, body, body_hash, source_system, source_reference, division_id)
  values (v_id, t.id, 1, ty.key, p_direction, p_occurred_at, p_ended_at, p_reply_to, nullif(p_body, ''), repeat('0', 64), p_source_system, p_source_reference, t.division_id) returning * into m;
  update communication_threads set last_activity_at = now() where id = t.id;
  perform set_config('ada.communication_record', 'off', true);
  perform communication_log(t.id, m.id, 'message_recorded', jsonb_build_object('seq', m.seq, 'type', ty.key, 'direction', p_direction));
  return jsonb_build_object('message_id', m.id, 'institutional_id', (select institutional_id from entity_registry where table_name = 'communication_messages' and entity_id = m.id),
                            'thread', t.id, 'seq', m.seq, 'duplicate', false);
end $$;

-- SECURITY INVOKER: participants and attachments are inserted under the CALLER's row security, so a party or document the caller cannot see (or that
-- does not exist) is refused identically.
create function communication_message_add(p_thread uuid, p_type text, p_direction text, p_occurred_at timestamptz, p_body text default null, p_participants jsonb default '[]',
                                          p_ended_at timestamptz default null, p_reply_to uuid default null, p_source_system text default null, p_source_reference text default null,
                                          p_attachments uuid[] default '{}') returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare r jsonb; x jsonb; v_inst text; v_msg uuid; d uuid; p jsonb;
begin
  if jsonb_typeof(coalesce(p_participants, '[]')) <> 'array' then raise exception 'participants must be a list' using errcode = '22023'; end if;
  r := communication_message_record(p_thread, p_type, p_direction, p_occurred_at, p_body, p_ended_at, p_reply_to, p_source_system, p_source_reference);
  if (r ->> 'duplicate')::boolean then return r; end if;
  v_msg := (r ->> 'message_id')::uuid;
  for p in select * from jsonb_array_elements(coalesce(p_participants, '[]')) loop
    v_inst := null;
    if nullif(p ->> 'entity', '') is not null then
      select institutional_id into v_inst from entity_registry where institutional_id = upper(btrim(p ->> 'entity')) or ada_id = btrim(p ->> 'entity');
      if v_inst is null then raise exception 'participant not found' using errcode = 'P0002'; end if;
    end if;
    if v_inst is null and nullif(btrim(coalesce(p ->> 'address', '')), '') is null then raise exception 'a participant needs a registered party or an address' using errcode = '23514'; end if;
    insert into communication_participants (message_id, role, entity_institutional_id, address_snapshot) values (v_msg, coalesce(p ->> 'role', 'other'), v_inst, nullif(btrim(p ->> 'address'), ''));
  end loop;
  foreach d in array coalesce(p_attachments, '{}') loop
    perform communication_attach_document(v_msg, d);
  end loop;
  return r;
end $$;

-- The only way content leaves the database: authorises (read), logs, and returns subject, participants, bodies, notes and attachments the caller may see
create function communication_read(p_thread uuid, p_from_seq integer default null, p_to_seq integer default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; v_msgs jsonb; v_notes jsonb;
begin
  select * into t from communication_threads where id = p_thread;
  if not found or not communication_can_row(t.id, t.owner_staff_id, t.division_id, t.effective_classification, t.effective_critical, t.client_deleted, t.status, 'read') then
    perform communication_note_denied(p_thread, 'read');
    return null;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'message', (select institutional_id from entity_registry where table_name = 'communication_messages' and entity_id = m.id),
           'seq', m.seq, 'type', m.type_key, 'direction', m.direction, 'occurred_at', m.occurred_at, 'ended_at', m.ended_at, 'recorded_at', m.recorded_at,
           'recorded_by', (select ada_id from staff where id = m.recorded_by),
           'in_reply_to_seq', (select r.seq from communication_messages r where r.id = m.in_reply_to_message_id),
           'body', m.body, 'body_hash', m.body_hash, 'body_purged', m.body_purged_at is not null,
           'participants', coalesce((select jsonb_agg(jsonb_build_object('role', cp.role, 'entity', cp.entity_institutional_id, 'address', cp.address_snapshot) order by cp.role, cp.id)
                                       from communication_participants cp where cp.message_id = m.id), '[]'),
           'attachments', coalesce((select jsonb_agg(jsonb_build_object('attachment', a.id, 'document', (select institutional_id from entity_registry where table_name = 'documents' and entity_id = a.document_id)) order by a.attached_at)
                                      from communication_attachments a where a.message_id = m.id and a.removed_at is null and document_can(a.document_id, 'view')), '[]')) order by m.seq), '[]')
    into v_msgs from communication_messages m where m.thread_id = t.id and (p_from_seq is null or m.seq >= p_from_seq) and (p_to_seq is null or m.seq <= p_to_seq);
  select coalesce(jsonb_agg(jsonb_build_object('note', c.id, 'message_seq', (select mm.seq from communication_messages mm where mm.id = c.message_id), 'by', (select ada_id from staff where id = c.author_id),
                                               'at', c.created_at, 'body', c.body) order by c.created_at), '[]')
    into v_notes from communication_comments c where c.thread_id = t.id;
  perform communication_log(t.id, null, 'read', jsonb_build_object('from_seq', p_from_seq, 'to_seq', p_to_seq, 'messages', jsonb_array_length(v_msgs)));
  return jsonb_build_object('thread', communication_inst_id(t.id), 'subject', t.subject, 'status', t.status, 'classification', t.effective_classification, 'messages', v_msgs, 'notes', v_notes);
end $$;

create function communication_attachment_open(p_attachment uuid, p_mode text default 'read') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a communication_attachments%rowtype; t communication_threads%rowtype; v_res jsonb;
begin
  if p_mode not in ('read', 'download') then raise exception 'mode must be read or download' using errcode = '22023'; end if;
  select * into a from communication_attachments where id = p_attachment;
  if found then select * into t from communication_threads where id = a.thread_id; end if;
  if not found or a.removed_at is not null or not communication_can_row(t.id, t.owner_staff_id, t.division_id, t.effective_classification, t.effective_critical, t.client_deleted, t.status, 'attachment') then
    perform security_note_lookup(coalesce(communication_inst_id(t.id), p_attachment::text), 'communication.attachment');
    return null;
  end if;
  v_res := document_open(a.document_id, p_mode);          -- the Documents module decides whether this caller may open this file, and logs it
  if v_res is null then return null; end if;
  perform communication_log(t.id, a.message_id, 'attachment_opened', jsonb_build_object('document', v_res ->> 'document', 'mode', p_mode));
  return v_res;
end $$;

-- ---------------------------------------------------------------------------
-- Commands: details, classification, retention, ownership, lifecycle
-- ---------------------------------------------------------------------------
create function communication_update(p_thread uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; k text; v_allowed constant text[] := array['subject', 'review_date', 'owner_staff_id']; v_keys text[];
begin
  t := communication_require(p_thread, 'edit');
  select array_agg(x order by x) into v_keys from jsonb_object_keys(p_changes) x;
  if v_keys is null then raise exception 'nothing to change' using errcode = '23514'; end if;
  foreach k in array v_keys loop
    if not (k = any (v_allowed)) then raise exception 'cannot change % here', k using errcode = '23514'; end if;
  end loop;
  if p_changes ? 'owner_staff_id' and not exists (select 1 from staff where id = (p_changes ->> 'owner_staff_id')::uuid and account_status = 'active' and deleted_at is null) then
    raise exception 'the owner must be an active staff member' using errcode = '23514';
  end if;
  update communication_threads set
    subject = case when p_changes ? 'subject' then nullif(btrim(p_changes ->> 'subject'), '') else subject end,
    review_date = case when p_changes ? 'review_date' then (p_changes ->> 'review_date')::date else review_date end,
    owner_staff_id = case when p_changes ? 'owner_staff_id' then (p_changes ->> 'owner_staff_id')::uuid else owner_staff_id end
   where id = t.id;
  perform communication_log(t.id, null, 'metadata', jsonb_build_object('fields', to_jsonb(v_keys)));
end $$;

create function communication_set_classification(p_thread uuid, p_class data_classification, p_critical boolean, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; e communication_threads%rowtype;
begin
  t := communication_require(p_thread, 'edit');
  if not has_permission('records.classify') then raise exception 'records.classify is required' using errcode = '42501'; end if;
  if p_critical is not null and p_critical is distinct from t.is_critical and not has_permission('communications.view_critical') then
    raise exception 'communications.view_critical is required to change whether a communication is critical' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update communication_threads set classification = p_class, is_critical = coalesce(p_critical, is_critical) where id = t.id returning * into e;
  if not classification_visible(e.effective_classification) then raise exception 'you cannot classify a communication above your own clearance' using errcode = '42501'; end if;
  perform communication_log(t.id, null, 'classification', jsonb_build_object('from', t.classification, 'to', p_class, 'critical_from', t.is_critical, 'critical_to', e.is_critical, 'reason', p_reason));
end $$;

create function communication_set_retention(p_thread uuid, p_class text, p_start date, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; rc retention_classes%rowtype;
begin
  t := communication_require(p_thread, 'view');
  if not has_permission('communications.configure', t.division_id) then raise exception 'communications.configure is required' using errcode = '42501'; end if;
  if t.status = 'disposed' then raise exception 'the communication is disposed' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into rc from retention_classes where key = p_class and is_active;
  if not found then raise exception 'unknown retention class' using errcode = '23514'; end if;
  perform set_config('ada.communication_retention', 'on', true);
  update communication_threads set retention_class_id = rc.id, retention_months = rc.period_months, retention_start = coalesce(p_start, retention_start) where id = t.id;
  perform set_config('ada.communication_retention', 'off', true);
  perform communication_log(t.id, null, 'retention', jsonb_build_object('class', rc.key, 'months', rc.period_months, 'start', coalesce(p_start, t.retention_start), 'reason', p_reason));
end $$;

create function communication_transfer(p_thread uuid, p_division uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype;
begin
  t := communication_require(p_thread, 'edit');
  if not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if not has_permission('communications.update', p_division) and not has_permission('communications.create', p_division) then raise exception 'you cannot hand a communication to a division where you have no communication rights' using errcode = '42501'; end if;
  if p_division = t.division_id then raise exception 'the communication is already with that division' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  perform set_config('ada.communication_transfer', 'on', true);
  update communication_threads set division_id = p_division where id = t.id;
  perform set_config('ada.communication_transfer', 'off', true);
  perform communication_log(t.id, null, 'transferred', jsonb_build_object('from', t.division_id, 'to', p_division, 'reason', p_reason));
end $$;

create function communication_set_status(p_thread uuid, p_action text, p_to communication_status, p_kind text, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype;
begin
  t := communication_require(p_thread, p_action);
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update communication_threads set status = p_to where id = t.id;
  perform communication_log(t.id, null, p_kind, jsonb_build_object('reason', p_reason));
end $$;
revoke execute on function communication_set_status(uuid, text, communication_status, text, text) from public, anon, authenticated;
create function communication_close(p_thread uuid, p_reason text) returns void language sql security definer set search_path = public, pg_temp as $$ select communication_set_status(p_thread, 'close', 'closed', 'closed', p_reason) $$;
create function communication_reopen(p_thread uuid, p_reason text) returns void language sql security definer set search_path = public, pg_temp as $$ select communication_set_status(p_thread, 'reopen', 'open', 'reopened', p_reason) $$;
create function communication_archive(p_thread uuid, p_reason text) returns void language sql security definer set search_path = public, pg_temp as $$ select communication_set_status(p_thread, 'archive', 'archived', 'archived', p_reason) $$;
create function communication_restore(p_thread uuid, p_reason text) returns void language sql security definer set search_path = public, pg_temp as $$ select communication_set_status(p_thread, 'restore', 'closed', 'restored', p_reason) $$;

-- ---------------------------------------------------------------------------
-- Commands: relationships, attachments, sharing, notes
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER: the insert runs under the CALLER's row security, so a target the caller cannot see (or that does not exist) is refused identically
create function communication_link_add(p_thread uuid, p_entity text, p_role text default 'subject') returns uuid
language plpgsql set search_path = public, pg_temp as $$
declare v_inst text; v_id uuid;
begin
  if not communication_can(p_thread, 'view') then raise exception 'communication not found' using errcode = 'P0002'; end if;
  if not communication_can(p_thread, 'edit') then raise exception 'you are not permitted to edit this communication' using errcode = '42501'; end if;
  select institutional_id into v_inst from entity_registry where institutional_id = upper(btrim(p_entity)) or ada_id = btrim(p_entity);
  if v_inst is null then raise exception 'entity not found' using errcode = 'P0002'; end if;
  insert into communication_links (thread_id, entity_institutional_id, role) values (p_thread, v_inst, p_role) returning id into v_id;
  return v_id;
end $$;

create function communication_link_remove(p_link uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l communication_links%rowtype; t communication_threads%rowtype;
begin
  select * into l from communication_links where id = p_link;
  if not found then raise exception 'communication not found' using errcode = 'P0002'; end if;
  t := communication_require(l.thread_id, 'edit');
  if l.removed_at is not null then raise exception 'the link is already removed' using errcode = '23514'; end if;
  update communication_links set removed_at = now(), removed_by = current_staff_id(), removal_reason = p_reason where id = l.id;
end $$;

create function communication_attach_document(p_message uuid, p_document uuid) returns uuid
language plpgsql set search_path = public, pg_temp as $$
declare m record; v_id uuid;
begin
  select id, thread_id into m from communication_messages where id = p_message;       -- explicit columns: the caller has no privilege on the content columns
  if not found or not communication_can(m.thread_id, 'view') then raise exception 'communication not found' using errcode = 'P0002'; end if;
  if not communication_can(m.thread_id, 'append') then raise exception 'you are not permitted to attach to this communication' using errcode = '42501'; end if;
  if not exists (select 1 from documents where id = p_document) then raise exception 'document not found' using errcode = 'P0002'; end if;
  insert into communication_attachments (thread_id, message_id, document_id) values (m.thread_id, m.id, p_document) returning id into v_id;
  return v_id;
end $$;

create function communication_attachment_remove(p_attachment uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a communication_attachments%rowtype; t communication_threads%rowtype;
begin
  select * into a from communication_attachments where id = p_attachment;
  if not found then raise exception 'communication not found' using errcode = 'P0002'; end if;
  t := communication_require(a.thread_id, 'edit');
  if a.removed_at is not null then raise exception 'the attachment is already removed' using errcode = '23514'; end if;
  update communication_attachments set removed_at = now(), removed_by = current_staff_id(), removal_reason = p_reason where id = a.id;
end $$;

create function communication_share(p_thread uuid, p_staff uuid, p_division uuid, p_actions text[], p_expires timestamptz default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; v_id uuid; v_actions text[];
begin
  t := communication_require(p_thread, 'share');
  if (p_staff is null) = (p_division is null) then raise exception 'share with exactly one person or one division' using errcode = '23514'; end if;
  if p_staff is not null and not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then raise exception 'the recipient must be an active staff member' using errcode = '23514'; end if;
  if p_division is not null and not exists (select 1 from divisions where id = p_division) then raise exception 'division not found' using errcode = 'P0002'; end if;
  if p_expires is not null and p_expires <= now() then raise exception 'the expiry must be in the future' using errcode = '23514'; end if;
  if t.effective_critical and p_expires is null then raise exception 'sharing a critical communication needs an expiry' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select array_agg(distinct x order by x) into v_actions from unnest(coalesce(p_actions, '{}') || array['view']) x;
  if not (v_actions <@ array['view', 'read', 'attachment', 'comment']) then raise exception 'a share can grant only view, read, attachment and comment' using errcode = '23514'; end if;
  insert into communication_access (thread_id, staff_id, division_id, actions, reason, granted_by, expires_at) values (t.id, p_staff, p_division, v_actions, p_reason, current_staff_id(), p_expires) returning id into v_id;
  perform communication_log(t.id, null, 'shared', jsonb_build_object('grant', v_id, 'actions', to_jsonb(v_actions), 'expires', p_expires, 'to_division', p_division is not null));
  return v_id;
end $$;

create function communication_unshare(p_grant uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g communication_access%rowtype; t communication_threads%rowtype;
begin
  select * into g from communication_access where id = p_grant;
  if not found then raise exception 'communication not found' using errcode = 'P0002'; end if;
  t := communication_require(g.thread_id, 'share');
  update communication_access set revoked_at = now(), revoked_by = current_staff_id() where id = g.id and revoked_at is null;
  perform communication_log(t.id, null, 'unshared', jsonb_build_object('grant', g.id, 'reason', p_reason));
end $$;

create function communication_comment_add(p_thread uuid, p_body text, p_message_seq integer default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; v_msg uuid; v_id uuid;
begin
  t := communication_require(p_thread, 'comment');
  if coalesce(btrim(p_body), '') = '' then raise exception 'a note needs its text' using errcode = '23514'; end if;
  if p_message_seq is not null then
    select id into v_msg from communication_messages where thread_id = t.id and seq = p_message_seq;
    if v_msg is null then raise exception 'message not found' using errcode = 'P0002'; end if;
  end if;
  insert into communication_comments (thread_id, message_id, author_id, body) values (t.id, v_msg, current_staff_id(), p_body) returning id into v_id;
  perform communication_log(t.id, v_msg, 'comment', '{}');
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Commands: legal holds and disposal
-- ---------------------------------------------------------------------------
create function communication_hold_place(p_thread uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; v_id uuid;
begin
  t := communication_require(p_thread, 'view');
  if not has_permission('communications.legal_hold', t.division_id) then raise exception 'communications.legal_hold is required' using errcode = '42501'; end if;
  insert into communication_holds (thread_id, reason, placed_by) values (t.id, p_reason, current_staff_id()) returning id into v_id;
  perform communication_log(t.id, null, 'hold_placed', jsonb_build_object('hold', v_id));
  return v_id;
end $$;

create function communication_hold_release(p_hold uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare h communication_holds%rowtype; t communication_threads%rowtype;
begin
  select * into h from communication_holds where id = p_hold;
  if not found then raise exception 'communication not found' using errcode = 'P0002'; end if;
  t := communication_require(h.thread_id, 'view');
  if not has_permission('communications.legal_hold', t.division_id) then raise exception 'communications.legal_hold is required' using errcode = '42501'; end if;
  if h.released_at is not null then raise exception 'the hold is already released' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update communication_holds set released_at = now(), released_by = current_staff_id(), release_reason = p_reason where id = h.id;
  perform communication_log(t.id, null, 'hold_released', jsonb_build_object('hold', h.id));
end $$;

create function communication_disposal_blockers(p_thread uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not communication_can(p_thread, 'view') then null
    when exists (select 1 from communication_holds h where h.thread_id = p_thread and h.released_at is null) then 'a legal hold prevents disposal'
    when exists (select 1 from communication_attachments a join document_holds h on h.document_id = a.document_id and h.released_at is null where a.thread_id = p_thread and a.removed_at is null)
      then 'a legal hold on an attached document prevents disposal' end
$$;
revoke execute on function communication_disposal_blockers(uuid) from public, anon;
grant execute on function communication_disposal_blockers(uuid) to authenticated;     -- used by the retention view; answers only for threads the caller may see

create function communication_request_disposal(p_thread uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t communication_threads%rowtype; v_id uuid; v_block text;
begin
  t := communication_require(p_thread, 'request_disposal');
  if t.retention_months is null then raise exception 'a permanent record is never disposed' using errcode = '23514'; end if;
  if t.retention_start + make_interval(months => t.retention_months) > current_date then raise exception 'the retention period has not elapsed (until %)', t.retention_start + make_interval(months => t.retention_months) using errcode = '23514'; end if;
  v_block := communication_disposal_blockers(t.id);
  if v_block is not null then raise exception '%', v_block using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  insert into communication_disposals (thread_id, reason, requested_by) values (t.id, p_reason, current_staff_id()) returning id into v_id;
  perform approval_open('communication_disposal', 'communication_disposals', v_id, null, t.division_id, 'communications.dispose', 'Disposal request',
                        case when t.effective_critical then 'confidential'::data_classification else t.effective_classification end);
  perform communication_log(t.id, null, 'disposal_requested', jsonb_build_object('disposal', v_id));
  return v_id;
end $$;

create function communication_disposal_decide(p_disposal uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare x communication_disposals%rowtype; t communication_threads%rowtype; v_gate text; v_block text; v_bodies integer; v_addr integer; v_notes integer; v_subject boolean;
begin
  select * into x from communication_disposals where id = p_disposal;
  if not found then raise exception 'communication not found' using errcode = 'P0002'; end if;
  t := communication_require(x.thread_id, 'dispose');
  if x.state <> 'requested' then raise exception 'this disposal request is already %', x.state using errcode = '23514'; end if;
  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a disposal' using errcode = '23514'; end if;
    perform approval_gate('communication_disposal', 'communication_disposals', x.id, t.division_id, null, x.requested_by, 'communications.dispose', false, p_note);
    update communication_disposals set state = 'rejected', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = x.id;
    perform approval_close('communication_disposals', x.id, 'rejected', p_note);
    perform communication_log(t.id, null, 'disposal_decided', jsonb_build_object('disposal', x.id, 'approved', false));
    return 'rejected';
  end if;
  v_block := communication_disposal_blockers(t.id);
  if v_block is not null then raise exception '%', v_block using errcode = '23514'; end if;
  v_gate := approval_gate('communication_disposal', 'communication_disposals', x.id, t.division_id, null, x.requested_by, 'communications.dispose', true, p_note);
  if v_gate = 'pending' then return 'pending'; end if;
  perform set_config('ada.communication_disposal', 'on', true);
  update communication_messages set body = null, body_purged_at = now(), status = 'purged' where thread_id = t.id and body is not null;
  get diagnostics v_bodies = row_count;
  update communication_participants set address_snapshot = null, address_purged_at = now() where thread_id = t.id and address_snapshot is not null;
  get diagnostics v_addr = row_count;
  update communication_comments set body = null, purged_at = now() where thread_id = t.id and body is not null;
  get diagnostics v_notes = row_count;
  v_subject := t.subject is not null;
  update communication_threads set subject = null, subject_purged_at = case when v_subject then now() else subject_purged_at end, status = 'disposed' where id = t.id;
  perform set_config('ada.communication_disposal', 'off', true);
  update communication_disposals set state = 'executed', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note,
         purge_summary = jsonb_build_object('bodies', v_bodies, 'addresses', v_addr, 'notes', v_notes, 'subject', v_subject) where id = x.id;
  perform approval_close('communication_disposals', x.id, 'approved', p_note);
  perform communication_log(t.id, null, 'disposal_decided', jsonb_build_object('disposal', x.id, 'approved', true, 'bodies', v_bodies));
  return 'approved';
end $$;

insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note) values
  ('communication_disposal', 'communications.dispose', false, true, 1, 'default');

-- ---------------------------------------------------------------------------
-- Security records: a lookup that matches a CRITICAL thread / message is recorded exactly like one that matched nothing
-- ---------------------------------------------------------------------------
create or replace function security_note_lookup(p_input text, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_in text := left(coalesce(p_input, ''), 64); r entity_registry%rowtype; v_found boolean;
begin
  select * into r from entity_registry where institutional_id = upper(btrim(v_in)) or ada_id = btrim(v_in);
  v_found := found;
  if v_found and (
       (r.entity_type = 'document' and exists (select 1 from documents d where d.id = r.entity_id and d.is_critical))
    or (r.entity_type = 'communication' and exists (select 1 from communication_threads t where t.id = r.entity_id and t.effective_critical))
    or (r.entity_type = 'communication_message' and exists (select 1 from communication_messages m join communication_threads t on t.id = m.thread_id where m.id = r.entity_id and t.effective_critical))) then
    v_found := false;
  end if;
  insert into security_events (actor_user_id, actor_staff_id, kind, requested_action, requested_input, entity_exists, entity_class, session_ref, source_addr, reason)
  values (auth.uid(), current_staff_id(), 'lookup', left(coalesce(p_action, 'resolve'), 40), v_in, v_found, case when v_found then r.classification end,
          nullif(current_setting('request.jwt.claim.session_id', true), ''), inet_client_addr(),
          case when v_found then 'not authorized for this entity' else 'no such entity' end);
end $$;

-- ---------------------------------------------------------------------------
-- Retrieval: request -> registry -> entity (-> its family) -> authorization -> communications. Found by institutional ID; never by scanning content.
-- ---------------------------------------------------------------------------
-- Who took part, by reference. Only for threads the caller may READ (participation is content: it must not be enumerable by a metadata reader).
create function communication_participant_hits(p_ids text[]) returns table (thread_id uuid, recorded_at timestamptz, role text, entity text)
language sql stable security definer set search_path = public, pg_temp as $$
  select cp.thread_id, m.recorded_at, cp.role, cp.entity_institutional_id
    from communication_participants cp join communication_messages m on m.id = cp.message_id
   where cp.entity_institutional_id = any (p_ids) and communication_can(cp.thread_id, 'read')
$$;
revoke execute on function communication_participant_hits(text[]) from public, anon;
grant execute on function communication_participant_hits(text[]) to authenticated;   -- called by the invoker-side search; it only ever returns threads the caller may READ

-- Communications related to a set of registered entities, as they stood at p_as_of (invoker: the caller's row security decides what exists for them).
-- Metadata only: no subject, no participants, no body.
create function communications_of(p_ids text[], p_from date default null, p_to date default null, p_as_of timestamptz default null) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare v_ts timestamptz := coalesce(p_as_of, now());
begin
  return coalesce((
    select jsonb_agg(x.j order by x.last_at desc nulls last, x.tid) from (
      select t.id as tid,
             (select max(m.occurred_at) from communication_messages m where m.thread_id = t.id and m.recorded_at <= v_ts) as last_at,
             jsonb_build_object(
               'thread', (select er.institutional_id from entity_registry er where er.table_name = 'communication_threads' and er.entity_id = t.id),
               'status', t.status, 'classification', t.effective_classification, 'division', t.division_id, 'started', t.created_at,
               'messages', (select count(*) from communication_messages m where m.thread_id = t.id and m.recorded_at <= v_ts),
               'first_occurred', (select min(m.occurred_at) from communication_messages m where m.thread_id = t.id and m.recorded_at <= v_ts),
               'last_occurred', (select max(m.occurred_at) from communication_messages m where m.thread_id = t.id and m.recorded_at <= v_ts),
               'types', coalesce((select jsonb_agg(distinct m.type_key) from communication_messages m where m.thread_id = t.id and m.recorded_at <= v_ts), '[]'),
               'relationships',
                 coalesce((select jsonb_agg(jsonb_build_object('entity', l.entity_institutional_id, 'role', l.role, 'via', 'link') order by l.linked_at) from communication_links l
                            where l.thread_id = t.id and l.entity_institutional_id = any (p_ids) and l.linked_at <= v_ts and (l.removed_at is null or l.removed_at > v_ts)), '[]'::jsonb)
                 || coalesce((select jsonb_agg(jsonb_build_object('entity', er.institutional_id, 'role', 'attachment', 'via', 'attachment') order by a.attached_at)
                                from communication_attachments a join entity_registry er on er.table_name = 'documents' and er.entity_id = a.document_id
                               where a.thread_id = t.id and er.institutional_id = any (p_ids) and a.attached_at <= v_ts and (a.removed_at is null or a.removed_at > v_ts)), '[]'::jsonb)
                 || coalesce((select jsonb_agg(jsonb_build_object('entity', h.entity, 'role', h.role, 'via', 'participant')) from communication_participant_hits(p_ids) h
                               where h.thread_id = t.id and h.recorded_at <= v_ts), '[]'::jsonb),
               'can_read', communication_can(t.id, 'read')) as j
        from communication_threads t
       where t.created_at <= v_ts
         and (exists (select 1 from communication_links l where l.thread_id = t.id and l.entity_institutional_id = any (p_ids) and l.linked_at <= v_ts and (l.removed_at is null or l.removed_at > v_ts))
              or exists (select 1 from communication_attachments a join entity_registry er on er.table_name = 'documents' and er.entity_id = a.document_id
                          where a.thread_id = t.id and er.institutional_id = any (p_ids) and a.attached_at <= v_ts and (a.removed_at is null or a.removed_at > v_ts))
              or exists (select 1 from communication_participant_hits(p_ids) h where h.thread_id = t.id and h.recorded_at <= v_ts))
         and ((p_from is null and p_to is null)
              or exists (select 1 from communication_messages m where m.thread_id = t.id and m.recorded_at <= v_ts
                            and (p_from is null or m.occurred_at >= p_from) and (p_to is null or m.occurred_at < p_to + 1)))) x), '[]'::jsonb);
end $$;

create function communications_for_entity(p_entity text, p_from date default null, p_to date default null, p_as_of timestamptz default null, p_include_children boolean default false) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare r entity_registry%rowtype;
begin
  select * into r from entity_registry where institutional_id = upper(btrim(coalesce(p_entity, ''))) or ada_id = btrim(coalesce(p_entity, ''));
  if not found then perform security_note_lookup(p_entity, 'communications_for_entity'); return null; end if;
  return communications_of(case when p_include_children then document_family_ids(r.institutional_id) else array[r.institutional_id] end, p_from, p_to, p_as_of);
end $$;

-- Resolve an institutional ID (thread or message) as the caller may know it. Hidden and missing are the same: nothing (and a lookup event).
create function communication_lookup(p_ref text) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare r entity_registry%rowtype; t record; m record;
begin
  select * into r from entity_registry where (institutional_id = upper(btrim(coalesce(p_ref, ''))) or ada_id = btrim(coalesce(p_ref, ''))) and entity_type in ('communication', 'communication_message');
  if found then
    if r.entity_type = 'communication' then
      select id, status into t from communication_threads where id = r.entity_id;
      if found then return jsonb_build_object('kind', 'thread', 'institutional_id', r.institutional_id, 'status', t.status, 'id', t.id); end if;
    else
      select id, seq, thread_id into m from communication_messages where id = r.entity_id;
      if found then return jsonb_build_object('kind', 'message', 'institutional_id', r.institutional_id, 'seq', m.seq, 'thread', m.thread_id, 'id', m.id); end if;
    end if;
  end if;
  perform security_note_lookup(p_ref, 'communication.lookup');
  return null;
end $$;

create view communication_retention_status with (security_invoker = true) as
  select t.id as thread_id, rc.key as retention_class, t.retention_months, t.retention_start,
         (t.retention_start + make_interval(months => t.retention_months))::date as retention_ends_on,
         t.review_date, (t.review_date is not null and t.review_date <= current_date) as review_due,
         communication_on_hold(t.id) as on_legal_hold,
         (communication_disposal_blockers(t.id) is not null) as hold_blocks_disposal,
         (t.status = 'archived' and t.retention_months is not null and t.retention_start + make_interval(months => t.retention_months) <= current_date and communication_disposal_blockers(t.id) is null) as disposal_eligible,
         case when t.status = 'disposed' then 'disposed'
              when exists (select 1 from communication_disposals x where x.thread_id = t.id and x.state = 'requested') then 'disposal_pending'
              when t.status = 'archived' then 'archived' else 'retained' end as disposition
  from communication_threads t join retention_classes rc on rc.id = t.retention_class_id;
comment on view communication_retention_status is 'Purpose: derived retention position of each thread - class, period, end date, review due, legal hold (on the thread or an attached document), disposal eligibility, disposition. Row access follows the thread. Nothing is stored.';

-- One thread, every METADATA slice (invoker: row security decides). No subject, no participants, no bodies - those need communication_read.
create function communication_360(p_thread uuid) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare t record;
begin
  select id, status, effective_classification, effective_critical, owner_staff_id, created_by, created_at, last_activity_at, closed_at, archived_at, disposed_at into t from communication_threads where id = p_thread;
  if not found then perform communication_note_denied(p_thread, 'view'); return null; end if;
  return jsonb_build_object(
    'identity', (select jsonb_build_object('institutional_id', er.institutional_id, 'entity_type', er.entity_type, 'origin_division_id', er.origin_division_id, 'origin_year', er.origin_year,
                          'current_division_id', er.current_division_id, 'status', er.status) from entity_registry er where er.table_name = 'communication_threads' and er.entity_id = t.id),
    'record', jsonb_build_object('status', t.status, 'classification', t.effective_classification, 'critical', t.effective_critical,
                          'owner', (select ada_id from staff where id = t.owner_staff_id), 'created_by', (select ada_id from staff where id = t.created_by), 'created_at', t.created_at,
                          'last_activity_at', t.last_activity_at, 'closed_at', t.closed_at, 'archived_at', t.archived_at, 'disposed_at', t.disposed_at),
    'retention', (select to_jsonb(x) - 'thread_id' from communication_retention_status x where x.thread_id = t.id),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('seq', m.seq, 'message', (select er.institutional_id from entity_registry er where er.table_name = 'communication_messages' and er.entity_id = m.id),
                          'type', m.type_key, 'direction', m.direction, 'occurred_at', m.occurred_at, 'ended_at', m.ended_at, 'recorded_at', m.recorded_at, 'content_purged', m.body_purged_at is not null) order by m.seq)
                          from communication_messages m where m.thread_id = t.id), '[]'),
    'relationships', coalesce((select jsonb_agg(jsonb_build_object('entity', l.entity_institutional_id, 'entity_type', er.entity_type, 'role', l.role, 'since', l.linked_at, 'removed_at', l.removed_at) order by l.linked_at)
                          from communication_links l join entity_registry er on er.institutional_id = l.entity_institutional_id where l.thread_id = t.id), '[]'),
    'attachments', coalesce((select jsonb_agg(jsonb_build_object('attachment', a.id, 'message_seq', (select mm.seq from communication_messages mm where mm.id = a.message_id),
                          'document', (select er.institutional_id from entity_registry er where er.table_name = 'documents' and er.entity_id = a.document_id), 'since', a.attached_at, 'removed_at', a.removed_at) order by a.attached_at)
                          from communication_attachments a where a.thread_id = t.id), '[]'),
    'access', jsonb_build_object('can_read', communication_can(t.id, 'read'), 'can_open_attachments', communication_can(t.id, 'attachment'), 'can_append', communication_can(t.id, 'append'),
                          'can_edit', communication_can(t.id, 'edit'), 'can_comment', communication_can(t.id, 'comment'), 'can_share', communication_can(t.id, 'share'),
                          'can_archive', communication_can(t.id, 'archive')),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'kind', e.kind, 'by', (select ada_id from staff where id = e.actor_staff_id), 'detail', e.detail) order by e.id desc)
                          from (select * from communication_events where thread_id = t.id and kind not in ('read', 'attachment_opened') order by id desc limit 50) e), '[]'));
end $$;

-- ---------------------------------------------------------------------------
-- Consistency and recovery (service role only; these answer questions about content, so they are not for API users)
-- ---------------------------------------------------------------------------
create function communication_integrity_drift() returns table (message_id uuid, thread_id uuid, seq integer, problem text)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.id, m.thread_id, m.seq, 'body does not match its recorded hash'
    from communication_messages m
   where m.body_purged_at is null and encode(extensions.digest(convert_to(m.id::text || '|' || coalesce(m.body, ''), 'UTF8'), 'sha256'), 'hex') <> m.body_hash
  union all
  select null::uuid, t.id, null::integer, 'message numbers are not gap-free'
    from communication_threads t
   where exists (select 1 from communication_messages m where m.thread_id = t.id)
     and (select count(*) from communication_messages m where m.thread_id = t.id) <> (select max(seq) from communication_messages m where m.thread_id = t.id)
$$;
revoke execute on function communication_integrity_drift() from public, anon, authenticated;
grant execute on function communication_integrity_drift() to service_role;

create function communication_backup_manifest() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'threads', (select count(*) from communication_threads), 'messages', (select count(*) from communication_messages), 'participants', (select count(*) from communication_participants),
    'links', (select count(*) from communication_links), 'attachments', (select count(*) from communication_attachments), 'events', (select count(*) from communication_events),
    'holds', (select count(*) from communication_holds), 'disposals', (select count(*) from communication_disposals), 'notes', (select count(*) from communication_comments),
    'threads_md5', (select md5(coalesce(string_agg(concat_ws('|', r.institutional_id, t.status, t.classification, t.effective_classification, t.effective_critical, t.division_id, t.retention_months, t.retention_start), ';' order by r.institutional_id), ''))
                      from communication_threads t join entity_registry r on r.table_name = 'communication_threads' and r.entity_id = t.id),
    'messages_md5', (select md5(coalesce(string_agg(concat_ws('|', r.institutional_id, m.seq, m.type_key, m.direction, m.occurred_at, m.body_hash, m.status), ';' order by r.institutional_id), ''))
                      from communication_messages m join entity_registry r on r.table_name = 'communication_messages' and r.entity_id = m.id),
    'links_md5', (select md5(coalesce(string_agg(concat_ws('|', thread_id, entity_institutional_id, role, removed_at is null), ';' order by thread_id, entity_institutional_id, role, linked_at), '')) from communication_links),
    'attachments_md5', (select md5(coalesce(string_agg(concat_ws('|', thread_id, message_id, document_id, removed_at is null), ';' order by thread_id, message_id, document_id, attached_at), '')) from communication_attachments),
    'events_md5', (select md5(coalesce(string_agg(concat_ws('|', thread_id, kind, actor_staff_id), ';' order by id), '')) from communication_events),
    'registry_md5', (select md5(coalesce(string_agg(concat_ws('|', institutional_id, entity_id, origin_division_id, origin_year, classification, status), ';' order by institutional_id), ''))
                      from entity_registry where table_name in ('communication_threads', 'communication_messages')))
$$;
revoke execute on function communication_backup_manifest() from public, anon, authenticated;
grant execute on function communication_backup_manifest() to service_role;


-- ---------------------------------------------------------------------------
-- Communications in the 360 views of the entities they concern (each section is independently authorized by the communications' own row security; metadata only)
-- ---------------------------------------------------------------------------
create or replace function client_360(p_client uuid) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  c record;
begin
  select cl.*, d.name as owner_division_name, o.name as org_name, o.legal_name as org_legal_name, o.trading_name as org_trading_name, o.registration_number as org_registration_number, o.website as org_website, o.email as org_email, o.phone as org_phone, o.address as org_address, o.city as org_city, o.country as org_country, o.industry as org_industry, o.social_links as org_social_links, o.id as org_row_id, o.status as org_status into c
    from clients cl left join divisions d on d.id = cl.owner_division_id left join organizations o on o.id = cl.organization_id where cl.id = p_client;
  if not found then return null; end if;                         -- RLS: also null when the caller may not see it

  return jsonb_build_object(
    'organization', (select jsonb_build_object('institutional_id', (select r.institutional_id from entity_registry r where r.table_name = 'organizations' and r.entity_id = c.organization_id), 'status', c.org_status,
                 'roles', jsonb_build_object('client', true, 'supplier', exists (select 1 from suppliers sp where sp.organization_id = c.organization_id), 'partner', exists (select 1 from partners pa where pa.organization_id = c.organization_id)))),
    'overview', jsonb_build_object(
      'id', c.ada_id, 'name', coalesce(c.org_name, c.name), 'legal_name', coalesce(c.org_legal_name, c.legal_name), 'trading_name', coalesce(c.org_trading_name, c.trading_name), 'type', c.client_type, 'status', c.status,
      'industry', coalesce(c.org_industry, c.industry), 'registration_number', coalesce(c.org_registration_number, c.registration_number), 'email', coalesce(c.org_email, c.email), 'phone', coalesce(c.org_phone, c.phone), 'website', coalesce(c.org_website, c.website),
      'address', coalesce(c.org_address, c.address), 'city', coalesce(c.org_city, c.city), 'country', coalesce(c.org_country, c.country), 'billing_address', c.billing_address, 'social_links', coalesce(c.org_social_links, c.social_links),
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
    'domains', domains_of(document_family_ids((select institutional_id from entity_registry where table_name = 'clients' and entity_id = p_client))),
    'communications', communications_of(document_family_ids((select institutional_id from entity_registry where table_name = 'clients' and entity_id = p_client))),
    'pending', '[]'::jsonb);
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
    'domains', domains_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'communications', communications_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'pending', jsonb_build_array('expenses', 'websites', 'deliverables'));
end $$;

create or replace function organization_360(p_org uuid) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare o organizations%rowtype; v_inst text;
begin
  select * into o from organizations where id = p_org;
  if not found then perform organization_note_denied(p_org); return null; end if;
  select institutional_id into v_inst from entity_registry where table_name = 'organizations' and entity_id = o.id;
  return jsonb_build_object(
    'identity', jsonb_build_object('institutional_id', v_inst, 'entity_type', 'external_organization', 'status', o.status,
                                   'merged_into', (select r.institutional_id from entity_registry r where r.table_name = 'organizations' and r.entity_id = o.merged_into_id)),
    'organization', jsonb_build_object('name', o.name, 'legal_name', o.legal_name, 'trading_name', o.trading_name, 'registration_number', o.registration_number, 'website', o.website,
                                       'email', o.email, 'phone', o.phone, 'address', o.address, 'city', o.city, 'country', o.country, 'industry', o.industry, 'social_links', o.social_links,
                                       'classification', o.effective_classification),
    'roles', jsonb_build_object(
      'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.ada_id, 'institutional_id', (select institutional_id from entity_registry where table_name = 'clients' and entity_id = c.id),
                                'status', c.status, 'live', c.deleted_at is null, 'division', (select key from divisions where id = c.owner_division_id)) order by c.created_at) from clients c where c.organization_id = o.id), '[]'),
      'supplier', (select jsonb_build_object('id', s.ada_id, 'institutional_id', (select institutional_id from entity_registry where table_name = 'suppliers' and entity_id = s.id), 'status', s.status) from suppliers s where s.organization_id = o.id),
      'partner', (select jsonb_build_object('institutional_id', (select institutional_id from entity_registry where table_name = 'partners' and entity_id = p.id), 'kind', p.kind, 'status', p.status, 'since', p.since) from partners p where p.organization_id = o.id)),
    'documents', documents_of(document_family_ids(v_inst)),
    'domains', domains_of(document_family_ids(v_inst)),
    'communications', communications_of(document_family_ids(v_inst)),
    'open_reviews', case when has_permission('matching.review') then (select count(*) from organization_reviews r where r.status = 'open' and o.id in (r.left_org_id, r.right_org_id)) end);
end $$;

create or replace function domain_360(p_domain uuid) returns jsonb
language plpgsql volatile set search_path = public, pg_temp as $$
declare d domains%rowtype;
begin
  select * into d from domains where id = p_domain;
  if not found then perform domain_note_denied(p_domain, 'view'); return null; end if;
  return jsonb_build_object(
    'identity', (select jsonb_build_object('institutional_id', er.institutional_id, 'entity_type', er.entity_type, 'origin_division_id', er.origin_division_id, 'origin_year', er.origin_year,
                          'current_division_id', er.current_division_id, 'status', er.status) from entity_registry er where er.table_name = 'domains' and er.entity_id = d.id),
    'record', jsonb_build_object('name', d.name, 'purpose', d.purpose, 'description', d.description, 'status', d.status, 'classification', d.effective_classification, 'created_at', d.created_at, 'retired_at', d.retired_at),
    'lifecycle', jsonb_build_object('expires_on', d.expires_on, 'expiry', (select to_jsonb(x) - 'domain_id' - 'status' - 'expires_on' from domain_expiry_status x where x.domain_id = d.id)),
    'registrations', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'period_start', r.period_start, 'period_end', r.period_end, 'order_reference', r.order_reference,
                          'registrar', r.registrar_institutional_id, 'recorded_at', r.recorded_at, 'note', r.note) order by r.period_start) from domain_registrations r where r.domain_id = d.id), '[]'),
    'relations', coalesce((select jsonb_agg(jsonb_build_object('relation', dr.relation, 'entity', dr.entity_institutional_id, 'entity_type', er.entity_type, 'since', dr.valid_from, 'until', dr.valid_to,
                          'reason', dr.reason, 'end_reason', dr.end_reason) order by dr.valid_from)
                          from domain_relations dr join entity_registry er on er.institutional_id = dr.entity_institutional_id where dr.domain_id = d.id), '[]'),
    'transfers', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'state', t.state, 'to', t.to_entity_institutional_id, 'requested_at', t.requested_at, 'closed_at', t.closed_at) order by t.requested_at)
                          from domain_transfers t where t.domain_id = d.id), '[]'),
    'websites', coalesce((select jsonb_agg(jsonb_build_object('website', h.website_id, 'hostname', h.hostname)) from website_hostname_domains h where h.domain_id = d.id), '[]'),
    'communications', communications_of(array[(select institutional_id from entity_registry where table_name = 'domains' and entity_id = d.id)]),
    'access', jsonb_build_object('can_update', domain_can(d.id, 'update'), 'can_renew', domain_can(d.id, 'renew'), 'can_suspend', domain_can(d.id, 'suspend'), 'can_transfer', domain_can(d.id, 'transfer'),
                          'can_approve', domain_can(d.id, 'approve'), 'can_retire', domain_can(d.id, 'retire')),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'kind', e.kind, 'by', (select ada_id from staff where id = e.actor_staff_id), 'detail', e.detail) order by e.id desc)
                          from (select * from domain_events where domain_id = d.id order by id desc limit 50) e), '[]'));
end $$;

create or replace function document_360(p_doc uuid) returns jsonb
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
    'communications', communications_of(array[(select institutional_id from entity_registry where table_name = 'documents' and entity_id = d.id)]),
    'publication', (select jsonb_build_object('state', p.state, 'public_ref', case when document_can(d.id, 'publish') then p.public_ref end, 'published_at', p.published_at)
                      from document_publications p where p.document_id = d.id and p.state in ('pending_approval', 'approved', 'published')),
    'access', jsonb_build_object('can_read', document_can(d.id, 'read'), 'can_download', document_can(d.id, 'download'), 'can_upload', document_can(d.id, 'upload'),
                          'can_edit', document_can(d.id, 'edit'), 'can_comment', document_can(d.id, 'comment'), 'can_share', document_can(d.id, 'share'),
                          'can_approve', document_can(d.id, 'approve'), 'can_publish', document_can(d.id, 'publish'), 'can_archive', document_can(d.id, 'archive')),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'kind', e.kind, 'by', (select ada_id from staff where id = e.actor_staff_id), 'detail', e.detail) order by e.id desc)
                          from (select * from document_events where document_id = d.id order by id desc limit 50) e), '[]'));
end $$;

-- ---------------------------------------------------------------------------
-- Grants and row-level security
-- ---------------------------------------------------------------------------
alter table communication_types enable row level security;
alter table communication_threads enable row level security;
alter table communication_messages enable row level security;
alter table communication_participants enable row level security;
alter table communication_links enable row level security;
alter table communication_attachments enable row level security;
alter table communication_access enable row level security;
alter table communication_holds enable row level security;
alter table communication_comments enable row level security;
alter table communication_disposals enable row level security;
alter table communication_events enable row level security;
revoke all on communication_types, communication_threads, communication_messages, communication_participants, communication_links, communication_attachments, communication_access,
  communication_holds, communication_comments, communication_disposals, communication_events, communication_retention_status from anon, authenticated;

-- CONTENT is withheld by column privileges: subject, bodies, body hashes, source references, participants and notes have no table access for API users
grant select (id, division_id, owner_staff_id, classification, effective_classification, is_critical, effective_critical, client_deleted, status, retention_class_id, retention_months,
              retention_start, review_date, created_by, created_at, updated_at, last_activity_at, closed_at, archived_at, disposed_at, subject_purged_at) on communication_threads to authenticated;
grant select (id, thread_id, seq, type_key, direction, occurred_at, ended_at, recorded_at, recorded_by, recorded_txid, in_reply_to_message_id, body_purged_at, division_id,
              effective_classification, status) on communication_messages to authenticated;
grant select on communication_types, communication_links, communication_attachments, communication_access, communication_holds, communication_events, communication_retention_status to authenticated;
grant select (id, thread_id, state, reason, requested_by, requested_at, decided_by, decided_at, decision_note) on communication_disposals to authenticated;
grant insert, update on communication_types to authenticated;
grant insert (thread_id, entity_institutional_id, role) on communication_links to authenticated;
grant insert (thread_id, message_id, document_id) on communication_attachments to authenticated;
grant insert (message_id, role, entity_institutional_id, address_snapshot) on communication_participants to authenticated;

create policy communication_types_select on communication_types for select to authenticated using (has_permission_anywhere('communications.view'));
create policy communication_types_insert on communication_types for insert to authenticated with check (has_permission('communications.configure'));
create policy communication_types_update on communication_types for update to authenticated using (has_permission('communications.configure')) with check (has_permission('communications.configure'));

create policy communication_threads_select on communication_threads for select to authenticated
  using (communication_can_row(id, owner_staff_id, division_id, effective_classification, effective_critical, client_deleted, status, 'view'));
create policy communication_messages_select on communication_messages for select to authenticated using (communication_can(thread_id, 'view'));
create policy communication_participants_insert on communication_participants for insert to authenticated
  with check (exists (select 1 from communication_messages m where m.id = message_id and m.recorded_txid = txid_current() and communication_can(m.thread_id, 'append'))
              and (entity_institutional_id is null or exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id)));
create policy communication_links_select on communication_links for select to authenticated
  using (communication_can(thread_id, 'view') and exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id));
create policy communication_links_insert on communication_links for insert to authenticated
  with check (communication_can(thread_id, 'edit') and exists (select 1 from entity_registry r where r.institutional_id = entity_institutional_id));
create policy communication_attachments_select on communication_attachments for select to authenticated
  using (communication_can(thread_id, 'view') and exists (select 1 from documents d where d.id = document_id));
create policy communication_attachments_insert on communication_attachments for insert to authenticated
  with check (communication_can(thread_id, 'append') and exists (select 1 from documents d where d.id = document_id)
              and exists (select 1 from communication_messages m where m.id = message_id and m.thread_id = communication_attachments.thread_id));
create policy communication_access_select on communication_access for select to authenticated using (communication_can(thread_id, 'share'));
create policy communication_holds_select on communication_holds for select to authenticated using (communication_can(thread_id, 'view') and has_permission_anywhere('communications.legal_hold'));
create policy communication_disposals_select on communication_disposals for select to authenticated
  using (communication_can(thread_id, 'view') and (has_permission_anywhere('communications.dispose') or has_permission_anywhere('communications.archive')));
create policy communication_events_select on communication_events for select to authenticated
  using (communication_can(thread_id, 'view') and (kind not in ('read', 'attachment_opened') or has_permission('audit.view') or communication_can(thread_id, 'archive')));

revoke execute on function communication_can_row(uuid, uuid, uuid, data_classification, boolean, boolean, communication_status, text), communication_can(uuid, text), communication_on_hold(uuid),
  communication_start(uuid, text, data_classification, boolean, text, uuid), communication_message_record(uuid, text, text, timestamptz, text, timestamptz, uuid, text, text),
  communication_message_add(uuid, text, text, timestamptz, text, jsonb, timestamptz, uuid, text, text, uuid[]), communication_read(uuid, integer, integer), communication_attachment_open(uuid, text),
  communication_update(uuid, jsonb), communication_set_classification(uuid, data_classification, boolean, text), communication_set_retention(uuid, text, date, text),
  communication_transfer(uuid, uuid, text), communication_close(uuid, text), communication_reopen(uuid, text), communication_archive(uuid, text), communication_restore(uuid, text),
  communication_link_add(uuid, text, text), communication_link_remove(uuid, text), communication_attach_document(uuid, uuid), communication_attachment_remove(uuid, text),
  communication_share(uuid, uuid, uuid, text[], timestamptz, text), communication_unshare(uuid, text), communication_comment_add(uuid, text, integer),
  communication_hold_place(uuid, text), communication_hold_release(uuid, text), communication_request_disposal(uuid, text), communication_disposal_decide(uuid, boolean, text),
  communications_of(text[], date, date, timestamptz), communications_for_entity(text, date, date, timestamptz, boolean), communication_lookup(text), communication_360(uuid) from public, anon;
grant execute on function communication_can_row(uuid, uuid, uuid, data_classification, boolean, boolean, communication_status, text), communication_can(uuid, text), communication_on_hold(uuid),
  communication_start(uuid, text, data_classification, boolean, text, uuid), communication_message_record(uuid, text, text, timestamptz, text, timestamptz, uuid, text, text),
  communication_message_add(uuid, text, text, timestamptz, text, jsonb, timestamptz, uuid, text, text, uuid[]), communication_read(uuid, integer, integer), communication_attachment_open(uuid, text),
  communication_update(uuid, jsonb), communication_set_classification(uuid, data_classification, boolean, text), communication_set_retention(uuid, text, date, text),
  communication_transfer(uuid, uuid, text), communication_close(uuid, text), communication_reopen(uuid, text), communication_archive(uuid, text), communication_restore(uuid, text),
  communication_link_add(uuid, text, text), communication_link_remove(uuid, text), communication_attach_document(uuid, uuid), communication_attachment_remove(uuid, text),
  communication_share(uuid, uuid, uuid, text[], timestamptz, text), communication_unshare(uuid, text), communication_comment_add(uuid, text, integer),
  communication_hold_place(uuid, text), communication_hold_release(uuid, text), communication_request_disposal(uuid, text), communication_disposal_decide(uuid, boolean, text),
  communications_of(text[], date, date, timestamptz), communications_for_entity(text, date, date, timestamptz, boolean), communication_lookup(text), communication_360(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Audit: every table, content REDACTED (the audit log is permanent; a disposed body must not survive in it), and the audit log must not
-- become a side channel for communications the reader cannot see
-- ---------------------------------------------------------------------------
do $$ begin
  perform attach_audit('communication_types'); perform attach_audit('communication_threads', array['subject']); perform attach_audit('communication_messages', array['body']);
  perform attach_audit('communication_participants', array['address_snapshot']); perform attach_audit('communication_links'); perform attach_audit('communication_attachments');
  perform attach_audit('communication_access'); perform attach_audit('communication_holds'); perform attach_audit('communication_comments', array['body']); perform attach_audit('communication_disposals');
end $$;

create function audit_communication_visible(p_table text, p_record uuid, p_new jsonb, p_old jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_table = 'communication_threads' then communication_can(p_record, 'view')
    when p_table in ('communication_messages', 'communication_links', 'communication_attachments', 'communication_access', 'communication_holds', 'communication_disposals')
      then communication_can(nullif(coalesce(p_new, p_old) ->> 'thread_id', '')::uuid, 'view')
    when p_table in ('communication_participants', 'communication_comments')
      then communication_can(nullif(coalesce(p_new, p_old) ->> 'thread_id', '')::uuid, 'read')
    else true end
$$;
revoke execute on function audit_communication_visible(text, uuid, jsonb, jsonb) from public, anon;
grant execute on function audit_communication_visible(text, uuid, jsonb, jsonb) to authenticated;
drop policy audit_select on audit_log;
create policy audit_select on audit_log for select to authenticated
  using (has_permission('audit.view') and audit_document_visible(table_name, record_id, new_data, old_data) and audit_domain_visible(table_name, record_id, new_data, old_data)
         and audit_communication_visible(table_name, record_id, new_data, old_data));
