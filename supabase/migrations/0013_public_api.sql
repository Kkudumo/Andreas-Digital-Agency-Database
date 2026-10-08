-- 0013_public_api: the ONLY surface websites may use. A dedicated login role (ada_public_api) has no table
-- access whatsoever; it can execute the fixed set of functions below, each of which authenticates the calling
-- website by API-key hash, checks its capability, and returns an explicitly constructed JSON DTO of approved,
-- published data. Nothing here reads a table on behalf of the caller beyond those DTOs.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'ada_public_api') then
    create role ada_public_api nologin;      -- ops grants LOGIN + password outside migrations
  end if;
end $$;

create schema public_api;
alter default privileges in schema public_api revoke execute on functions from public;
grant usage on schema public_api to ada_public_api;

create function public_api.authorize(p_key_hash text, p_capability text) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare w websites;
begin
  w := site_from_key_hash(p_key_hash);
  if w.id is null or not (p_capability = any (w.capabilities)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return w.id;
end $$;

create function public_api.divisions(p_key_hash text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'divisions.read');
  return coalesce((select jsonb_agg(jsonb_build_object('code', d.key, 'name', d.name, 'description', d.public_description) order by d.sort_order)
                   from divisions d where d.public_state = 'published' and d.is_active), '[]'::jsonb);
end $$;

create function public_api.vacancies(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'vacancies.read');
  return coalesce((
    select jsonb_agg(public_api.vacancy_dto(v.id) order by v.published_at desc)
    from vacancies v join divisions d on d.id = v.division_id
    where v.status = 'published' and v.deleted_at is null and (v.closing_date is null or v.closing_date >= current_date)
      and (p_division is null or d.key = p_division)), '[]'::jsonb);
end $$;

create function public_api.vacancy_dto(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', v.ada_id, 'title', v.title, 'summary', v.summary, 'description', v.description, 'requirements', v.requirements,
    'employment_type', v.employment_type, 'closing_date', v.closing_date, 'published_at', v.published_at,
    'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end,
    'salary', case when v.salary_public then jsonb_build_object('min', v.salary_min, 'max', v.salary_max, 'currency', v.salary_currency) end))
  from vacancies v join divisions d on d.id = v.division_id where v.id = p_id
$$;

create function public_api.vacancy(p_key_hash text, p_ada_id text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'vacancies.read');
  return (select public_api.vacancy_dto(v.id) from vacancies v
          where v.ada_id = p_ada_id and v.status = 'published' and v.deleted_at is null
            and (v.closing_date is null or v.closing_date >= current_date));
end $$;

create function public_api.team(p_key_hash text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'team.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'id', p.ada_id, 'name', p.public_name, 'title', p.public_title, 'bio', p.bio, 'photo', p.photo_ref, 'email', p.public_email,
             'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end))
           order by d.sort_order nulls last, p.public_name)
    from staff_profiles p
    join staff s on s.id = p.staff_id
    left join divisions d on d.id = s.primary_division_id
    where p.status = 'published' and s.deleted_at is null and s.employment_status in ('active', 'on_leave', 'contractor')), '[]'::jsonb);
end $$;

-- Statistics are derived from live records, never typed in.
create function public_api.statistics(p_key_hash text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'statistics.read');
  return jsonb_build_object(
    'staff', (select count(*) from staff where deleted_at is null and employment_status in ('active', 'on_leave', 'contractor')),
    'team_members', (select count(*) from staff_profiles p join staff s on s.id = p.staff_id
                      where p.status = 'published' and s.deleted_at is null and s.employment_status in ('active', 'on_leave', 'contractor')),
    'open_vacancies', (select count(*) from vacancies where status = 'published' and deleted_at is null and (closing_date is null or closing_date >= current_date)),
    'divisions', (select count(*) from divisions where public_state = 'published' and is_active));
end $$;

-- Incoming application from a connected website. Source website is taken from the API identity, not from the request.
create function public_api.submit_application(p_key_hash text, p_vacancy_id text, p_name text, p_email text, p_phone text default null,
                                              p_cover text default null, p_source_page text default null, p_referrer text default null,
                                              p_utm jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_site uuid := public_api.authorize(p_key_hash, 'applications.submit');
begin
  return jsonb_build_object('reference', create_application_internal(
    p_vacancy_id, p_name, p_email, p_phone, p_cover, null, v_site,
    left(p_source_page, 500), left(p_referrer, 500),
    left(p_utm ->> 'utm_source', 200), left(p_utm ->> 'utm_medium', 200), left(p_utm ->> 'utm_campaign', 200),
    left(p_utm ->> 'utm_term', 200), left(p_utm ->> 'utm_content', 200)));
end $$;

-- Only the entry-point functions are callable; helpers stay private.
revoke all on all functions in schema public_api from public, anon, authenticated;
grant execute on function public_api.divisions(text), public_api.vacancies(text, text), public_api.vacancy(text, text),
  public_api.team(text), public_api.statistics(text),
  public_api.submit_application(text, text, text, text, text, text, text, text, jsonb) to ada_public_api;
