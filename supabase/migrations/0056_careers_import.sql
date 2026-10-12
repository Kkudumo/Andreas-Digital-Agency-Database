-- 0056_careers_import: bringing the careers records of the old website project (career_opportunities, career_applications) into ADA Core.
--  * The old applications carry far more than ADA Core's application row (qualification, institution, skills, nationality ...). Those details are kept, not dropped:
--    applications.details (jsonb, same access as the application, which is restricted to recruitment).
--  * legacy_imports remembers which old record became which new one, so an import can be run again without duplicating anything.
--  * import_vacancy / import_application are run by the OWNER from the SQL editor with the SQL scripts/import-careers.mjs generates from an export of the old
--    tables. They are not callable by anyone else. They create the records exactly as exported (original dates and statuses, no notifications, no website events
--    for applications), and keep CV files as REFERENCES to the old project's storage (cv_ref 'legacy-storage:<bucket>/<path>'): the files stay where they are
--    until the documents module takes them over.

alter table applications add column details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object' and pg_column_size(details) <= 32768);
comment on column applications.details is 'Everything the applicant filled in beyond the core fields (qualification, institution, skills, nationality, availability ...) and the previous system''s internal notes. Personal data: read only by those who may read the application. [class: restricted]';

create table legacy_imports (
  source      text not null,
  source_id   text not null,
  entity_type text not null,
  entity_id   uuid not null,
  imported_at timestamptz not null default now(),
  primary key (source, source_id, entity_type)
);
comment on table legacy_imports is 'Purpose: which record of a previous system became which ADA Core record (so a re-run of an import is safe). [class: internal]';
alter table legacy_imports enable row level security;
revoke all on legacy_imports from anon, authenticated;
grant select on legacy_imports to authenticated;
create policy legacy_imports_select on legacy_imports for select to authenticated using (has_permission('audit.view'));

create function import_vacancy(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_div uuid; v_pos uuid; v_id uuid; v_ada text; v_status vacancy_status; v_type employment_type; v_title text := btrim(coalesce(p ->> 'title', ''));
begin
  if (p ->> 'legacy_id') is null or v_title = '' then raise exception 'legacy_id and title are required' using errcode = '22023'; end if;
  select entity_id into v_id from legacy_imports where source = 'career_opportunities' and source_id = p ->> 'legacy_id' and entity_type = 'vacancy';
  if found then return jsonb_build_object('result', 'exists', 'id', (select ada_id from vacancies where id = v_id)); end if;
  if coalesce((p ->> 'is_test')::boolean, false) then return jsonb_build_object('result', 'skipped', 'reason', 'test record'); end if;
  select id into v_div from divisions where key = p ->> 'division';
  if v_div is null then raise exception 'unknown division %', p ->> 'division' using errcode = '22023'; end if;
  v_status := coalesce(nullif(p ->> 'status', ''), 'draft')::vacancy_status;
  v_type := coalesce(nullif(p ->> 'employment_type', ''), 'full_time')::employment_type;
  select id into v_pos from positions where division_id = v_div and lower(title) = lower(v_title) limit 1;
  if v_pos is null then
    insert into positions (title, division_id, description, headcount) values (v_title, v_div, left(p ->> 'summary', 500), greatest(coalesce((p ->> 'openings')::integer, 1), 1)) returning id into v_pos;
  end if;
  insert into vacancies (position_id, division_id, title, summary, description, requirements, employment_type, openings, closing_date, status, published_at, closed_at, status_reason, created_at)
  values (v_pos, v_div, v_title, left(p ->> 'summary', 500), p ->> 'description', p ->> 'requirements', v_type, greatest(coalesce((p ->> 'openings')::integer, 1), 1),
          nullif(p ->> 'closing_date', '')::date, v_status, case when v_status = 'published' then coalesce((p ->> 'published_at')::timestamptz, now()) end,
          case when v_status in ('closed', 'filled') then now() end, 'imported from the previous website', coalesce((p ->> 'created_at')::timestamptz, now()))
  returning id, ada_id into v_id, v_ada;
  insert into legacy_imports (source, source_id, entity_type, entity_id) values ('career_opportunities', p ->> 'legacy_id', 'vacancy', v_id);
  return jsonb_build_object('result', 'created', 'id', v_ada);
end $$;

create function import_application(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_vac uuid; v_div uuid; v_pos uuid; v_person uuid; v_app uuid; v_ada text; v_id uuid; v_status application_status;
  v_email text := lower(btrim(coalesce(p ->> 'email', ''))); v_name text := btrim(coalesce(p ->> 'full_name', ''));
begin
  if (p ->> 'legacy_id') is null then raise exception 'legacy_id is required' using errcode = '22023'; end if;
  select entity_id into v_id from legacy_imports where source = 'career_applications' and source_id = p ->> 'legacy_id' and entity_type = 'application';
  if found then return jsonb_build_object('result', 'exists', 'id', (select ada_id from applications where id = v_id)); end if;
  if length(v_name) < 2 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('result', 'skipped', 'reason', 'no usable name or email'); end if;
  v_status := coalesce(nullif(p ->> 'status', ''), 'submitted')::application_status;

  select entity_id into v_vac from legacy_imports where source = 'career_opportunities' and source_id = p ->> 'vacancy_legacy_id' and entity_type = 'vacancy';
  if v_vac is null then
    -- general / talent-pool / internship applications and applications to a vacancy that was not imported: one standing, closed vacancy per division
    select id into v_div from divisions where key = coalesce(nullif(p ->> 'division', ''), 'administration');
    if v_div is null then select id into v_div from divisions where key = 'administration'; end if;
    select id into v_vac from vacancies where division_id = v_div and title = 'General applications (imported from the previous website)' and deleted_at is null;
    if v_vac is null then
      select id into v_pos from positions where division_id = v_div and title = 'General applications' limit 1;
      if v_pos is null then insert into positions (title, division_id, description) values ('General applications', v_div, 'Applications that were not for a specific vacancy') returning id into v_pos; end if;
      insert into vacancies (position_id, division_id, title, summary, description, employment_type, openings, status, closed_at, status_reason)
      values (v_pos, v_div, 'General applications (imported from the previous website)', 'Standing record for applications that were not for a specific vacancy.', 'Imported from the previous website.', 'full_time', 1, 'closed', now(), 'imported from the previous website')
      returning id into v_vac;
    end if;
  end if;

  insert into people (full_name, email, phone) values (left(v_name, 200), v_email, nullif(btrim(coalesce(p ->> 'phone', '')), ''))
  on conflict (lower(email)) where email is not null do update set phone = coalesce(people.phone, excluded.phone) returning id into v_person;

  begin
    insert into applications (vacancy_id, person_id, status, cover_letter, cv_ref, source_page, submitted_at, status_changed_at, status_reason, details)
    values (v_vac, v_person, v_status, nullif(p ->> 'cover_letter', ''), nullif(p ->> 'cv_ref', ''), '(imported)',
            coalesce((p ->> 'submitted_at')::timestamptz, now()), coalesce((p ->> 'updated_at')::timestamptz, (p ->> 'submitted_at')::timestamptz, now()),
            case when v_status = 'submitted' then null else 'imported from the previous website' end, coalesce(p -> 'details', '{}'::jsonb))
    returning id, ada_id into v_app, v_ada;
  exception when unique_violation then
    return jsonb_build_object('result', 'skipped', 'reason', 'this person already has an application for that vacancy');
  end;
  insert into application_status_history (application_id, from_status, to_status, reason, changed_at)
  values (v_app, null, v_status, 'imported from the previous website', coalesce((p ->> 'submitted_at')::timestamptz, now()));
  insert into legacy_imports (source, source_id, entity_type, entity_id) values ('career_applications', p ->> 'legacy_id', 'application', v_app);
  return jsonb_build_object('result', 'created', 'id', v_ada);
end $$;

revoke execute on function import_vacancy(jsonb), import_application(jsonb) from public, anon, authenticated;
