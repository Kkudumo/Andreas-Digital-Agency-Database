-- 0026_finance_foundation: groundwork for contracts, invoices and payments.
--  * contacts move from ADA-CON to ADA-CTC so that ADA-CON-YYYY-#### can mean Contract (IDs are rewritten in place;
--    the immutable audit_log keeps the historical text - see docs/workflows/CONTRACTS.md);
--  * entity types for contract (CON), invoice (INV) and payment (PAY);
--  * finance permissions (matrix delta generated from permission_matrix.csv);
--  * finance_settings (VAT, default terms) and bank_accounts (received-into accounts), both under finance.configure;
--  * the approval engine learns about DISCOUNTS: a request can carry an amount and a discount, each resolved against
--    its own policy (kinds such as 'invoice' and 'discount'), requiring BOTH permissions and the larger quorum;
--  * the approval queue is classification-aware, so a pending approval cannot reveal a restricted client's record.

-- ---------------------------------------------------------------------------
-- 1. Prefix move: contact CON -> CTC, then contract/invoice/payment
-- ---------------------------------------------------------------------------
alter table entity_registry drop constraint entity_registry_entity_type_fkey;
alter table entity_registry add constraint entity_registry_entity_type_fkey
  foreign key (entity_type) references entity_types (key) on update cascade;
alter table id_sequences drop constraint id_sequences_prefix_fkey;
alter table id_sequences add constraint id_sequences_prefix_fkey
  foreign key (prefix) references entity_types (prefix) on update cascade;

update entity_types set prefix = 'CTC', description = 'Client contact (a person''s relationship to a client)' where key = 'contact';

alter table client_contacts disable trigger ada_id_assign;
update client_contacts set ada_id = regexp_replace(ada_id, '^ADA-CON-', 'ADA-CTC-') where ada_id like 'ADA-CON-%';
alter table client_contacts enable trigger ada_id_assign;
update entity_registry set ada_id = regexp_replace(ada_id, '^ADA-CON-', 'ADA-CTC-') where entity_type = 'contact' and ada_id like 'ADA-CON-%';

insert into entity_types (key, prefix, description) values
  ('contract', 'CON', 'Contract (commercial agreement with a client)'),
  ('invoice',  'INV', 'Invoice'),
  ('payment',  'PAY', 'Payment received');

-- ---------------------------------------------------------------------------
-- 2. Permissions
-- ---------------------------------------------------------------------------
insert into permissions (key, module, action, description, sensitivity) values
  ('contracts.view', 'contracts', 'view', 'View contracts and their versions', 'confidential'::data_classification),
  ('contracts.create', 'contracts', 'create', 'Draft contracts and amendments', 'confidential'::data_classification),
  ('contracts.update', 'contracts', 'update', 'Edit draft contracts and link projects', 'confidential'::data_classification),
  ('contracts.approve', 'contracts', 'approve', 'Approve contracts before they are sent', 'confidential'::data_classification),
  ('contracts.terminate', 'contracts', 'terminate', 'Terminate or cancel contracts', 'confidential'::data_classification),
  ('invoices.view', 'invoices', 'view', 'View invoices and billable items', 'confidential'::data_classification),
  ('invoices.create', 'invoices', 'create', 'Raise invoices and billable items', 'confidential'::data_classification),
  ('invoices.update', 'invoices', 'update', 'Edit draft invoices', 'confidential'::data_classification),
  ('invoices.approve', 'invoices', 'approve', 'Approve invoices before they are issued', 'confidential'::data_classification),
  ('invoices.issue', 'invoices', 'issue', 'Issue approved invoices to the client', 'confidential'::data_classification),
  ('invoices.void', 'invoices', 'void', 'Void or cancel invoices', 'confidential'::data_classification),
  ('payments.view', 'payments', 'view', 'View payments and allocations', 'confidential'::data_classification),
  ('payments.record', 'payments', 'record', 'Record received payments', 'confidential'::data_classification),
  ('payments.allocate', 'payments', 'allocate', 'Allocate payments to invoices', 'confidential'::data_classification),
  ('payments.reconcile', 'payments', 'reconcile', 'Reconcile payments against bank statements', 'confidential'::data_classification),
  ('payments.reverse', 'payments', 'reverse', 'Request reversal or refund of a payment', 'confidential'::data_classification),
  ('finance.configure', 'finance', 'configure', 'Configure finance settings (VAT, payment terms, bank accounts)', 'confidential'::data_classification),
  ('discounts.approve', 'discounts', 'approve', 'Approve discounts above the policy threshold', 'confidential'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'contracts.view'),
  ('administration_officer', 'contracts.view'),
  ('finance_officer', 'contracts.view'),
  ('division_lead', 'contracts.view'),
  ('ceo', 'contracts.create'),
  ('division_lead', 'contracts.create'),
  ('ceo', 'contracts.update'),
  ('division_lead', 'contracts.update'),
  ('ceo', 'contracts.approve'),
  ('ceo', 'contracts.terminate'),
  ('ceo', 'invoices.view'),
  ('finance_officer', 'invoices.view'),
  ('division_lead', 'invoices.view'),
  ('ceo', 'invoices.create'),
  ('finance_officer', 'invoices.create'),
  ('ceo', 'invoices.update'),
  ('finance_officer', 'invoices.update'),
  ('ceo', 'invoices.approve'),
  ('finance_officer', 'invoices.approve'),
  ('ceo', 'invoices.issue'),
  ('finance_officer', 'invoices.issue'),
  ('ceo', 'invoices.void'),
  ('ceo', 'payments.view'),
  ('finance_officer', 'payments.view'),
  ('ceo', 'payments.record'),
  ('finance_officer', 'payments.record'),
  ('ceo', 'payments.allocate'),
  ('finance_officer', 'payments.allocate'),
  ('ceo', 'payments.reconcile'),
  ('finance_officer', 'payments.reconcile'),
  ('ceo', 'payments.reverse'),
  ('finance_officer', 'payments.reverse'),
  ('ceo', 'finance.configure'),
  ('ceo', 'discounts.approve')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;

-- ---------------------------------------------------------------------------
-- 3. Finance settings and bank accounts
-- ---------------------------------------------------------------------------
create table finance_settings (
  id                         boolean primary key default true check (id),
  base_currency              char(3) not null default 'NAD',
  vat_registered             boolean not null default false,
  vat_rate                   numeric(5,2) not null default 15 check (vat_rate between 0 and 100),
  vat_number                 text,
  default_payment_terms_days integer not null default 30 check (default_payment_terms_days between 0 and 365),
  updated_by                 uuid references staff (id),
  updated_at                 timestamptz not null default now(),
  check (not vat_registered or coalesce(btrim(vat_number), '') <> '')
);
insert into finance_settings default values;
comment on table finance_settings is 'Purpose: the single row of organisation-wide finance settings. Invoices COPY the VAT rate and terms they were issued under (snapshot), so changing this never alters an issued invoice. [class: confidential]';

create table bank_accounts (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique check (btrim(name) <> ''),
  bank_name    text,
  account_hint text check (account_hint is null or length(account_hint) <= 8),
  currency     char(3) not null default 'NAD',
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table bank_accounts is 'Purpose: ADA''s own accounts that payments are received into. Only a short hint (last digits) is stored, never a full account number. [class: confidential]';
comment on column bank_accounts.account_hint is 'Last few digits only, for recognition. Full account numbers must not be stored here.';
create trigger finance_settings_updated before update on finance_settings for each row execute function set_updated_at();
create trigger bank_accounts_updated before update on bank_accounts for each row execute function set_updated_at();

alter table finance_settings enable row level security;
alter table bank_accounts enable row level security;
revoke all on finance_settings, bank_accounts from anon, authenticated;
grant select, update on finance_settings to authenticated;
grant select, insert, update on bank_accounts to authenticated;
create policy finance_settings_select on finance_settings for select to authenticated
  using (has_permission('finance.view') or has_permission('invoices.view') or has_permission('contracts.view'));
create policy finance_settings_update on finance_settings for update to authenticated
  using (has_permission('finance.configure')) with check (has_permission('finance.configure'));
create policy bank_accounts_select on bank_accounts for select to authenticated
  using (has_permission('payments.view') or has_permission('finance.configure'));
create policy bank_accounts_insert on bank_accounts for insert to authenticated with check (has_permission('finance.configure'));
create policy bank_accounts_update on bank_accounts for update to authenticated
  using (has_permission('finance.configure')) with check (has_permission('finance.configure'));
do $$ begin perform attach_audit('finance_settings'); perform attach_audit('bank_accounts'); end $$;

-- ---------------------------------------------------------------------------
-- 4. Approval queue: classification-aware
-- ---------------------------------------------------------------------------
alter table approval_requests add column classification data_classification not null default 'internal';
comment on column approval_requests.classification is 'Classification of the record awaiting approval (stricter of the record and its client). The queue shows a request only to approvers who may also see the record, so it cannot reveal a restricted client.';
drop policy approval_requests_select on approval_requests;
create policy approval_requests_select on approval_requests for select to authenticated
  using ((requested_by = current_staff_id() or has_permission(required_permission, division_id)) and classification_visible(classification));

-- approval_sync records the record's classification when it opens a request
create or replace function approval_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  j jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
  v_status text := j ->> 'status';
  v_old text := o ->> 'status';
  v_req uuid;
  v_class data_classification;
begin
  if v_status = 'pending_approval' and (tg_op = 'INSERT' or v_old is distinct from 'pending_approval') then
    v_class := greatest(coalesce((j ->> 'effective_classification')::data_classification, 'internal'),
                        coalesce((select classification from clients where id = nullif(j ->> 'client_id', '')::uuid), 'internal'));
    update approval_requests set status = 'cancelled', decided_at = now()
     where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
    insert into approval_requests (kind, entity_table, entity_id, entity_ada_id, division_id, required_permission, summary, requested_by, classification)
    values (tg_argv[0], tg_table_name, new.id, j ->> 'ada_id', nullif(j ->> nullif(tg_argv[3], ''), '')::uuid, tg_argv[1],
            j ->> tg_argv[2], current_staff_id(), v_class);
  elsif tg_op = 'UPDATE' and v_old = 'pending_approval' and v_status <> 'pending_approval' then
    select requested_by into v_req from approval_requests where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
    update approval_requests ar
       set status = case when v_status in ('approved', 'published') then 'approved'::approval_status
                         when v_status in ('rejected') or (v_status = 'draft' and v_req is distinct from current_staff_id()) then 'rejected'::approval_status
                         else 'cancelled'::approval_status end,
           decided_by = current_staff_id(), decided_at = now(), decision_note = coalesce(j ->> 'status_reason', j ->> 'decision_note'),
           self_approved = coalesce((select bool_or(d.is_self) from approval_decisions d where d.request_id = ar.id and d.decision = 'approve'), false)
     where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
  end if;
  return null;
end $$;

-- Generic open/close for records whose approval state is not a single status column (e.g. contract versions).
create function approval_open(p_kind text, p_table text, p_entity uuid, p_ada_id text, p_division uuid, p_permission text,
                              p_summary text, p_class data_classification) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  update approval_requests set status = 'cancelled', decided_at = now()
   where entity_table = p_table and entity_id = p_entity and status = 'pending';
  insert into approval_requests (kind, entity_table, entity_id, entity_ada_id, division_id, required_permission, summary, requested_by, classification)
  values (p_kind, p_table, p_entity, p_ada_id, p_division, p_permission, p_summary, current_staff_id(), p_class)
  returning id into v_id;
  return v_id;
end $$;

create function approval_close(p_table text, p_entity uuid, p_outcome approval_status, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update approval_requests ar
     set status = p_outcome, decided_by = current_staff_id(), decided_at = now(), decision_note = p_note,
         self_approved = coalesce((select bool_or(d.is_self) from approval_decisions d where d.request_id = ar.id and d.decision = 'approve'), false)
   where entity_table = p_table and entity_id = p_entity and status = 'pending';
end $$;
revoke execute on function approval_open(text, text, uuid, text, uuid, text, text, data_classification),
  approval_close(text, uuid, approval_status, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Approval gate with discounts
-- ---------------------------------------------------------------------------
drop function approval_gate(text, text, uuid, uuid, numeric, uuid, text, boolean, text);
drop function qualified_approver_count(text, uuid, uuid);

-- Staff who hold ALL the given permissions in the division (p_permission2 optional), excluding one staff id.
create function qualified_approver_count(p_permission text, p_division uuid, p_exclude uuid, p_permission2 text default null) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::integer from staff s
  where s.account_status = 'active' and s.deleted_at is null and s.id is distinct from p_exclude
    and exists (select 1 from staff_roles sr join role_permissions rp on rp.role_id = sr.role_id join permissions p on p.id = rp.permission_id
                where sr.staff_id = s.id and p.key = p_permission and (sr.division_id is null or sr.division_id = p_division))
    and (p_permission2 is null
         or exists (select 1 from staff_roles sr join role_permissions rp on rp.role_id = sr.role_id join permissions p on p.id = rp.permission_id
                    where sr.staff_id = s.id and p.key = p_permission2 and (sr.division_id is null or sr.division_id = p_division)))
$$;

-- The one authorisation call. p_discount (optional) is resolved against policy kind 'discount': the decider must hold the
-- permissions of BOTH policies, the quorum is the larger of the two, and self-approval needs both policies to allow it.
create function approval_gate(p_kind text, p_table text, p_entity uuid, p_division uuid, p_amount numeric, p_requested_by uuid,
                              p_fallback_permission text, p_approve boolean, p_note text, p_discount numeric default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pol approval_policies;
  dpol approval_policies;
  v_perm text;
  v_dperm text;
  v_me uuid := current_staff_id();
  v_self boolean;
  v_req approval_requests%rowtype;
  v_required integer;
  v_others integer;
  v_have integer;
  v_allow boolean;
  v_sole boolean;
begin
  pol := approval_policy(p_kind, p_division, p_amount);
  v_perm := coalesce(pol.required_permission, p_fallback_permission);
  if coalesce(p_discount, 0) > 0 then
    dpol := approval_policy('discount', p_division, p_discount);
    v_dperm := dpol.required_permission;
  end if;
  if v_me is null or not has_permission(v_perm, p_division) or (v_dperm is not null and not has_permission(v_dperm, p_division)) then
    raise exception '% is required to decide this', case when v_me is not null and has_permission(v_perm, p_division) then v_dperm else v_perm end using errcode = '42501';
  end if;
  select * into v_req from approval_requests where entity_table = p_table and entity_id = p_entity and status = 'pending' for update;
  if not found then raise exception 'no approval is pending for this record' using errcode = 'P0002'; end if;

  v_self := p_requested_by is not null and p_requested_by = v_me;
  v_others := qualified_approver_count(v_perm, p_division, v_me, v_dperm);
  v_allow := coalesce(pol.allow_self_approval, false) and (dpol.id is null or dpol.allow_self_approval);
  v_sole := coalesce(pol.self_approval_only_if_sole_approver, true) or coalesce(dpol.self_approval_only_if_sole_approver, false);
  if v_self then
    if not v_allow then
      raise exception 'you cannot decide your own request: separation of duties applies' using errcode = '42501';
    end if;
    if v_sole and v_others > 0 then
      raise exception 'you cannot decide your own request: another qualified approver exists, so separation of duties applies' using errcode = '42501';
    end if;
  end if;
  if exists (select 1 from approval_decisions where request_id = v_req.id and approver_id = v_me) then
    raise exception 'you have already decided this request' using errcode = '23505';
  end if;

  if not p_approve then
    insert into approval_decisions (request_id, approver_id, decision, note, is_self) values (v_req.id, v_me, 'reject', p_note, v_self);
    return 'rejected';
  end if;

  v_required := greatest(coalesce(pol.min_approvers, 1), coalesce(dpol.min_approvers, 1), 1);
  if v_required > 1 + v_others then
    raise exception 'policy requires % approvers but only % qualified approver(s) exist', v_required, 1 + v_others using errcode = '23514';
  end if;
  insert into approval_decisions (request_id, approver_id, decision, note, is_self) values (v_req.id, v_me, 'approve', p_note, v_self);
  select count(*) into v_have from approval_decisions where request_id = v_req.id and decision = 'approve';
  update approval_requests set required_approvals = v_required where id = v_req.id;
  return case when v_have >= v_required then 'approved' else 'pending' end;
end $$;
revoke execute on function qualified_approver_count(text, uuid, uuid, text),
  approval_gate(text, text, uuid, uuid, numeric, uuid, text, boolean, text, numeric) from public, anon, authenticated;

-- Quotes: pass the quote's total discount so a 'discount' policy applies to quotes too.
create or replace function quote_transition(p_id uuid, p_to quote_status, p_note text default null) returns quote_status
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  q quotes%rowtype;
  v_edit boolean;
  v_appr boolean;
  v_lines integer;
  v_gate text;
begin
  select * into q from quotes where id = p_id for update;
  if not found or not can_view_quote(p_id) then raise exception 'quote not found' using errcode = 'P0002'; end if;
  v_edit := has_permission('quotes.update', q.division_id);
  v_appr := has_permission('quotes.approve');

  case
    when q.status = 'draft' and p_to = 'pending_approval' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      select count(*) into v_lines from quote_lines where quote_id = p_id;
      if v_lines = 0 then raise exception 'add at least one line before submitting' using errcode = '23514'; end if;
      if q.valid_until < current_date then raise exception 'the validity date is in the past' using errcode = '23514'; end if;
      if (select status from clients where id = q.client_id) = 'archived' then raise exception 'the client is archived' using errcode = '23514'; end if;
      update quotes set status = p_to, requested_by = current_staff_id(), status_reason = null where id = p_id;
      perform notify_holders('quotes.approve', null, 'approval.required', 'Quote awaiting approval: ' || q.title, null, 'quotes', q.id, q.ada_id);
    when q.status = 'pending_approval' and p_to = 'draft' then
      if not (v_edit or v_appr) then raise exception 'not permitted' using errcode = '42501'; end if;
      update quotes set status = p_to, status_reason = p_note where id = p_id;
    when q.status = 'pending_approval' and p_to = 'approved' then
      v_gate := approval_gate('quote', 'quotes', q.id, q.division_id, q.total, q.requested_by, 'quotes.approve', true, p_note,
                           (select coalesce(sum(discount_amount), 0) from quote_lines where quote_id = q.id));
      if v_gate = 'pending' then return 'pending_approval'; end if;       -- more approvers needed
      update quotes set status = p_to, approved_by = current_staff_id(), approved_at = now(), status_reason = null where id = p_id;
    when q.status = 'approved' and p_to = 'sent' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if q.valid_until < current_date then raise exception 'the quote has expired' using errcode = '23514'; end if;
      update quotes set status = p_to, sent_at = now() where id = p_id;
    when q.status = 'sent' and p_to = 'accepted' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if q.valid_until < current_date then raise exception 'the quote expired on %', q.valid_until using errcode = '23514'; end if;
      update quotes set status = p_to, decided_at = now(), decision_note = p_note where id = p_id;
      perform emit_event('quote.accepted', 'quotes', q.id, q.ada_id, jsonb_build_object('status', 'accepted'));
      if q.lead_id is not null then                                    -- the lead has done its job
        update leads set status = 'converted', converted_at = now() where id = q.lead_id and status <> 'converted';
        perform emit_event('lead.converted', 'leads', q.lead_id, (select ada_id from leads where id = q.lead_id), jsonb_build_object('status', 'converted'));
      end if;
      perform notify_holders('projects.create', q.division_id, 'quote.accepted', 'Quote accepted: ' || q.title, 'Convert it into a project.', 'quotes', q.id, q.ada_id);
    when q.status = 'sent' and p_to = 'rejected' then
      if not v_edit then raise exception 'quotes.update is required' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'record why the client declined' using errcode = '23514'; end if;
      update quotes set status = p_to, decided_at = now(), decision_note = p_note where id = p_id;
    when q.status in ('draft', 'pending_approval', 'approved', 'sent') and p_to = 'cancelled' then
      if not (v_edit or v_appr) then raise exception 'not permitted' using errcode = '42501'; end if;
      if coalesce(btrim(p_note), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
      update quotes set status = p_to, status_reason = p_note where id = p_id;
    else
      raise exception 'invalid quote transition % -> %', q.status, p_to using errcode = '23514';
  end case;
  return p_to;
end $$;
