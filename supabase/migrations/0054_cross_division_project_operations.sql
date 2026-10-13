-- 0054_cross_division_project_operations: one client/project, many participating divisions, separated finance ownership.
-- The intake operation creates the project and its participating divisions atomically.
-- Financials are maintained through a separate finance-controlled operation so Administration/Web/Marketing
-- never need finance.create simply to create or work on the project.

create function project_intake_create_v2(
  p_client uuid,
  p_division uuid,
  p_participating_divisions uuid[] default '{}',
  p_name text default null,
  p_description text default null,
  p_type text default null,
  p_priority text default 'normal',
  p_start date default null,
  p_due date default null
) returns uuid
language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  v_id uuid;
  v_priority priority_level;
  v_division uuid;
begin
  v_priority := coalesce(nullif(btrim(coalesce(p_priority, '')), ''), 'normal')::priority_level;

  insert into projects (
    client_id, lead_division_id, name, description, project_type,
    priority, start_date, due_date
  )
  values (
    p_client,
    p_division,
    btrim(p_name),
    nullif(btrim(coalesce(p_description, '')), ''),
    nullif(btrim(coalesce(p_type, '')), ''),
    v_priority,
    p_start,
    p_due
  )
  returning id into v_id;

  foreach v_division in array coalesce(p_participating_divisions, '{}'::uuid[]) loop
    if v_division is distinct from p_division then
      insert into project_divisions (project_id, division_id)
      values (v_id, v_division)
      on conflict do nothing;
    end if;
  end loop;

  return v_id;
end $$;

create function project_financials_set(
  p_project uuid,
  p_quoted_amount numeric default null,
  p_budget numeric default null,
  p_notes text default null
) returns void
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  insert into project_financials (project_id, currency, quoted_amount, budget, notes)
  values (
    p_project,
    'NAD',
    p_quoted_amount,
    p_budget,
    nullif(btrim(coalesce(p_notes, '')), '')
  )
  on conflict (project_id) do update
    set quoted_amount = excluded.quoted_amount,
        budget = excluded.budget,
        notes = excluded.notes,
        updated_at = now();
end $$;

revoke execute on function project_intake_create_v2(uuid, uuid, uuid[], text, text, text, text, date, date) from public, anon;
grant execute on function project_intake_create_v2(uuid, uuid, uuid[], text, text, text, text, date, date) to authenticated;

revoke execute on function project_financials_set(uuid, numeric, numeric, text) from public, anon;
grant execute on function project_financials_set(uuid, numeric, numeric, text) to authenticated;

comment on function project_intake_create_v2(uuid, uuid, uuid[], text, text, text, text, date, date)
is 'Creates one client project and all participating divisions under existing project RLS/permission rules.';
comment on function project_financials_set(uuid, numeric, numeric, text)
is 'Creates or updates confidential project commercial figures; project_financials RLS requires finance.create.';
