-- 0045_project_write_functions: named entry points for the project writes the interface performs (Pilot V0.1 finding F5).
-- Projects, project contacts / divisions / members and tasks were written by direct INSERTs under row-level security. Those policies and guard triggers are
-- the rules and they are unchanged; these functions only give each write a NAME, so the interface calls an operation instead of a table. They are
-- SECURITY INVOKER: they run as the caller, every row-level-security policy and guard trigger applies exactly as for a direct insert (so a hidden client or
-- project answers exactly as an unknown one does), the audit triggers fire as before, and they grant no new power. Direct insert privileges stay (other
-- modules and tests rely on them).
create function project_create(p_client uuid, p_division uuid, p_name text, p_description text default null) returns uuid
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into projects (client_id, lead_division_id, name, description)
  values (p_client, p_division, btrim(p_name), nullif(btrim(coalesce(p_description, '')), ''))
  returning id into v_id;
  return v_id;
end $$;

create function project_add_contact(p_project uuid, p_contact uuid, p_role text default null) returns void
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  insert into project_contacts (project_id, contact_id, role) values (p_project, p_contact, nullif(btrim(coalesce(p_role, '')), ''));
end $$;

create function project_add_division(p_project uuid, p_division uuid) returns void
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  insert into project_divisions (project_id, division_id) values (p_project, p_division);
end $$;

create function project_add_member(p_project uuid, p_staff uuid, p_role text default null) returns void
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  insert into project_members (project_id, staff_id, member_role) values (p_project, p_staff, coalesce(nullif(btrim(coalesce(p_role, '')), ''), 'member'));
end $$;

create function task_create(p_project uuid, p_title text, p_description text default null, p_assignee uuid default null, p_due date default null) returns uuid
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into tasks (project_id, title, description, assignee_id, due_date)
  values (p_project, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''), p_assignee, p_due)
  returning id into v_id;
  return v_id;
end $$;

revoke execute on function project_create(uuid, uuid, text, text), project_add_contact(uuid, uuid, text), project_add_division(uuid, uuid),
  project_add_member(uuid, uuid, text), task_create(uuid, text, text, uuid, date) from public, anon;
grant execute on function project_create(uuid, uuid, text, text), project_add_contact(uuid, uuid, text), project_add_division(uuid, uuid),
  project_add_member(uuid, uuid, text), task_create(uuid, text, text, uuid, date) to authenticated;
