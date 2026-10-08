-- 0028_invoices: Contract/Project -> Billable items -> Invoice -> Approval -> Issued.
--  * Billable items are the staging area. They are created from an agreed contract line (at the AGREED price), from a
--    project's service lines when no contract covers it, or manually with a stated reason. Quantity already billed is
--    tracked so a line can never be billed twice, across amendments too (origin_line_id).
--  * An invoice references the client, billing contact (a client_contacts row), contract, project and division. It
--    holds immutable line snapshots (quantity, price, discount, tax) and, at ISSUE, a documented SNAPSHOT of the
--    legal/billing identity as it was - the one place a copy is legally required. The invoice is never recomputed
--    from today's catalogue price or today's client name.
--  * Approval uses the shared approval engine (kind 'invoice', amount = total, discount = line discounts).
--  * Issued invoices are locked for every caller. Balances are NOT stored: see payments (0029).

create type billable_status as enum ('open', 'invoiced', 'void');
create type invoice_status as enum ('draft', 'pending_approval', 'approved', 'issued', 'partially_paid', 'paid', 'cancelled');

create table billable_items (
  id                       uuid primary key default gen_random_uuid(),
  client_id                uuid not null references clients (id) on delete restrict,
  division_id              uuid not null references divisions (id),
  source                   text not null check (source in ('contract', 'project', 'manual')),
  contract_id              uuid references contracts (id),
  contract_line_origin_id  uuid references contract_lines (id),
  project_id               uuid references projects (id),
  project_service_id       uuid references project_services (id),
  service_id               uuid references services (id),
  price_id                 uuid references service_prices (id),
  description              text not null check (btrim(description) <> ''),
  quantity                 numeric(12,2) not null check (quantity > 0),
  unit_price               numeric(14,2) not null check (unit_price >= 0),
  discount_amount          numeric(14,2) not null default 0 check (discount_amount >= 0),
  currency                 char(3) not null,
  status                   billable_status not null default 'open',
  manual_reason            text,
  void_reason              text,
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (discount_amount <= quantity * unit_price),
  check (source <> 'contract' or (contract_id is not null and contract_line_origin_id is not null)),
  check (source <> 'project' or project_service_id is not null),
  check (source <> 'manual' or coalesce(btrim(manual_reason), '') <> '')
);
create index billable_items_client_idx on billable_items (client_id);
create index billable_items_origin_idx on billable_items (contract_line_origin_id) where contract_line_origin_id is not null;
create index billable_items_pservice_idx on billable_items (project_service_id) where project_service_id is not null;
comment on table billable_items is 'Purpose: work/charges ready to invoice. unit_price/discount are SNAPSHOTS of the agreed contract line, project service line or a stated manual charge; they never follow the catalogue. Immutable apart from open -> invoiced/void. [class: confidential]';
create trigger billable_items_updated before update on billable_items for each row execute function set_updated_at();

create table invoices (
  id                                uuid primary key default gen_random_uuid(),
  ada_id                            text not null unique,
  client_id                         uuid not null references clients (id) on delete restrict,
  division_id                       uuid not null references divisions (id),
  contract_id                       uuid references contracts (id),
  project_id                        uuid references projects (id),
  billing_contact_id                uuid references client_contacts (id),
  status                            invoice_status not null default 'draft',
  currency                          char(3) not null,
  vat_rate                          numeric(5,2) not null default 0 check (vat_rate between 0 and 100),
  payment_terms_days                integer not null default 30 check (payment_terms_days between 0 and 365),
  po_reference                      text,
  notes                             text,
  subtotal                          numeric(14,2) not null default 0,
  discount_total                    numeric(14,2) not null default 0,
  tax_total                         numeric(14,2) not null default 0,
  total                             numeric(14,2) not null default 0,
  issue_date                        date,
  due_date                          date,
  requested_by                      uuid references staff (id),
  approved_by                       uuid references staff (id),
  approved_at                       timestamptz,
  issued_by                         uuid references staff (id),
  issued_at                         timestamptz,
  cancelled_at                      timestamptz,
  status_reason                     text,
  client_name_snapshot              text,
  client_address_snapshot           text,
  client_registration_snapshot      text,
  billing_contact_name_snapshot     text,
  billing_contact_email_snapshot    text,
  seller_legal_name_snapshot        text,
  seller_vat_number_snapshot        text,
  effective_classification          data_classification not null default 'internal',
  client_deleted                    boolean not null default false,
  created_by                        uuid references staff (id),
  created_at                        timestamptz not null default now(),
  updated_at                        timestamptz not null default now(),
  check (due_date is null or issue_date is null or due_date >= issue_date)
);
create index invoices_client_idx on invoices (client_id);
create index invoices_contract_idx on invoices (contract_id) where contract_id is not null;
create index invoices_project_idx on invoices (project_id) where project_id is not null;
create index invoices_status_idx on invoices (status);
comment on table invoices is 'Purpose: one invoice. References client, billing contact, contract, project and division by id. Totals are derived from the lines; the *_snapshot columns are taken ONCE at issue and never change. There is no balance column - the balance is derived from payment allocations. [class: confidential]';
comment on column invoices.client_name_snapshot           is 'SNAPSHOT: the client''s name as it was when the invoice was issued (a legal document must not change if the client is renamed). Not an identity field.';
comment on column invoices.client_address_snapshot        is 'SNAPSHOT: the client''s address at issue. Not an identity field.';
comment on column invoices.client_registration_snapshot   is 'SNAPSHOT: the client''s registration number at issue. Not an identity field.';
comment on column invoices.billing_contact_name_snapshot  is 'SNAPSHOT: the billing contact''s name at issue. Not an identity field.';
comment on column invoices.billing_contact_email_snapshot is 'SNAPSHOT: the billing contact''s email at issue. Not an identity field.';
comment on column invoices.seller_legal_name_snapshot     is 'SNAPSHOT: ADA''s legal name at issue.';
comment on column invoices.seller_vat_number_snapshot     is 'SNAPSHOT: ADA''s VAT number at issue.';
do $$ begin perform attach_ada_id('invoices', 'invoice'); end $$;
create trigger invoices_updated before update on invoices for each row execute function set_updated_at();
create trigger approval_sync_trg after insert or update on invoices
  for each row execute function approval_sync('invoice', 'invoices.approve', 'ada_id', 'division_id');

create table invoice_lines (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references invoices (id) on delete restrict,
  billable_item_id uuid not null references billable_items (id),
  position         integer not null default 100,
  service_id       uuid references services (id),
  price_id         uuid references service_prices (id),
  description      text not null,
  quantity         numeric(12,2) not null check (quantity > 0),
  unit_price       numeric(14,2) not null check (unit_price >= 0),
  discount_amount  numeric(14,2) not null default 0 check (discount_amount >= 0),
  tax_rate         numeric(5,2) not null default 0,
  net_amount       numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2)) stored,
  tax_amount       numeric(14,2) generated always as (round(round(quantity * unit_price - discount_amount, 2) * tax_rate / 100, 2)) stored,
  line_total       numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2) + round(round(quantity * unit_price - discount_amount, 2) * tax_rate / 100, 2)) stored,
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
create unique index invoice_lines_one_active_per_item on invoice_lines (billable_item_id) where active;
create index invoice_lines_invoice_idx on invoice_lines (invoice_id, position);
comment on table invoice_lines is 'Purpose: the invoice''s immutable line snapshots (quantity, price, discount, tax rate at the time). Locked once the invoice leaves draft. active=false marks lines of a cancelled invoice (their billable items are free to be invoiced again). [class: confidential]';

-- ---------------------------------------------------------------------------
-- Classification inheritance (same pattern as projects/contracts)
-- ---------------------------------------------------------------------------
create function finance_inherit_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select classification, deleted_at is not null into new.effective_classification, new.client_deleted from clients where id = new.client_id;
  return new;
end $$;
create trigger billable_items_inherit_trg before insert or update of client_id on billable_items for each row execute function finance_inherit_classification();
create trigger invoices_inherit_trg before insert or update of client_id on invoices for each row execute function finance_inherit_classification();

-- ---------------------------------------------------------------------------
-- Guards (apply to EVERY caller)
-- ---------------------------------------------------------------------------
create function billable_items_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'billable items cannot be deleted; void them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then new.created_by := current_staff_id(); return new; end if;
  if (new.client_id, new.division_id, new.source, new.contract_id, new.contract_line_origin_id, new.project_id, new.project_service_id, new.service_id, new.price_id,
      new.description, new.quantity, new.unit_price, new.discount_amount, new.currency)
     is distinct from
     (old.client_id, old.division_id, old.source, old.contract_id, old.contract_line_origin_id, old.project_id, old.project_service_id, old.service_id, old.price_id,
      old.description, old.quantity, old.unit_price, old.discount_amount, old.currency) then
    raise exception 'a billable item is a snapshot and cannot be edited; void it and create another' using errcode = '42501';
  end if;
  if old.status = 'void' and new.status <> 'void' then raise exception 'a void billable item cannot be reopened' using errcode = '23514'; end if;
  if old.status = 'invoiced' and new.status = 'void' then raise exception 'an invoiced item must be released from its invoice before it is voided' using errcode = '23514'; end if;
  return new;
end $$;
create trigger billable_items_guard_trg before insert or update or delete on billable_items for each row execute function billable_items_guard();

create function invoices_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c record;
begin
  if tg_op = 'DELETE' then raise exception 'invoices cannot be deleted; cancel them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if new.billing_contact_id is not null and not exists (select 1 from client_contacts cc where cc.id = new.billing_contact_id and cc.client_id = new.client_id and cc.is_active) then
      raise exception 'the billing contact must be an active contact of the invoice''s client' using errcode = '23514';
    end if;
    return new;
  end if;
  if new.client_id is distinct from old.client_id or new.division_id is distinct from old.division_id or new.currency is distinct from old.currency
     or new.contract_id is distinct from old.contract_id or new.project_id is distinct from old.project_id then
    raise exception 'an invoice''s client, division, currency, contract and project cannot change' using errcode = '42501';
  end if;
  -- status graph
  if new.status is distinct from old.status and not (
       (old.status = 'draft'            and new.status in ('pending_approval', 'cancelled'))
    or (old.status = 'pending_approval' and new.status in ('draft', 'approved', 'cancelled'))
    or (old.status = 'approved'         and new.status in ('issued', 'cancelled'))
    or (old.status = 'issued'           and new.status in ('partially_paid', 'paid', 'cancelled'))
    or (old.status = 'partially_paid'   and new.status in ('issued', 'paid'))
    or (old.status = 'paid'             and new.status in ('partially_paid', 'issued'))) then
    raise exception 'invalid invoice status change % -> %', old.status, new.status using errcode = '23514';
  end if;
  -- content is editable only while draft
  if old.status <> 'draft' and (new.billing_contact_id, new.vat_rate, new.payment_terms_days, new.po_reference, new.notes, new.subtotal, new.discount_total, new.tax_total, new.total)
     is distinct from (old.billing_contact_id, old.vat_rate, old.payment_terms_days, old.po_reference, old.notes, old.subtotal, old.discount_total, old.tax_total, old.total) then
    raise exception 'an invoice can only be edited while it is a draft' using errcode = '42501';
  end if;
  -- the issue snapshot is written once, at issue, and never again
  if old.status in ('issued', 'partially_paid', 'paid') or (old.status = 'cancelled' and old.issued_at is not null) then
    if (new.issue_date, new.due_date, new.issued_at, new.issued_by, new.client_name_snapshot, new.client_address_snapshot, new.client_registration_snapshot,
        new.billing_contact_name_snapshot, new.billing_contact_email_snapshot, new.seller_legal_name_snapshot, new.seller_vat_number_snapshot)
       is distinct from
       (old.issue_date, old.due_date, old.issued_at, old.issued_by, old.client_name_snapshot, old.client_address_snapshot, old.client_registration_snapshot,
        old.billing_contact_name_snapshot, old.billing_contact_email_snapshot, old.seller_legal_name_snapshot, old.seller_vat_number_snapshot) then
      raise exception 'an issued invoice is a legal record and cannot be altered' using errcode = '42501';
    end if;
  end if;
  if new.billing_contact_id is distinct from old.billing_contact_id and new.billing_contact_id is not null
     and not exists (select 1 from client_contacts cc where cc.id = new.billing_contact_id and cc.client_id = new.client_id and cc.is_active) then
    raise exception 'the billing contact must be an active contact of the invoice''s client' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger invoices_guard_trg before insert or update or delete on invoices for each row execute function invoices_guard();

create function invoice_lines_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_status invoice_status;
begin
  select status into v_status from invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if v_status = 'draft' then
    if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then raise exception 'a line cannot move between invoices' using errcode = '42501'; end if;
    return coalesce(new, old);
  end if;
  -- after draft only one thing may happen: the lines of a cancelled invoice are deactivated
  if tg_op = 'UPDATE' and v_status = 'cancelled' and not new.active and old.active
     and (new.invoice_id, new.billable_item_id, new.quantity, new.unit_price, new.discount_amount, new.tax_rate, new.description)
         is not distinct from (old.invoice_id, old.billable_item_id, old.quantity, old.unit_price, old.discount_amount, old.tax_rate, old.description) then
    return new;
  end if;
  raise exception 'invoice lines are locked once the invoice leaves draft' using errcode = '42501';
end $$;
create trigger invoice_lines_guard_trg before insert or update or delete on invoice_lines for each row execute function invoice_lines_guard();

create function invoice_lines_total() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update invoices set
    subtotal       = coalesce((select sum(round(quantity * unit_price, 2)) from invoice_lines where invoice_id = v), 0),
    discount_total = coalesce((select sum(discount_amount) from invoice_lines where invoice_id = v), 0),
    tax_total      = coalesce((select sum(tax_amount) from invoice_lines where invoice_id = v), 0),
    total          = coalesce((select sum(line_total) from invoice_lines where invoice_id = v), 0)
  where id = v and status = 'draft';
  return null;
end $$;
create trigger invoice_lines_total_trg after insert or update or delete on invoice_lines for each row execute function invoice_lines_total();

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------
create function can_view_invoice_row(p_division uuid, p_class data_classification, p_client_deleted boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('invoices.view', p_division) and classification_visible(p_class)
     and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_invoice(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_invoice_row(i.division_id, i.effective_classification, i.client_deleted) from invoices i where i.id = p_id), false)
$$;

-- Loads an invoice the caller may see, or fails exactly as for one that does not exist.
create function invoice_load(p_id uuid) returns invoices
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype;
begin
  select * into i from invoices where id = p_id for update;
  if not found or not can_view_invoice_row(i.division_id, i.effective_classification, i.client_deleted) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  return i;
end $$;

-- Valid allocated payments against an invoice. Replaced in 0029 once payments exist.
create function invoice_valid_allocated(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$ select 0::numeric $$;

-- ---------------------------------------------------------------------------
-- Billable items
-- ---------------------------------------------------------------------------
create function billable_from_contract(p_contract uuid, p_line uuid, p_quantity numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c contracts%rowtype; cl contract_lines%rowtype; v_origin uuid; v_billed numeric; v_billed_disc numeric; v_remaining numeric; v_qty numeric; v_disc numeric; v_id uuid;
begin
  c := contract_load(p_contract);
  if not has_permission('invoices.create', c.division_id) then raise exception 'invoices.create is required in that division' using errcode = '42501'; end if;
  if c.status not in ('signed', 'active') then raise exception 'only a signed or active contract can be billed (currently %)', c.status using errcode = '23514'; end if;
  select l.origin_line_id into v_origin from contract_lines l join contract_versions v on v.id = l.version_id where l.id = p_line and v.contract_id = c.id;
  if v_origin is null then raise exception 'contract line not found' using errcode = 'P0002'; end if;
  select l.* into cl from contract_lines l join contract_versions v on v.id = l.version_id
   where v.contract_id = c.id and v.status = 'signed' and l.origin_line_id = v_origin;
  if not found then raise exception 'that line is not part of the terms currently in force' using errcode = '23514'; end if;
  select coalesce(sum(quantity), 0), coalesce(sum(discount_amount), 0) into v_billed, v_billed_disc
    from billable_items where contract_line_origin_id = v_origin and status <> 'void';
  v_remaining := cl.quantity - v_billed;
  v_qty := coalesce(p_quantity, v_remaining);
  if v_qty <= 0 or v_qty > v_remaining then raise exception 'only % of this line remain to be billed', greatest(v_remaining, 0) using errcode = '23514'; end if;
  v_disc := case when v_qty = v_remaining then greatest(cl.discount_amount - v_billed_disc, 0) else round(cl.discount_amount * v_qty / cl.quantity, 2) end;
  v_disc := least(v_disc, round(v_qty * cl.unit_price, 2));
  insert into billable_items (client_id, division_id, source, contract_id, contract_line_origin_id, service_id, price_id, description, quantity, unit_price, discount_amount, currency)
  values (c.client_id, c.division_id, 'contract', c.id, v_origin, cl.service_id, cl.price_id, cl.description, v_qty, cl.unit_price, v_disc, c.currency)
  returning id into v_id;
  return v_id;
end $$;

create function billable_from_project(p_project_service uuid, p_quantity numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ps project_services%rowtype; p projects%rowtype; v_billed numeric; v_billed_disc numeric; v_remaining numeric; v_qty numeric; v_disc numeric; v_id uuid;
begin
  select * into ps from project_services where id = p_project_service;
  if not found then raise exception 'project service not found' using errcode = 'P0002'; end if;
  select * into p from projects where id = ps.project_id;
  if not can_view_project(p.id) then raise exception 'project service not found' using errcode = 'P0002'; end if;
  if not has_permission('invoices.create', p.lead_division_id) then raise exception 'invoices.create is required in that division' using errcode = '42501'; end if;
  if exists (select 1 from contract_projects cp join contracts c on c.id = cp.contract_id where cp.project_id = p.id and c.status in ('signed', 'active')) then
    raise exception 'this project is covered by a contract: bill it through the contract' using errcode = '23514';
  end if;
  select coalesce(sum(quantity), 0), coalesce(sum(discount_amount), 0) into v_billed, v_billed_disc
    from billable_items where project_service_id = ps.id and status <> 'void';
  v_remaining := ps.quantity - v_billed;
  v_qty := coalesce(p_quantity, v_remaining);
  if v_qty <= 0 or v_qty > v_remaining then raise exception 'only % of this service remain to be billed', greatest(v_remaining, 0) using errcode = '23514'; end if;
  v_disc := case when v_qty = v_remaining then greatest(ps.discount_amount - v_billed_disc, 0) else round(ps.discount_amount * v_qty / ps.quantity, 2) end;
  v_disc := least(v_disc, round(v_qty * ps.unit_price, 2));
  insert into billable_items (client_id, division_id, source, project_id, project_service_id, service_id, price_id, description, quantity, unit_price, discount_amount, currency)
  values (p.client_id, p.lead_division_id, 'project', p.id, ps.id, ps.service_id, ps.price_id,
          coalesce(ps.description, (select name from services where id = ps.service_id)), v_qty, ps.unit_price, v_disc, ps.currency)
  returning id into v_id;
  return v_id;
end $$;

create function billable_manual(p_client uuid, p_division uuid, p_description text, p_quantity numeric, p_unit_price numeric, p_reason text,
                                p_project uuid default null, p_discount numeric default 0, p_currency text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clients%rowtype; v_id uuid;
begin
  if not has_permission('invoices.create', p_division) then raise exception 'invoices.create is required in that division' using errcode = '42501'; end if;
  select * into c from clients where id = p_client and deleted_at is null;
  if not found or not can_view_client(p_client) then raise exception 'client not found' using errcode = 'P0002'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required for a manual charge' using errcode = '23514'; end if;
  if p_project is not null and not exists (select 1 from projects where id = p_project and client_id = p_client and deleted_at is null) then
    raise exception 'project not found for this client' using errcode = 'P0002';
  end if;
  insert into billable_items (client_id, division_id, source, project_id, description, quantity, unit_price, discount_amount, currency, manual_reason)
  values (p_client, p_division, 'manual', p_project, p_description, p_quantity, p_unit_price, p_discount,
          coalesce(p_currency, (select base_currency from finance_settings)), p_reason)
  returning id into v_id;
  return v_id;
end $$;

create function billable_void(p_item uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b billable_items%rowtype;
begin
  select * into b from billable_items where id = p_item for update;
  if not found or not can_view_invoice_row(b.division_id, b.effective_classification, b.client_deleted) then raise exception 'billable item not found' using errcode = 'P0002'; end if;
  if not has_permission('invoices.update', b.division_id) then raise exception 'invoices.update is required' using errcode = '42501'; end if;
  if b.status <> 'open' then raise exception 'only an open item can be voided (currently %)', b.status using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update billable_items set status = 'void', void_reason = p_reason where id = p_item;
end $$;

-- ---------------------------------------------------------------------------
-- Invoices
-- ---------------------------------------------------------------------------
create function invoice_add_lines(p_invoice uuid, p_items uuid[]) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype; b billable_items%rowtype; v_id uuid; n integer := 0; v_pos integer;
begin
  i := invoice_load(p_invoice);
  if not has_permission('invoices.update', i.division_id) then raise exception 'invoices.update is required' using errcode = '42501'; end if;
  if i.status <> 'draft' then raise exception 'an invoice can only be edited while it is a draft' using errcode = '42501'; end if;
  select coalesce(max(position), 0) into v_pos from invoice_lines where invoice_id = i.id;
  foreach v_id in array p_items loop
    select * into b from billable_items where id = v_id for update;
    if not found or not can_view_invoice_row(b.division_id, b.effective_classification, b.client_deleted) then raise exception 'billable item not found' using errcode = 'P0002'; end if;
    if b.client_id <> i.client_id then raise exception 'every item must belong to the invoice''s client' using errcode = '23514'; end if;
    if b.currency <> i.currency then raise exception 'every item must be in the invoice''s currency (%)', i.currency using errcode = '23514'; end if;
    if b.status <> 'open' then raise exception 'billable item is not open (%)', b.status using errcode = '23514'; end if;
    v_pos := v_pos + 10;
    insert into invoice_lines (invoice_id, billable_item_id, position, service_id, price_id, description, quantity, unit_price, discount_amount, tax_rate)
    values (i.id, b.id, v_pos, b.service_id, b.price_id, b.description, b.quantity, b.unit_price, b.discount_amount, i.vat_rate);
    update billable_items set status = 'invoiced' where id = b.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create function invoice_create(p_items uuid[], p_contact uuid default null, p_division uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b billable_items%rowtype; v_client uuid; v_currency char(3); v_divs uuid[]; v_div uuid; v_contracts uuid[]; v_projects uuid[];
  v_contract uuid; v_project uuid; v_contact uuid; v_terms integer; v_rate numeric; v_id uuid; s finance_settings%rowtype;
begin
  if p_items is null or cardinality(p_items) = 0 then raise exception 'choose at least one billable item' using errcode = '23514'; end if;
  select * into b from billable_items where id = p_items[1];
  if not found or not can_view_invoice_row(b.division_id, b.effective_classification, b.client_deleted) then raise exception 'billable item not found' using errcode = 'P0002'; end if;
  v_client := b.client_id; v_currency := b.currency;
  select array_agg(distinct division_id), array_agg(distinct contract_id) filter (where contract_id is not null), array_agg(distinct project_id) filter (where project_id is not null)
    into v_divs, v_contracts, v_projects from billable_items where id = any (p_items);
  v_div := coalesce(p_division, case when cardinality(v_divs) = 1 then v_divs[1] end);
  if v_div is null then raise exception 'these items belong to several divisions; choose the invoicing division' using errcode = '23514'; end if;
  if not has_permission('invoices.create', v_div) then raise exception 'invoices.create is required in that division' using errcode = '42501'; end if;
  if (select status from clients where id = v_client) = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
  v_contract := case when cardinality(v_contracts) = 1 then v_contracts[1] end;
  v_project := case when cardinality(v_projects) = 1 then v_projects[1] end;
  select * into s from finance_settings;
  v_rate := case when s.vat_registered then s.vat_rate else 0 end;
  v_terms := coalesce((select payment_terms_days from contract_versions where contract_id = v_contract and status = 'signed'), s.default_payment_terms_days);
  v_contact := coalesce(p_contact,
                        (select contact_id from contract_versions where contract_id = v_contract and status = 'signed'),
                        (select cc.id from client_contacts cc where cc.client_id = v_client and cc.is_active and cc.is_billing order by cc.is_primary desc limit 1),
                        (select cc.id from client_contacts cc where cc.client_id = v_client and cc.is_active and cc.is_primary limit 1));
  if v_contact is not null and not exists (select 1 from client_contacts cc where cc.id = v_contact and cc.client_id = v_client and cc.is_active) then
    v_contact := null;
  end if;
  insert into invoices (client_id, division_id, contract_id, project_id, billing_contact_id, currency, vat_rate, payment_terms_days)
  values (v_client, v_div, v_contract, v_project, v_contact, v_currency, v_rate, v_terms) returning id into v_id;
  perform invoice_add_lines(v_id, p_items);
  return v_id;
end $$;

create function invoice_remove_line(p_line uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype; l invoice_lines%rowtype;
begin
  select * into l from invoice_lines where id = p_line;
  if not found or not can_view_invoice(l.invoice_id) then raise exception 'invoice line not found' using errcode = 'P0002'; end if;
  i := invoice_load(l.invoice_id);
  if not has_permission('invoices.update', i.division_id) then raise exception 'invoices.update is required' using errcode = '42501'; end if;
  if i.status <> 'draft' then raise exception 'an invoice can only be edited while it is a draft' using errcode = '42501'; end if;
  delete from invoice_lines where id = p_line;
  update billable_items set status = 'open' where id = l.billable_item_id;
end $$;

create function invoice_set_terms(p_invoice uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype; k text; allowed text[] := array['billing_contact_id', 'payment_terms_days', 'po_reference', 'notes'];
begin
  i := invoice_load(p_invoice);
  if not has_permission('invoices.update', i.division_id) then raise exception 'invoices.update is required' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any (allowed) then raise exception 'unknown invoice term: %', k using errcode = '22023'; end if;
  end loop;
  if i.status <> 'draft' then raise exception 'an invoice can only be edited while it is a draft' using errcode = '42501'; end if;
  update invoices set
    billing_contact_id = case when p_changes ? 'billing_contact_id' then (p_changes ->> 'billing_contact_id')::uuid else billing_contact_id end,
    payment_terms_days = case when p_changes ? 'payment_terms_days' then (p_changes ->> 'payment_terms_days')::integer else payment_terms_days end,
    po_reference       = case when p_changes ? 'po_reference' then p_changes ->> 'po_reference' else po_reference end,
    notes              = case when p_changes ? 'notes' then p_changes ->> 'notes' else notes end
  where id = i.id;
end $$;

create function invoice_transition(p_id uuid, p_to invoice_status, p_note text default null) returns invoice_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  i invoices%rowtype; v_gate text; v_me uuid := current_staff_id(); n integer;
  c clients%rowtype; cc record; o organization%rowtype; s finance_settings%rowtype;
begin
  i := invoice_load(p_id);
  case
    when i.status = 'draft' and p_to = 'pending_approval' then
      if not (has_permission('invoices.update', i.division_id) or has_permission('invoices.create', i.division_id)) then raise exception 'invoices.update is required' using errcode = '42501'; end if;
      select count(*) into n from invoice_lines where invoice_id = i.id;
      if n = 0 then raise exception 'add at least one line before submitting' using errcode = '23514'; end if;
      if i.total <= 0 then raise exception 'an invoice must have a positive total' using errcode = '23514'; end if;
      if i.billing_contact_id is null then raise exception 'a billing contact is required' using errcode = '23514'; end if;
      if (select status from clients where id = i.client_id) = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
      update invoices set status = 'pending_approval', requested_by = v_me, status_reason = null where id = i.id;
      if i.effective_classification = 'internal' then
        perform notify_holders('invoices.approve', i.division_id, 'approval.required', 'Invoice awaiting approval: ' || i.ada_id, null, 'invoices', i.id, i.ada_id);
      end if;

    when i.status = 'pending_approval' and p_to = 'draft' then
      if v_me is not distinct from i.requested_by then                           -- the requester withdraws it
        if not (has_permission('invoices.update', i.division_id) or has_permission('invoices.create', i.division_id)) then raise exception 'not permitted' using errcode = '42501'; end if;
      else                                                                       -- an approver sends it back
        if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to send an invoice back' using errcode = '23514'; end if;
        perform approval_gate('invoice', 'invoices', i.id, i.division_id, i.total, i.requested_by, 'invoices.approve', false, p_note, i.discount_total);
      end if;
      update invoices set status = 'draft', status_reason = p_note where id = i.id;

    when i.status = 'pending_approval' and p_to = 'approved' then
      v_gate := approval_gate('invoice', 'invoices', i.id, i.division_id, i.total, i.requested_by, 'invoices.approve', true, p_note, i.discount_total);
      if v_gate = 'pending' then return i.status; end if;                        -- more approvers needed
      update invoices set status = 'approved', approved_by = v_me, approved_at = now(), status_reason = null where id = i.id;

    when i.status = 'approved' and p_to = 'issued' then
      if not has_permission('invoices.issue', i.division_id) then raise exception 'invoices.issue is required' using errcode = '42501'; end if;
      select * into c from clients where id = i.client_id;
      select pe.full_name as nm, pe.email as em into cc from client_contacts k join people pe on pe.id = k.person_id where k.id = i.billing_contact_id;
      select * into o from organization limit 1;
      select * into s from finance_settings;
      update invoices set status = 'issued', issue_date = current_date, due_date = current_date + payment_terms_days, issued_at = now(), issued_by = v_me,
             client_name_snapshot = c.name,
             client_address_snapshot = nullif(btrim(concat_ws(', ', c.address, c.city, c.country)), ''),
             client_registration_snapshot = c.registration_number,
             billing_contact_name_snapshot = cc.nm, billing_contact_email_snapshot = cc.em,
             seller_legal_name_snapshot = o.legal_name,
             seller_vat_number_snapshot = case when s.vat_registered then s.vat_number end
       where id = i.id;
      perform emit_event('invoice.issued', 'invoices', i.id, i.ada_id, jsonb_build_object('currency', i.currency));

    else
      raise exception 'invalid invoice transition % -> %', i.status, p_to using errcode = '23514';
  end case;
  return (select status from invoices where id = i.id);
end $$;

-- Cancel an invoice. Its billable items return to open so they can be invoiced correctly; the cancelled invoice and
-- its lines remain on record. An invoice with valid payments allocated must have them unallocated or reversed first.
create function invoice_void(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype;
begin
  i := invoice_load(p_id);
  if i.status in ('draft', 'pending_approval') then
    if not (has_permission('invoices.update', i.division_id) or has_permission('invoices.void', i.division_id)) then raise exception 'not permitted' using errcode = '42501'; end if;
  elsif i.status in ('approved', 'issued') then
    if not has_permission('invoices.void', i.division_id) then raise exception 'invoices.void is required' using errcode = '42501'; end if;
  else
    raise exception 'a % invoice cannot be cancelled; reverse its payments first', i.status using errcode = '23514';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if invoice_valid_allocated(i.id) > 0 then raise exception 'payments are allocated to this invoice; unallocate or reverse them first' using errcode = '23514'; end if;
  update invoices set status = 'cancelled', cancelled_at = now(), status_reason = p_reason where id = i.id;
  update invoice_lines set active = false where invoice_id = i.id;
  update billable_items set status = 'open' where id in (select billable_item_id from invoice_lines where invoice_id = i.id);
  if i.issued_at is not null then perform emit_event('invoice.cancelled', 'invoices', i.id, i.ada_id, '{}'); end if;
end $$;

insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note)
values ('invoice', 'invoices.approve', true, true, 1, 'default');

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table billable_items enable row level security;
alter table invoices       enable row level security;
alter table invoice_lines  enable row level security;
revoke all on billable_items, invoices, invoice_lines from anon, authenticated;
grant select on billable_items, invoices, invoice_lines to authenticated;
create policy billable_items_select on billable_items for select to authenticated using (can_view_invoice_row(division_id, effective_classification, client_deleted));
create policy invoices_select on invoices for select to authenticated using (can_view_invoice_row(division_id, effective_classification, client_deleted));
create policy invoice_lines_select on invoice_lines for select to authenticated using (can_view_invoice(invoice_id));

revoke execute on function can_view_invoice_row(uuid, data_classification, boolean), can_view_invoice(uuid), invoice_load(uuid), invoice_valid_allocated(uuid),
  billable_from_contract(uuid, uuid, numeric), billable_from_project(uuid, numeric),
  billable_manual(uuid, uuid, text, numeric, numeric, text, uuid, numeric, text), billable_void(uuid, text),
  invoice_add_lines(uuid, uuid[]), invoice_create(uuid[], uuid, uuid), invoice_remove_line(uuid), invoice_set_terms(uuid, jsonb),
  invoice_transition(uuid, invoice_status, text), invoice_void(uuid, text) from public, anon, authenticated;
grant execute on function can_view_invoice_row(uuid, data_classification, boolean), can_view_invoice(uuid),
  billable_from_contract(uuid, uuid, numeric), billable_from_project(uuid, numeric),
  billable_manual(uuid, uuid, text, numeric, numeric, text, uuid, numeric, text), billable_void(uuid, text),
  invoice_add_lines(uuid, uuid[]), invoice_create(uuid[], uuid, uuid), invoice_remove_line(uuid), invoice_set_terms(uuid, jsonb),
  invoice_transition(uuid, invoice_status, text), invoice_void(uuid, text) to authenticated;

do $$ begin
  perform attach_audit('billable_items');
  perform attach_audit('invoices');
  perform attach_audit('invoice_lines');
end $$;
