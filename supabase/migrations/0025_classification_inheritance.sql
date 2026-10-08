-- 0025_classification_inheritance: a record that belongs to a restricted client is itself restricted.
-- Found by the existence-leakage suite: projects and leads of a restricted client were visible to division staff,
-- and their client_id column pointed at a client those people must not know exists.
--
-- Design: each dependent table carries effective_classification = the stricter of its own classification and its
-- client's. It is maintained by triggers, and visibility policies read ONLY the row's own columns. There is
-- deliberately no "is this client hidden from me?" helper: any such boolean would let a caller probe which ids are
-- restricted clients.

alter table projects  add column effective_classification data_classification not null default 'internal';
alter table leads     add column effective_classification data_classification not null default 'internal';
alter table enquiries add column effective_classification data_classification not null default 'internal';
comment on column projects.effective_classification  is 'Stricter of the project''s own classification and its client''s. Maintained by trigger; drives visibility.';
comment on column leads.effective_classification     is 'Inherited from the lead''s client (internal when none). Maintained by trigger; drives visibility.';
comment on column enquiries.effective_classification is 'Inherited from the enquiry''s client (internal when none). Maintained by trigger; drives visibility.';

create function projects_inherit_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.effective_classification := greatest(new.classification, coalesce((select classification from clients where id = new.client_id), 'internal'));
  return new;
end $$;
create trigger projects_inherit_trg before insert or update of client_id, classification on projects
  for each row execute function projects_inherit_classification();

create function client_linked_inherit_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.effective_classification := coalesce((select classification from clients where id = new.client_id), 'internal');
  return new;
end $$;
create trigger leads_inherit_trg before insert or update of client_id on leads
  for each row execute function client_linked_inherit_classification();
create trigger enquiries_inherit_trg before insert or update of client_id on enquiries
  for each row execute function client_linked_inherit_classification();

-- When a client is reclassified, everything that belongs to it follows.
create function clients_propagate_classification() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.classification is distinct from old.classification then
    update projects  set effective_classification = greatest(classification, new.classification) where client_id = new.id;
    update leads     set effective_classification = new.classification where client_id = new.id;
    update enquiries set effective_classification = new.classification where client_id = new.id;
  end if;
  return null;
end $$;
create trigger clients_propagate_classification_trg after update of classification on clients
  for each row execute function clients_propagate_classification();

-- Backfill existing rows.
update projects p  set effective_classification = greatest(p.classification, c.classification) from clients c where c.id = p.client_id;
update leads l     set effective_classification = c.classification from clients c where c.id = l.client_id;
update enquiries e set effective_classification = c.classification from clients c where c.id = e.client_id;

-- Visibility reads the row's own effective classification.
create function classification_visible(p_class data_classification) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select p_class in ('public', 'internal')
      or (p_class = 'restricted' and has_permission('records.view_restricted'))
      or (p_class = 'confidential' and has_permission('records.view_confidential'))
$$;
revoke execute on function classification_visible(data_classification) from public, anon;
grant execute on function classification_visible(data_classification) to authenticated;

drop policy projects_select on projects;
drop policy projects_update on projects;
create policy projects_select on projects for select to authenticated
  using (can_view_project_row(id, lead_division_id, effective_classification, deleted_at));
create policy projects_update on projects for update to authenticated
  using (can_edit_project_row(id, lead_division_id, effective_classification, deleted_at))
  with check (can_edit_project_row(id, lead_division_id, effective_classification, null));

create or replace function can_view_project(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_view_project_row(p.id, p.lead_division_id, p.effective_classification, p.deleted_at)
                   from projects p where p.id = p_id), false)
$$;
create or replace function can_edit_project(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select can_edit_project_row(p.id, p.lead_division_id, p.effective_classification, p.deleted_at)
                   from projects p where p.id = p_id), false)
$$;

drop policy leads_select on leads;
drop policy leads_update on leads;
drop policy enquiries_select on enquiries;
create policy leads_select on leads for select to authenticated
  using (has_permission('leads.view', division_id) and classification_visible(effective_classification));
create policy leads_update on leads for update to authenticated
  using (has_permission('leads.update', division_id) and classification_visible(effective_classification))
  with check (has_permission('leads.update', division_id) and classification_visible(effective_classification));
create policy enquiries_select on enquiries for select to authenticated
  using (has_permission('leads.view', division_id) and classification_visible(effective_classification));

-- A person is not visible through a lead the viewer cannot see.
create or replace function can_view_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from staff s where s.person_id = p_id and has_permission('hr.view'))
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.view', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_view_client(cc.client_id))
      or exists (select 1 from leads l where l.person_id = p_id and has_permission('leads.view', l.division_id) and classification_visible(l.effective_classification))
$$;
create or replace function can_edit_person(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from staff s where s.person_id = p_id and has_permission('hr.update'))
      or exists (select 1 from applications a join vacancies v on v.id = a.vacancy_id
                 where a.person_id = p_id and has_permission('applications.review', v.division_id))
      or exists (select 1 from client_contacts cc where cc.person_id = p_id and can_edit_client(cc.client_id))
      or exists (select 1 from leads l where l.person_id = p_id and has_permission('leads.update', l.division_id) and classification_visible(l.effective_classification))
$$;
