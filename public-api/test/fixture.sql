-- Owner-level fixture for the public API integration test (scripts/test-db.sh): two registered websites with known keys, and two published services.
-- Keys here are test-only strings; only their SHA-256 hashes are stored, exactly as in production.
insert into websites (name, domain, environment, status, capabilities, api_key_hash, api_key_prefix) values
  ('Integration Site', 'integration.ada.test', 'production', 'active',
     array['divisions.read', 'services.read', 'vacancies.read', 'team.read', 'statistics.read', 'applications.submit', 'enquiries.submit', 'portfolio.read', 'documents.read', 'content.read', 'settings.read'],
     encode(extensions.digest('itest-full-key-0001', 'sha256'), 'hex'), 'itest-fu'),
  ('Limited Integration Site', 'limited-integration.ada.test', 'production', 'active', array['divisions.read'], encode(extensions.digest('itest-limited-key-0002', 'sha256'), 'hex'), 'itest-li');
update services set status = 'published', published_at = now()
 where status_reason = 'initial catalogue load' and name in ('Business Check-up', 'Business website', 'CCTV installation');

-- one published post, one draft post, one published FAQ, one internal setting (owner-level inserts stand in for the Hub's workflow)
insert into content_posts (title, summary, body, status, published_at) values
  ('Integration news', 'A published post', 'Body', 'published', now()), ('Integration draft', 'Not public', 'Body', 'draft', null);
insert into faqs (question, answer, status, published_at) values ('Integration question?', 'An answer.', 'published', now()), ('Hidden question?', 'Draft.', 'draft', null);
insert into site_settings (key, label, value, is_public) values ('integration.internal_note', 'Internal', 'secret', false);
