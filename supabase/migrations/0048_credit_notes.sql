-- 0048_credit_notes: correcting an issued invoice without rewriting it.
--  * Identity: a credit note is a registered entity (type `credit_note`, ADA-CRN-YYYY-####, plus the permanent institutional ID).
--  * It is issued AGAINST one invoice (a reference): client, division and currency are taken from that invoice and never typed again, and the credit note
--    inherits the invoice's classification, so a restricted client's credit notes are invisible to everyone without access.
--  * Lines are snapshots (quantity, price, discount, tax rate), either taken from an invoice line (a part or the whole of it) or free-form with a description.
--    Nothing can be credited beyond what was invoiced: per invoice line (by quantity) and per invoice (by total), checked under row locks.
--  * Lifecycle: draft -> pending_approval -> approved -> issued (+ cancelled before issue). Approval is the shared engine (kind `credit_note`, no self-approval
--    unless the policy allows it and the requester is the only qualified approver). An issued credit note is a legal record: locked for every caller, with the
--    same one-time identity snapshot as an invoice. It is never edited or deleted; correct it with another document.
--  * Applying: on issue the credit is applied to its own invoice up to what is still owed there; any excess stays as unapplied customer credit that can be applied
--    to another open invoice of the same client and currency (credit_note_allocate) and released again (credit_note_unallocate), exactly like a payment.
--  * Balances are DERIVED: invoice_balance = total - allocated payments - applied credit; an invoice's status follows payments + credit (a fully credited
--    invoice reads `paid`, i.e. fully settled). Nothing about balances is stored.

-- ---------------------------------------------------------------------------
-- 1. Permissions (the reviewed matrix, supabase/seed_data/permission_matrix.csv, carries the same rows)
-- ---------------------------------------------------------------------------
insert into permissions (key, module, action, description, sensitivity) values
  ('credit_notes.view', 'credit_notes', 'view', 'View credit notes and their applications', 'confidential'::data_classification),
  ('credit_notes.create', 'credit_notes', 'create', 'Draft, edit, submit and cancel credit notes', 'confidential'::data_classification),
  ('credit_notes.approve', 'credit_notes', 'approve', 'Approve credit notes before they are issued', 'confidential'::data_classification),
  ('credit_notes.issue', 'credit_notes', 'issue', 'Issue approved credit notes to the client', 'confidential'::data_classification),
  ('credit_notes.apply', 'credit_notes', 'apply', 'Apply unapplied credit to invoices and release applications', 'confidential'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'credit_notes.view'), ('administration_officer', 'credit_notes.view'), ('finance_officer', 'credit_notes.view'), ('division_lead', 'credit_notes.view'), ('auditor', 'credit_notes.view'),
  ('ceo', 'credit_notes.create'), ('finance_officer', 'credit_notes.create'),
  ('ceo', 'credit_notes.approve'), ('finance_officer', 'credit_notes.approve'),
  ('ceo', 'credit_notes.issue'), ('finance_officer', 'credit_notes.issue'),
  ('ceo', 'credit_notes.apply'), ('finance_officer', 'credit_notes.apply')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create type credit_note_status as enum ('draft', 'pending_approval', 'approved', 'issued', 'cancelled');

create table credit_notes (
  id                           uuid primary key default gen_random_uuid(),
  ada_id                       text not null unique,
  invoice_id                   uuid not null references invoices (id) on delete restrict,
  client_id                    uuid not null references clients (id) on delete restrict,
  division_id                  uuid not null references divisions (id),
  currency                     char(3) not null,
  reason_code                  text not null check (reason_code in ('billing_error', 'price_adjustment', 'service_not_delivered', 'goodwill', 'duplicate', 'other')),
  reason_note                  text,
  status                       credit_note_status not null default 'draft',
  subtotal                     numeric(14,2) not null default 0,
  discount_total               numeric(14,2) not null default 0,
  tax_total                    numeric(14,2) not null default 0,
  total                        numeric(14,2) not null default 0,
  requested_by                 uuid references staff (id),
  approved_by                  uuid references staff (id),
  approved_at                  timestamptz,
  issued_by                    uuid references staff (id),
  issued_at                    timestamptz,
  issue_date                   date,
  cancelled_at                 timestamptz,
  status_reason                text,
  client_name_snapshot         text,
  client_address_snapshot      text,
  client_registration_snapshot text,
  seller_legal_name_snapshot   text,
  seller_vat_number_snapshot   text,
  effective_classification     data_classification not null default 'internal',
  client_deleted               boolean not null default false,
  created_by                   uuid references staff (id),
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now(),
  check (reason_code <> 'other' or coalesce(btrim(reason_note), '') <> '')
);
create index credit_notes_invoice_idx on credit_notes (invoice_id);
create index credit_notes_client_idx on credit_notes (client_id);
create index credit_notes_status_idx on credit_notes (status);
comment on table credit_notes is 'Purpose: one credit note against one issued invoice. Client, division and currency come from the invoice; lines are snapshots; totals derive from the lines while draft; an issued credit note is a legal record (identity snapshot taken once at issue). What is applied / left unapplied is derived from credit_note_allocations. Written only by the credit_note_* functions. [class: confidential]';
comment on column credit_notes.client_name_snapshot       is 'SNAPSHOT: the client''s name as it was when the credit note was issued. Not an identity field.';
comment on column credit_notes.client_address_snapshot    is 'SNAPSHOT: the client''s address at issue. Not an identity field.';
comment on column credit_notes.client_registration_snapshot is 'SNAPSHOT: the client''s registration number at issue. Not an identity field.';
comment on column credit_notes.seller_legal_name_snapshot is 'SNAPSHOT: ADA''s legal name at issue.';
comment on column credit_notes.seller_vat_number_snapshot is 'SNAPSHOT: ADA''s VAT number at issue.';
do $$ begin perform attach_ada_id('credit_notes', 'credit_note'); end $$;
create trigger credit_notes_updated before update on credit_notes for each row execute function set_updated_at();
create trigger approval_sync_trg after insert or update on credit_notes
  for each row execute function approval_sync('credit_note', 'credit_notes.approve', 'ada_id', 'division_id');

create table credit_note_lines (
  id              uuid primary key default gen_random_uuid(),
  credit_note_id  uuid not null references credit_notes (id) on delete restrict,
  invoice_line_id uuid references invoice_lines (id),
  position        integer not null default 100,
  description     text not null check (btrim(description) <> ''),
  quantity        numeric(12,2) not null check (quantity > 0),
  unit_price      numeric(14,2) not null check (unit_price >= 0),
  discount_amount numeric(14,2) not null default 0 check (discount_amount >= 0),
  tax_rate        numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  net_amount      numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2)) stored,
  tax_amount      numeric(14,2) generated always as (round(round(quantity * unit_price - discount_amount, 2) * tax_rate / 100, 2)) stored,
  line_total      numeric(14,2) generated always as (round(quantity * unit_price - discount_amount, 2) + round(round(quantity * unit_price - discount_amount, 2) * tax_rate / 100, 2)) stored,
  created_at      timestamptz not null default now(),
  check (discount_amount <= quantity * unit_price)
);
create index credit_note_lines_cn_idx on credit_note_lines (credit_note_id, position);
create index credit_note_lines_invline_idx on credit_note_lines (invoice_line_id) where invoice_line_id is not null;
comment on table credit_note_lines is 'Purpose: the credit note''s line snapshots (quantity, price, discount, tax rate). Taken from an invoice line (so a price change elsewhere never moves them) or free-form. Locked once the credit note leaves draft. [class: confidential]';

create table credit_note_allocations (
  id             uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references credit_notes (id) on delete restrict,
  invoice_id     uuid not null references invoices (id) on delete restrict,
  amount         numeric(14,2) not null check (amount > 0),
  status         text not null default 'active' check (status in ('active', 'released')),
  allocated_by   uuid references staff (id),
  allocated_at   timestamptz not null default now(),
  released_by    uuid references staff (id),
  released_at    timestamptz,
  release_reason text,
  check ((status = 'active') = (released_at is null))
);
create unique index credit_note_allocations_one_active on credit_note_allocations (credit_note_id, invoice_id) where status = 'active';
create index credit_note_allocations_invoice_idx on credit_note_allocations (invoice_id) where status = 'active';
comment on table credit_note_allocations is 'Purpose: how much of which issued credit note settles which invoice. Never beyond the credit left on the note or the amount still owed on the invoice (enforced under row locks). Released, not deleted. [class: confidential]';

update entity_types set is_built = true, domain_table = 'credit_notes', division_col = 'division_id', status_col = 'status', class_col = 'effective_classification',
       label_col = null, description = 'Credit note (a correction against an issued invoice)' where key = 'credit_note';

-- ---------------------------------------------------------------------------
-- 3. Derived amounts (never stored)
-- ---------------------------------------------------------------------------
-- Credit applied to an invoice: active applications of issued credit notes.
create function invoice_credit_applied(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(a.amount), 0) from credit_note_allocations a join credit_notes c on c.id = a.credit_note_id
   where a.invoice_id = p_invoice and a.status = 'active' and c.status = 'issued'
$$;
-- What is still owed on an invoice (internal: no visibility check). total - allocated payments - applied credit.
create function invoice_open_amount(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select i.total - invoice_valid_allocated(i.id) - invoice_credit_applied(i.id) from invoices i where i.id = p_invoice
$$;
create function credit_note_applied(p_credit_note uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from credit_note_allocations where credit_note_id = p_credit_note and status = 'active'
$$;
-- Credit left on an issued credit note (0 before issue and after cancellation).
create function credit_note_unapplied(p_credit_note uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when c.status = 'issued' then c.total - credit_note_applied(c.id) else 0 end from credit_notes c where c.id = p_credit_note
$$;
-- Invoice balance now also subtracts applied credit. Visible only to someone who can see the invoice.
create or replace function invoice_balance(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when can_view_invoice(i.id) and i.status not in ('draft', 'pending_approval', 'approved', 'cancelled') then i.total - invoice_valid_allocated(i.id) - invoice_credit_applied(i.id) end
  from invoices i where i.id = p_invoice
$$;
create function invoice_credited(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when can_view_invoice(i.id) then invoice_credit_applied(i.id) end from invoices i where i.id = p_invoice
$$;
revoke execute on function invoice_credit_applied(uuid), invoice_open_amount(uuid), credit_note_applied(uuid), credit_note_unapplied(uuid) from public, anon, authenticated;
-- the same two figures for API callers: answered only for a credit note the caller may see (nothing for a hidden or unknown id)
create function credit_note_applied_amount(p_credit_note uuid) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not can_view_credit_note(p_credit_note) then return null; end if;
  return credit_note_applied(p_credit_note);
end $$;
create function credit_note_unapplied_amount(p_credit_note uuid) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not can_view_credit_note(p_credit_note) then return null; end if;
  return credit_note_unapplied(p_credit_note);
end $$;


create or replace view invoice_balances with (security_invoker = true) as
  select i.id as invoice_id, i.ada_id, i.client_id, i.status, i.currency, i.total, invoice_paid(i.id) as paid, invoice_balance(i.id) as balance,
         (i.due_date is not null and i.due_date < current_date and i.status in ('issued', 'partially_paid')) as is_overdue,
         invoice_credited(i.id) as credited
  from invoices i;

create view credit_note_balances with (security_invoker = true) as
  select c.id as credit_note_id, c.ada_id, c.client_id, c.invoice_id, c.status, c.currency, c.total,
         case when c.status = 'issued' then credit_note_applied_amount(c.id) else 0::numeric end as applied,
         credit_note_unapplied_amount(c.id) as unapplied
    from credit_notes c;
comment on view credit_note_balances is 'Purpose: derived amount applied and still unapplied (customer credit) per credit note. Row access follows the credit note''s own visibility. Nothing here is stored. [class: confidential]';

-- ---------------------------------------------------------------------------
-- 4. Inheritance
-- ---------------------------------------------------------------------------
create function credit_notes_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype;
begin
  select * into i from invoices where id = new.invoice_id;
  new.client_id := i.client_id; new.division_id := i.division_id; new.currency := i.currency;
  new.effective_classification := i.effective_classification; new.client_deleted := i.client_deleted;
  return new;
end $$;
create trigger credit_notes_inherit_trg before insert or update of invoice_id, status on credit_notes for each row execute function credit_notes_inherit();

-- an invoice whose classification / deletion changes (a client being restricted) re-derives its credit notes and the history of their approvals
create function credit_notes_follow_invoice() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (new.effective_classification, new.client_deleted) is distinct from (old.effective_classification, old.client_deleted) then
    update credit_notes set status = status where invoice_id = new.id;
    update approval_requests set classification = new.effective_classification where entity_table = 'credit_notes' and entity_id in (select id from credit_notes where invoice_id = new.id);
  end if;
  return null;
end $$;
create trigger credit_notes_follow_invoice_trg after update on invoices for each row execute function credit_notes_follow_invoice();

-- ---------------------------------------------------------------------------
-- 5. Guards (apply to EVERY caller)
-- ---------------------------------------------------------------------------
create function credit_notes_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then raise exception 'credit notes cannot be deleted; cancel them before issue' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if new.status <> 'draft' then raise exception 'a credit note starts as a draft' using errcode = '42501'; end if;
    return new;
  end if;
  if new.invoice_id is distinct from old.invoice_id or new.client_id is distinct from old.client_id or new.division_id is distinct from old.division_id or new.currency is distinct from old.currency then
    raise exception 'a credit note''s invoice, client, division and currency cannot change' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'draft'            and new.status in ('pending_approval', 'cancelled'))
    or (old.status = 'pending_approval' and new.status in ('draft', 'approved', 'cancelled'))
    or (old.status = 'approved'         and new.status in ('issued', 'cancelled'))) then
    raise exception 'invalid credit note status change % -> %', old.status, new.status using errcode = '23514';
  end if;
  if old.status <> 'draft' and (new.reason_code, new.reason_note, new.subtotal, new.discount_total, new.tax_total, new.total) is distinct from (old.reason_code, old.reason_note, old.subtotal, old.discount_total, old.tax_total, old.total) then
    raise exception 'a credit note can only be edited while it is a draft' using errcode = '42501';
  end if;
  if old.status = 'issued' and (new.issue_date, new.issued_at, new.issued_by, new.client_name_snapshot, new.client_address_snapshot, new.client_registration_snapshot, new.seller_legal_name_snapshot, new.seller_vat_number_snapshot)
     is distinct from (old.issue_date, old.issued_at, old.issued_by, old.client_name_snapshot, old.client_address_snapshot, old.client_registration_snapshot, old.seller_legal_name_snapshot, old.seller_vat_number_snapshot) then
    raise exception 'an issued credit note is a legal record and cannot be altered' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger credit_notes_guard_trg before insert or update or delete on credit_notes for each row execute function credit_notes_guard();

create function credit_note_lines_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_status credit_note_status; v_invoice uuid;
begin
  select status, invoice_id into v_status, v_invoice from credit_notes where id = coalesce(new.credit_note_id, old.credit_note_id);
  if v_status <> 'draft' then raise exception 'credit note lines are locked once the credit note leaves draft' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and new.credit_note_id is distinct from old.credit_note_id then raise exception 'a line cannot move between credit notes' using errcode = '42501'; end if;
  if tg_op <> 'DELETE' and new.invoice_line_id is not null and not exists (select 1 from invoice_lines il where il.id = new.invoice_line_id and il.invoice_id = v_invoice and il.active) then
    raise exception 'the line must belong to the invoice being credited' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $$;
create trigger credit_note_lines_guard_trg before insert or update or delete on credit_note_lines for each row execute function credit_note_lines_guard();

create function credit_note_lines_total() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := coalesce(new.credit_note_id, old.credit_note_id);
begin
  update credit_notes set
    subtotal       = coalesce((select sum(round(quantity * unit_price, 2)) from credit_note_lines where credit_note_id = v), 0),
    discount_total = coalesce((select sum(discount_amount) from credit_note_lines where credit_note_id = v), 0),
    tax_total      = coalesce((select sum(tax_amount) from credit_note_lines where credit_note_id = v), 0),
    total          = coalesce((select sum(line_total) from credit_note_lines where credit_note_id = v), 0)
  where id = v and status = 'draft';
  return null;
end $$;
create trigger credit_note_lines_total_trg after insert or update or delete on credit_note_lines for each row execute function credit_note_lines_total();

create function credit_note_allocations_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare cn credit_notes%rowtype; inv invoices%rowtype;
begin
  if tg_op = 'DELETE' then raise exception 'applications cannot be deleted; release them' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if (new.credit_note_id, new.invoice_id, new.amount, new.allocated_by, new.allocated_at) is distinct from (old.credit_note_id, old.invoice_id, old.amount, old.allocated_by, old.allocated_at) or old.status = 'released' then
      raise exception 'an application cannot be edited; release it and apply again' using errcode = '42501';
    end if;
    return new;
  end if;
  -- insert: lock the credit note, then the invoice (always in this order), and check every cap under the locks
  select * into cn from credit_notes where id = new.credit_note_id for update;
  select * into inv from invoices where id = new.invoice_id for update;
  if cn.client_id <> inv.client_id then raise exception 'a credit note can only be applied to invoices of the same client' using errcode = '23514'; end if;
  if cn.currency <> inv.currency then raise exception 'credit note currency (%) differs from invoice currency (%)', cn.currency, inv.currency using errcode = '23514'; end if;
  if cn.status <> 'issued' then raise exception 'only an issued credit note can be applied (currently %)', cn.status using errcode = '23514'; end if;
  if inv.status not in ('issued', 'partially_paid') then raise exception 'credit can only be applied to an issued invoice that is not yet settled (currently %)', inv.status using errcode = '23514'; end if;
  if new.amount > credit_note_unapplied(cn.id) then raise exception 'the application exceeds the credit left on the credit note (%)', credit_note_unapplied(cn.id) using errcode = '23514'; end if;
  if new.amount > invoice_open_amount(inv.id) then raise exception 'the application exceeds the amount still owed on the invoice (%)', invoice_open_amount(inv.id) using errcode = '23514'; end if;
  new.allocated_by := current_staff_id();
  return new;
end $$;
create trigger credit_note_allocations_guard_trg before insert or update or delete on credit_note_allocations for each row execute function credit_note_allocations_guard();

-- the invoice's status follows what is settled by payments and credit
create function credit_note_allocations_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform invoice_sync_status(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger credit_note_allocations_sync_trg after insert or update on credit_note_allocations for each row execute function credit_note_allocations_sync();

-- a client with credit still unapplied cannot be removed
create function clients_block_delete_with_credit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.deleted_at is not null and old.deleted_at is null and exists (select 1 from credit_notes c where c.client_id = new.id and credit_note_unapplied(c.id) > 0) then
    raise exception 'the client has credit that is not yet applied; apply it first' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger clients_block_delete_with_credit_trg before update of deleted_at on clients for each row execute function clients_block_delete_with_credit();

-- ---------------------------------------------------------------------------
-- 6. Authorisation helpers
-- ---------------------------------------------------------------------------
create function can_view_credit_note_row(p_division uuid, p_class data_classification, p_client_deleted boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(has_permission('credit_notes.view', p_division), false) and classification_visible(p_class)
     and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_credit_note(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_credit_note_row(c.division_id, c.effective_classification, c.client_deleted) from credit_notes c where c.id = p_id), false)
$$;
create function credit_note_load(p_id uuid) returns credit_notes
language plpgsql security definer set search_path = public, pg_temp as $$
declare c credit_notes%rowtype;
begin
  select * into c from credit_notes where id = p_id for update;
  if not found or not can_view_credit_note_row(c.division_id, c.effective_classification, c.client_deleted) then raise exception 'credit note not found' using errcode = 'P0002'; end if;
  return c;
end $$;

-- nothing may be credited beyond what was invoiced: per invoice line (by quantity) and per invoice (by total), counting every other credit note that is
-- submitted, approved or issued. The caller holds the invoice row lock, so two credit notes cannot both slip under the cap.
create function credit_note_check_caps(p_credit_note uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c credit_notes%rowtype; inv invoices%rowtype; v_other numeric; r record;
begin
  select * into c from credit_notes where id = p_credit_note;
  select * into inv from invoices where id = c.invoice_id;
  select coalesce(sum(o.total), 0) into v_other from credit_notes o where o.invoice_id = c.invoice_id and o.id <> c.id and o.status in ('pending_approval', 'approved', 'issued');
  if v_other + c.total > inv.total then
    raise exception 'credit notes would exceed the invoice total: % already credited, % requested, invoice total %', v_other, c.total, inv.total using errcode = '23514';
  end if;
  for r in
    select il.id, il.quantity as invoiced, l.qty as mine,
           coalesce((select sum(l2.quantity) from credit_note_lines l2 join credit_notes o on o.id = l2.credit_note_id
                      where l2.invoice_line_id = il.id and o.id <> c.id and o.status in ('pending_approval', 'approved', 'issued')), 0) as others
      from (select invoice_line_id, sum(quantity) as qty from credit_note_lines where credit_note_id = c.id and invoice_line_id is not null group by 1) l
      join invoice_lines il on il.id = l.invoice_line_id
  loop
    if r.mine + r.others > r.invoiced then
      raise exception 'an invoice line cannot be credited beyond the quantity invoiced (% invoiced, % already credited, % requested)', r.invoiced, r.others, r.mine using errcode = '23514';
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Commands
-- ---------------------------------------------------------------------------
create function credit_note_create(p_invoice uuid, p_reason_code text, p_reason_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype; v_id uuid;
begin
  i := invoice_load(p_invoice);
  if not has_permission('credit_notes.create', i.division_id) then raise exception 'credit_notes.create is required' using errcode = '42501'; end if;
  if i.status not in ('issued', 'partially_paid', 'paid') then raise exception 'a credit note can only be raised against an issued invoice (currently %)', i.status using errcode = '23514'; end if;
  insert into credit_notes (invoice_id, client_id, division_id, currency, reason_code, reason_note)
  values (i.id, i.client_id, i.division_id, i.currency, p_reason_code, nullif(btrim(coalesce(p_reason_note, '')), ''))
  returning id into v_id;
  return v_id;
end $$;

-- A line taken from an invoice line: price, discount (pro rata) and tax rate are copied. Quantity defaults to everything not yet credited.
create function credit_note_add_line(p_credit_note uuid, p_invoice_line uuid, p_quantity numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c credit_notes%rowtype; il invoice_lines%rowtype; v_others numeric; v_qty numeric; v_id uuid; v_desc numeric;
begin
  c := credit_note_load(p_credit_note);
  if not has_permission('credit_notes.create', c.division_id) then raise exception 'credit_notes.create is required' using errcode = '42501'; end if;
  if c.status <> 'draft' then raise exception 'credit note lines can only change while it is a draft' using errcode = '42501'; end if;
  select * into il from invoice_lines where id = p_invoice_line and invoice_id = c.invoice_id and active;
  if not found then raise exception 'invoice line not found' using errcode = 'P0002'; end if;
  select coalesce(sum(l.quantity), 0) into v_others from credit_note_lines l join credit_notes o on o.id = l.credit_note_id
   where l.invoice_line_id = il.id and (o.id = c.id or o.status in ('pending_approval', 'approved', 'issued'));
  v_qty := coalesce(p_quantity, il.quantity - v_others);
  if v_qty is null or v_qty <= 0 then raise exception 'there is nothing left to credit on that line' using errcode = '23514'; end if;
  if v_others + v_qty > il.quantity then raise exception 'an invoice line cannot be credited beyond the quantity invoiced (% invoiced, % already credited)', il.quantity, v_others using errcode = '23514'; end if;
  v_desc := round(il.discount_amount * v_qty / il.quantity, 2);
  insert into credit_note_lines (credit_note_id, invoice_line_id, description, quantity, unit_price, discount_amount, tax_rate)
  values (c.id, il.id, il.description, v_qty, il.unit_price, v_desc, il.tax_rate) returning id into v_id;
  return v_id;
end $$;

-- A free-form line (an agreed concession that is not a part of one invoice line). The tax rate defaults to the invoice's.
create function credit_note_add_custom_line(p_credit_note uuid, p_description text, p_quantity numeric, p_unit_price numeric, p_tax_rate numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c credit_notes%rowtype; v_id uuid; v_rate numeric;
begin
  c := credit_note_load(p_credit_note);
  if not has_permission('credit_notes.create', c.division_id) then raise exception 'credit_notes.create is required' using errcode = '42501'; end if;
  if c.status <> 'draft' then raise exception 'credit note lines can only change while it is a draft' using errcode = '42501'; end if;
  v_rate := coalesce(p_tax_rate, (select vat_rate from invoices where id = c.invoice_id));
  insert into credit_note_lines (credit_note_id, description, quantity, unit_price, tax_rate) values (c.id, btrim(p_description), p_quantity, p_unit_price, v_rate) returning id into v_id;
  return v_id;
end $$;

create function credit_note_remove_line(p_line uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l credit_note_lines%rowtype; c credit_notes%rowtype;
begin
  select * into l from credit_note_lines where id = p_line;
  if not found or not can_view_credit_note(l.credit_note_id) then raise exception 'credit note line not found' using errcode = 'P0002'; end if;
  c := credit_note_load(l.credit_note_id);
  if not has_permission('credit_notes.create', c.division_id) then raise exception 'credit_notes.create is required' using errcode = '42501'; end if;
  if c.status <> 'draft' then raise exception 'credit note lines can only change while it is a draft' using errcode = '42501'; end if;
  delete from credit_note_lines where id = l.id;
end $$;

create function credit_note_transition(p_id uuid, p_to credit_note_status, p_note text default null) returns credit_note_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare c credit_notes%rowtype; inv invoices%rowtype; v_gate text; v_me uuid := current_staff_id(); n integer; cl clients%rowtype; o organization%rowtype; s finance_settings%rowtype; v_apply numeric;
begin
  c := credit_note_load(p_id);
  perform 1 from invoices where id = c.invoice_id for update;                    -- the invoice lock serialises the caps for credit notes of one invoice
  select * into inv from invoices where id = c.invoice_id;
  case
    when c.status = 'draft' and p_to = 'pending_approval' then
      if not has_permission('credit_notes.create', c.division_id) then raise exception 'credit_notes.create is required' using errcode = '42501'; end if;
      select count(*) into n from credit_note_lines where credit_note_id = c.id;
      if n = 0 then raise exception 'add at least one line before submitting' using errcode = '23514'; end if;
      if c.total <= 0 then raise exception 'a credit note must have a positive total' using errcode = '23514'; end if;
      if inv.status not in ('issued', 'partially_paid', 'paid') then raise exception 'the invoice is % and can no longer be credited', inv.status using errcode = '23514'; end if;
      perform credit_note_check_caps(c.id);
      update credit_notes set status = 'pending_approval', requested_by = v_me, status_reason = null where id = c.id;
      if c.effective_classification = 'internal' then
        perform notify_holders('credit_notes.approve', c.division_id, 'approval.required', 'Credit note awaiting approval: ' || c.ada_id, null, 'credit_notes', c.id, c.ada_id);
      end if;

    when c.status = 'pending_approval' and p_to = 'draft' then
      if v_me is not distinct from c.requested_by then
        if not has_permission('credit_notes.create', c.division_id) then raise exception 'not permitted' using errcode = '42501'; end if;
      else
        if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to send a credit note back' using errcode = '23514'; end if;
        perform approval_gate('credit_note', 'credit_notes', c.id, c.division_id, c.total, c.requested_by, 'credit_notes.approve', false, p_note);
      end if;
      update credit_notes set status = 'draft', status_reason = p_note where id = c.id;

    when c.status = 'pending_approval' and p_to = 'approved' then
      perform credit_note_check_caps(c.id);
      v_gate := approval_gate('credit_note', 'credit_notes', c.id, c.division_id, c.total, c.requested_by, 'credit_notes.approve', true, p_note);
      if v_gate = 'pending' then return c.status; end if;
      update credit_notes set status = 'approved', approved_by = v_me, approved_at = now(), status_reason = null where id = c.id;

    when c.status = 'approved' and p_to = 'issued' then
      if not has_permission('credit_notes.issue', c.division_id) then raise exception 'credit_notes.issue is required' using errcode = '42501'; end if;
      if inv.status not in ('issued', 'partially_paid', 'paid') then raise exception 'the invoice is % and can no longer be credited', inv.status using errcode = '23514'; end if;
      perform credit_note_check_caps(c.id);
      select * into cl from clients where id = c.client_id;
      select * into o from organization limit 1;
      select * into s from finance_settings;
      update credit_notes set status = 'issued', issue_date = current_date, issued_at = now(), issued_by = v_me,
             client_name_snapshot = cl.name,
             client_address_snapshot = nullif(btrim(concat_ws(', ', cl.address, cl.city, cl.country)), ''),
             client_registration_snapshot = cl.registration_number,
             seller_legal_name_snapshot = o.legal_name,
             seller_vat_number_snapshot = case when s.vat_registered then s.vat_number end
       where id = c.id;
      -- apply it to its own invoice up to what is still owed there; the rest stays as unapplied credit
      v_apply := least(c.total, greatest(invoice_open_amount(inv.id), 0));
      if v_apply > 0 and inv.status in ('issued', 'partially_paid') then
        insert into credit_note_allocations (credit_note_id, invoice_id, amount) values (c.id, inv.id, v_apply);
      end if;
      perform emit_event('credit_note.issued', 'credit_notes', c.id, c.ada_id, jsonb_build_object('currency', c.currency));

    when c.status in ('draft', 'pending_approval', 'approved') and p_to = 'cancelled' then
      if not (has_permission('credit_notes.create', c.division_id) or has_permission('credit_notes.approve', c.division_id)) then raise exception 'not permitted' using errcode = '42501'; end if;
      if c.status = 'approved' and not has_permission('credit_notes.approve', c.division_id) then raise exception 'credit_notes.approve is required to cancel an approved credit note' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required to cancel a credit note' using errcode = '23514'; end if;
      update credit_notes set status = 'cancelled', cancelled_at = now(), status_reason = p_note where id = c.id;

    else
      raise exception 'invalid credit note transition % -> %', c.status, p_to using errcode = '23514';
  end case;
  return (select status from credit_notes where id = c.id);
end $$;

create function credit_note_allocate(p_credit_note uuid, p_invoice uuid, p_amount numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c credit_notes%rowtype; i invoices%rowtype; v_amount numeric; v_id uuid;
begin
  c := credit_note_load(p_credit_note);                              -- credit note first, then invoice: the same lock order as the trigger
  i := invoice_load(p_invoice);
  if not has_permission('credit_notes.apply') then raise exception 'credit_notes.apply is required' using errcode = '42501'; end if;
  if i.client_id <> c.client_id then raise exception 'a credit note can only be applied to invoices of the same client' using errcode = '23514'; end if;
  v_amount := coalesce(p_amount, least(credit_note_unapplied(c.id), invoice_open_amount(i.id)));
  if v_amount is null or v_amount <= 0 then raise exception 'there is nothing to apply' using errcode = '23514'; end if;
  insert into credit_note_allocations (credit_note_id, invoice_id, amount) values (c.id, i.id, v_amount) returning id into v_id;
  return v_id;
end $$;

create function credit_note_unallocate(p_allocation uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a credit_note_allocations%rowtype;
begin
  select * into a from credit_note_allocations where id = p_allocation;
  if not found or not can_view_credit_note(a.credit_note_id) or not can_view_invoice(a.invoice_id) then raise exception 'application not found' using errcode = 'P0002'; end if;
  perform credit_note_load(a.credit_note_id);
  perform invoice_load(a.invoice_id);
  if not has_permission('credit_notes.apply') then raise exception 'credit_notes.apply is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into a from credit_note_allocations where id = p_allocation for update;
  if a.status <> 'active' then raise exception 'that application is already released' using errcode = '23514'; end if;
  update credit_note_allocations set status = 'released', released_by = current_staff_id(), released_at = now(), release_reason = p_reason where id = a.id;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Grants, RLS, audit
-- ---------------------------------------------------------------------------
alter table credit_notes            enable row level security;
alter table credit_note_lines       enable row level security;
alter table credit_note_allocations enable row level security;
revoke all on credit_notes, credit_note_lines, credit_note_allocations, credit_note_balances from anon, authenticated;
grant select on credit_notes, credit_note_lines, credit_note_allocations, credit_note_balances to authenticated;
create policy credit_notes_select on credit_notes for select to authenticated using (can_view_credit_note_row(division_id, effective_classification, client_deleted));
create policy credit_note_lines_select on credit_note_lines for select to authenticated using (can_view_credit_note(credit_note_id));
create policy credit_note_allocations_select on credit_note_allocations for select to authenticated using (can_view_credit_note(credit_note_id));

revoke execute on function invoice_credited(uuid), credit_note_applied_amount(uuid), credit_note_unapplied_amount(uuid), can_view_credit_note_row(uuid, data_classification, boolean), can_view_credit_note(uuid), credit_note_load(uuid), credit_note_check_caps(uuid),
  credit_note_create(uuid, text, text), credit_note_add_line(uuid, uuid, numeric), credit_note_add_custom_line(uuid, text, numeric, numeric, numeric), credit_note_remove_line(uuid),
  credit_note_transition(uuid, credit_note_status, text), credit_note_allocate(uuid, uuid, numeric), credit_note_unallocate(uuid, text) from public, anon, authenticated;
grant execute on function invoice_credited(uuid), credit_note_applied_amount(uuid), credit_note_unapplied_amount(uuid), can_view_credit_note_row(uuid, data_classification, boolean), can_view_credit_note(uuid),
  credit_note_create(uuid, text, text), credit_note_add_line(uuid, uuid, numeric), credit_note_add_custom_line(uuid, text, numeric, numeric, numeric), credit_note_remove_line(uuid),
  credit_note_transition(uuid, credit_note_status, text), credit_note_allocate(uuid, uuid, numeric), credit_note_unallocate(uuid, text) to authenticated;

do $$ begin
  perform attach_audit('credit_notes');
  perform attach_audit('credit_note_lines');
  perform attach_audit('credit_note_allocations');
end $$;

-- ---------------------------------------------------------------------------
-- 9. Search
-- ---------------------------------------------------------------------------
insert into search_sources (entity_type, label_expr, attribute_exprs, note) values
  ('credit_note', 'x.ada_id', array['x.status::text', 'x.currency'], 'METADATA only: number, status, currency; no amounts and no client text')
on conflict (entity_type) do nothing;
select attach_search('public.credit_notes'::regclass);

-- ---------------------------------------------------------------------------
-- 10. The finance functions that must now count credit (copies of 0029 / 0028 with the one change each)
-- ---------------------------------------------------------------------------
create or replace function payment_allocations_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare pay payments%rowtype; inv invoices%rowtype; v_other numeric;
begin
  if tg_op = 'DELETE' then raise exception 'allocations cannot be deleted; release them' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if (new.payment_id, new.invoice_id, new.amount, new.allocated_by, new.allocated_at) is distinct from (old.payment_id, old.invoice_id, old.amount, old.allocated_by, old.allocated_at)
       or old.status = 'released' then
      raise exception 'an allocation cannot be edited; release it and allocate again' using errcode = '42501';
    end if;
    return new;
  end if;
  -- insert: lock the payment, then the invoice (always in this order), and check every cap under the locks
  select * into pay from payments where id = new.payment_id for update;
  select * into inv from invoices where id = new.invoice_id for update;
  if pay.client_id <> inv.client_id then raise exception 'a payment can only settle invoices of the same client' using errcode = '23514'; end if;
  if pay.currency <> inv.currency then raise exception 'payment currency (%) differs from invoice currency (%)', pay.currency, inv.currency using errcode = '23514'; end if;
  if pay.status <> 'received' then raise exception 'only a received payment can be allocated (currently %)', pay.status using errcode = '23514'; end if;
  if inv.status not in ('issued', 'partially_paid') then raise exception 'payments can only be allocated to an issued invoice that is not yet paid (currently %)', inv.status using errcode = '23514'; end if;
  if new.amount > payment_credit(pay.id) then raise exception 'the allocation exceeds the credit left on the payment (%)', payment_credit(pay.id) using errcode = '23514'; end if;
  if new.amount > invoice_open_amount(inv.id) then raise exception 'the allocation exceeds the invoice balance (%)', invoice_open_amount(inv.id) using errcode = '23514'; end if;
  new.allocated_by := current_staff_id();
  return new;
end $$;

create or replace function invoice_sync_status(p_invoice uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype; v_paid numeric; v_to invoice_status;
begin
  select * into i from invoices where id = p_invoice for update;
  if not found or i.status not in ('issued', 'partially_paid', 'paid') then return; end if;
  v_paid := invoice_valid_allocated(i.id) + invoice_credit_applied(i.id);   -- settled = cash allocated + credit notes applied
  v_to := case when v_paid >= i.total then 'paid' when v_paid > 0 then 'partially_paid' else 'issued' end;
  if v_to is distinct from i.status then
    update invoices set status = v_to where id = i.id;
    perform emit_event(case when v_to = 'paid' then 'invoice.paid' else 'invoice.payment_changed' end, 'invoices', i.id, i.ada_id, jsonb_build_object('status', v_to));
  end if;
end $$;

create or replace function payment_allocate(p_payment uuid, p_invoice uuid, p_amount numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p payments%rowtype; i invoices%rowtype; v_amount numeric; v_id uuid;
begin
  p := payment_load(p_payment);                                   -- payment first, then invoice: the same lock order as the trigger
  i := invoice_load(p_invoice);
  if not has_permission('payments.allocate') then raise exception 'payments.allocate is required' using errcode = '42501'; end if;
  if i.client_id <> p.client_id then raise exception 'a payment can only settle invoices of the same client' using errcode = '23514'; end if;
  v_amount := coalesce(p_amount, least(payment_credit(p.id), invoice_open_amount(i.id)));
  if v_amount is null or v_amount <= 0 then raise exception 'there is nothing to allocate' using errcode = '23514'; end if;
  insert into payment_allocations (payment_id, invoice_id, amount) values (p.id, i.id, v_amount) returning id into v_id;
  return v_id;
end $$;

create or replace function invoice_void(p_id uuid, p_reason text) returns void
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
  if exists (select 1 from credit_notes c where c.invoice_id = i.id and c.status in ('pending_approval', 'approved', 'issued')) then raise exception 'credit notes exist for this invoice; cancel or release them first' using errcode = '23514'; end if;
  if invoice_valid_allocated(i.id) > 0 then raise exception 'payments are allocated to this invoice; unallocate or reverse them first' using errcode = '23514'; end if;
  update invoices set status = 'cancelled', cancelled_at = now(), status_reason = p_reason where id = i.id;
  update invoice_lines set active = false where invoice_id = i.id;
  update billable_items set status = 'open' where id in (select billable_item_id from invoice_lines where invoice_id = i.id);
  if i.issued_at is not null then perform emit_event('invoice.cancelled', 'invoices', i.id, i.ada_id, '{}'); end if;
end $$;

create or replace function document_family_ids(p_registry_id text) returns text[]
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
      or (er.table_name = 'payments'  and er.entity_id in (select id from payments  where client_id = r.entity_id))
      or (er.table_name = 'expenses'  and er.entity_id in (select id from expenses  where client_id = r.entity_id))
      or (er.table_name = 'credit_notes' and er.entity_id in (select id from credit_notes where client_id = r.entity_id))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets   where client_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets    where client_id = r.entity_id));
  elsif r.table_name = 'projects' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'contracts' and er.entity_id in (select contract_id from contract_projects where project_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes   where project_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices where project_id = r.entity_id
                                                           or contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = r.entity_id)))
      or (er.table_name = 'payments'  and er.entity_id in (select pa.payment_id from payment_allocations pa join invoices i on i.id = pa.invoice_id
                                                           where pa.status = 'active' and (i.project_id = r.entity_id or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = r.entity_id))))
      or (er.table_name = 'expenses'  and er.entity_id in (select id from expenses where project_id = r.entity_id))
      or (er.table_name = 'credit_notes' and er.entity_id in (select c.id from credit_notes c join invoices i on i.id = c.invoice_id
                                                              where i.project_id = r.entity_id or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = r.entity_id)))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets  where project_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets   where project_id = r.entity_id));
  elsif r.table_name = 'organizations' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'clients'   and er.entity_id in (select id from clients   where organization_id = r.entity_id))
      or (er.table_name = 'suppliers' and er.entity_id in (select id from suppliers where organization_id = r.entity_id))
      or (er.table_name = 'partners'  and er.entity_id in (select id from partners  where organization_id = r.entity_id));
    select v_ids || coalesce(array_agg(x), '{}') into v_ids
      from (select unnest(document_family_ids(er.institutional_id)) x from entity_registry er
             where er.table_name = 'clients' and er.entity_id in (select id from clients where organization_id = r.entity_id)) q;
    select coalesce(array_agg(distinct x), '{}') into v_ids from unnest(v_ids) x;
  end if;
  return v_ids;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Client 360 / Project 360: credited amounts and the credit notes themselves (read side only; the rest of each view is unchanged)
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
                 'due_date', i.due_date, 'paid', invoice_paid(i.id), 'credited', invoice_credited(i.id), 'balance', invoice_balance(i.id), 'contract', (select ada_id from contracts where id = i.contract_id)) order by i.created_at)
               from invoices i where i.client_id = p_client), '[]'),
    'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('id', cn.ada_id, 'status', cn.status, 'currency', cn.currency, 'total', cn.total, 'invoice', (select ada_id from invoices where id = cn.invoice_id),
                 'applied', credit_note_applied_amount(cn.id), 'unapplied', credit_note_unapplied_amount(cn.id)) order by cn.created_at) from credit_notes cn where cn.client_id = p_client), '[]'),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', py.ada_id, 'status', py.status, 'currency', py.currency, 'amount', py.amount, 'received_on', py.received_on,
                 'method', py.method, 'reconciliation', py.reconciliation, 'credit', b.credit) order by py.received_on, py.created_at)
               from payments py join payment_balances b on b.payment_id = py.id where py.client_id = p_client), '[]'),
    'finance_summary', (select jsonb_build_object(
                 'invoiced', coalesce(sum(i.total) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'paid', coalesce(sum(invoice_paid(i.id)) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
                 'credited', coalesce(sum(invoice_credited(i.id)) filter (where i.status in ('issued', 'partially_paid', 'paid')), 0),
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
                 'paid', invoice_paid(i.id), 'credited', invoice_credited(i.id), 'balance', invoice_balance(i.id)) order by i.created_at)
               from invoices i where i.project_id = p_project
                  or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)
                  or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = p_project)), '[]'),
    -- payments are not stored against a project: they are the active allocations to the invoices above (derived, never copied)
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', py.ada_id, 'status', py.status, 'currency', py.currency, 'amount', py.amount, 'received_on', py.received_on,
                 'method', py.method, 'reconciliation', py.reconciliation) order by py.received_on, py.created_at)
               from payments py where py.id in (select pa.payment_id from payment_allocations pa join invoices i on i.id = pa.invoice_id
                 where pa.status = 'active' and (i.project_id = p_project
                    or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)
                    or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = p_project)))), '[]'),
    'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('id', cn.ada_id, 'status', cn.status, 'currency', cn.currency, 'total', cn.total, 'invoice', i2.ada_id) order by cn.created_at)
               from credit_notes cn join invoices i2 on i2.id = cn.invoice_id
               where i2.project_id = p_project or i2.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = p_project)), '[]'),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', ast.ada_id, 'name', ast.name, 'status', ast.status, 'condition', ast.condition) order by ast.created_at) from assets ast where ast.project_id = p_project), '[]'),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', tk.ada_id, 'title', tk.title, 'status', tk.status, 'priority', tk.priority) order by tk.created_at) from tickets tk where tk.project_id = p_project), '[]'),
    'documents', documents_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'domains', domains_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    'communications', communications_of(document_family_ids((select institutional_id from entity_registry where table_name = 'projects' and entity_id = p_project))),
    -- expenses: the project's costs as recorded (one row each) and the derived totals per currency (cost = approved + paid; nothing is stored)
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', x.ada_id, 'status', x.status, 'category', c.name, 'currency', x.currency, 'total', x.total, 'date', x.expense_date) order by x.expense_date, x.created_at)
               from expenses x join expense_categories c on c.id = x.category_id where x.project_id = p_project), '[]'),
    'costs', coalesce((select jsonb_agg(to_jsonb(pc) - 'project_id' order by pc.currency) from project_costs pc where pc.project_id = p_project), '[]'),
    'pending', jsonb_build_array('websites', 'deliverables'));
end $$;
revoke execute on function client_360(uuid), project_360(uuid) from public, anon;
grant execute on function client_360(uuid), project_360(uuid) to authenticated;
