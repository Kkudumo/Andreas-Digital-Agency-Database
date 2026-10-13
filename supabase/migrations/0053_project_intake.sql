-- 0053_project_intake: production project intake for ADA IRM.
-- Captures delivery metadata and optional confidential commercial figures in one controlled transaction.
-- SECURITY INVOKER keeps all existing RLS/permission rules authoritative.

create function project_intake_create(
  p_client uuid,
  p_division uuid,
  p_name text,
  p_description text default null,
  p_type text default null,
  p_priority text default 'normal',
  p_start date default null,
  p_due date default null,
  p_quoted_amount numeric default null,
  p_budget numeric default null,
  p_finance_notes text default null
) returns uuid
language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  v_id uuid;
  v_priority priority_level;
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

  if p_quoted_amount is not null or p_budget is not null or nullif(btrim(coalesce(p_finance_notes, '')), '') is not null then
    insert into project_financials (project_id, currency, quoted_amount, budget, notes)
    values (
      v_id,
      'NAD',
      p_quoted_amount,
      p_budget,
      nullif(btrim(coalesce(p_finance_notes, '')), '')
    );
  end if;

  return v_id;
end $$;

revoke execute on function project_intake_create(uuid, uuid, text, text, text, text, date, date, numeric, numeric, text) from public, anon;
grant execute on function project_intake_create(uuid, uuid, text, text, text, text, date, date, numeric, numeric, text) to authenticated;

comment on function project_intake_create(uuid, uuid, text, text, text, text, date, date, numeric, numeric, text)
is 'Controlled ADA IRM project intake. General project data and confidential financials are written under the caller RLS permissions in one transaction.';
