-- 0005_audit: append-only audit trail with before/after values, written by triggers
-- (so no application code path can forget to log, or forge an entry).

create table audit_log (
  id              bigint generated always as identity primary key,
  occurred_at     timestamptz not null default now(),
  actor_user_id   uuid,
  actor_staff_id  uuid,
  actor_ada_id    text,
  action          text not null,
  table_name      text not null,
  record_id       uuid,
  record_ada_id   text,
  old_data        jsonb,
  new_data        jsonb,
  changed_fields  text[],
  reason          text,
  result          text not null default 'success'
);
create index audit_log_occurred_idx on audit_log (occurred_at desc);
create index audit_log_record_idx   on audit_log (table_name, record_id);
create index audit_log_actor_idx    on audit_log (actor_staff_id);
comment on table audit_log is 'Purpose: immutable record of who changed what, when, from what to what. Written only by triggers. [class: restricted]';

alter table audit_log enable row level security;
revoke all on audit_log from anon, authenticated;
grant select on audit_log to authenticated;
create policy audit_select on audit_log for select to authenticated using (has_permission('audit.view'));

-- Immutability: nobody (including owners) can update, delete or truncate through SQL
-- without first dropping these triggers, which is itself a superuser-only, visible act.
create function audit_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_log is append-only' using errcode = '42501';
end $$;
create trigger audit_no_update before update or delete on audit_log for each row execute function audit_immutable();
create trigger audit_no_truncate before truncate on audit_log for each statement execute function audit_immutable();

-- Generic row-change recorder. Trigger args: columns to redact (values never stored).
create function audit_row() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old   jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new   jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_col   text;
  v_diff  text[];
  v_row   jsonb := coalesce(v_new, v_old);
  v_staff uuid  := current_staff_id();
begin
  if tg_nargs > 0 then
    foreach v_col in array tg_argv loop
      if v_old ? v_col then v_old := jsonb_set(v_old, array[v_col], '"[redacted]"'); end if;
      if v_new ? v_col then v_new := jsonb_set(v_new, array[v_col], '"[redacted]"'); end if;
    end loop;
  end if;

  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into v_diff
    from jsonb_object_keys(v_new) k
    where k <> 'updated_at' and v_new -> k is distinct from v_old -> k;
    if v_diff is null then
      return null;                       -- no-op update; nothing to record
    end if;
  end if;

  insert into audit_log (actor_user_id, actor_staff_id, actor_ada_id, action, table_name,
                         record_id, record_ada_id, old_data, new_data, changed_fields, reason)
  values (auth.uid(), v_staff, (select ada_id from staff where id = v_staff),
          tg_op, tg_table_name,
          nullif(v_row ->> 'id', '')::uuid, v_row ->> 'ada_id', v_old, v_new, v_diff,
          nullif(current_setting('ada.reason', true), ''));
  return null;
end $$;

create function attach_audit(p_table regclass, p_redact text[] default '{}') returns void
language plpgsql as $$
begin
  execute format(
    'create trigger zz_audit after insert or update or delete on %s
       for each row execute function audit_row(%s)',
    p_table, coalesce((select string_agg(quote_literal(c), ', ') from unnest(p_redact) c), ''));
end $$;
revoke execute on function attach_audit(regclass, text[]) from public, anon, authenticated;

-- Trusted server code may record non-row events (exports, sensitive reads, security events).
create function record_audit_event(p_action text, p_table text, p_record_id uuid, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_staff uuid := current_staff_id();
begin
  insert into audit_log (actor_user_id, actor_staff_id, actor_ada_id, action, table_name, record_id, new_data, reason)
  values (auth.uid(), v_staff, (select ada_id from staff where id = v_staff), p_action, p_table, p_record_id, p_detail,
          nullif(current_setting('ada.reason', true), ''));
end $$;
revoke execute on function record_audit_event(text, text, uuid, jsonb) from public, anon, authenticated;
grant execute on function record_audit_event(text, text, uuid, jsonb) to service_role;

-- Attach to everything created so far.
do $$ begin perform attach_audit('organization'); end $$;
do $$ begin perform attach_audit('divisions'); end $$;
do $$ begin perform attach_audit('positions'); end $$;
do $$ begin perform attach_audit('staff'); end $$;
select attach_audit('staff_private', array['personal_email','personal_phone','national_id','date_of_birth',
                                            'home_address','emergency_contact_name','emergency_contact_phone','hr_notes']);
do $$ begin perform attach_audit('roles'); end $$;
do $$ begin perform attach_audit('role_permissions'); end $$;
do $$ begin perform attach_audit('staff_roles'); end $$;
