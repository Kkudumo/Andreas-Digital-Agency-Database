-- One hash that captures ADA Core's security posture for the API-facing roles: table and column grants,
-- RLS flags, policies, and function EXECUTE grants / SECURITY DEFINER flags. Backups record it; restores
-- and migrations must reproduce it exactly. Grants to owner/admin roles are deliberately excluded because
-- they legitimately differ between providers.
with api_roles as (select oid from pg_roles where rolname in ('anon', 'authenticated', 'ada_public_api')),
facts as (
  select 'T:' || c.relname || ':' || a.grantee::regrole::text || ':' || a.privilege_type as f
    from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and a.grantee in (select oid from api_roles)
  union all
  select 'C:' || c.relname || '.' || at.attname || ':' || a.grantee::regrole::text || ':' || a.privilege_type
    from pg_class c join pg_attribute at on at.attrelid = c.oid cross join lateral aclexplode(at.attacl) a
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and at.attacl is not null and a.grantee in (select oid from api_roles)
  union all
  select 'R:' || c.relname || ':' || c.relrowsecurity::text from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
  union all
  select 'P:' || tablename || ':' || policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, '') from pg_policies where schemaname = 'public'
  union all
  select 'F:' || p.oid::regprocedure::text || ':' || case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end || ':' || p.prosecdef::text
    from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace in ('public'::regnamespace, 'public_api'::regnamespace)
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and (a.grantee = 0 or a.grantee in (select oid from api_roles))
)
select md5(string_agg(f, '|' order by f)) from facts;
