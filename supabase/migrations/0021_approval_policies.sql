-- 0021_approval_policies: the minimum reusable approval foundation.
--  * approval_policies say, per kind (+ optional division and amount threshold): which permission approves,
--    how many approvers are needed, and whether self-approval is allowed at all.
--  * Self-approval is a POLICY, not a role privilege. Where allowed it is limited to the period in which the
--    requester is the ONLY qualified approver; the moment a second qualified approver exists, separation of
--    duties applies automatically. Every self-approval is recorded.
--  * approval_gate() is the single call a workflow makes to authorise a decision. It replaces the earlier
--    hardcoded "<module>.approve_own" permissions.
-- Adopted so far by: price changes and quotes. Other kinds (vacancy, profile, service, portfolio) still gate on
-- their publish permission and can adopt approval_gate() with one call each - see docs/workflows/APPROVALS.md.

create table approval_policies (
  id                                  uuid primary key default gen_random_uuid(),
  kind                                text not null check (btrim(kind) <> ''),
  division_id                         uuid references divisions (id),
  min_amount                          numeric(14,2) check (min_amount >= 0),
  required_permission                 text not null,
  allow_self_approval                 boolean not null default false,
  self_approval_only_if_sole_approver boolean not null default true,
  min_approvers                       integer not null default 1 check (min_approvers between 1 and 5),
  is_active                           boolean not null default true,
  note                                text,
  created_at                          timestamptz not null default now(),
  updated_at                          timestamptz not null default now()
);
create unique index approval_policies_unique on approval_policies
  (kind, coalesce(division_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(min_amount, -1));
comment on table approval_policies is 'Purpose: configurable approval rules. The most specific active row wins (division match first, then the highest min_amount not above the amount). No row = the caller''s default permission, one approver, no self-approval. [class: restricted]';
create trigger approval_policies_updated before update on approval_policies for each row execute function set_updated_at();

create function approval_policies_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from permissions where key = new.required_permission) then
    raise exception 'unknown permission %', new.required_permission using errcode = '23514';
  end if;
  return new;
end $$;
create trigger approval_policies_guard_trg before insert or update on approval_policies for each row execute function approval_policies_guard();

alter table approval_requests add column self_approved boolean not null default false,
                              add column required_approvals integer;
comment on column approval_requests.self_approved is 'True when the requester was also an approver (only possible where the policy allows it). Recorded for audit and review.';

create table approval_decisions (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references approval_requests (id) on delete restrict,
  approver_id uuid not null references staff (id),
  decision    text not null check (decision in ('approve', 'reject')),
  note        text,
  is_self     boolean not null default false,
  decided_at  timestamptz not null default now(),
  unique (request_id, approver_id)
);
comment on table approval_decisions is 'Purpose: each individual approval or rejection (supports more than one approver). Append-only. [class: restricted]';
create trigger approval_decisions_immutable before update or delete on approval_decisions for each row execute function append_only();

-- Carry the self-approval fact onto the request when it closes.
create or replace function approval_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  j jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
  v_status text := j ->> 'status';
  v_old text := o ->> 'status';
  v_req uuid;
begin
  if v_status = 'pending_approval' and (tg_op = 'INSERT' or v_old is distinct from 'pending_approval') then
    update approval_requests set status = 'cancelled', decided_at = now()
     where entity_table = tg_table_name and entity_id = new.id and status = 'pending';
    insert into approval_requests (kind, entity_table, entity_id, entity_ada_id, division_id, required_permission, summary, requested_by)
    values (tg_argv[0], tg_table_name, new.id, j ->> 'ada_id', nullif(j ->> nullif(tg_argv[3], ''), '')::uuid, tg_argv[1],
            j ->> tg_argv[2], current_staff_id());
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

create function qualified_approver_count(p_permission text, p_division uuid, p_exclude uuid) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select count(distinct s.id)::integer
  from staff s
  join staff_roles sr on sr.staff_id = s.id
  join role_permissions rp on rp.role_id = sr.role_id
  join permissions p on p.id = rp.permission_id
  where p.key = p_permission and (sr.division_id is null or sr.division_id = p_division)
    and s.account_status = 'active' and s.deleted_at is null and s.id is distinct from p_exclude
$$;

create function approval_policy(p_kind text, p_division uuid, p_amount numeric) returns approval_policies
language sql stable security definer set search_path = public, pg_temp as $$
  select * from approval_policies
   where is_active and kind = p_kind and (division_id is null or division_id = p_division)
     and coalesce(min_amount, 0) <= coalesce(p_amount, 0)
   order by (division_id is not null) desc, coalesce(min_amount, 0) desc
   limit 1
$$;

-- The one authorisation call. Returns 'approved' (quorum reached), 'pending' (needs more approvers) or 'rejected'.
create function approval_gate(p_kind text, p_table text, p_entity uuid, p_division uuid, p_amount numeric, p_requested_by uuid,
                              p_fallback_permission text, p_approve boolean, p_note text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pol approval_policies;
  v_perm text;
  v_me uuid := current_staff_id();
  v_self boolean;
  v_req approval_requests%rowtype;
  v_required integer;
  v_others integer;
  v_have integer;
begin
  pol := approval_policy(p_kind, p_division, p_amount);
  v_perm := coalesce(pol.required_permission, p_fallback_permission);
  if v_me is null or not has_permission(v_perm, p_division) then
    raise exception '% is required to decide this', v_perm using errcode = '42501';
  end if;
  select * into v_req from approval_requests where entity_table = p_table and entity_id = p_entity and status = 'pending' for update;
  if not found then raise exception 'no approval is pending for this record' using errcode = 'P0002'; end if;

  v_self := p_requested_by is not null and p_requested_by = v_me;
  v_others := qualified_approver_count(v_perm, p_division, v_me);
  if v_self then
    if not coalesce(pol.allow_self_approval, false) then
      raise exception 'you cannot decide your own request: separation of duties applies' using errcode = '42501';
    end if;
    if coalesce(pol.self_approval_only_if_sole_approver, true) and v_others > 0 then
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

  v_required := greatest(coalesce(pol.min_approvers, 1), 1);
  if v_required > 1 + v_others then
    raise exception 'policy requires % approvers but only % qualified approver(s) exist', v_required, 1 + v_others using errcode = '23514';
  end if;
  insert into approval_decisions (request_id, approver_id, decision, note, is_self) values (v_req.id, v_me, 'approve', p_note, v_self);
  select count(*) into v_have from approval_decisions where request_id = v_req.id and decision = 'approve';
  update approval_requests set required_approvals = v_required where id = v_req.id;
  return case when v_have >= v_required then 'approved' else 'pending' end;
end $$;

-- ---------------------------------------------------------------------------
-- Adopt the gate: price changes
-- ---------------------------------------------------------------------------
create or replace function price_decide(p_price uuid, p_approve boolean, p_note text default null) returns service_prices
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p service_prices%rowtype;
  s services%rowtype;
  v_latest date;
  v_gate text;
begin
  select * into p from service_prices where id = p_price for update;
  if not found then raise exception 'price not found' using errcode = 'P0002'; end if;
  select * into s from services where id = p.service_id;
  if p.status <> 'pending_approval' then raise exception 'this price is already %', p.status using errcode = '23514'; end if;

  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required to reject a price' using errcode = '23514'; end if;
    perform approval_gate('price_change', 'service_prices', p.id, s.division_id, p.amount, p.proposed_by, 'pricing.approve', false, p_note);
    update service_prices set status = 'rejected', decision_note = p_note, approved_by = null where id = p_price returning * into p;
    return p;
  end if;

  v_gate := approval_gate('price_change', 'service_prices', p.id, s.division_id, p.amount, p.proposed_by, 'pricing.approve', true, p_note);
  if v_gate = 'pending' then return p; end if;                      -- more approvers needed; stays pending

  select max(effective_from) into v_latest from service_prices where service_id = p.service_id and status = 'approved';
  if v_latest is not null and p.effective_from <= v_latest then
    raise exception 'a newer price (%) has been approved since this was proposed', v_latest using errcode = '23514';
  end if;
  if p.effective_from < current_date then
    update service_prices set effective_from = current_date where id = p_price;
    p.effective_from := current_date;
    if v_latest is not null and p.effective_from <= v_latest then
      raise exception 'a newer price (%) has been approved since this was proposed', v_latest using errcode = '23514';
    end if;
  end if;
  update service_prices set effective_to = p.effective_from - 1
   where service_id = p.service_id and status = 'approved' and effective_to is null;
  update service_prices set status = 'approved', approved_by = current_staff_id(), approved_at = now(), decision_note = p_note
   where id = p_price returning * into p;
  perform emit_event('price.changed', 'service_prices', p.id, s.ada_id,
                     jsonb_build_object('service', s.ada_id, 'effective_from', p.effective_from, 'status', 'approved'));
  if p.proposed_by is not null then
    insert into notifications (recipient_staff_id, type, title, entity_table, entity_id, entity_ada_id)
    values (p.proposed_by, 'price.approved', 'Price approved for ' || s.name, 'service_prices', p.id, s.ada_id);
  end if;
  return p;
end $$;

-- ---------------------------------------------------------------------------
-- Adopt the gate: quotes (amount-aware)
-- ---------------------------------------------------------------------------
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
      v_gate := approval_gate('quote', 'quotes', q.id, q.division_id, q.total, q.requested_by, 'quotes.approve', true, p_note);
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

-- The superseded hardcoded mechanism goes away entirely.
drop function assert_not_own_request(uuid, text);
delete from role_permissions where permission_id in (select id from permissions where key in ('pricing.approve_own', 'quotes.approve_own'));
delete from permissions where key in ('pricing.approve_own', 'quotes.approve_own');

-- Default policies reproduce today's behaviour: a sole approver may approve their own request; as soon as a
-- second qualified approver exists, separation of duties applies - with no configuration change needed.
insert into approval_policies (kind, required_permission, allow_self_approval, self_approval_only_if_sole_approver, min_approvers, note) values
  ('price_change', 'pricing.approve', true, true, 1, 'default'),
  ('quote',        'quotes.approve',  true, true, 1, 'default');

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
alter table approval_policies  enable row level security;
alter table approval_decisions enable row level security;
revoke all on approval_policies, approval_decisions from anon, authenticated;
grant select, insert, update on approval_policies to authenticated;     -- no delete: deactivate (is_active) to keep history
grant select on approval_decisions to authenticated;
create policy approval_policies_select on approval_policies for select to authenticated using (has_permission('approvals.configure'));
create policy approval_policies_insert on approval_policies for insert to authenticated with check (has_permission('approvals.configure'));
create policy approval_policies_update on approval_policies for update to authenticated
  using (has_permission('approvals.configure')) with check (has_permission('approvals.configure'));
create policy approval_decisions_select on approval_decisions for select to authenticated
  using (exists (select 1 from approval_requests r where r.id = request_id));

revoke execute on function qualified_approver_count(text, uuid, uuid), approval_policy(text, uuid, numeric),
  approval_gate(text, text, uuid, uuid, numeric, uuid, text, boolean, text) from public, anon, authenticated;

do $$ begin perform attach_audit('approval_policies'); end $$;
