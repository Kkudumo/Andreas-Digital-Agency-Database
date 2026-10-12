-- PERMANENT: the named project write operations (project_create, project_add_contact, project_add_division, project_add_member, task_create).
-- They are SECURITY INVOKER entry points over the same row-level-security policies and guard triggers as a direct insert, so the proof is: an authorised
-- caller succeeds; every refused caller is refused with exactly the code a direct insert gives; a hidden client or project answers exactly as an unknown one;
-- nothing new is granted; the audit trail is written.
begin;
select tests.setup();
select tests.setup_hr();
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.remember('c:wrap', tests.mkclient_id('web_lead', 'Wrap Co', 'web'));
select tests.remember('ct:wrap', tests.scalar('web_lead', format('select add_client_contact(%L, ''Wendy Wrap'', ''wendy@wrap.example'', null, ''Director'', true)::text', tests.id('c:wrap'))));
select tests.remember('c:other', tests.mkclient_id('tech_lead', 'Other Co', 'tech'));
select tests.remember('ct:other', tests.scalar('tech_lead', format('select add_client_contact(%L, ''Olga Other'', ''olga@other.example'')::text', tests.id('c:other'))));
select tests.try('web_lead', format('select claim_client_for_division(%L, %L)', tests.id('c:wrap'), tests.id('div:web')));

-- 1. an authorised caller creates a project
select tests.remember('p:wrap', tests.scalar('web_lead', format($q$ select project_create(%L, %L, '  Wrap Website  ', 'The site')::text $q$, tests.id('c:wrap'), tests.id('div:web'))));
select tests.check('1. project_create: a project of that client and lead division, name trimmed, status proposed, ADA id minted, no way to pass a status',
  (select (client_id = tests.id('c:wrap') and lead_division_id = tests.id('div:web') and name = 'Wrap Website' and status = 'proposed' and ada_id ~ '^ADA-PRJ-' and description = 'The site')::text from projects where id = tests.id('p:wrap')), 'true');
select tests.check('2. it is registered with a permanent institutional id', (select (count(*) = 1)::text from entity_registry where table_name = 'projects' and entity_id = tests.id('p:wrap')), 'true');

-- 2. refused callers are refused exactly as for a direct insert
create function tests.direct_project(p_user text, p_client uuid) returns text language sql as $$
  select tests.try(p_user, format($q$ insert into projects (client_id, lead_division_id, name) values (%L, %L, 'x') $q$, p_client, tests.id('div:web')))
$$;
create function tests.wrapped_project(p_user text, p_client uuid) returns text language sql as $$
  select tests.try(p_user, format($q$ select project_create(%L, %L, 'x') $q$, p_client, tests.id('div:web')))
$$;
select tests.check('3. for every caller (cleared or not) project_create and a direct insert give the SAME outcome',
  (select string_agg(u || ':' || (tests.wrapped_project(u, tests.id('c:wrap')) = tests.direct_project(u, tests.id('c:wrap')))::text, ',' order by u)
     from unnest(array['web_lead', 'ceo', 'web_staff', 'tech_lead', 'tech_staff', 'fin', 'audit', 'suspended', 'outsider']) u),
  'audit:true,ceo:true,fin:true,outsider:true,suspended:true,tech_lead:true,tech_staff:true,web_lead:true,web_staff:true');
select tests.check('4. the refusals are real refusals (another division, suspended staff and an outsider cannot create a Web project)',
  tests.wrapped_project('tech_lead', tests.id('c:wrap')) || tests.wrapped_project('suspended', tests.id('c:wrap')) || tests.wrapped_project('outsider', tests.id('c:wrap')), 'ERR:42501ERR:42501ERR:42501');
select tests.check('5. a hidden (confidential) client answers exactly as an id that never existed, for every uncleared caller',
  (select string_agg(tests.same_for(u, format($q$ select project_create(%%L, %L, 'x')::text $q$, tests.id('div:web')), tests.id('client:C_conf'), tests.id('x:random')), ',' order by u)
     from unnest(array['web_lead', 'web_staff', 'tech_lead', 'tech_staff', 'fin', 'suspended', 'outsider']) u),
  'same,same,same,same,same,same,same');
select tests.check('6. anonymous cannot call it at all', tests.scalar_anon(format($q$ select project_create(%L, %L, 'x')::text $q$, tests.id('c:wrap'), tests.id('div:web'))), 'ERR:42501');

-- 3. contacts, divisions, members, tasks
select tests.check('7. project_add_contact: the client''s own contact is added; another client''s contact is refused',
  tests.try('web_lead', format($q$ select project_add_contact(%L, %L, 'Sponsor') $q$, tests.id('p:wrap'), tests.id('ct:wrap'))) || tests.try('web_lead', format($q$ select project_add_contact(%L, %L) $q$, tests.id('p:wrap'), tests.id('ct:other'))), 'okERR:23514');
select tests.check('8. project_add_division needs organization-wide projects.update (management succeeds, the division lead is refused exactly like a direct insert); project_add_member works for the lead; a participating division (Tech, after management added it) may add members; refusals match direct inserts',
  tests.try('ceo', format($q$ select project_add_division(%L, %L) $q$, tests.id('p:wrap'), tests.id('div:tech'))) || '|' ||
  tests.try('web_lead', format($q$ select project_add_division(%L, %L) $q$, tests.id('p:wrap'), tests.id('div:management'))) || '=' || tests.try('web_lead', format($q$ insert into project_divisions (project_id, division_id) values (%L, %L) $q$, tests.id('p:wrap'), tests.id('div:management'))) || '|' ||
  tests.try('web_lead', format($q$ select project_add_member(%L, %L, 'developer') $q$, tests.id('p:wrap'), tests.id('staff:web_staff'))) || '|' ||
  tests.try('tech_lead', format($q$ select project_add_division(%L, %L) $q$, tests.id('p:wrap'), tests.id('div:management'))) || '=' || tests.try('tech_lead', format($q$ insert into project_divisions (project_id, division_id) values (%L, %L) $q$, tests.id('p:wrap'), tests.id('div:management'))) || '|' ||
  tests.try('suspended', format($q$ select project_add_member(%L, %L) $q$, tests.id('p:wrap'), tests.id('staff:tech_staff'))) || '=' || tests.try('suspended', format($q$ insert into project_members (project_id, staff_id) values (%L, %L) $q$, tests.id('p:wrap'), tests.id('staff:tech_staff'))) || '|' ||
  tests.try('tech_lead', format($q$ select project_add_member(%L, %L) $q$, tests.id('p:wrap'), tests.id('staff:tech_staff'))),
  'ok|ERR:42501=ERR:42501|ok|ERR:42501=ERR:42501|ERR:42501=ERR:42501|ok');
select tests.remember('t:wrap', tests.scalar('web_lead', format($q$ select task_create(%L, 'Wireframes', 'First draft', %L, current_date + 7)::text $q$, tests.id('p:wrap'), tests.id('staff:web_staff'))));
select tests.check('9. task_create: the task belongs to the project, is assigned, dated and has an ADA id',
  (select (project_id = tests.id('p:wrap') and title = 'Wireframes' and assignee_id = tests.id('staff:web_staff') and due_date = current_date + 7 and ada_id ~ '^ADA-TSK-')::text from tasks where id = tests.id('t:wrap')), 'true');
select tests.check('10. task_create for a project the caller cannot see answers as for an unknown project',
  (select string_agg(tests.same_for(u, $q$ select task_create(%L, 'x')::text $q$, tests.id('p:wrap'), tests.id('x:random')), ',' order by u) from unnest(array['suspended', 'outsider']) u), 'same,same');

-- 4. nothing new is granted, and the history is written
select tests.check('11. all five are SECURITY INVOKER (they run with the caller''s rights) and are not executable by anon',
  (select string_agg(p.proname || ':' || (not p.prosecdef)::text || ':' || (not has_function_privilege('anon', p.oid, 'execute'))::text, ',' order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname in ('project_create', 'project_add_contact', 'project_add_division', 'project_add_member', 'task_create')),
  'project_add_contact:true:true,project_add_division:true:true,project_add_member:true:true,project_create:true:true,task_create:true:true');
select tests.check('12. the audit trail records the project, the task and the links (written by the same triggers as a direct insert)',
  (select (count(*) filter (where table_name = 'projects') >= 1 and count(*) filter (where table_name = 'tasks') >= 1 and count(*) filter (where table_name in ('project_contacts', 'project_divisions', 'project_members')) >= 3)::text
     from audit_log where record_id = tests.id('p:wrap') or record_id = tests.id('t:wrap') or (new_data ->> 'project_id') = tests.id('p:wrap')::text), 'true');
select tests.check('13. the project cannot be pushed past the guard (status only through project_transition)', tests.try('web_lead', format($q$ update projects set status = 'active' where id = %L $q$, tests.id('p:wrap'))), 'ERR:42501');

select tests.finish();
rollback;
