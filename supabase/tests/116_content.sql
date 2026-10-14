-- PERMANENT: the Content section - a post is a registered entity, written as a draft by the division that owns it, published only through content_transition by someone
-- who may publish, audited, searchable by title, and read by the websites ONLY when published (and only its public fields). Plus the careers fields (vacancy
-- slug / location / responsibilities ...) and the applicant's profile answers.
begin;
select tests.setup();
select tests.setup_hr();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
update websites set capabilities = capabilities || array['content.read'] where domain = (select domain from websites where id = (select id from tests.ids where key = 'site:main'));

select tests.check('the content permissions: the CEO publishes; administration, division leads and staff write; the auditor reads',
  (select string_agg(p.key || '=' || (select string_agg(r.key, '+' order by r.key) from role_permissions rp join roles r on r.id = rp.role_id where rp.permission_id = p.id), ' ; ' order by p.key) from permissions p where p.module = 'content'),
  'content.archive=administration_officer+ceo+division_lead ; content.create=administration_officer+ceo+division_lead+division_staff ; content.publish=ceo ; content.update=administration_officer+ceo+division_lead+division_staff ; content.view=administration_officer+auditor+ceo+division_lead+division_staff');

-- Writing ---------------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('p1', tests.scalar('web_staff', format($q$ insert into content_posts (kind, slug, title, excerpt, body, division_id, tags, cover_path)
  values ('journal', 'zeta-launch', 'Zeta website launched', 'We launched the Zeta site.', '[{"id":"b1","type":"paragraph","text":"Secret body words."}]', %L, array['launch','web'], '/portraits/x.webp') returning id::text $q$, tests.id('div:web'))));
select tests.check('division staff write a draft for their own division', (select concat_ws('|', status::text, kind, (author_staff_id = tests.id('staff:web_staff'))::text) from content_posts where id = tests.id('p1')), 'draft|journal|true');
select tests.check('the post is a registered entity with a permanent 9-character institutional ID',
  (select concat_ws('|', r.entity_type, r.entity_family, length(r.institutional_id)::text, (r.institutional_id ~ '^T7[0-9A-HJKMNP-TV-Z]{7}$')::text) from entity_registry r where r.table_name = 'content_posts' and r.entity_id = tests.id('p1')), 'post|operations|9|true');
select tests.check('the author cannot be forged on creation', tests.scalar('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, author_staff_id) values ('news', 'forged-author', 'Forged', %L, %L) returning (author_staff_id = %L)::text $q$, tests.id('div:web'), tests.id('staff:ceo'), tests.id('staff:web_staff'))), 'true');
select tests.check('a post cannot be created already published or approved', concat_ws(',', tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, status) values ('news', 'sneaky-pub', 'Sneaky', %L, 'published') $q$, tests.id('div:web'))),
  tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, approved_by) values ('news', 'sneaky-appr', 'Sneaky', %L, %L) $q$, tests.id('div:web'), tests.id('staff:ceo')))), 'ERR:42501,ERR:42501');
select tests.check('another division cannot write in it, and cannot see its drafts', concat_ws(',', tests.try('tech_staff', format($q$ insert into content_posts (kind, slug, title, division_id) values ('news', 'tech-in-web', 'x y', %L) $q$, tests.id('div:web'))),
  tests.scalar('tech_staff', format('select count(*)::text from content_posts where id = %L', tests.id('p1')))), 'ERR:42501,0');
select tests.check('the same division lead, the CEO, administration and the auditor see the draft; recruiter, outsider and suspended do not',
  concat_ws(',', tests.scalar('web_lead', format('select count(*)::text from content_posts where id = %L', tests.id('p1'))), tests.scalar('ceo', format('select count(*)::text from content_posts where id = %L', tests.id('p1'))),
    tests.scalar('admin', format('select count(*)::text from content_posts where id = %L', tests.id('p1'))), tests.scalar('audit', format('select count(*)::text from content_posts where id = %L', tests.id('p1'))),
    tests.scalar('recruiter', format('select count(*)::text from content_posts where id = %L', tests.id('p1'))), tests.scalar('outsider', format('select count(*)::text from content_posts where id = %L', tests.id('p1'))),
    tests.scalar('suspended', format('select count(*)::text from content_posts where id = %L', tests.id('p1')))), '1,1,1,1,0,0,0');
select tests.check('the anonymous role has no access at all', tests.scalar_anon('select count(*)::text from content_posts') || ',' || tests.scalar_anon('select content_transition(gen_random_uuid(), ''published'')::text'), 'ERR:42501,ERR:42501');
select tests.check('bad input is refused: a slug with spaces, a body that is not a list, a javascript cover, an ftp link, an empty title, 21 tags',
  concat_ws(',', tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id) values ('news', 'Bad Slug', 'ok title', %L) $q$, tests.id('div:web'))),
    tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, body) values ('news', 'body-bad', 'ok title', %L, '{"a":1}') $q$, tests.id('div:web'))),
    tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, cover_path) values ('news', 'cover-bad', 'ok title', %L, 'javascript:alert(1)') $q$, tests.id('div:web'))),
    tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, external_url) values ('news', 'url-bad', 'ok title', %L, 'ftp://x.example/a') $q$, tests.id('div:web'))),
    tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id) values ('news', 'title-bad', ' ', %L) $q$, tests.id('div:web'))),
    tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id, tags) values ('news', 'tags-bad', 'ok title', %L, (select array_agg('t' || g) from generate_series(1, 21) g)) $q$, tests.id('div:web')))),
  'ERR:23514,ERR:23514,ERR:23514,ERR:23514,ERR:23514,ERR:23514');
select tests.check('a web address is unique among live posts', tests.try('web_lead', format($q$ insert into content_posts (kind, slug, title, division_id) values ('news', 'zeta-launch', 'Another one', %L) $q$, tests.id('div:web'))), 'ERR:23505');
select tests.check('nobody can delete a post', concat_ws(',', tests.try('ceo', format('delete from content_posts where id = %L', tests.id('p1'))), tests.try('web_staff', format('delete from content_posts where id = %L', tests.id('p1')))), 'ERR:42501,ERR:42501');

-- Status only through content_transition ------------------------------------------------------------------------------------------------------------------
select tests.check('status cannot be edited directly, not even by the CEO', concat_ws(',', tests.try('web_staff', format($q$ update content_posts set status = 'published' where id = %L $q$, tests.id('p1'))), tests.try('ceo', format($q$ update content_posts set status = 'published' where id = %L $q$, tests.id('p1')))), 'ERR:42501,ERR:42501');
select tests.remember('p2', tests.scalar('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id) values ('news', 'empty-one', 'Nothing in it', %L) returning id::text $q$, tests.id('div:web'))));
select tests.check('submitting needs an excerpt and some content', tests.scalar('web_staff', format($q$ select content_transition(%L, 'pending_approval')::text $q$, tests.id('p2'))), 'ERR:23514');
select tests.scalar('web_staff', format($q$ select content_transition(%L, 'pending_approval')::text $q$, tests.id('p1')));
select tests.check('the author submits for approval; the approval request is recorded and the CEO is notified', concat_ws('|', (select status::text from content_posts where id = tests.id('p1')),
  (select count(*)::text from approval_requests where entity_table = 'content_posts' and entity_id = tests.id('p1') and kind = 'content_publication' and status = 'pending'),
  (select count(*)::text from notifications n where n.entity_id = tests.id('p1') and n.type = 'approval.required')), 'pending_approval|1|1');
select tests.check('neither the author, nor the division lead, nor administration may approve or publish', concat_ws(',', tests.scalar('web_staff', format($q$ select content_transition(%L, 'approved')::text $q$, tests.id('p1'))),
  tests.scalar('web_lead', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('p1'))), tests.scalar('admin', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('p1')))), 'ERR:42501,ERR:42501,ERR:42501');
select tests.check('a post that someone cannot see answers "not found", exactly like a made-up id', tests.scalar('tech_staff', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('p1'))) || '|' || tests.scalar('tech_staff', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('x:random'))), 'ERR:P0002|ERR:P0002');
select tests.check('the CEO approves', tests.scalar('ceo', format($q$ select content_transition(%L, 'approved')::text $q$, tests.id('p1'))), 'approved');
select tests.check('... then publishes', tests.scalar('ceo', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('p1'))), 'published');
select tests.check('the dates are set and the approval is on the record',
  concat_ws('|', (select (published_at is not null and display_date is not null and approved_by = tests.id('staff:ceo'))::text from content_posts where id = tests.id('p1')),
    (select status::text from approval_requests where entity_table = 'content_posts' and entity_id = tests.id('p1') order by requested_at desc limit 1)), 'true|approved');
select tests.check('publishing emitted exactly one post.published event', (select count(*)::text from events where event_type = 'post.published' and entity_id = tests.id('p1')), '1');
select tests.check('the web address cannot change while a post is published', tests.try('ceo', format($q$ update content_posts set slug = 'changed-address' where id = %L $q$, tests.id('p1'))), 'ERR:23514');
select tests.check('when its author edits a published post it goes back to draft (and leaves the website)', tests.try('web_staff', format($q$ update content_posts set title = 'Zeta website launched (edited)' where id = %L $q$, tests.id('p1'))), 'ok');
select tests.check('... with the reason recorded', (select status::text || ':' || coalesce(status_reason, '') from content_posts where id = tests.id('p1')), 'draft:edited after approval; needs re-approval');
select tests.check('the CEO publishes it again', tests.scalar('ceo', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('p1'))), 'published');
select tests.check('when the CEO edits it, it stays published', tests.try('ceo', format($q$ update content_posts set excerpt = 'We launched the Zeta site today.', title = 'Zeta website launched' where id = %L $q$, tests.id('p1'))), 'ok');
select tests.check('... still published', (select status::text from content_posts where id = tests.id('p1')), 'published');

-- What the websites get ------------------------------------------------------------------------------------------------------------------------------------
select tests.check('a website without the content capability gets nothing', tests.pub('limited', 'posts'), 'ERR:42501');
select tests.check('with the capability: exactly the published post, with only its public fields',
  concat_ws('|', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'posts')::jsonb)),
    (select string_agg(k, ',' order by k) from jsonb_object_keys((tests.pub('main', 'posts')::jsonb) -> 0) k)),
  '1|body,cover,division,excerpt,featured,kind,published_at,slug,tags,title');
select tests.check('no author, status, internal ID, approval or draft field ever appears', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'posts')::jsonb) x where x ? 'author_staff_id' or x ? 'status' or x ? 'id' or x ? 'approved_by' or x ? 'status_reason'), '0');
select tests.check('one post by its web address; an unknown address and a draft both answer null', concat_ws('|', (tests.pub('main', 'post', quote_literal('zeta-launch'))::jsonb ->> 'title'), coalesce(tests.pub('main', 'post', quote_literal('nope-nothing')), '-'),
  coalesce(tests.pub('main', 'post', quote_literal('empty-one')), '-')), 'Zeta website launched|-|-');
select tests.check('kind and limit filters work', concat_ws('|', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'posts', quote_literal('news'))::jsonb)), (select count(*)::text from jsonb_array_elements(tests.pub('main', 'posts', quote_literal('journal'))::jsonb))), '0|1');
select tests.remember('pf', tests.scalar('ceo', format($q$ insert into content_posts (kind, slug, title, excerpt, body, division_id) values ('news', 'finance-note', 'Finance note', 'Internal', '[{"id":"1","type":"paragraph","text":"x"}]', %L) returning id::text $q$, tests.id('div:finance'))));
select tests.scalar('ceo', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('pf')));
select tests.check('... even when it is published (the division is not public)', (select count(*)::text from jsonb_array_elements(tests.pub('main', 'posts')::jsonb)), '1');
select tests.remember('pa', tests.scalar('ceo', $q$ insert into content_posts (kind, slug, title, excerpt, body) values ('announcement', 'agency-news', 'Agency news', 'For everyone', '[{"id":"1","type":"paragraph","text":"hello"}]') returning id::text $q$));
select tests.scalar('ceo', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('pa')));
select tests.check('an agency-wide post (no division) appears on the website without a division', concat_ws('|', (tests.pub('main', 'post', quote_literal('agency-news'))::jsonb ->> 'title'), (not ((tests.pub('main', 'post', quote_literal('agency-news'))::jsonb) ? 'division'))::text), 'Agency news|true');
select tests.check('the public functions are not reachable by signed-in staff or by anonymous callers', concat_ws(',', tests.try('ceo', $q$ select public_api.posts('x')::text $q$), tests.scalar_anon($q$ select public_api.posts('x')::text $q$)), 'ERR:42501,ERR:42501');
select tests.check('unpublishing removes it from the website at once, with an event', concat_ws('|', tests.scalar('ceo', format($q$ select content_transition(%L, 'unpublished')::text $q$, tests.id('p1'))),
  (select count(*)::text from jsonb_array_elements(tests.pub('main', 'posts')::jsonb) x where x ->> 'slug' = 'zeta-launch'), (select count(*)::text from events where event_type = 'post.unpublished' and entity_id = tests.id('p1'))), 'unpublished|0|1');
select tests.check('an archived post cannot come back; its address can be reused', concat_ws('|', tests.scalar('ceo', format($q$ select content_transition(%L, 'archived')::text $q$, tests.id('p1'))),
  tests.scalar('ceo', format($q$ select content_transition(%L, 'published')::text $q$, tests.id('p1'))),
  tests.try('web_staff', format($q$ insert into content_posts (kind, slug, title, division_id) values ('news', 'zeta-launch', 'Reused address', %L) $q$, tests.id('div:web')))), 'archived|ERR:23514|ok');

-- Search and audit -----------------------------------------------------------------------------------------------------------------------------------------
select tests.check('posts are found by title, never by what is in the body', concat_ws('|', tests.scalar('ceo', $q$ select (search('agency news')->>'total') $q$), tests.scalar('ceo', $q$ select (search('secret body words')->>'total') $q$)), '1|0');
select tests.check('another division does not find a draft or a post of a division it cannot read', tests.scalar('tech_staff', $q$ select (search('Reused address')->>'total') $q$), '0');
select tests.check('creating and publishing are in the audit trail', ((select count(*) from audit_log where table_name = 'content_posts' and action = 'INSERT') > 0 and (select count(*) from audit_log where table_name = 'content_posts' and action = 'UPDATE') > 0)::text, 'true');

-- Careers fields -------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('vac:c', tests.scalar('web_lead', $q$ insert into vacancies (position_id, title, summary, description, requirements, closing_date, slug, location, responsibilities, qualifications, experience, application_instructions, featured)
  select id, 'Web Developer II', 'Join ADA Web', 'Build great sites', 'TypeScript', current_date + 30, 'web-developer-ii', 'Rundu, Namibia', 'Ship client sites', 'Degree in IT', '2 years', 'Apply with your CV', true from positions where title = 'Web Developer' returning id::text $q$));
select tests.check('a vacancy keeps the website''s careers fields', (select concat_ws('|', slug, location, responsibilities, qualifications, experience, application_instructions, featured::text) from vacancies where id = tests.id('vac:c')),
  'web-developer-ii|Rundu, Namibia|Ship client sites|Degree in IT|2 years|Apply with your CV|true');
select tests.check('a vacancy web address is unique', tests.try('web_lead', format($q$ insert into vacancies (position_id, title, summary, description, slug) select id, 'Other', 's', 'd', 'web-developer-ii' from positions where title = 'Web Developer' $q$)), 'ERR:23505');
select tests.scalar('web_lead', format($q$ select vacancy_transition(%L, 'pending_approval')::text $q$, tests.id('vac:c')));
select tests.scalar('ceo', format($q$ select vacancy_transition(%L, 'approved')::text $q$, tests.id('vac:c')));
select tests.scalar('ceo', format($q$ select vacancy_transition(%L, 'published')::text $q$, tests.id('vac:c')));
select tests.check('the public vacancy carries the new fields', (select (x ->> 'slug') || '|' || (x ->> 'location') || '|' || (x ->> 'responsibilities') || '|' || (x ->> 'featured') from jsonb_array_elements(tests.pub('main', 'vacancies')::jsonb) x where x ->> 'title' = 'Web Developer II'), 'web-developer-ii|Rundu, Namibia|Ship client sites|true');
select tests.check('the new fields are frozen once the vacancy leaves draft, like the rest of its content', tests.try('web_lead', format($q$ update vacancies set responsibilities = 'changed' where id = %L $q$, tests.id('vac:c'))), 'ERR:42501');

-- The applicant's own answers --------------------------------------------------------------------------------------------------------------------------------
create temp table appref as select (tests.pub('main', 'submit_application', format('%L, %L, %L', (select ada_id from vacancies where id = tests.id('vac:c')), 'Ann Second', 'ann@example.com'))::jsonb ->> 'reference') as ref;
select tests.check('the website sends the applicant''s answers right after the application',
  tests.pub('main', 'submit_application_profile', format($q$%L, '{"application_type":"internship","nationality":"namibian","highest_qualification":"degree","institution":"UNAM","completion_year":2026,"skills":"TypeScript","github_url":"https://github.com/ann","motivation":"I love building."}'::jsonb$q$, (select ref from appref)))::jsonb ->> 'reference', (select ref from appref));
select tests.check('they are stored once, as a child of the application, and not editable again', concat_ws('|',
  (select count(*)::text from application_profiles where application_id = (select id from applications where ada_id = (select ref from appref))),
  tests.pub('main', 'submit_application_profile', format($q$%L, '{"skills":"again"}'::jsonb$q$, (select ref from appref)))), '1|ERR:P0002');
select tests.check('a website without the capability, an unknown application and an unknown key are all refused', concat_ws('|',
  tests.pub('tech', 'submit_application_profile', format($q$%L, '{"skills":"x"}'::jsonb$q$, (select ref from appref))), tests.pub('main', 'submit_application_profile', format($q$%L, '{"skills":"x"}'::jsonb$q$, 'ADA-APP-1999-0001')),
  tests.scalar_pub(format($q$ select public_api.submit_application_profile('bad-key', %L, '{}'::jsonb)::text $q$, (select ref from appref)))), 'ERR:42501|ERR:P0002|ERR:42501');
select tests.check('unknown fields and bad values are refused', concat_ws('|', tests.pub('main', 'submit_application_profile', format($q$%L, '{"salary":"1"}'::jsonb$q$, 'x')), tests.pub('main', 'submit_application_profile', format($q$%L, '[1]'::jsonb$q$, 'x'))), 'ERR:22023|ERR:22023');
select tests.check('those who may read the application read the answers; others cannot', concat_ws(',', tests.scalar('ceo', 'select count(*)::text from application_profiles'), tests.scalar('web_lead', 'select count(*)::text from application_profiles'),
  tests.scalar('tech_staff', 'select count(*)::text from application_profiles'), tests.scalar('outsider', 'select count(*)::text from application_profiles'), tests.scalar_anon('select count(*)::text from application_profiles')), '1,1,0,0,ERR:42501');
select tests.check('personal answers are redacted in the audit trail', (select count(*)::text from audit_log where table_name = 'application_profiles' and (new_data::text like '%I love building%' or new_data::text like '%namibian%')), '0');
select tests.finish();
rollback;
