-- First-administrator bootstrap on an empty ADA.
begin;
insert into auth.users (id, email) values (tests.uid('founder'), 'founder@ada.test');
select tests.check('bootstrap creates the first administrator',
  (select (bootstrap_first_admin(tests.uid('founder'), 'Founder', 'founder@ada.test') is not null)::text), 'true');
select tests.check('the founder holds the org-wide CEO role',
  tests.scalar('founder', $q$ select (my_access() -> 'roles' @> '[{"key":"ceo"}]'::jsonb)::text $q$), 'true');
select tests.check('the founder has an ADA staff ID',
  (select (ada_id ~ '^ADA-STF-\d{4}-0001$')::text from staff), 'true');
select tests.check('bootstrap refuses to run twice',
  tests.try_owner($q$ select bootstrap_first_admin(gen_random_uuid(), 'Evil', 'evil@x.x') $q$), 'ERR:55000');
select tests.finish();
rollback;
