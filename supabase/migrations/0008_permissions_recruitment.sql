-- 0008_permissions_recruitment: permissions and the Recruiter role for recruitment, onboarding,
-- public profiles and the website registry. Generated from the matrix CSV diff (scripts/build-rbac-delta.mjs).

insert into roles (key, name, description, is_system) values
  ('recruiter', 'Recruiter', 'Handles vacancies and applications; no access to finance or other HR data.', true);

insert into permissions (key, module, action, description, sensitivity) values
  ('positions.manage', 'positions', 'manage', 'Create and edit positions and headcount', 'restricted'::data_classification),
  ('vacancies.view', 'vacancies', 'view', 'View vacancies including drafts', 'internal'::data_classification),
  ('vacancies.create', 'vacancies', 'create', 'Create draft vacancies', 'internal'::data_classification),
  ('vacancies.update', 'vacancies', 'update', 'Edit vacancies and submit them for approval', 'internal'::data_classification),
  ('vacancies.publish', 'vacancies', 'publish', 'Approve, publish, unpublish and close vacancies', 'restricted'::data_classification),
  ('applications.view', 'applications', 'view', 'View applications and applicant details', 'confidential'::data_classification),
  ('applications.review', 'applications', 'review', 'Screen, shortlist, interview and record review notes', 'confidential'::data_classification),
  ('applications.decide', 'applications', 'decide', 'Make offers and reject at final stages', 'confidential'::data_classification),
  ('applications.hire', 'applications', 'hire', 'Accept an offer and trigger controlled onboarding', 'confidential'::data_classification),
  ('onboarding.manage', 'onboarding', 'manage', 'Manage onboarding and offboarding tasks', 'restricted'::data_classification),
  ('staff.offboard', 'staff', 'offboard', 'Record staff departure and revoke access', 'restricted'::data_classification),
  ('profiles.view', 'profiles', 'view', 'View all public staff profiles including drafts', 'internal'::data_classification),
  ('profiles.edit', 'profiles', 'edit', 'Edit other staff members public profile drafts', 'internal'::data_classification),
  ('profiles.publish', 'profiles', 'publish', 'Approve, publish and unpublish public staff profiles', 'restricted'::data_classification),
  ('websites.view', 'websites', 'view', 'View the registry of connected websites', 'restricted'::data_classification),
  ('websites.manage', 'websites', 'manage', 'Register websites and issue or rotate their API keys', 'restricted'::data_classification);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from (values
  ('ceo', 'positions.manage'),
  ('administration_officer', 'positions.manage'),
  ('ceo', 'vacancies.view'),
  ('administration_officer', 'vacancies.view'),
  ('division_lead', 'vacancies.view'),
  ('auditor', 'vacancies.view'),
  ('recruiter', 'vacancies.view'),
  ('ceo', 'vacancies.create'),
  ('administration_officer', 'vacancies.create'),
  ('division_lead', 'vacancies.create'),
  ('recruiter', 'vacancies.create'),
  ('ceo', 'vacancies.update'),
  ('administration_officer', 'vacancies.update'),
  ('division_lead', 'vacancies.update'),
  ('recruiter', 'vacancies.update'),
  ('ceo', 'vacancies.publish'),
  ('ceo', 'applications.view'),
  ('administration_officer', 'applications.view'),
  ('division_lead', 'applications.view'),
  ('recruiter', 'applications.view'),
  ('ceo', 'applications.review'),
  ('administration_officer', 'applications.review'),
  ('division_lead', 'applications.review'),
  ('recruiter', 'applications.review'),
  ('ceo', 'applications.decide'),
  ('ceo', 'applications.hire'),
  ('ceo', 'onboarding.manage'),
  ('administration_officer', 'onboarding.manage'),
  ('ceo', 'staff.offboard'),
  ('ceo', 'profiles.view'),
  ('administration_officer', 'profiles.view'),
  ('ceo', 'profiles.edit'),
  ('administration_officer', 'profiles.edit'),
  ('ceo', 'profiles.publish'),
  ('ceo', 'websites.view'),
  ('administration_officer', 'websites.view'),
  ('auditor', 'websites.view'),
  ('ceo', 'websites.manage')
) as v(role_key, permission_key)
join roles r on r.key = v.role_key
join permissions p on p.key = v.permission_key;
