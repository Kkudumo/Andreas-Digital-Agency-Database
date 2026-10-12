-- 0044_search_finance_sources: invoices and payments become searchable (Pilot V0.1 finding F2).
-- Until now they were not Search sources, so `related:<client>` could not return invoices although the documentation said it would, and an invoice or payment
-- could only be reached through the 360 pages. They are added the same way as every other entity type: a label and a few METADATA attributes read from the
-- authoritative row, visible only where the caller's own row-level security shows the row (restricted clients' finance records stay invisible: the same
-- non-disclosure tests that cover every other type are extended to these two).
--   invoice: label = its ADA number; attributes = status, currency        (no amounts, no client text, no notes)
--   payment: label = its ADA number; attributes = method, status, bank reference   (no amounts, no notes)
-- Relationships: the family of a client now includes its payments; the family of a project also includes the invoices billed through a contract that covers
-- it, and the payments allocated to them (the same rule as Project 360, migration 0042). document_family_ids is read-only and SECURITY INVOKER, so each caller
-- only ever gets the members their own row-level security lets them see.
insert into search_sources (entity_type, label_expr, attribute_exprs, note) values
  ('invoice', 'x.ada_id', array['x.status::text', 'x.currency'], 'METADATA only: number, status, currency; no amounts and no client text'),
  ('payment', 'x.ada_id', array['x.method::text', 'x.status::text', 'x.reference'], 'METADATA only: number, method, status and the bank reference; no amounts')
on conflict (entity_type) do nothing;
select attach_search('public.invoices'::regclass);
select attach_search('public.payments'::regclass);

create or replace function document_family_ids(p_registry_id text) returns text[]
language plpgsql stable set search_path = public, pg_temp as $$
declare r entity_registry%rowtype; v_ids text[] := '{}';
begin
  select * into r from entity_registry where institutional_id = p_registry_id;
  if not found then return '{}'; end if;
  v_ids := array[r.institutional_id];
  if r.table_name = 'clients' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'projects'  and er.entity_id in (select id from projects  where client_id = r.entity_id))
      or (er.table_name = 'contracts' and er.entity_id in (select id from contracts where client_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes    where client_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices  where client_id = r.entity_id))
      or (er.table_name = 'payments'  and er.entity_id in (select id from payments  where client_id = r.entity_id))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets   where client_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets    where client_id = r.entity_id));
  elsif r.table_name = 'projects' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'contracts' and er.entity_id in (select contract_id from contract_projects where project_id = r.entity_id))
      or (er.table_name = 'quotes'    and er.entity_id in (select id from quotes   where project_id = r.entity_id))
      or (er.table_name = 'invoices'  and er.entity_id in (select id from invoices where project_id = r.entity_id
                                                           or contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = r.entity_id)))
      or (er.table_name = 'payments'  and er.entity_id in (select pa.payment_id from payment_allocations pa join invoices i on i.id = pa.invoice_id
                                                           where pa.status = 'active' and (i.project_id = r.entity_id or i.contract_id in (select cp.contract_id from contract_projects cp where cp.project_id = r.entity_id))))
      or (er.table_name = 'tickets'   and er.entity_id in (select id from tickets  where project_id = r.entity_id))
      or (er.table_name = 'assets'    and er.entity_id in (select id from assets   where project_id = r.entity_id));
  elsif r.table_name = 'organizations' then
    select v_ids || coalesce(array_agg(er.institutional_id), '{}') into v_ids from entity_registry er where
         (er.table_name = 'clients'   and er.entity_id in (select id from clients   where organization_id = r.entity_id))
      or (er.table_name = 'suppliers' and er.entity_id in (select id from suppliers where organization_id = r.entity_id))
      or (er.table_name = 'partners'  and er.entity_id in (select id from partners  where organization_id = r.entity_id));
    select v_ids || coalesce(array_agg(x), '{}') into v_ids
      from (select unnest(document_family_ids(er.institutional_id)) x from entity_registry er
             where er.table_name = 'clients' and er.entity_id in (select id from clients where organization_id = r.entity_id)) q;
    select coalesce(array_agg(distinct x), '{}') into v_ids from unnest(v_ids) x;
  end if;
  return v_ids;
end $$;

select search_rebuild();   -- index the invoices and payments that already exist
