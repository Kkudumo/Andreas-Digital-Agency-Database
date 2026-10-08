-- 0027_contracts: Client -> Contact -> Quote -> Contract -> Project.
--  * A contract is the agreed commercial terms with ONE existing client. It references the client, the authorised
--    contact (a client_contacts row), the originating quote, the projects it covers, the services and the price
--    versions. It never copies identity: no client_name, no contact_name.
--  * The commercial terms live in immutable VERSIONS. Line prices are SNAPSHOTS of what was agreed (copied from the
--    quote or stated with a reason); later catalogue price changes never touch them.
--  * A signed version is never rewritten. An amendment is a new version; when it is signed the previous one becomes
--    "superseded" with an effective_to date. History (status trail + audit) is append-only.
--  * Lifecycle (contract_transition): draft -> internal_review -> approved -> sent -> signed -> active ->
--    expired | terminated, plus rejected, cancelled and renewed. Approval uses the shared approval engine
--    (kind 'contract', amount = contract total, discount = total line discounts).
--  * Visibility: contracts.view in the contract's division AND the client's classification (inherited), exactly like
--    projects/leads. A restricted client's contracts are indistinguishable from non-existent ones.

create type contract_status as enum ('draft', 'internal_review', 'approved', 'sent', 'signed', 'active', 'expired', 'terminated', 'rejected', 'cancelled', 'renewed');
create type contract_version_status as enum ('draft', 'internal_review', 'approved', 'sent', 'signed', 'rejected', 'cancelled', 'superseded');

create table contracts (
  id                       uuid primary key default gen_random_uuid(),
  ada_id                   text not null unique,
  client_id                uuid not null references clients (id) on delete restrict,
  quote_id                 uuid references quotes (id),
  division_id              uuid not null references divisions (id),
  owner_staff_id           uuid references staff (id),
  renewed_from_id          uuid references contracts (id),
  title                    text not null check (btrim(title) <> ''),
  currency                 char(3) not null default 'NAD',
  status                   contract_status not null default 'draft',
  current_version_no       integer not null default 1,
  signed_at                timestamptz,
  activated_at             timestamptz,
  terminated_at            timestamptz,
  status_reason            text,
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index contracts_client_idx on contracts (client_id);
create index contracts_quote_idx on contracts (quote_id);
create index contracts_status_idx on contracts (status);
create unique index contracts_one_per_quote on contracts (quote_id) where quote_id is not null and status not in ('rejected', 'cancelled');
create unique index contracts_one_renewal on contracts (renewed_from_id) where renewed_from_id is not null and status not in ('rejected', 'cancelled');
comment on table contracts is 'Purpose: the contract header - ONE authoritative record per agreement. References client, quote, division, owner; commercial terms live in contract_versions. No identity fields are stored here. [class: confidential]';
comment on column contracts.effective_classification is 'Inherited from the client (stricter classification wins). Maintained by trigger; drives visibility.';
comment on column contracts.client_deleted is 'True while the client is soft-deleted; hides the contract from anyone without records.view_deleted.';
do $$ begin perform attach_ada_id('contracts', 'contract'); end $$;
create trigger contracts_updated before update on contracts for each row execute function set_updated_at();

create table contract_versions (
  id                   uuid primary key default gen_random_uuid(),
  contract_id          uuid not null references contracts (id) on delete restrict,
  version_no           integer not null check (version_no >= 1),
  status               contract_version_status not null default 'draft',
  change_summary       text,
  contact_id           uuid references client_contacts (id),
  start_date           date,
  end_date             date,
  payment_terms_days   integer check (payment_terms_days between 0 and 365),
  payment_terms_text   text,
  terms_text           text,
  auto_renew           boolean not null default false,
  renewal_notice_days  integer check (renewal_notice_days between 0 and 365),
  renewal_term_months  integer check (renewal_term_months between 1 and 120),
  renewal_notes        text,
  document_ref         text,
  subtotal             numeric(14,2) not null default 0,
  discount_total       numeric(14,2) not null default 0,
  total                numeric(14,2) not null default 0,
  requested_by         uuid references staff (id),
  approved_by          uuid references staff (id),
  approved_at          timestamptz,
  sent_at              timestamptz,
  signed_on            date,
  signed_at            timestamptz,
  effective_from       date,
  effective_to         date,
  decision_note        text,
  created_by           uuid references staff (id),
  created_at           timestamptz not null default now(),
  unique (contract_id, version_no),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create unique index contract_versions_one_in_flight on contract_versions (contract_id) where status in ('draft', 'internal_review', 'approved', 'sent');
comment on table contract_versions is 'Purpose: the commercial terms of a contract, version by version. Editable only while draft; a signed version is immutable and later marked superseded (never rewritten). contact_id is the authorised contact (a client_contacts row). [class: confidential]';
comment on column contract_versions.total is 'Derived from the lines by trigger (subtotal - discounts); never typed in.';
comment on column contract_versions.document_ref is 'Reference to the signed/issued document until the documents module links it properly.';

create table contract_lines (
  id                    uuid primary key default gen_random_uuid(),
  version_id            uuid not null references contract_versions (id) on delete restrict,
  origin_line_id        uuid references contract_lines (id),
  position              integer not null default 100,
  service_id            uuid references services (id),
  price_id              uuid references service_prices (id),
  quote_line_id         uuid references quote_lines (id),
  description           text not null check (btrim(description) <> ''),
  quantity              numeric(12,2) not null default 1 check (quantity > 0),
  unit_price            numeric(14,2) not null check (unit_price >= 0),
  discount_amount       numeric(14,2) not null default 0 check (discount_amount >= 0),
  price_override_reason text,
  line_total            numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2)) stored,
  created_at            timestamptz not null default now(),
  check (price_id is null or service_id is not null),
  check (discount_amount <= quantity * unit_price)
);
create index contract_lines_version_idx on contract_lines (version_id, position);
create index contract_lines_origin_idx on contract_lines (origin_line_id);
comment on table contract_lines is 'Purpose: the agreed services and prices. unit_price/discount_amount are SNAPSHOTS of what was agreed (copied from the quote or stated with a reason); price_id records the catalogue version they came from. origin_line_id links a line to the same line in earlier versions so billing continues across amendments. [class: confidential]';

create function contract_lines_set_origin() returns trigger
language plpgsql as $$
begin
  if new.origin_line_id is null then new.origin_line_id := new.id; end if;
  return new;
end $$;
create trigger contract_lines_origin_trg before insert on contract_lines for each row execute function contract_lines_set_origin();

create table contract_projects (
  contract_id uuid not null references contracts (id) on delete restrict,
  project_id  uuid not null references projects (id) on delete restrict,
  linked_by   uuid references staff (id),
  linked_at   timestamptz not null default now(),
  primary key (contract_id, project_id)
);
create index contract_projects_project_idx on contract_projects (project_id);
comment on table contract_projects is 'Purpose: which projects a contract covers (a contract can cover several projects, a project can sit under several contracts over time). [class: confidential]';

create table contract_status_history (
  id             bigint generated always as identity primary key,
  contract_id    uuid not null references contracts (id) on delete restrict,
  version_no     integer,
  scope          text not null check (scope in ('contract', 'version')),
  from_status    text,
  to_status      text not null,
  actor_staff_id uuid references staff (id),
  note           text,
  created_at     timestamptz not null default now()
);
create index contract_status_history_idx on contract_status_history (contract_id, id);
comment on table contract_status_history is 'Purpose: append-only trail of every contract and version status change. Survives amendments; never edited. [class: confidential]';
create trigger contract_status_history_immutable before update or delete on contract_status_history for each row execute function append_only();

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create function contracts_inherit_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select classification, deleted_at is not null into new.effective_classification, new.client_deleted from clients where id = new.client_id;
  return new;
end $$;
create trigger contracts_inherit_trg before insert or update of client_id on contracts
  for each row execute function contracts_inherit_classification();

create function contracts_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    return new;
  end if;
  if tg_op = 'DELETE' then raise exception 'contracts cannot be deleted; cancel or terminate them' using errcode = '42501'; end if;
  if new.client_id is distinct from old.client_id or new.currency is distinct from old.currency or new.quote_id is distinct from old.quote_id
     or new.renewed_from_id is distinct from old.renewed_from_id or new.division_id is distinct from old.division_id then
    raise exception 'a contract''s client, quote, division and currency cannot change; create a new contract' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger contracts_guard_trg before insert or update or delete on contracts for each row execute function contracts_guard();

-- A version is editable only while draft; once past draft its commercial terms are frozen for EVERY caller.
create function contract_versions_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype;
begin
  if tg_op = 'DELETE' then raise exception 'contract versions cannot be deleted' using errcode = '42501'; end if;
  select * into c from contracts where id = new.contract_id;
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if new.contact_id is not null and not exists (select 1 from client_contacts cc where cc.id = new.contact_id and cc.client_id = c.client_id and cc.is_active) then
      raise exception 'the authorised contact must be an active contact of the contract''s client' using errcode = '23514';
    end if;
    return new;
  end if;
  if new.contract_id is distinct from old.contract_id or new.version_no is distinct from old.version_no then
    raise exception 'a version''s contract and number cannot change' using errcode = '42501';
  end if;
  if old.status <> 'draft' and (
       (new.change_summary, new.contact_id, new.start_date, new.end_date, new.payment_terms_days, new.payment_terms_text, new.terms_text, new.auto_renew,
        new.renewal_notice_days, new.renewal_term_months, new.renewal_notes, new.subtotal, new.discount_total, new.total)
       is distinct from
       (old.change_summary, old.contact_id, old.start_date, old.end_date, old.payment_terms_days, old.payment_terms_text, old.terms_text, old.auto_renew,
        old.renewal_notice_days, old.renewal_term_months, old.renewal_notes, old.subtotal, old.discount_total, old.total)) then
    raise exception 'contract terms are locked once a version leaves draft; create an amendment' using errcode = '42501';
  end if;
  if new.document_ref is distinct from old.document_ref
     and not (old.status in ('draft', 'internal_review', 'approved', 'sent') or (old.status = 'signed' and old.document_ref is null)) then
    raise exception 'the document reference of a signed version cannot be changed' using errcode = '42501';
  end if;
  if old.status in ('signed', 'superseded') and new.signed_on is distinct from old.signed_on then
    raise exception 'the signature date cannot be changed' using errcode = '42501';
  end if;
  if new.contact_id is distinct from old.contact_id and new.contact_id is not null
     and not exists (select 1 from client_contacts cc where cc.id = new.contact_id and cc.client_id = c.client_id and cc.is_active) then
    raise exception 'the authorised contact must be an active contact of the contract''s client' using errcode = '23514';
  end if;
  if old.status in ('signed', 'superseded', 'rejected', 'cancelled') and new.status is distinct from old.status
     and not (old.status = 'signed' and new.status = 'superseded') then
    raise exception 'a % version cannot change status', old.status using errcode = '23514';
  end if;
  return new;
end $$;
create trigger contract_versions_guard_trg before insert or update or delete on contract_versions for each row execute function contract_versions_guard();

create function contract_lines_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_status contract_version_status;
begin
  select status into v_status from contract_versions where id = coalesce(new.version_id, old.version_id);
  if v_status is distinct from 'draft' then
    raise exception 'contract lines are locked once the version leaves draft; create an amendment' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.version_id is distinct from old.version_id then
    raise exception 'a line cannot move between versions' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger contract_lines_guard_trg before insert or update or delete on contract_lines for each row execute function contract_lines_guard();

create function contract_lines_total() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := coalesce(new.version_id, old.version_id);
begin
  update contract_versions
     set subtotal = coalesce((select sum(round(quantity * unit_price, 2)) from contract_lines where version_id = v), 0),
         discount_total = coalesce((select sum(discount_amount) from contract_lines where version_id = v), 0),
         total = coalesce((select sum(line_total) from contract_lines where version_id = v), 0)
   where id = v;
  return null;
end $$;
create trigger contract_lines_total_trg after insert or update or delete on contract_lines for each row execute function contract_lines_total();

create function contract_projects_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then raise exception 'a project link cannot be removed; the link is part of the contract record' using errcode = '42501'; end if;
  if not exists (select 1 from contracts c join projects p on p.client_id = c.client_id where c.id = new.contract_id and p.id = new.project_id) then
    raise exception 'the project must belong to the contract''s client' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger contract_projects_guard_trg before insert or update or delete on contract_projects for each row execute function contract_projects_guard();

-- ---------------------------------------------------------------------------
-- Visibility (row-based; no helper that reveals whether a hidden client or contract exists)
-- ---------------------------------------------------------------------------
create function can_view_contract_row(p_division uuid, p_class data_classification, p_client_deleted boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('contracts.view', p_division) and classification_visible(p_class)
     and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_contract(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_contract_row(c.division_id, c.effective_classification, c.client_deleted) from contracts c where c.id = p_id), false)
$$;
create function can_view_contract_version(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_contract_row(c.division_id, c.effective_classification, c.client_deleted)
                   from contract_versions v join contracts c on c.id = v.contract_id where v.id = p_id), false)
$$;

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
create function contract_log(p_contract uuid, p_version integer, p_scope text, p_from text, p_to text, p_note text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into contract_status_history (contract_id, version_no, scope, from_status, to_status, actor_staff_id, note)
  values (p_contract, p_version, p_scope, p_from, p_to, current_staff_id(), p_note)
$$;

-- Loads a contract the caller may see, or fails exactly as for a contract that does not exist.
create function contract_load(p_id uuid) returns contracts
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype;
begin
  select * into c from contracts where id = p_id for update;
  if not found or not can_view_contract_row(c.division_id, c.effective_classification, c.client_deleted) then
    raise exception 'contract not found' using errcode = 'P0002';
  end if;
  return c;
end $$;

create function contract_create(p_client uuid, p_division uuid, p_title text, p_contact uuid default null, p_currency text default 'NAD') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clients%rowtype; v_id uuid; v_terms integer;
begin
  if not has_permission('contracts.create', p_division) then
    raise exception 'contracts.create is required in that division' using errcode = '42501';
  end if;
  select * into c from clients where id = p_client and deleted_at is null;
  if not found or not can_view_client(p_client) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if c.status = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
  select default_payment_terms_days into v_terms from finance_settings;
  insert into contracts (client_id, division_id, owner_staff_id, title, currency) values (p_client, p_division, current_staff_id(), p_title, p_currency)
  returning id into v_id;
  insert into contract_versions (contract_id, version_no, contact_id, payment_terms_days, start_date) values (v_id, 1, p_contact, v_terms, current_date);
  perform contract_log(v_id, 1, 'contract', null, 'draft', 'created');
  return v_id;
end $$;

-- Accepted quote -> contract: client, contact, services, price versions and discounts are carried over exactly as quoted.
create function contract_create_from_quote(p_quote uuid, p_title text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare q quotes%rowtype; v_id uuid; v_ver uuid; v_terms integer;
begin
  select * into q from quotes where id = p_quote for update;
  if not found or not can_view_quote(p_quote) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  if not has_permission('contracts.create', q.division_id) then raise exception 'contracts.create is required in that division' using errcode = '42501'; end if;
  if q.status <> 'accepted' then raise exception 'only an accepted quote can become a contract (currently %)', q.status using errcode = '23514'; end if;
  if exists (select 1 from contracts where quote_id = p_quote and status not in ('rejected', 'cancelled')) then
    raise exception 'this quote already has a contract' using errcode = '23505';
  end if;
  select default_payment_terms_days into v_terms from finance_settings;
  insert into contracts (client_id, quote_id, division_id, owner_staff_id, title, currency)
  values (q.client_id, p_quote, q.division_id, coalesce(q.assigned_staff_id, current_staff_id()), coalesce(nullif(btrim(p_title), ''), q.title), q.currency)
  returning id into v_id;
  insert into contract_versions (contract_id, version_no, contact_id, payment_terms_days, terms_text, start_date)
  values (v_id, 1, q.contact_id, v_terms, q.terms, current_date) returning id into v_ver;
  insert into contract_lines (version_id, position, service_id, price_id, quote_line_id, description, quantity, unit_price, discount_amount, price_override_reason)
  select v_ver, l.position, l.service_id, l.price_id, l.id, l.description, l.quantity, l.unit_price, l.discount_amount, l.price_override_reason
  from quote_lines l where l.quote_id = p_quote order by l.position, l.created_at;
  if q.project_id is not null then
    insert into contract_projects (contract_id, project_id, linked_by) values (v_id, q.project_id, current_staff_id()) on conflict do nothing;
  end if;
  perform contract_log(v_id, 1, 'contract', null, 'draft', 'created from quote');
  return v_id;
end $$;

create function contract_add_line(p_contract uuid, p_service uuid default null, p_quantity numeric default 1, p_unit_price numeric default null,
                                  p_override_reason text default null, p_description text default null, p_discount numeric default 0) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c contracts%rowtype; v contract_versions%rowtype; s services%rowtype; pr service_prices; v_id uuid; v_desc text;
begin
  c := contract_load(p_contract);
  if not has_permission('contracts.update', c.division_id) then raise exception 'contracts.update is required' using errcode = '42501'; end if;
  select * into v from contract_versions where contract_id = c.id and status = 'draft';
  if not found then raise exception 'contract lines can only be changed while a version is a draft' using errcode = '42501'; end if;
  if p_service is not null then
    select * into s from services where id = p_service and deleted_at is null and can_view_service(id);
    if not found then raise exception 'service not found' using errcode = 'P0002'; end if;
    pr := price_on(p_service, current_date);
    v_desc := coalesce(nullif(btrim(p_description), ''), s.name);
    if p_unit_price is null then
      if pr.id is null then raise exception 'this service has no approved price in force; give a price and a reason' using errcode = '23514'; end if;
      if pr.currency <> c.currency then raise exception 'the service price is in %, the contract is in %', pr.currency, c.currency using errcode = '23514'; end if;
      insert into contract_lines (version_id, service_id, price_id, description, quantity, unit_price, discount_amount)
      values (v.id, p_service, pr.id, v_desc, p_quantity, pr.amount, p_discount) returning id into v_id;
    else
      if coalesce(btrim(p_override_reason), '') = '' then raise exception 'a reason is required when the price differs from the catalogue' using errcode = '23514'; end if;
      insert into contract_lines (version_id, service_id, price_id, description, quantity, unit_price, discount_amount, price_override_reason)
      values (v.id, p_service, pr.id, v_desc, p_quantity, p_unit_price, p_discount, p_override_reason) returning id into v_id;
    end if;
  else
    if p_unit_price is null or coalesce(btrim(p_description), '') = '' then
      raise exception 'a custom line needs a description and a price' using errcode = '23514';
    end if;
    insert into contract_lines (version_id, description, quantity, unit_price, discount_amount, price_override_reason)
    values (v.id, p_description, p_quantity, p_unit_price, p_discount, p_override_reason) returning id into v_id;
  end if;
  return v_id;
end $$;

create function contract_remove_line(p_line uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype; v_contract uuid;
begin
  select v.contract_id into v_contract from contract_lines l join contract_versions v on v.id = l.version_id where l.id = p_line;
  if v_contract is null then raise exception 'contract line not found' using errcode = 'P0002'; end if;
  c := contract_load(v_contract);
  if not has_permission('contracts.update', c.division_id) then raise exception 'contracts.update is required' using errcode = '42501'; end if;
  delete from contract_lines where id = p_line;
end $$;

-- Edit the working draft version's terms. Whitelisted keys only.
create function contract_set_terms(p_contract uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c contracts%rowtype; v contract_versions%rowtype; k text;
  allowed text[] := array['title', 'contact_id', 'start_date', 'end_date', 'payment_terms_days', 'payment_terms_text', 'terms_text', 'auto_renew',
                          'renewal_notice_days', 'renewal_term_months', 'renewal_notes', 'document_ref', 'change_summary'];
begin
  c := contract_load(p_contract);
  if not has_permission('contracts.update', c.division_id) then raise exception 'contracts.update is required' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any (allowed) then raise exception 'unknown contract term: %', k using errcode = '22023'; end if;
  end loop;
  select * into v from contract_versions where contract_id = c.id and status in ('draft', 'internal_review', 'approved', 'sent') for update;
  if not found then raise exception 'there is no open version to edit; create an amendment' using errcode = '42501'; end if;
  if v.status <> 'draft' and (p_changes - 'document_ref') <> '{}'::jsonb then
    raise exception 'contract terms can only be edited while the version is a draft' using errcode = '42501';
  end if;
  if p_changes ? 'title' then
    if v.version_no <> 1 or c.current_version_no <> 1 then raise exception 'the title is fixed once the contract has been amended' using errcode = '23514'; end if;
    update contracts set title = p_changes ->> 'title' where id = c.id;
  end if;
  update contract_versions set
    contact_id          = case when p_changes ? 'contact_id' then (p_changes ->> 'contact_id')::uuid else contact_id end,
    start_date          = case when p_changes ? 'start_date' then (p_changes ->> 'start_date')::date else start_date end,
    end_date            = case when p_changes ? 'end_date' then (p_changes ->> 'end_date')::date else end_date end,
    payment_terms_days  = case when p_changes ? 'payment_terms_days' then (p_changes ->> 'payment_terms_days')::integer else payment_terms_days end,
    payment_terms_text  = case when p_changes ? 'payment_terms_text' then p_changes ->> 'payment_terms_text' else payment_terms_text end,
    terms_text          = case when p_changes ? 'terms_text' then p_changes ->> 'terms_text' else terms_text end,
    auto_renew          = case when p_changes ? 'auto_renew' then (p_changes ->> 'auto_renew')::boolean else auto_renew end,
    renewal_notice_days = case when p_changes ? 'renewal_notice_days' then (p_changes ->> 'renewal_notice_days')::integer else renewal_notice_days end,
    renewal_term_months = case when p_changes ? 'renewal_term_months' then (p_changes ->> 'renewal_term_months')::integer else renewal_term_months end,
    renewal_notes       = case when p_changes ? 'renewal_notes' then p_changes ->> 'renewal_notes' else renewal_notes end,
    document_ref        = case when p_changes ? 'document_ref' then p_changes ->> 'document_ref' else document_ref end,
    change_summary      = case when p_changes ? 'change_summary' then p_changes ->> 'change_summary' else change_summary end
  where id = v.id;
end $$;

create function contract_set_owner(p_contract uuid, p_staff uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype;
begin
  c := contract_load(p_contract);
  if not has_permission('contracts.update', c.division_id) then raise exception 'contracts.update is required' using errcode = '42501'; end if;
  if not exists (select 1 from staff where id = p_staff and account_status = 'active' and deleted_at is null) then
    raise exception 'the owner must be an active staff member' using errcode = '23514';
  end if;
  update contracts set owner_staff_id = p_staff where id = c.id;
end $$;

create function contract_link_project(p_contract uuid, p_project uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype;
begin
  c := contract_load(p_contract);
  if not has_permission('contracts.update', c.division_id) then raise exception 'contracts.update is required' using errcode = '42501'; end if;
  if c.status in ('rejected', 'cancelled', 'terminated', 'expired', 'renewed') then raise exception 'this contract is %', c.status using errcode = '23514'; end if;
  if not can_view_project(p_project) or not exists (select 1 from projects where id = p_project and client_id = c.client_id and deleted_at is null) then
    raise exception 'project not found for this client' using errcode = 'P0002';
  end if;
  insert into contract_projects (contract_id, project_id, linked_by) values (c.id, p_project, current_staff_id()) on conflict do nothing;
end $$;

-- Lifecycle. p_to is the contract-level target; for an amendment in flight the same verbs act on the amendment version
-- and the contract header keeps its status (active/signed).
create function contract_transition(p_contract uuid, p_to contract_status, p_note text default null, p_date date default null) returns contract_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c contracts%rowtype;
  v contract_versions%rowtype;
  cur contract_versions%rowtype;
  v_edit boolean;
  v_first boolean;
  v_gate text;
  v_lines integer;
  v_perm text;
  v_signed date;
begin
  c := contract_load(p_contract);
  v_edit := has_permission('contracts.update', c.division_id);
  select * into v from contract_versions where contract_id = c.id and status in ('draft', 'internal_review', 'approved', 'sent') for update;
  select * into cur from contract_versions where contract_id = c.id and status = 'signed';
  v_first := cur.id is null;                                 -- no signed version yet: header mirrors the working version

  case
    when p_to = 'internal_review' and v.status = 'draft' then
      if not v_edit then raise exception 'contracts.update is required' using errcode = '42501'; end if;
      select count(*) into v_lines from contract_lines where version_id = v.id;
      if v_lines = 0 then raise exception 'add at least one line before submitting' using errcode = '23514'; end if;
      if v.start_date is null then raise exception 'a start date is required' using errcode = '23514'; end if;
      if v.contact_id is null then raise exception 'an authorised contact is required' using errcode = '23514'; end if;
      if v.payment_terms_days is null then raise exception 'payment terms are required' using errcode = '23514'; end if;
      if (select status from clients where id = c.client_id) = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
      update contract_versions set status = 'internal_review', requested_by = current_staff_id() where id = v.id;
      perform approval_open('contract', 'contract_versions', v.id, c.ada_id, c.division_id,
                            coalesce((approval_policy('contract', c.division_id, v.total)).required_permission, 'contracts.approve'),
                            'Contract ' || c.ada_id || ' v' || v.version_no, c.effective_classification);
      if c.effective_classification = 'internal' then
        perform notify_holders('contracts.approve', c.division_id, 'approval.required', 'Contract awaiting approval: ' || c.ada_id, null, 'contracts', c.id, c.ada_id);
      end if;
      perform contract_log(c.id, v.version_no, 'version', 'draft', 'internal_review', p_note);
      if v_first then update contracts set status = 'internal_review' where id = c.id; perform contract_log(c.id, v.version_no, 'contract', 'draft', 'internal_review', p_note); end if;

    when p_to = 'draft' and v.status = 'internal_review' then
      if not (v_edit or has_permission('contracts.approve', c.division_id)) then raise exception 'not permitted' using errcode = '42501'; end if;
      update contract_versions set status = 'draft', decision_note = p_note where id = v.id;
      perform approval_close('contract_versions', v.id, 'cancelled', p_note);
      perform contract_log(c.id, v.version_no, 'version', 'internal_review', 'draft', p_note);
      if v_first then update contracts set status = 'draft' where id = c.id; perform contract_log(c.id, v.version_no, 'contract', 'internal_review', 'draft', p_note); end if;

    when p_to = 'approved' and v.status = 'internal_review' then
      v_gate := approval_gate('contract', 'contract_versions', v.id, c.division_id, v.total, v.requested_by, 'contracts.approve', true, p_note, v.discount_total);
      if v_gate = 'pending' then return c.status; end if;               -- more approvers needed
      update contract_versions set status = 'approved', approved_by = current_staff_id(), approved_at = now(), decision_note = p_note where id = v.id;
      perform approval_close('contract_versions', v.id, 'approved', p_note);
      perform contract_log(c.id, v.version_no, 'version', 'internal_review', 'approved', p_note);
      if v_first then update contracts set status = 'approved' where id = c.id; perform contract_log(c.id, v.version_no, 'contract', 'internal_review', 'approved', p_note); end if;
      perform emit_event('contract.approved', 'contracts', c.id, c.ada_id, jsonb_build_object('version', v.version_no));

    when p_to = 'rejected' and v.status = 'internal_review' then
      if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a contract' using errcode = '23514'; end if;
      perform approval_gate('contract', 'contract_versions', v.id, c.division_id, v.total, v.requested_by, 'contracts.approve', false, p_note, v.discount_total);
      update contract_versions set status = 'rejected', decision_note = p_note where id = v.id;
      perform approval_close('contract_versions', v.id, 'rejected', p_note);
      perform contract_log(c.id, v.version_no, 'version', 'internal_review', 'rejected', p_note);
      if v_first then update contracts set status = 'rejected', status_reason = p_note where id = c.id; perform contract_log(c.id, v.version_no, 'contract', 'internal_review', 'rejected', p_note); end if;

    when p_to = 'sent' and v.status = 'approved' then
      if not v_edit then raise exception 'contracts.update is required' using errcode = '42501'; end if;
      update contract_versions set status = 'sent', sent_at = now() where id = v.id;
      perform contract_log(c.id, v.version_no, 'version', 'approved', 'sent', p_note);
      if v_first then update contracts set status = 'sent' where id = c.id; perform contract_log(c.id, v.version_no, 'contract', 'approved', 'sent', p_note); end if;
      perform emit_event('contract.sent', 'contracts', c.id, c.ada_id, jsonb_build_object('version', v.version_no));

    when p_to = 'rejected' and v.status = 'sent' then                  -- the client declined
      if not v_edit then raise exception 'contracts.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'record why the client declined' using errcode = '23514'; end if;
      update contract_versions set status = 'rejected', decision_note = p_note where id = v.id;
      perform contract_log(c.id, v.version_no, 'version', 'sent', 'rejected', p_note);
      if v_first then update contracts set status = 'rejected', status_reason = p_note where id = c.id; perform contract_log(c.id, v.version_no, 'contract', 'sent', 'rejected', p_note); end if;

    when p_to = 'signed' and v.status = 'sent' then
      if not v_edit then raise exception 'contracts.update is required' using errcode = '42501'; end if;
      v_signed := coalesce(p_date, current_date);
      if v_signed > current_date then raise exception 'the signature date cannot be in the future' using errcode = '23514'; end if;
      if cur.id is not null then                                       -- an amendment: the previous signed version is superseded, not rewritten
        update contract_versions set status = 'superseded', effective_to = v_signed where id = cur.id;
        perform contract_log(c.id, cur.version_no, 'version', 'signed', 'superseded', 'superseded by version ' || v.version_no);
      end if;
      update contract_versions set status = 'signed', signed_on = v_signed, signed_at = now(), effective_from = v_signed where id = v.id;
      perform contract_log(c.id, v.version_no, 'version', 'sent', 'signed', p_note);
      if v_first then
        update contracts set status = 'signed', signed_at = now() where id = c.id;
        perform contract_log(c.id, v.version_no, 'contract', 'sent', 'signed', p_note);
      end if;
      perform emit_event('contract.signed', 'contracts', c.id, c.ada_id, jsonb_build_object('version', v.version_no));

    when p_to = 'active' and c.status = 'signed' and v.id is null then
      if not v_edit then raise exception 'contracts.update is required' using errcode = '42501'; end if;
      if cur.start_date > current_date then raise exception 'the contract starts on %', cur.start_date using errcode = '23514'; end if;
      perform contract_activate_row(c.id);

    when p_to = 'expired' and c.status = 'active' and v.id is null then
      if not v_edit then raise exception 'contracts.update is required' using errcode = '42501'; end if;
      if cur.end_date is null or cur.end_date >= current_date then raise exception 'the contract has not reached its end date' using errcode = '23514'; end if;
      update contracts set status = 'expired' where id = c.id;
      perform contract_log(c.id, cur.version_no, 'contract', 'active', 'expired', p_note);
      perform emit_event('contract.expired', 'contracts', c.id, c.ada_id, '{}');

    when p_to = 'terminated' and c.status in ('signed', 'active') then
      if not has_permission('contracts.terminate', c.division_id) then raise exception 'contracts.terminate is required' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
      if v.id is not null then
        update contract_versions set status = 'cancelled', decision_note = 'contract terminated' where id = v.id;
        perform approval_close('contract_versions', v.id, 'cancelled', 'contract terminated');
        perform contract_log(c.id, v.version_no, 'version', v.status::text, 'cancelled', 'contract terminated');
      end if;
      update contracts set status = 'terminated', terminated_at = now(), status_reason = p_note where id = c.id;
      perform contract_log(c.id, c.current_version_no, 'contract', c.status::text, 'terminated', p_note);
      perform emit_event('contract.terminated', 'contracts', c.id, c.ada_id, '{}');

    when p_to = 'cancelled' and v.id is not null then
      if not (v_edit or has_permission('contracts.approve', c.division_id)) then raise exception 'not permitted' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
      update contract_versions set status = 'cancelled', decision_note = p_note where id = v.id;
      perform approval_close('contract_versions', v.id, 'cancelled', p_note);
      perform contract_log(c.id, v.version_no, 'version', v.status::text, 'cancelled', p_note);
      if v_first then update contracts set status = 'cancelled', status_reason = p_note where id = c.id; perform contract_log(c.id, v.version_no, 'contract', c.status::text, 'cancelled', p_note); end if;

    else
      raise exception 'invalid contract transition % -> %', c.status, p_to using errcode = '23514';
  end case;
  return (select status from contracts where id = c.id);
end $$;

-- Internal: activate a signed contract (used by the manual transition and by the scheduled job).
create function contract_activate_row(p_contract uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype;
begin
  select * into c from contracts where id = p_contract;
  update contracts set status = 'active', activated_at = now() where id = p_contract;
  perform contract_log(p_contract, c.current_version_no, 'contract', 'signed', 'active', null);
  if c.renewed_from_id is not null then
    update contracts set status = 'renewed' where id = c.renewed_from_id and status in ('active', 'expired');
    if found then perform contract_log(c.renewed_from_id, null, 'contract', null, 'renewed', 'renewed by ' || c.ada_id); end if;
  end if;
  perform emit_event('contract.activated', 'contracts', c.id, c.ada_id, '{}');
end $$;

-- An amendment is a NEW version. The signed version stays exactly as signed until the amendment is signed, and then
-- becomes superseded (effective_to set) - it is never rewritten.
create function contract_amend(p_contract uuid, p_summary text) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype; cur contract_versions%rowtype; v_new uuid; v_no integer;
begin
  c := contract_load(p_contract);
  if not has_permission('contracts.create', c.division_id) then raise exception 'contracts.create is required in that division' using errcode = '42501'; end if;
  if c.status not in ('signed', 'active') then raise exception 'only a signed or active contract can be amended (currently %)', c.status using errcode = '23514'; end if;
  if coalesce(btrim(p_summary), '') = '' then raise exception 'describe what the amendment changes' using errcode = '23514'; end if;
  if exists (select 1 from contract_versions where contract_id = c.id and status in ('draft', 'internal_review', 'approved', 'sent')) then
    raise exception 'there is already an amendment in progress' using errcode = '23505';
  end if;
  select * into cur from contract_versions where contract_id = c.id and status = 'signed';
  v_no := c.current_version_no + 1;
  insert into contract_versions (contract_id, version_no, change_summary, contact_id, start_date, end_date, payment_terms_days, payment_terms_text, terms_text,
                                 auto_renew, renewal_notice_days, renewal_term_months, renewal_notes)
  select contract_id, v_no, p_summary, case when exists (select 1 from client_contacts cc where cc.id = cur.contact_id and cc.is_active) then cur.contact_id end,
         start_date, end_date, payment_terms_days, payment_terms_text, terms_text, auto_renew, renewal_notice_days, renewal_term_months, renewal_notes
  from contract_versions where id = cur.id returning id into v_new;
  insert into contract_lines (version_id, origin_line_id, position, service_id, price_id, quote_line_id, description, quantity, unit_price, discount_amount, price_override_reason)
  select v_new, origin_line_id, position, service_id, price_id, quote_line_id, description, quantity, unit_price, discount_amount, price_override_reason
  from contract_lines where version_id = cur.id order by position, created_at;
  update contracts set current_version_no = v_no where id = c.id;
  perform contract_log(c.id, v_no, 'version', null, 'draft', 'amendment: ' || p_summary);
  perform emit_event('contract.amended', 'contracts', c.id, c.ada_id, jsonb_build_object('version', v_no));
  return v_no;
end $$;

-- Renewal: a NEW contract for the next term at the agreed prices (not today's catalogue). The old contract becomes
-- "renewed" when the new one is activated.
create function contract_renew(p_contract uuid, p_start date default null, p_term_months integer default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c contracts%rowtype; cur contract_versions%rowtype; v_id uuid; v_ver uuid; v_start date; v_months integer;
begin
  c := contract_load(p_contract);
  if not has_permission('contracts.create', c.division_id) then raise exception 'contracts.create is required in that division' using errcode = '42501'; end if;
  if c.status not in ('active', 'expired') then raise exception 'only an active or expired contract can be renewed (currently %)', c.status using errcode = '23514'; end if;
  if exists (select 1 from contracts where renewed_from_id = c.id and status not in ('rejected', 'cancelled')) then
    raise exception 'this contract already has a renewal' using errcode = '23505';
  end if;
  select * into cur from contract_versions where contract_id = c.id and status = 'signed';
  v_months := coalesce(p_term_months, cur.renewal_term_months, 12);
  v_start := coalesce(p_start, cur.end_date + 1, current_date);
  insert into contracts (client_id, division_id, owner_staff_id, renewed_from_id, title, currency)
  values (c.client_id, c.division_id, coalesce(c.owner_staff_id, current_staff_id()), c.id, 'Renewal: ' || c.title, c.currency) returning id into v_id;
  insert into contract_versions (contract_id, version_no, change_summary, contact_id, start_date, end_date, payment_terms_days, payment_terms_text, terms_text,
                                 auto_renew, renewal_notice_days, renewal_term_months, renewal_notes)
  values (v_id, 1, 'renewal of ' || c.ada_id, case when exists (select 1 from client_contacts cc where cc.id = cur.contact_id and cc.is_active) then cur.contact_id end,
          v_start, (v_start + make_interval(months => v_months))::date - 1, cur.payment_terms_days, cur.payment_terms_text, cur.terms_text,
          cur.auto_renew, cur.renewal_notice_days, cur.renewal_term_months, cur.renewal_notes) returning id into v_ver;
  insert into contract_lines (version_id, position, service_id, price_id, quote_line_id, description, quantity, unit_price, discount_amount, price_override_reason)
  select v_ver, position, service_id, price_id, quote_line_id, description, quantity, unit_price, discount_amount, price_override_reason
  from contract_lines where version_id = cur.id order by position, created_at;
  insert into contract_projects (contract_id, project_id, linked_by)
  select v_id, project_id, current_staff_id() from contract_projects where contract_id = c.id;
  perform contract_log(v_id, 1, 'contract', null, 'draft', 'renewal of ' || c.ada_id);
  return v_id;
end $$;

-- Scheduled jobs (service role).
create function activate_contracts() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n integer := 0;
begin
  for r in select c.id from contracts c join contract_versions v on v.contract_id = c.id and v.status = 'signed'
           where c.status = 'signed' and v.start_date <= current_date
             and not exists (select 1 from contract_versions w where w.contract_id = c.id and w.status in ('draft', 'internal_review', 'approved', 'sent')) loop
    perform contract_activate_row(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

create function expire_contracts() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n integer := 0;
begin
  for r in select c.id, c.current_version_no, c.ada_id from contracts c join contract_versions v on v.contract_id = c.id and v.status = 'signed'
           where c.status = 'active' and v.end_date is not null and v.end_date < current_date loop
    update contracts set status = 'expired' where id = r.id;
    perform contract_log(r.id, r.current_version_no, 'contract', 'active', 'expired', 'end date passed');
    perform emit_event('contract.expired', 'contracts', r.id, r.ada_id, '{}');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Contracts whose renewal window is open (RLS applies: invoker rights).
create function contracts_due_for_renewal(p_within_days integer default 60)
returns table (contract_id uuid, ada_id text, end_date date, auto_renew boolean)
language sql stable as $$
  select c.id, c.ada_id, v.end_date, v.auto_renew
  from contracts c join contract_versions v on v.contract_id = c.id and v.status = 'signed'
  where c.status = 'active' and v.end_date is not null and v.end_date <= current_date + p_within_days
    and not exists (select 1 from contracts r where r.renewed_from_id = c.id and r.status not in ('rejected', 'cancelled'))
$$;

-- The terms in force today (the signed version), falling back to the working version. Invoker rights: RLS applies.
create function contract_terms(p_contract uuid) returns setof contract_versions
language sql stable as $$
  select * from contract_versions where contract_id = p_contract
  order by (status = 'signed') desc, version_no desc limit 1
$$;

-- ---------------------------------------------------------------------------
-- Default approval policy and the quote -> contract hook on project conversion is added in 0030
-- ---------------------------------------------------------------------------
insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note)
values ('contract', 'contracts.approve', true, true, 1, 'default');

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table contracts               enable row level security;
alter table contract_versions       enable row level security;
alter table contract_lines          enable row level security;
alter table contract_projects       enable row level security;
alter table contract_status_history enable row level security;
revoke all on contracts, contract_versions, contract_lines, contract_projects, contract_status_history from anon, authenticated;
grant select on contracts, contract_versions, contract_lines, contract_projects, contract_status_history to authenticated;

create policy contracts_select on contracts for select to authenticated using (can_view_contract_row(division_id, effective_classification, client_deleted));
create policy contract_versions_select on contract_versions for select to authenticated using (can_view_contract(contract_id));
create policy contract_lines_select on contract_lines for select to authenticated using (can_view_contract_version(version_id));
create policy contract_projects_select on contract_projects for select to authenticated using (can_view_contract(contract_id));
create policy contract_status_history_select on contract_status_history for select to authenticated using (can_view_contract(contract_id));

revoke execute on function can_view_contract_row(uuid, data_classification, boolean), can_view_contract(uuid), can_view_contract_version(uuid),
  contract_log(uuid, integer, text, text, text, text), contract_load(uuid), contract_activate_row(uuid),
  contract_create(uuid, uuid, text, uuid, text), contract_create_from_quote(uuid, text),
  contract_add_line(uuid, uuid, numeric, numeric, text, text, numeric), contract_remove_line(uuid), contract_set_terms(uuid, jsonb),
  contract_set_owner(uuid, uuid), contract_link_project(uuid, uuid), contract_transition(uuid, contract_status, text, date),
  contract_amend(uuid, text), contract_renew(uuid, date, integer), activate_contracts(), expire_contracts(),
  contracts_due_for_renewal(integer), contract_terms(uuid) from public, anon, authenticated;
grant execute on function can_view_contract_row(uuid, data_classification, boolean), can_view_contract(uuid), can_view_contract_version(uuid),
  contract_create(uuid, uuid, text, uuid, text), contract_create_from_quote(uuid, text),
  contract_add_line(uuid, uuid, numeric, numeric, text, text, numeric), contract_remove_line(uuid), contract_set_terms(uuid, jsonb),
  contract_set_owner(uuid, uuid), contract_link_project(uuid, uuid), contract_transition(uuid, contract_status, text, date),
  contract_amend(uuid, text), contract_renew(uuid, date, integer), contracts_due_for_renewal(integer), contract_terms(uuid) to authenticated;
grant execute on function activate_contracts(), expire_contracts() to service_role;

do $$ begin
  perform attach_audit('contracts');
  perform attach_audit('contract_versions');
  perform attach_audit('contract_lines');
  perform attach_audit('contract_projects');
end $$;
