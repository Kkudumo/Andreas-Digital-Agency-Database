-- 0047_expenses: what ADA spends, on the institutional foundation (not a stand-alone ledger).
--  * Identity: an expense is a registered entity (type `expense`, ADA-EXP-YYYY-####, plus the permanent institutional ID) through the one registration path.
--  * References, never copies: the supplier (a role of an organization), the project, the division, the category and the bank account are references to
--    their own authoritative records. The client is derived from the project; nothing about a supplier, project or client is typed again here.
--  * Workflow (all through functions; nothing writes the table directly):
--      draft -> pending_approval -> approved -> paid        (+ rejected, cancelled)   (pending_approval is what the shared approval engine watches for)
--    Approval uses the shared approval engine (kind `expense`, amount = total; policy-driven, no self-approval unless the policy allows it and the requester
--    is the only qualified approver). Content is editable only while draft; paid expenses are final. Nothing is deleted.
--  * Privacy: an expense inherits the classification of the project / client it is linked to, so a restricted client's costs are invisible to everyone
--    without access (counts, search, approvals queue, derived views included); a record that does not exist and one you may not see answer identically.
--  * Derived, never stored: project cost (view `project_costs`) and what is owed to suppliers (view `expense_payables`) are computed from the expenses.
--    The interim `project_financials.cost_to_date` planning field is left alone and no longer needed for actual cost.

-- ---------------------------------------------------------------------------
-- 1. Permissions (the reviewed matrix, supabase/seed_data/permission_matrix.csv, carries the same rows)
-- ---------------------------------------------------------------------------
insert into permissions (key, module, action, description, sensitivity) values
  ('expenses.view', 'expenses', 'view', 'View expenses (own division)', 'confidential'::data_classification),
  ('expenses.create', 'expenses', 'create', 'Record expenses', 'confidential'::data_classification),
  ('expenses.update', 'expenses', 'update', 'Edit draft expenses and submit them for approval', 'confidential'::data_classification),
  ('expenses.approve', 'expenses', 'approve', 'Approve or reject submitted expenses', 'confidential'::data_classification),
  ('expenses.pay', 'expenses', 'pay', 'Record that an approved expense was paid', 'confidential'::data_classification),
  ('expenses.void', 'expenses', 'void', 'Cancel an approved expense that has not been paid', 'confidential'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'expenses.view'), ('administration_officer', 'expenses.view'), ('finance_officer', 'expenses.view'), ('division_lead', 'expenses.view'), ('auditor', 'expenses.view'),
  ('ceo', 'expenses.create'), ('administration_officer', 'expenses.create'), ('finance_officer', 'expenses.create'), ('division_lead', 'expenses.create'),
  ('ceo', 'expenses.update'), ('administration_officer', 'expenses.update'), ('finance_officer', 'expenses.update'), ('division_lead', 'expenses.update'),
  ('ceo', 'expenses.approve'), ('finance_officer', 'expenses.approve'),
  ('ceo', 'expenses.pay'), ('finance_officer', 'expenses.pay'),
  ('ceo', 'expenses.void')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create type expense_status as enum ('draft', 'pending_approval', 'approved', 'paid', 'rejected', 'cancelled');

create table expense_categories (
  id         uuid primary key default gen_random_uuid(),
  key        text not null unique check (key ~ '^[a-z][a-z0-9_]*$'),
  name       text not null check (btrim(name) <> ''),
  is_active  boolean not null default true,
  sort_order integer not null default 100
);
comment on table expense_categories is 'Purpose: the reviewed list of expense categories used to group costs in reports. Changed only through expense_category_set (finance.configure). [class: internal]';
insert into expense_categories (key, name, sort_order) values
  ('hosting', 'Hosting and infrastructure', 10), ('software', 'Software and subscriptions', 20), ('hardware', 'Hardware and equipment', 30),
  ('subcontractors', 'Subcontractors and freelancers', 40), ('professional_fees', 'Professional fees', 50), ('marketing', 'Marketing', 60),
  ('travel', 'Travel and accommodation', 70), ('office', 'Office and utilities', 80), ('training', 'Training', 90), ('other', 'Other', 999);

create table expenses (
  id                       uuid primary key default gen_random_uuid(),
  ada_id                   text not null unique,
  division_id              uuid not null references divisions (id),
  supplier_id              uuid references suppliers (id),
  project_id               uuid references projects (id),
  client_id                uuid references clients (id) on delete restrict,
  category_id              uuid not null references expense_categories (id),
  description              text not null check (btrim(description) <> ''),
  supplier_reference       text,
  expense_date             date not null default current_date,
  currency                 char(3) not null,
  amount_net               numeric(14,2) not null check (amount_net > 0),
  tax_amount               numeric(14,2) not null default 0 check (tax_amount >= 0),
  total                    numeric(14,2) generated always as (amount_net + tax_amount) stored,
  status                   expense_status not null default 'draft',
  requested_by             uuid references staff (id),
  approved_by              uuid references staff (id),
  approved_at              timestamptz,
  paid_on                  date,
  paid_from_account_id     uuid references bank_accounts (id),
  payment_reference        text,
  status_reason            text,
  effective_classification data_classification not null default 'internal',
  client_deleted           boolean not null default false,
  created_by               uuid references staff (id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (status <> 'paid' or (paid_on is not null and paid_from_account_id is not null))
);
create index expenses_division_idx on expenses (division_id);
create index expenses_project_idx on expenses (project_id) where project_id is not null;
create index expenses_client_idx on expenses (client_id) where client_id is not null;
create index expenses_supplier_idx on expenses (supplier_id) where supplier_id is not null;
create index expenses_status_idx on expenses (status);
comment on table expenses is 'Purpose: one cost ADA incurred: supplier, project, division and category by reference; net amount, tax and the derived total; a controlled lifecycle (draft -> pending_approval -> approved -> paid). The client is derived from the project; classification is inherited from the project / client. Nothing derived (project cost, payables) is stored here. Written only by the expense_* functions. [class: confidential]';
comment on column expenses.supplier_reference is 'What the supplier called this bill (their invoice number). Used only to stop the same bill being recorded twice; not an identity field.';
do $$ begin perform attach_ada_id('expenses', 'expense'); end $$;
create trigger expenses_updated before update on expenses for each row execute function set_updated_at();
create trigger approval_sync_trg after insert or update on expenses
  for each row execute function approval_sync('expense', 'expenses.approve', 'ada_id', 'division_id');

create table expense_events (
  id         bigint generated always as identity primary key,
  expense_id uuid not null references expenses (id) on delete restrict,
  kind       text not null check (kind in ('created', 'updated', 'submitted', 'withdrawn', 'sent_back', 'approved', 'rejected', 'paid', 'cancelled')),
  from_status expense_status,
  to_status   expense_status,
  note       text,
  actor_id   uuid references staff (id),
  at         timestamptz not null default now()
);
create index expense_events_expense_idx on expense_events (expense_id, id);
comment on table expense_events is 'Purpose: the append-only story of an expense: who did what, when, with what note. Visible exactly where the expense is. [class: confidential]';

update entity_types set is_built = true, domain_table = 'expenses', division_col = 'division_id', status_col = 'status', class_col = 'effective_classification',
       label_col = null, description = 'Expense (a cost ADA incurred)' where key = 'expense';

-- ---------------------------------------------------------------------------
-- 3. Inheritance (classification and client come from the project / client; nothing is typed twice)
-- ---------------------------------------------------------------------------
create function expenses_inherit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pc data_classification; v_pclient uuid; v_cc data_classification; v_cd boolean;
begin
  if new.project_id is not null then
    select client_id, effective_classification into v_pclient, v_pc from projects where id = new.project_id;
    new.client_id := v_pclient;
  else
    new.client_id := null;
  end if;
  if new.client_id is not null then select classification, deleted_at is not null into v_cc, v_cd from clients where id = new.client_id; end if;
  new.effective_classification := greatest('internal'::data_classification, coalesce(v_pc, 'internal'), coalesce(v_cc, 'internal'));
  new.client_deleted := coalesce(v_cd, false);
  return new;
end $$;
create trigger expenses_inherit_trg before insert or update of project_id, status on expenses for each row execute function expenses_inherit();

-- a client / project whose classification (or deletion) changes re-derives its expenses and the history of their approvals
create function expenses_follow_client() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update expenses set status = status where client_id = new.id;
  update approval_requests set classification = (select e.effective_classification from expenses e where e.id = approval_requests.entity_id)
   where entity_table = 'expenses' and entity_id in (select id from expenses where client_id = new.id);
  return null;
end $$;
create trigger expenses_follow_client_trg after update of classification, deleted_at on clients for each row execute function expenses_follow_client();
create function expenses_follow_project() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.effective_classification is distinct from old.effective_classification then
    update expenses set status = status where project_id = new.id;
    update approval_requests set classification = (select e.effective_classification from expenses e where e.id = approval_requests.entity_id)
     where entity_table = 'expenses' and entity_id in (select id from expenses where project_id = new.id);
  end if;
  return null;
end $$;
create trigger expenses_follow_project_trg after update on projects for each row execute function expenses_follow_project();

-- ---------------------------------------------------------------------------
-- 4. Guards (apply to EVERY caller, the table owner's functions included)
-- ---------------------------------------------------------------------------
create function expenses_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then raise exception 'expenses cannot be deleted; cancel them' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    new.created_by := current_staff_id();
    if new.status <> 'draft' then raise exception 'an expense starts as a draft' using errcode = '42501'; end if;
    return new;
  end if;
  if new.division_id is distinct from old.division_id or new.currency is distinct from old.currency then
    raise exception 'an expense''s division and currency cannot change' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'draft'            and new.status in ('pending_approval', 'cancelled'))
    or (old.status = 'pending_approval' and new.status in ('draft', 'approved', 'rejected', 'cancelled'))
    or (old.status = 'approved'         and new.status in ('paid', 'cancelled'))) then
    raise exception 'invalid expense status change % -> %', old.status, new.status using errcode = '23514';
  end if;
  if old.status <> 'draft' and (new.supplier_id, new.project_id, new.category_id, new.description, new.supplier_reference, new.expense_date, new.amount_net, new.tax_amount)
     is distinct from (old.supplier_id, old.project_id, old.category_id, old.description, old.supplier_reference, old.expense_date, old.amount_net, old.tax_amount) then
    raise exception 'an expense can only be edited while it is a draft' using errcode = '42501';
  end if;
  if old.status = 'paid' and (new.paid_on, new.paid_from_account_id, new.payment_reference) is distinct from (old.paid_on, old.paid_from_account_id, old.payment_reference) then
    raise exception 'a paid expense is final' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger expenses_guard_trg before insert or update or delete on expenses for each row execute function expenses_guard();

create function expense_events_guard() returns trigger
language plpgsql as $$
begin
  raise exception 'the expense history is append-only' using errcode = '42501';
end $$;
create trigger expense_events_guard_trg before update or delete on expense_events for each row execute function expense_events_guard();

-- ---------------------------------------------------------------------------
-- 5. Authorisation helpers
-- ---------------------------------------------------------------------------
create function can_view_expense_row(p_division uuid, p_class data_classification, p_client_deleted boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(has_permission('expenses.view', p_division), false) and classification_visible(p_class)
     and (not p_client_deleted or has_permission('records.view_deleted'))
$$;
create function can_view_expense(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_expense_row(e.division_id, e.effective_classification, e.client_deleted) from expenses e where e.id = p_id), false)
$$;
-- Loads an expense the caller may see (locked for the command), or fails exactly as for one that does not exist.
create function expense_load(p_id uuid) returns expenses
language plpgsql security definer set search_path = public, pg_temp as $$
declare e expenses%rowtype;
begin
  select * into e from expenses where id = p_id for update;
  if not found or not can_view_expense_row(e.division_id, e.effective_classification, e.client_deleted) then
    raise exception 'expense not found' using errcode = 'P0002';
  end if;
  return e;
end $$;
create function expense_log(p_expense uuid, p_kind text, p_from expense_status, p_to expense_status, p_note text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into expense_events (expense_id, kind, from_status, to_status, note, actor_id) values (p_expense, p_kind, p_from, p_to, nullif(btrim(coalesce(p_note, '')), ''), current_staff_id())
$$;
-- may the caller attach this project / supplier? (the same visibility rules as everywhere else; a hidden one answers like a missing one)
create function expense_project_usable(p_project uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_project(p.id) and can_view_client(p.client_id) and classification_visible(p.effective_classification) and p.status not in ('cancelled', 'archived')
                   from projects p where p.id = p_project and p.deleted_at is null), false)
$$;
create function expense_supplier_usable(p_supplier uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from suppliers s where s.id = p_supplier) and (has_permission_anywhere('suppliers.view') or has_permission_anywhere('assets.view') or has_permission_anywhere('expenses.view'))
$$;

-- ---------------------------------------------------------------------------
-- 6. Commands
-- ---------------------------------------------------------------------------
create function expense_create(p_division uuid, p_category text, p_description text, p_amount_net numeric, p_currency text default null, p_tax numeric default 0,
                               p_expense_date date default null, p_supplier uuid default null, p_supplier_reference text default null, p_project uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cat uuid; v_id uuid; v_cur char(3); v_ref text := nullif(btrim(coalesce(p_supplier_reference, '')), '');
begin
  if current_staff_id() is null or not has_permission('expenses.create', p_division) then raise exception 'expenses.create is required in that division' using errcode = '42501'; end if;
  select id into v_cat from expense_categories where key = p_category and is_active;
  if v_cat is null then raise exception 'unknown expense category' using errcode = '22023'; end if;
  if p_project is not null and not expense_project_usable(p_project) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if p_supplier is not null and not expense_supplier_usable(p_supplier) then raise exception 'supplier not found' using errcode = 'P0002'; end if;
  v_cur := upper(coalesce(nullif(btrim(coalesce(p_currency, '')), ''), (select base_currency from finance_settings limit 1)));
  if v_ref is not null and p_supplier is not null and exists (
       select 1 from expenses e where e.supplier_id = p_supplier and lower(btrim(e.supplier_reference)) = lower(v_ref) and e.status not in ('cancelled', 'rejected')
          and can_view_expense_row(e.division_id, e.effective_classification, e.client_deleted)) then
    raise exception 'this supplier bill is already recorded' using errcode = '23505';
  end if;
  insert into expenses (division_id, supplier_id, project_id, category_id, description, supplier_reference, expense_date, currency, amount_net, tax_amount)
  values (p_division, p_supplier, p_project, v_cat, btrim(p_description), v_ref, coalesce(p_expense_date, current_date), v_cur, p_amount_net, coalesce(p_tax, 0))
  returning id into v_id;
  perform expense_log(v_id, 'created', null, 'draft', null);
  return v_id;
end $$;

-- Edit a draft. Allowed keys: description, category, amount_net, tax_amount, expense_date, supplier_reference, supplier, project.
create function expense_update(p_expense uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e expenses%rowtype; k text; v_cat uuid;
begin
  e := expense_load(p_expense);
  if not (has_permission('expenses.update', e.division_id) or (has_permission('expenses.create', e.division_id) and e.created_by is not distinct from current_staff_id())) then
    raise exception 'expenses.update is required' using errcode = '42501';
  end if;
  if e.status <> 'draft' then raise exception 'an expense can only be edited while it is a draft' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if k not in ('description', 'category', 'amount_net', 'tax_amount', 'expense_date', 'supplier_reference', 'supplier', 'project') then
      raise exception 'cannot change "%" here', k using errcode = '22023';
    end if;
  end loop;
  if p_changes ? 'category' then
    select id into v_cat from expense_categories where key = p_changes ->> 'category' and is_active;
    if v_cat is null then raise exception 'unknown expense category' using errcode = '22023'; end if;
  end if;
  if p_changes ? 'project' and nullif(p_changes ->> 'project', '') is not null and not expense_project_usable((p_changes ->> 'project')::uuid) then raise exception 'project not found' using errcode = 'P0002'; end if;
  if p_changes ? 'supplier' and nullif(p_changes ->> 'supplier', '') is not null and not expense_supplier_usable((p_changes ->> 'supplier')::uuid) then raise exception 'supplier not found' using errcode = 'P0002'; end if;
  update expenses set
    description        = case when p_changes ? 'description' then btrim(p_changes ->> 'description') else description end,
    category_id        = coalesce(v_cat, category_id),
    amount_net         = case when p_changes ? 'amount_net' then (p_changes ->> 'amount_net')::numeric else amount_net end,
    tax_amount         = case when p_changes ? 'tax_amount' then (p_changes ->> 'tax_amount')::numeric else tax_amount end,
    expense_date       = case when p_changes ? 'expense_date' then (p_changes ->> 'expense_date')::date else expense_date end,
    supplier_reference = case when p_changes ? 'supplier_reference' then nullif(btrim(p_changes ->> 'supplier_reference'), '') else supplier_reference end,
    supplier_id        = case when p_changes ? 'supplier' then nullif(p_changes ->> 'supplier', '')::uuid else supplier_id end,
    project_id         = case when p_changes ? 'project' then nullif(p_changes ->> 'project', '')::uuid else project_id end
   where id = e.id;
  perform expense_log(e.id, 'updated', 'draft', 'draft', (select string_agg(x, ', ' order by x) from jsonb_object_keys(p_changes) x));
end $$;

create function expense_transition(p_expense uuid, p_to expense_status, p_note text default null) returns expense_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare e expenses%rowtype; v_gate text; v_me uuid := current_staff_id();
begin
  e := expense_load(p_expense);
  case
    when e.status = 'draft' and p_to = 'pending_approval' then
      if not (has_permission('expenses.update', e.division_id) or (has_permission('expenses.create', e.division_id) and e.created_by is not distinct from v_me)) then raise exception 'expenses.update is required' using errcode = '42501'; end if;
      update expenses set status = 'pending_approval', requested_by = v_me, status_reason = null where id = e.id;
      perform expense_log(e.id, 'submitted', 'draft', 'pending_approval', p_note);
      if e.effective_classification = 'internal' then
        perform notify_holders('expenses.approve', e.division_id, 'approval.required', 'Expense awaiting approval: ' || e.ada_id, null, 'expenses', e.id, e.ada_id);
      end if;

    when e.status = 'pending_approval' and p_to = 'draft' then
      if v_me is not distinct from e.requested_by then                              -- the requester withdraws it
        if not (has_permission('expenses.update', e.division_id) or has_permission('expenses.create', e.division_id)) then raise exception 'not permitted' using errcode = '42501'; end if;
        update expenses set status = 'draft', status_reason = p_note where id = e.id;
        perform expense_log(e.id, 'withdrawn', 'pending_approval', 'draft', p_note);
      else                                                                          -- an approver sends it back
        if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to send an expense back' using errcode = '23514'; end if;
        perform approval_gate('expense', 'expenses', e.id, e.division_id, e.total, e.requested_by, 'expenses.approve', false, p_note);
        update expenses set status = 'draft', status_reason = p_note where id = e.id;
        perform expense_log(e.id, 'sent_back', 'pending_approval', 'draft', p_note);
      end if;

    when e.status = 'pending_approval' and p_to = 'approved' then
      v_gate := approval_gate('expense', 'expenses', e.id, e.division_id, e.total, e.requested_by, 'expenses.approve', true, p_note);
      if v_gate = 'pending' then return e.status; end if;                           -- more approvers needed
      update expenses set status = 'approved', approved_by = v_me, approved_at = now(), status_reason = null where id = e.id;
      perform expense_log(e.id, 'approved', 'pending_approval', 'approved', p_note);

    when e.status = 'pending_approval' and p_to = 'rejected' then
      if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject an expense' using errcode = '23514'; end if;
      perform approval_gate('expense', 'expenses', e.id, e.division_id, e.total, e.requested_by, 'expenses.approve', false, p_note);
      update expenses set status = 'rejected', status_reason = p_note where id = e.id;
      perform expense_log(e.id, 'rejected', 'pending_approval', 'rejected', p_note);

    when e.status in ('draft', 'pending_approval') and p_to = 'cancelled' then
      if not (has_permission('expenses.update', e.division_id) or e.created_by is not distinct from v_me or e.requested_by is not distinct from v_me) then raise exception 'not permitted' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required to cancel an expense' using errcode = '23514'; end if;
      update expenses set status = 'cancelled', status_reason = p_note where id = e.id;
      perform expense_log(e.id, 'cancelled', e.status, 'cancelled', p_note);

    else
      raise exception 'invalid expense transition % -> % (payment and cancelling an approved expense have their own commands)', e.status, p_to using errcode = '23514';
  end case;
  return (select status from expenses where id = e.id);
end $$;

create function expense_pay(p_expense uuid, p_account uuid, p_paid_on date default null, p_reference text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e expenses%rowtype; a bank_accounts%rowtype;
begin
  e := expense_load(p_expense);
  if not has_permission('expenses.pay', e.division_id) then raise exception 'expenses.pay is required' using errcode = '42501'; end if;
  if e.status <> 'approved' then raise exception 'only an approved expense can be paid (currently %)', e.status using errcode = '23514'; end if;
  select * into a from bank_accounts where id = p_account and is_active;
  if not found then raise exception 'bank account not found' using errcode = 'P0002'; end if;
  if a.currency <> e.currency then raise exception 'the account is in %, the expense in %', a.currency, e.currency using errcode = '23514'; end if;
  if coalesce(p_paid_on, current_date) > current_date then raise exception 'the payment date cannot be in the future' using errcode = '23514'; end if;
  update expenses set status = 'paid', paid_on = coalesce(p_paid_on, current_date), paid_from_account_id = p_account, payment_reference = nullif(btrim(coalesce(p_reference, '')), '') where id = e.id;
  perform expense_log(e.id, 'paid', 'approved', 'paid', p_reference);
  perform emit_event('expense.paid', 'expenses', e.id, e.ada_id, jsonb_build_object('currency', e.currency));
end $$;

create function expense_void(p_expense uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e expenses%rowtype;
begin
  e := expense_load(p_expense);
  if not has_permission('expenses.void', e.division_id) then raise exception 'expenses.void is required' using errcode = '42501'; end if;
  if e.status <> 'approved' then raise exception 'only an approved, unpaid expense can be cancelled here (currently %)', e.status using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update expenses set status = 'cancelled', status_reason = p_reason where id = e.id;
  perform expense_log(e.id, 'cancelled', 'approved', 'cancelled', p_reason);
end $$;

create function expense_category_set(p_key text, p_name text, p_active boolean default true) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not has_permission('finance.configure') then raise exception 'finance.configure is required' using errcode = '42501'; end if;
  if p_key !~ '^[a-z][a-z0-9_]*$' then raise exception 'a category key is lower-case letters, digits and underscores' using errcode = '22023'; end if;
  insert into expense_categories (key, name, is_active) values (p_key, btrim(p_name), coalesce(p_active, true))
  on conflict (key) do update set name = excluded.name, is_active = excluded.is_active
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Derived views (nothing here is stored; row access follows the expense's own visibility)
-- ---------------------------------------------------------------------------
create view project_costs with (security_invoker = true) as
  select e.project_id, e.currency,
         coalesce(sum(e.total) filter (where e.status = 'paid'), 0)::numeric(14,2) as paid,
         coalesce(sum(e.total) filter (where e.status = 'approved'), 0)::numeric(14,2) as approved_unpaid,
         coalesce(sum(e.total) filter (where e.status = 'pending_approval'), 0)::numeric(14,2) as awaiting_approval,
         coalesce(sum(e.total) filter (where e.status in ('approved', 'paid')), 0)::numeric(14,2) as cost
    from expenses e where e.project_id is not null group by e.project_id, e.currency;
comment on view project_costs is 'Purpose: derived actual cost of a project from its expenses (cost = approved + paid; awaiting approval shown apart). Row access follows each expense. Nothing here is stored. [class: confidential]';

create view expense_payables with (security_invoker = true) as
  select e.supplier_id, e.currency, count(*)::integer as bills, sum(e.total)::numeric(14,2) as owed, min(e.expense_date) as oldest
    from expenses e where e.status = 'approved' group by e.supplier_id, e.currency;
comment on view expense_payables is 'Purpose: derived amount approved but not yet paid, per supplier and currency. Row access follows each expense. Nothing here is stored. [class: confidential]';

-- ---------------------------------------------------------------------------
-- 8. Grants, RLS, audit
-- ---------------------------------------------------------------------------
alter table expense_categories enable row level security;
alter table expenses           enable row level security;
alter table expense_events     enable row level security;
revoke all on expense_categories, expenses, expense_events from anon, authenticated;
revoke all on project_costs, expense_payables from anon, authenticated;
grant select on expense_categories, expenses, expense_events, project_costs, expense_payables to authenticated;
create policy expense_categories_select on expense_categories for select to authenticated using (has_permission_anywhere('expenses.view') or has_permission_anywhere('expenses.create'));
create policy expenses_select on expenses for select to authenticated using (can_view_expense_row(division_id, effective_classification, client_deleted));
create policy expense_events_select on expense_events for select to authenticated using (can_view_expense(expense_id));

revoke execute on function can_view_expense_row(uuid, data_classification, boolean), can_view_expense(uuid), expense_load(uuid), expense_log(uuid, text, expense_status, expense_status, text),
  expense_project_usable(uuid), expense_supplier_usable(uuid), expense_create(uuid, text, text, numeric, text, numeric, date, uuid, text, uuid), expense_update(uuid, jsonb),
  expense_transition(uuid, expense_status, text), expense_pay(uuid, uuid, date, text), expense_void(uuid, text), expense_category_set(text, text, boolean)
  from public, anon, authenticated;
grant execute on function can_view_expense_row(uuid, data_classification, boolean), can_view_expense(uuid), expense_create(uuid, text, text, numeric, text, numeric, date, uuid, text, uuid),
  expense_update(uuid, jsonb), expense_transition(uuid, expense_status, text), expense_pay(uuid, uuid, date, text), expense_void(uuid, text), expense_category_set(text, text, boolean)
  to authenticated;

do $$ begin
  perform attach_audit('expenses');
  perform attach_audit('expense_categories');      -- expense_events is itself the append-only history (like ticket_events / asset_history), so it is not audited twice
end $$;

-- ---------------------------------------------------------------------------
-- 9. Search and relationships
-- ---------------------------------------------------------------------------
insert into search_sources (entity_type, label_expr, attribute_exprs, note) values
  ('expense', 'x.ada_id', array['x.status::text', 'x.supplier_reference'], 'METADATA only: number, status and the supplier''s own bill number; no amounts, no description')
on conflict (entity_type) do nothing;
select attach_search('public.expenses'::regclass);

-- the family of a client / project now includes its expenses (so `related:` and the documents / communications slices see them)
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

-- Project 360 gains the project's expenses and derived costs (read side only; the rest of the view is as in 0042).
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
                  or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)
                  or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = p_project)), '[]'),
    -- payments are not stored against a project: they are the active allocations to the invoices above (derived, never copied)
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', py.ada_id, 'status', py.status, 'currency', py.currency, 'amount', py.amount, 'received_on', py.received_on,
                 'method', py.method, 'reconciliation', py.reconciliation) order by py.received_on, py.created_at)
               from payments py where py.id in (select pa.payment_id from payment_allocations pa join invoices i on i.id = pa.invoice_id
                 where pa.status = 'active' and (i.project_id = p_project
                    or i.id in (select il.invoice_id from invoice_lines il join billable_items b on b.id = il.billable_item_id where b.project_id = p_project and il.active)
                    or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = p_project)))), '[]'),
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
revoke execute on function project_360(uuid) from public, anon;
grant execute on function project_360(uuid) to authenticated;
