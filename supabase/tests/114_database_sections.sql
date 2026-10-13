-- PERMANENT: the arrangement of the database into sections - every table belongs to exactly one section, the catalogue holds no stale names, it is readable by
-- signed-in staff only, and the foreign keys a person or page looks things up by are indexed. A new table with no section, or a new lookup foreign key with no
-- index, fails here: the arrangement cannot silently rot.
begin;
select tests.setup();
select tests.check('every table of the public schema belongs to a section', (select coalesce(string_agg(c.relname, ', ' order by c.relname), 'none') from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and not exists (select 1 from db_section_tables t where t.table_name = c.relname)), 'none');
select tests.check('no section lists a table that does not exist', (select coalesce(string_agg(t.table_name, ', '), 'none') from db_section_tables t where to_regclass('public.' || t.table_name) is null), 'none');
select tests.check('there are 13 sections, numbered 1 to 13, each with at least one table', (select count(*)::text || ':' || min(position)::text || '-' || max(position)::text || ':' || count(*) filter (where exists (select 1 from db_section_tables t where t.section_key = s.key))::text from db_sections s), '13:1-13:13');
select tests.check('the services and prices section holds the catalogue, the people and careers section holds vacancies and applications',
  (select string_agg(section_key, ',' order by table_name) from db_section_tables where table_name in ('service_prices', 'services', 'vacancies', 'applications', 'invoices')), 'people_careers,finance,services_prices,services_prices,people_careers');
select tests.check('signed-in staff can read the arrangement as one document; its table counts add up to the number of tables',
  tests.scalar('web_lead', $q$ select (select sum(jsonb_array_length(s -> 'tables')) from jsonb_array_elements(database_sections()) s)::text $q$), (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r'));
select tests.check('anonymous callers can neither read the catalogue nor run the function', concat_ws(',', tests.scalar_anon('select count(*)::text from db_sections'), tests.scalar_anon('select database_sections()::text'), tests.scalar_anon('select count(*)::text from db_section_tables')), 'ERR:42501,ERR:42501,ERR:42501');
select tests.check('nobody can edit the catalogue through the API', concat_ws(',', tests.try('ceo', $q$ update db_sections set title = 'x' $q$), tests.try('ceo', $q$ delete from db_section_tables $q$), tests.try('ceo', $q$ insert into db_sections (key, position, title, summary) values ('zz', 99, 'x', 'y') $q$)), 'ERR:42501,ERR:42501,ERR:42501');
-- indexes
select tests.check('every foreign key to a main record (not an actor column such as created_by) has an index to look it up by',
  (select coalesce(string_agg(tbl || '.' || col, ', ' order by tbl, col), 'none') from (
     select c.conrelid, c.conkey, c.conrelid::regclass::text tbl, (select attname from pg_attribute where attrelid = c.conrelid and attnum = c.conkey[1]) col
       from pg_constraint c where c.contype = 'f' and c.connamespace = 'public'::regnamespace and array_length(c.conkey, 1) = 1) fk
   where not exists (select 1 from pg_index i where i.indrelid = fk.conrelid and i.indkey[0] = fk.conkey[1])
     and col !~ '(_by$|^actor_staff_id$|^author_id$|^reviewer_id$|^approver_id$|^actor_id$)' and not (tbl = 'id_settings' and col = 'codebook_version')), 'none');
select tests.check('the list pages have their newest-first sort orders', (select count(*)::text from pg_indexes where schemaname = 'public' and indexname in ('ix_quotes_created', 'ix_contracts_created', 'ix_invoices_created', 'ix_projects_created', 'ix_clients_created', 'ix_documents_updated', 'ix_tickets_created')), '7');
select tests.check('search was already indexed for fast matching (full-text and trigram)', (select string_agg(indexname, ',' order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'search_index' and indexdef ~* 'gin'), 'search_index_label_norm_trgm,search_index_label_trgm,search_index_tsv_idx');
select tests.finish();
rollback;
