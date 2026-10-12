-- PERMANENT: Website content - news/announcements/updates, testimonials, FAQs and site settings: creation as draft, the publication workflow and its permissions,
-- re-approval when public wording changes, testimonial consent, settings validation, explicit public DTOs, capabilities, events and audit.
begin;
select tests.setup();
select tests.setup_hr();
insert into tests.ids values ('x:random', gen_random_uuid());
update websites set capabilities = capabilities || array['content.read', 'settings.read'] where domain = 'main.ada.test';
create table tests.outs (k text primary key, v text);
create function tests.o(p_key text, p_val text) returns void language sql as $$ insert into tests.outs values (p_key, p_val) on conflict (k) do update set v = excluded.v $$;
create function tests.g(p_key text) returns text language sql stable as $$ select v from tests.outs where k = p_key $$;
create function tests.ct(p_user text, p_id text, p_kind text, p_to text, p_note text default null) returns text language sql as $$
  select tests.scalar(p_user, format($q$ select content_transition(%L, %L, %L, %L)::text $q$, p_kind, p_id, p_to, p_note))
$$;
create function tests.api_titles(p_fn text, p_extra text default '') returns text language sql as $$
  select coalesce((select string_agg(coalesce(e ->> 'title', e ->> 'person_name', e ->> 'question', e ->> 'key'), ',' order by ord) from jsonb_array_elements(tests.pub('main', p_fn, p_extra)::jsonb) with ordinality t(e, ord)), 'none')
$$;

-- 1. Creating --------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('post:a', tests.scalar('web_lead', format($q$ insert into content_posts (division_id, content_type, title, summary, body) values (%L, 'news', 'New Website Prices!', 'We have new prices', 'Full text') returning id::text $q$, tests.id('div:web'))));
select tests.remember('post:b', tests.scalar('web_lead', format($q$ insert into content_posts (division_id, title, summary) values (%L, 'New Website Prices!', 'Same title again') returning id::text $q$, tests.id('div:web'))));
select tests.check('1. a division lead creates a post as a draft: ADA-NWS id, an address made from the title, and the same title gets a different address',
  (select string_agg(ada_id ~ '^ADA-NWS-2026-' || ' ' || status::text || ' ' || slug, ' | ' order by created_at, slug) from content_posts where id in (tests.id('post:a'), tests.id('post:b'))), 'true draft new-website-prices | true draft new-website-prices-2');
select tests.check('2. who may create: not division staff, not another division''s lead, not suspended staff or an outsider; an agency-wide post needs an organization-wide role',
  tests.scalar('web_staff', format($q$ insert into content_posts (division_id, title, summary) values (%L, 'x', 'x') returning id::text $q$, tests.id('div:web'))) ||
  tests.scalar('tech_lead', format($q$ insert into content_posts (division_id, title, summary) values (%L, 'x', 'x') returning id::text $q$, tests.id('div:web'))) ||
  tests.scalar('suspended', $q$ insert into content_posts (title, summary) values ('x', 'x') returning id::text $q$) ||
  tests.scalar('outsider', $q$ insert into content_posts (title, summary) values ('x', 'x') returning id::text $q$) || '|' ||
  tests.scalar('web_lead', $q$ insert into content_posts (title, summary) values ('Agency news', 'x') returning id::text $q$) || '|' ||
  (tests.scalar('admin', $q$ insert into content_posts (title, summary) values ('Agency news', 'x') returning status::text $q$)),
  'ERR:42501ERR:42501ERR:42501ERR:42501|ERR:42501|draft');
select tests.check('3. content cannot be created as published, and status cannot be changed by a plain update',
  tests.scalar('web_lead', format($q$ insert into content_posts (division_id, title, summary, status) values (%L, 'y', 'y', 'published') returning id::text $q$, tests.id('div:web'))) ||
  tests.try('web_lead', format($q$ update content_posts set status = 'published' where id = %L $q$, tests.id('post:a'))), 'ERR:42501ERR:42501');
select tests.check('4. a bad address or cover image is refused', tests.try('web_lead', format($q$ update content_posts set cover_image_url = 'http://insecure.example/x.png' where id = %L $q$, tests.id('post:a'))), 'ERR:23514');

-- 2. Workflow --------------------------------------------------------------------------------------------------------------------------------------------
select tests.o('s1', tests.ct('web_lead', tests.id('post:a')::text, 'post', 'pending_approval'));
select tests.check('5. submitting for approval opens an approval request that management sees', tests.g('s1') || '|' ||
  (select count(*)::text || min(kind) from approval_requests where entity_id = tests.id('post:a') and status = 'pending') || '|' || tests.scalar('ceo', $q$ select count(*)::text from approval_requests where kind = 'content_publication' $q$),
  'pending_approval|1content_publication|1');
select tests.check('6. the preparer cannot approve or publish (no content.publish); nothing is public yet',
  tests.ct('web_lead', tests.id('post:a')::text, 'post', 'approved') || tests.ct('admin', tests.id('post:a')::text, 'post', 'approved') || '|' || tests.api_titles('posts'), 'ERR:42501ERR:42501|none');
select tests.o('s2', tests.ct('ceo', tests.id('post:a')::text, 'post', 'approved') || '/' || tests.ct('ceo', tests.id('post:a')::text, 'post', 'published'));
select tests.check('7. management approves and publishes; the public API now returns the post with exactly the approved fields and no internal ones',
  tests.g('s2') || '|' || tests.api_titles('posts') || '|' ||
  (select string_agg(k, ',' order by k) from jsonb_object_keys((tests.pub('main', 'posts')::jsonb) -> 0) k), 'approved/published|New Website Prices!|content,division,featured,id,published_at,slug,summary,title,type');
select tests.check('8. the post is also fetched by its address; an unknown address is null; a site without content.read is refused',
  (tests.pub('main', 'post', quote_literal('new-website-prices'))::jsonb ->> 'title') || '|' || coalesce(tests.pub('main', 'post', quote_literal('nope')), 'null') || '|' || tests.pub('limited', 'posts'),
  'New Website Prices!|null|ERR:42501');
select tests.check('9. publishing emitted a content_post.published event with identifiers only',
  (select count(*)::text || bool_and(entity_ada_id ~ '^ADA-NWS-')::text from events where event_type = 'content_post.published'), '1true');
select tests.o('e1', tests.try('web_lead', format($q$ update content_posts set body = 'Changed text' where id = %L $q$, tests.id('post:a'))));
select tests.check('10. editing a published post returns it to draft (it leaves the website until approved again), and its address is frozen while approved',
  tests.g('e1') || '|' || (select status::text from content_posts where id = tests.id('post:a')) || '|' || tests.api_titles('posts') || '|' ||
  (select count(*)::text from events where event_type = 'content_post.unpublished'), 'ok|draft|none|1');
select tests.ct('web_lead', tests.id('post:a')::text, 'post', 'pending_approval'); select tests.ct('ceo', tests.id('post:a')::text, 'post', 'approved'); select tests.ct('ceo', tests.id('post:a')::text, 'post', 'published');
select tests.check('11. the address of an approved or published post cannot change', tests.try('web_lead', format($q$ update content_posts set slug = 'something-else' where id = %L $q$, tests.id('post:a'))), 'ERR:42501');
select tests.check('12. unpublish and archive need content.publish; an unpublished post disappears from the API',
  tests.ct('web_lead', tests.id('post:a')::text, 'post', 'unpublished') || '|' || tests.ct('ceo', tests.id('post:a')::text, 'post', 'unpublished', 'out of date') || '|' || tests.api_titles('posts'), 'ERR:42501|unpublished|none');
select tests.check('13. invalid moves are refused (a draft cannot be published directly) and an unknown record looks like a missing one',
  tests.ct('ceo', tests.id('post:b')::text, 'post', 'published') || tests.ct('ceo', tests.id('x:random')::text, 'post', 'approved') || tests.ct('ceo', tests.id('post:b')::text, 'nonsense', 'approved'), 'ERR:23514ERR:P0002ERR:22023');

-- 3. Division filter, featured order, type filter ------------------------------------------------------------------------------------------------------
select tests.remember('post:c', tests.scalar('admin', $q$ insert into content_posts (title, summary, content_type, featured) values ('Agency announcement', 'for everyone', 'announcement', true) returning id::text $q$));
select tests.remember('post:d', tests.scalar('web_lead', format($q$ insert into content_posts (division_id, title, summary) values (%L, 'Web update', 'web only') returning id::text $q$, tests.id('div:web'))));
select tests.remember('post:e', tests.scalar('admin', format($q$ insert into content_posts (division_id, title, summary) values (%L, 'Tech news', 'tech only') returning id::text $q$, tests.id('div:tech'))));
select tests.ct('ceo', tests.id('post:c')::text, 'post', 'pending_approval'); select tests.ct('ceo', tests.id('post:c')::text, 'post', 'approved'); select tests.ct('ceo', tests.id('post:c')::text, 'post', 'published');
select tests.ct('ceo', tests.id('post:d')::text, 'post', 'pending_approval'); select tests.ct('ceo', tests.id('post:d')::text, 'post', 'approved'); select tests.ct('ceo', tests.id('post:d')::text, 'post', 'published');
select tests.ct('ceo', tests.id('post:e')::text, 'post', 'pending_approval'); select tests.ct('ceo', tests.id('post:e')::text, 'post', 'approved'); select tests.ct('ceo', tests.id('post:e')::text, 'post', 'published');
select tests.check('14. the feed: featured first, agency-wide posts appear for every division, a division sees only its own plus agency-wide, and a type filter works',
  tests.api_titles('posts') || '|' || tests.api_titles('posts', quote_literal('news') || ', ' || quote_literal('web')) || '|' || tests.api_titles('posts', quote_literal('announcement')),
  'Agency announcement,Tech news,Web update|Web update|Agency announcement');
select tests.check('15. staff see the drafts of colleagues (so they can review), the suspended and outsiders see nothing',
  tests.scalar('web_staff', 'select count(*)::text from content_posts') || '/' || tests.scalar('suspended', 'select count(*)::text from content_posts') || '/' || tests.scalar('outsider', 'select count(*)::text from content_posts'), '6/0/0');

-- 4. Testimonials and FAQs ---------------------------------------------------------------------------------------------------------------------------------
select tests.remember('tst:a', tests.scalar('web_lead', format($q$ insert into testimonials (division_id, quote, person_name, person_role, organization_name, sort_order) values (%L, 'They fixed our site fast.', 'A. Customer', 'Owner', 'Rundu Lodge', 10) returning id::text $q$, tests.id('div:web'))));
select tests.ct('web_lead', tests.id('tst:a')::text, 'testimonial', 'pending_approval'); select tests.ct('ceo', tests.id('tst:a')::text, 'testimonial', 'approved');
select tests.check('16. a testimonial cannot be published without the person''s consent, and a consent needs a note saying how it was given',
  tests.ct('ceo', tests.id('tst:a')::text, 'testimonial', 'published') || tests.try('ceo', format($q$ update testimonials set consent_confirmed = true where id = %L $q$, tests.id('tst:a'))), 'ERR:23514ERR:23514');
select tests.try('ceo', format($q$ update testimonials set consent_confirmed = true, consent_note = 'Written consent by email, 3 Oct 2026' where id = %L $q$, tests.id('tst:a')));
select tests.check('17. recording consent is a content change, so approval is needed again; then it publishes and the API shows the quote without the consent note',
  (select status::text from testimonials where id = tests.id('tst:a')) || '|' ||
  (tests.ct('ceo', tests.id('tst:a')::text, 'testimonial', 'pending_approval') || '/' || tests.ct('ceo', tests.id('tst:a')::text, 'testimonial', 'approved') || '/' || tests.ct('ceo', tests.id('tst:a')::text, 'testimonial', 'published')) || '|' ||
  (select string_agg(k, ',' order by k) from jsonb_object_keys((tests.pub('main', 'testimonials')::jsonb) -> 0) k), 'draft|pending_approval/approved/published|division,id,organization_name,person_name,person_role,quote');
select tests.remember('faq:a', tests.scalar('web_lead', format($q$ insert into faqs (division_id, question, answer, sort_order) values (%L, 'Do you work outside Rundu?', 'Yes, remotely across Namibia.', 20) returning id::text $q$, tests.id('div:web'))));
select tests.remember('faq:b', tests.scalar('admin', $q$ insert into faqs (question, answer, sort_order) values ('Is VAT charged?', 'No, ADA is not VAT registered.', 10) returning id::text $q$));
select tests.ct('ceo', tests.id('faq:a')::text, 'faq', 'pending_approval'); select tests.ct('ceo', tests.id('faq:a')::text, 'faq', 'approved'); select tests.ct('ceo', tests.id('faq:a')::text, 'faq', 'published');
select tests.ct('ceo', tests.id('faq:b')::text, 'faq', 'pending_approval'); select tests.ct('ceo', tests.id('faq:b')::text, 'faq', 'approved'); select tests.ct('ceo', tests.id('faq:b')::text, 'faq', 'published');
select tests.check('18. FAQs come back in their set order, agency-wide ones for every division; a division filter without matches still returns the agency-wide ones',
  tests.api_titles('faqs') || '|' || tests.api_titles('faqs', quote_literal('tech')), 'Is VAT charged?,Do you work outside Rundu?|Is VAT charged?');

-- 5. Settings ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('19. the seeded facts: agency phone and place, each division''s email, and the marketing budget rule',
  (select count(*)::text from site_settings where key = 'company.phone' and value = '+264 81 803 2641') || '|' || (select count(*)::text from site_settings where key = 'division.email') || '|' ||
  (select string_agg(key || '=' || value, ',' order by key) from site_settings where key like 'marketing.%'),
  '1|4|marketing.ada_share_grow=35,marketing.ada_share_scale=30,marketing.ada_share_test=40,marketing.grow_from=5000,marketing.min_budget=1499.99,marketing.scale_from=15000');
select tests.try('web_lead', $q$ update site_settings set value = '+264 81 000 0000' where key = 'company.phone' $q$);
select tests.check('20. only settings.update changes a setting (a plain update by anyone else changes nothing); values are validated by type; a key and its division cannot change; a key is unique',
  (select value from site_settings where key = 'company.phone') || '|' ||
  tests.try('web_lead', $q$ insert into site_settings (key, label, value) values ('company.other', 'x', 'x') $q$) ||
  tests.try('ceo', $q$ update site_settings set value = 'not an email' where key = 'division.email' $q$) ||
  tests.try('ceo', $q$ update site_settings set value = 'abc' where key = 'marketing.min_budget' $q$) || tests.try('ceo', $q$ update site_settings set key = 'company.other' where key = 'company.phone' $q$) ||
  tests.try('ceo', $q$ insert into site_settings (key, label, value) values ('company.phone', 'again', '1') $q$), '+264 81 803 2641|ERR:42501ERR:23514ERR:23514ERR:42501ERR:23505');
select tests.try('ceo', $q$ update site_settings set value = '+264 81 803 9999' where key = 'company.phone' $q$);
select tests.try('ceo', $q$ insert into site_settings (key, label, value, is_public) values ('company.bank_note', 'Internal note', 'do not publish', false) $q$);
select tests.check('21. a changed setting is recorded (who, when), emits a settings.changed event, and the public API returns only public settings (agency-wide, plus the requested division''s)',
  (select (updated_by = tests.id('staff:ceo'))::text from site_settings where key = 'company.phone') || '|' || (select count(*)::text from events where event_type = 'settings.changed') || '|' ||
  (select count(*)::text from jsonb_array_elements(tests.pub('main', 'settings')::jsonb) e where e ->> 'key' = 'company.bank_note') || '|' ||
  (select string_agg(e ->> 'key', ',' order by e ->> 'key') from jsonb_array_elements(tests.pub('main', 'settings', quote_literal('marketing'))::jsonb) e where e ->> 'key' like 'marketing.%' and e ->> 'key' like '%share_%') || '|' ||
  (select count(*)::text from jsonb_array_elements(tests.pub('main', 'settings')::jsonb) e where e ->> 'key' like 'marketing.%') || '|' ||
  (select e ->> 'value' from jsonb_array_elements(tests.pub('main', 'settings')::jsonb) e where e ->> 'key' = 'company.phone'),
  'true|1|0|marketing.ada_share_grow,marketing.ada_share_scale,marketing.ada_share_test|0|+264 81 803 9999');
select tests.check('22. the settings feed needs its own capability',  tests.pub('tech', 'settings') || tests.pub('tech', 'posts'), 'ERR:42501ERR:42501');

-- 6. Audit ------------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('23. creating, approving, publishing and changing settings are audited with who did it',
  (select (count(*) filter (where table_name = 'content_posts' and action = 'INSERT') >= 5 and count(*) filter (where table_name = 'content_posts' and action = 'UPDATE') >= 8
           and count(*) filter (where table_name = 'site_settings' and action = 'UPDATE') >= 1 and count(*) filter (where table_name = 'testimonials') >= 3 and bool_and(actor_staff_id is not null))::text
     from audit_log where table_name in ('content_posts', 'testimonials', 'faqs', 'site_settings') and action in ('INSERT', 'UPDATE')), 'true');
select tests.finish();
rollback;
