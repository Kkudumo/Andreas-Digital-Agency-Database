-- 0029_payments: payments received, allocated to invoices, reversed/refunded, reconciled.
--  * A payment references the client (id), the bank account it landed in, and nothing else of the client. It is
--    immutable once recorded: a mistake is corrected by an approved reversal and a new payment, never by editing.
--  * A payment can be allocated across several invoices and an invoice can be paid by several payments (partial
--    payments). What is left on a payment after allocation is client CREDIT (overpayment) - derived, never stored.
--  * An invoice balance is NEVER a stored number: balance = invoice total - valid allocated payments, derived on demand.
--    Invoice status (issued / partially_paid / paid) follows the allocations automatically.
--  * Allocation caps (payment credit, invoice balance), same client and currency are enforced by a locking trigger,
--    so concurrent allocation cannot double-spend a payment.
--  * Reversal and refund go through the shared approval engine (kinds 'payment_reversal' and 'refund').

create type payment_method as enum ('bank_transfer', 'card', 'cash', 'cheque', 'mobile_money', 'other');
create type payment_status as enum ('received', 'reversed', 'refunded');
create type reconciliation_status as enum ('unreconciled', 'reconciled', 'disputed');

create table payments (
  id                       uuid primary key default gen_random_uuid(),
  ada_id                   text not null unique,
  client_id                uuid not null references clients (id) on delete restrict,
  received_account_id      uuid not null references bank_accounts (id),
  method                   payment_method not null,
  reference                text,
  amount                   numeric(14,2) not null check (amount > 0),
  currency                 char(3) not null,
  received_on              date not null default current_date,
  status                   payment_status not null default 'received',
  reconciliation           reconciliation_status not null default 'unreconciled',
  statement_ref            text,
  reconciled_by            uuid references staff (id),
  reconciled_at            timestamptz,
  notes                    text,
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  recorded_by              uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (received_on <= current_date + 1)
);
create index payments_client_idx on payments (client_id);
-- A bank reference is unique per account. Only DISCOVERABLE payments take part in the global rule, so a restricted
-- client's payment can never make someone else's insert fail (that would reveal it exists); within one client it always applies.
create unique index payments_reference_discoverable on payments (received_account_id, lower(reference))
  where reference is not null and status <> 'reversed' and effective_classification in ('public', 'internal');
create unique index payments_reference_per_client on payments (client_id, received_account_id, lower(reference))
  where reference is not null and status <> 'reversed';
comment on table payments is 'Purpose: money received. References the client and the receiving bank account. Immutable; corrected by reversal. No balance column: allocation and credit are derived. [class: confidential]';
do $$ begin perform attach_ada_id('payments', 'payment'); end $$;
create trigger payments_updated before update on payments for each row execute function set_updated_at();
create trigger payments_inherit_trg before insert or update of client_id on payments for each row execute function finance_inherit_classification();

create table payment_allocations (
  id             uuid primary key default gen_random_uuid(),
  payment_id     uuid not null references payments (id) on delete restrict,
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
create unique index payment_allocations_one_active on payment_allocations (payment_id, invoice_id) where status = 'active';
create index payment_allocations_invoice_idx on payment_allocations (invoice_id) where status = 'active';
comment on table payment_allocations is 'Purpose: how much of which payment settles which invoice. A payment can only be allocated once to an invoice, never beyond its remaining credit or the invoice balance (enforced under row locks). Released, not deleted. [class: confidential]';

create table payment_reversals (
  id           uuid primary key default gen_random_uuid(),
  payment_id   uuid not null references payments (id) on delete restrict,
  kind         text not null check (kind in ('reversal', 'refund')),
  amount       numeric(14,2) not null check (amount > 0),
  reason       text not null check (btrim(reason) <> ''),
  status       text not null default 'pending_approval' check (status in ('pending_approval', 'approved', 'rejected', 'cancelled')),
  requested_by uuid references staff (id),
  requested_at timestamptz not null default now(),
  decided_by   uuid references staff (id),
  decided_at   timestamptz,
  decision_note text
);
create unique index payment_reversals_one_pending on payment_reversals (payment_id) where status = 'pending_approval';
create index payment_reversals_payment_idx on payment_reversals (payment_id);
comment on table payment_reversals is 'Purpose: requests to reverse a payment (whole) or refund part of its unallocated credit. Approved through the shared approval engine; the effect is applied by the system on approval. [class: confidential]';

-- ---------------------------------------------------------------------------
-- Derived amounts (never stored)
-- ---------------------------------------------------------------------------
create function payment_refunded(p_payment uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from payment_reversals where payment_id = p_payment and kind = 'refund' and status = 'approved'
$$;
create function payment_allocated(p_payment uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from payment_allocations where payment_id = p_payment and status = 'active'
$$;
-- Credit left on a payment: amount - refunds - active allocations (0 once reversed).
create function payment_credit(p_payment uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when p.status = 'reversed' then 0 else p.amount - payment_refunded(p.id) - payment_allocated(p.id) end from payments p where p.id = p_payment
$$;

-- Valid allocations: active allocations on a payment that has not been reversed.
create or replace function invoice_valid_allocated(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(a.amount), 0) from payment_allocations a join payments p on p.id = a.payment_id
  where a.invoice_id = p_invoice and a.status = 'active' and p.status <> 'reversed'
$$;
revoke execute on function payment_refunded(uuid), payment_allocated(uuid), payment_credit(uuid), invoice_valid_allocated(uuid) from public, anon, authenticated;

-- Invoice balance = total - valid allocated payments. Visible only to someone who can see the invoice.
create function invoice_balance(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when can_view_invoice(i.id) and i.status not in ('draft', 'pending_approval', 'approved', 'cancelled') then i.total - invoice_valid_allocated(i.id) end
  from invoices i where i.id = p_invoice
$$;
create function invoice_paid(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when can_view_invoice(i.id) then invoice_valid_allocated(i.id) end from invoices i where i.id = p_invoice
$$;

create view invoice_balances with (security_invoker = true) as
  select i.id as invoice_id, i.ada_id, i.client_id, i.status, i.currency, i.total, invoice_paid(i.id) as paid, invoice_balance(i.id) as balance,
         (i.due_date is not null and i.due_date < current_date and i.status in ('issued', 'partially_paid')) as is_overdue
  from invoices i;
comment on view invoice_balances is 'Purpose: derived invoice balance (total - valid allocated payments) and overdue flag. Row access follows the invoice''s own visibility. Nothing here is stored.';

create view payment_balances with (security_invoker = true) as
  select p.id as payment_id, p.ada_id, p.client_id, p.currency, p.status, p.amount, x.refunded, x.allocated,
         case when p.status = 'reversed' then 0::numeric(14,2) else p.amount - x.refunded - x.allocated end as credit
  from payments p
  cross join lateral (select
    coalesce((select sum(r.amount) from payment_reversals r where r.payment_id = p.id and r.kind = 'refund' and r.status = 'approved'), 0::numeric(14,2)) as refunded,
    coalesce((select sum(a.amount) from payment_allocations a where a.payment_id = p.id and a.status = 'active'), 0::numeric(14,2)) as allocated) x;
comment on view payment_balances is 'Purpose: derived allocation and unallocated credit (overpayment) per payment. Nothing here is stored.';

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create function payments_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'payments cannot be deleted; reverse them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.recorded_by := current_staff_id();
    if new.currency <> (select currency from bank_accounts where id = new.received_account_id) then
      raise exception 'the payment currency must match the receiving account (%)', (select currency from bank_accounts where id = new.received_account_id) using errcode = '23514';
    end if;
    if not exists (select 1 from bank_accounts where id = new.received_account_id and is_active) then
      raise exception 'that bank account is not active' using errcode = '23514';
    end if;
    return new;
  end if;
  if (new.client_id, new.received_account_id, new.method, new.reference, new.amount, new.currency, new.received_on, new.ada_id)
     is distinct from (old.client_id, old.received_account_id, old.method, old.reference, old.amount, old.currency, old.received_on, old.ada_id) then
    raise exception 'a recorded payment is immutable; reverse it and record the correct one' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (old.status = 'received' and new.status in ('reversed', 'refunded')) then
    raise exception 'invalid payment status change % -> %', old.status, new.status using errcode = '23514';
  end if;
  return new;
end $$;
create trigger payments_guard_trg before insert or update or delete on payments for each row execute function payments_guard();

create function payment_allocations_guard() returns trigger
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
  if new.amount > inv.total - invoice_valid_allocated(inv.id) then raise exception 'the allocation exceeds the invoice balance (%)', inv.total - invoice_valid_allocated(inv.id) using errcode = '23514'; end if;
  new.allocated_by := current_staff_id();
  return new;
end $$;
create trigger payment_allocations_guard_trg before insert or update or delete on payment_allocations for each row execute function payment_allocations_guard();

-- Invoice status follows the valid allocations: issued <-> partially_paid <-> paid.
create function invoice_sync_status(p_invoice uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i invoices%rowtype; v_paid numeric; v_to invoice_status;
begin
  select * into i from invoices where id = p_invoice for update;
  if not found or i.status not in ('issued', 'partially_paid', 'paid') then return; end if;
  v_paid := invoice_valid_allocated(i.id);
  v_to := case when v_paid >= i.total then 'paid' when v_paid > 0 then 'partially_paid' else 'issued' end;
  if v_to is distinct from i.status then
    update invoices set status = v_to where id = i.id;
    perform emit_event(case when v_to = 'paid' then 'invoice.paid' else 'invoice.payment_changed' end, 'invoices', i.id, i.ada_id, jsonb_build_object('status', v_to));
  end if;
end $$;

create function payment_allocations_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform invoice_sync_status(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger payment_allocations_sync_trg after insert or update on payment_allocations for each row execute function payment_allocations_sync();

create function payment_reversals_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'reversal requests cannot be deleted' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and (new.payment_id, new.kind, new.amount, new.reason) is distinct from (old.payment_id, old.kind, old.amount, old.reason) then
    raise exception 'a reversal request cannot be edited' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.status <> 'pending_approval' then
    raise exception 'a decided reversal request is final' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger payment_reversals_guard_trg before insert or update or delete on payment_reversals for each row execute function payment_reversals_guard();

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------
create function can_view_payment_row(p_class data_classification, p_client_deleted boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select has_permission('payments.view') and classification_visible(p_class) and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_payment(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_payment_row(p.effective_classification, p.client_deleted) from payments p where p.id = p_id), false)
$$;

create function payment_load(p_id uuid) returns payments
language plpgsql security definer set search_path = public, pg_temp as $$
declare p payments%rowtype;
begin
  select * into p from payments where id = p_id for update;
  if not found or not can_view_payment_row(p.effective_classification, p.client_deleted) then raise exception 'payment not found' using errcode = 'P0002'; end if;
  return p;
end $$;

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
create function payment_allocate(p_payment uuid, p_invoice uuid, p_amount numeric default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p payments%rowtype; i invoices%rowtype; v_amount numeric; v_id uuid;
begin
  p := payment_load(p_payment);                                   -- payment first, then invoice: the same lock order as the trigger
  i := invoice_load(p_invoice);
  if not has_permission('payments.allocate') then raise exception 'payments.allocate is required' using errcode = '42501'; end if;
  if i.client_id <> p.client_id then raise exception 'a payment can only settle invoices of the same client' using errcode = '23514'; end if;
  v_amount := coalesce(p_amount, least(payment_credit(p.id), i.total - invoice_valid_allocated(i.id)));
  if v_amount is null or v_amount <= 0 then raise exception 'there is nothing to allocate' using errcode = '23514'; end if;
  insert into payment_allocations (payment_id, invoice_id, amount) values (p.id, i.id, v_amount) returning id into v_id;
  return v_id;
end $$;

create function payment_record(p_client uuid, p_account uuid, p_amount numeric, p_method payment_method, p_received_on date default null,
                               p_reference text default null, p_invoice uuid default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clients%rowtype; a bank_accounts%rowtype; v_id uuid;
begin
  if not has_permission('payments.record') then raise exception 'payments.record is required' using errcode = '42501'; end if;
  select * into c from clients where id = p_client and deleted_at is null;
  if not found or not can_view_client(p_client) then raise exception 'client not found' using errcode = 'P0002'; end if;
  select * into a from bank_accounts where id = p_account;
  if not found then raise exception 'bank account not found' using errcode = 'P0002'; end if;
  if p_invoice is not null and not has_permission('payments.allocate') then raise exception 'payments.allocate is required to allocate on receipt' using errcode = '42501'; end if;
  insert into payments (client_id, received_account_id, method, reference, amount, currency, received_on, notes)
  values (p_client, p_account, p_method, nullif(btrim(p_reference), ''), p_amount, a.currency, coalesce(p_received_on, current_date), p_notes)
  returning id into v_id;
  perform emit_event('payment.received', 'payments', v_id, (select ada_id from payments where id = v_id), jsonb_build_object('currency', a.currency));
  if p_invoice is not null then perform payment_allocate(v_id, p_invoice); end if;
  return v_id;
end $$;

create function payment_unallocate(p_allocation uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a payment_allocations%rowtype; p payments%rowtype;
begin
  select * into a from payment_allocations where id = p_allocation;
  if not found then raise exception 'allocation not found' using errcode = 'P0002'; end if;
  p := payment_load(a.payment_id);
  perform invoice_load(a.invoice_id);
  if not has_permission('payments.allocate') then raise exception 'payments.allocate is required' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into a from payment_allocations where id = p_allocation for update;
  if a.status <> 'active' then raise exception 'that allocation is already released' using errcode = '23514'; end if;
  update payment_allocations set status = 'released', released_by = current_staff_id(), released_at = now(), release_reason = p_reason where id = a.id;
end $$;

create function payment_request_reversal(p_payment uuid, p_kind text, p_amount numeric default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p payments%rowtype; v_amount numeric; v_id uuid;
begin
  p := payment_load(p_payment);
  if not has_permission('payments.reverse') then raise exception 'payments.reverse is required' using errcode = '42501'; end if;
  if p_kind not in ('reversal', 'refund') then raise exception 'kind must be reversal or refund' using errcode = '22023'; end if;
  if p.status <> 'received' then raise exception 'only a received payment can be reversed or refunded (currently %)', p.status using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if p_kind = 'reversal' then
    if payment_refunded(p.id) > 0 then raise exception 'a payment that has been partly refunded cannot be reversed' using errcode = '23514'; end if;
    v_amount := p.amount;
  else
    v_amount := coalesce(p_amount, payment_credit(p.id));
    if v_amount <= 0 or v_amount > payment_credit(p.id) then raise exception 'a refund cannot exceed the unallocated credit on the payment (%)', payment_credit(p.id) using errcode = '23514'; end if;
  end if;
  insert into payment_reversals (payment_id, kind, amount, reason, requested_by) values (p.id, p_kind, v_amount, p_reason, current_staff_id()) returning id into v_id;
  perform approval_open(case when p_kind = 'reversal' then 'payment_reversal' else 'refund' end, 'payment_reversals', v_id, p.ada_id, null,
                        coalesce((approval_policy(case when p_kind = 'reversal' then 'payment_reversal' else 'refund' end, null, v_amount)).required_permission, 'finance.approve'),
                        initcap(p_kind) || ' of payment ' || p.ada_id, p.effective_classification);
  if p.effective_classification = 'internal' then
    perform notify_holders('finance.approve', null, 'approval.required', initcap(p_kind) || ' awaiting approval: ' || p.ada_id, null, 'payments', p.id, p.ada_id);
  end if;
  return v_id;
end $$;

create function payment_reversal_decide(p_reversal uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payment_reversals%rowtype; p payments%rowtype; v_gate text; v_kind text;
begin
  select * into r from payment_reversals where id = p_reversal;
  if not found then raise exception 'reversal request not found' using errcode = 'P0002'; end if;
  p := payment_load(r.payment_id);                                -- visibility + lock
  select * into r from payment_reversals where id = p_reversal for update;
  if r.status <> 'pending_approval' then raise exception 'this request is already %', r.status using errcode = '23514'; end if;
  v_kind := case when r.kind = 'reversal' then 'payment_reversal' else 'refund' end;
  if not p_approve and coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject' using errcode = '23514'; end if;
  v_gate := approval_gate(v_kind, 'payment_reversals', r.id, null, r.amount, r.requested_by, 'finance.approve', p_approve, p_note);
  if v_gate = 'pending' then return 'pending'; end if;
  if v_gate = 'rejected' then
    update payment_reversals set status = 'rejected', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = r.id;
    perform approval_close('payment_reversals', r.id, 'rejected', p_note);
    return 'rejected';
  end if;
  -- approved: re-check the facts, then apply
  if p.status <> 'received' then raise exception 'the payment is no longer in a state that can be %', r.kind using errcode = '23514'; end if;
  if r.kind = 'refund' and r.amount > payment_credit(p.id) then raise exception 'the unallocated credit is now smaller than the refund' using errcode = '23514'; end if;
  update payment_reversals set status = 'approved', decided_by = current_staff_id(), decided_at = now(), decision_note = p_note where id = r.id;
  perform approval_close('payment_reversals', r.id, 'approved', p_note);
  if r.kind = 'reversal' then
    update payment_allocations set status = 'released', released_by = current_staff_id(), released_at = now(), release_reason = 'payment reversed'
     where payment_id = p.id and status = 'active';
    update payments set status = 'reversed' where id = p.id;
    perform emit_event('payment.reversed', 'payments', p.id, p.ada_id, '{}');
  else
    if payment_refunded(p.id) >= p.amount then update payments set status = 'refunded' where id = p.id; end if;
    perform emit_event('payment.refunded', 'payments', p.id, p.ada_id, '{}');
  end if;
  return 'approved';
end $$;

create function payment_reconcile(p_payment uuid, p_status reconciliation_status default 'reconciled', p_statement_ref text default null, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p payments%rowtype;
begin
  p := payment_load(p_payment);
  if not has_permission('payments.reconcile') then raise exception 'payments.reconcile is required' using errcode = '42501'; end if;
  if p.status = 'reversed' then raise exception 'a reversed payment is not reconciled' using errcode = '23514'; end if;
  if p_status = 'reconciled' and coalesce(btrim(p_statement_ref), '') = '' then raise exception 'a bank statement reference is required to reconcile' using errcode = '23514'; end if;
  if p_status = 'disputed' and coalesce(btrim(p_note), '') = '' then raise exception 'say why the payment is disputed' using errcode = '23514'; end if;
  update payments set reconciliation = p_status, statement_ref = coalesce(nullif(btrim(p_statement_ref), ''), statement_ref),
         reconciled_by = case when p_status = 'reconciled' then current_staff_id() end, reconciled_at = case when p_status = 'reconciled' then now() end,
         notes = coalesce(p_note, notes)
   where id = p.id;
end $$;

insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note) values
  ('payment_reversal', 'finance.approve', false, true, 1, 'default: a reversal must be approved by someone other than the requester'),
  ('refund',           'finance.approve', false, true, 1, 'default: a refund must be approved by someone other than the requester');

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table payments            enable row level security;
alter table payment_allocations enable row level security;
alter table payment_reversals   enable row level security;
revoke all on payments, payment_allocations, payment_reversals, invoice_balances, payment_balances from anon, authenticated;
grant select on payments, payment_allocations, payment_reversals, invoice_balances, payment_balances to authenticated;
create policy payments_select on payments for select to authenticated using (can_view_payment_row(effective_classification, client_deleted));
create policy payment_allocations_select on payment_allocations for select to authenticated using (can_view_payment(payment_id));
create policy payment_reversals_select on payment_reversals for select to authenticated using (can_view_payment(payment_id));

revoke execute on function can_view_payment_row(data_classification, boolean), can_view_payment(uuid), payment_load(uuid), invoice_sync_status(uuid),
  invoice_balance(uuid), invoice_paid(uuid), payment_allocate(uuid, uuid, numeric),
  payment_record(uuid, uuid, numeric, payment_method, date, text, uuid, text), payment_unallocate(uuid, text),
  payment_request_reversal(uuid, text, numeric, text), payment_reversal_decide(uuid, boolean, text),
  payment_reconcile(uuid, reconciliation_status, text, text) from public, anon, authenticated;
grant execute on function can_view_payment_row(data_classification, boolean), can_view_payment(uuid), invoice_balance(uuid), invoice_paid(uuid),
  payment_allocate(uuid, uuid, numeric), payment_record(uuid, uuid, numeric, payment_method, date, text, uuid, text), payment_unallocate(uuid, text),
  payment_request_reversal(uuid, text, numeric, text), payment_reversal_decide(uuid, boolean, text),
  payment_reconcile(uuid, reconciliation_status, text, text) to authenticated;

do $$ begin
  perform attach_audit('payments');
  perform attach_audit('payment_allocations');
  perform attach_audit('payment_reversals');
end $$;
