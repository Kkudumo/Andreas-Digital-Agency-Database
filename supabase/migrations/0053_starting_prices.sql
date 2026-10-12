-- 0053_starting_prices: a price can be a STARTING price ("from N$x").
-- Most of ADA's published prices are "From N$x": the price for the standard scope, with a larger job quoted in writing. The catalogue could not say so, so a
-- website (or a quote) could not tell "N$649" from "from N$649". This adds the fact to the price VERSION (so it is immutable once approved, like the amount)
-- and passes it on to the public catalogue. Quotes still use the price in force; the flag changes nothing about arithmetic.
--  * service_prices.is_starting_price (default false: every existing price keeps meaning "fixed").
--  * price_propose gains a trailing optional p_starting (existing 5-argument calls keep working).
--  * The approved-price immutability rule now covers the flag.
--  * public_api.services returns "starting_price": true inside "price" when it is one.

alter table service_prices add column is_starting_price boolean not null default false;
comment on column service_prices.is_starting_price is 'True when the published price is a starting price ("from N$x"): the standard scope, larger work quoted. Part of the immutable price version.';

create or replace function service_prices_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'approved' then raise exception 'approved prices cannot be deleted' using errcode = '42501'; end if;
    return old;
  end if;
  if old.status = 'approved' then
    if (new.amount, new.currency, new.effective_from, new.service_id, new.version, new.reason, new.proposed_by, new.approved_by, new.approved_at, new.is_starting_price)
       is distinct from (old.amount, old.currency, old.effective_from, old.service_id, old.version, old.reason, old.proposed_by, old.approved_by, old.approved_at, old.is_starting_price)
       or new.status is distinct from old.status then
      raise exception 'approved prices are immutable (only effective_to may be set when a newer version takes over)' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop function price_propose(uuid, numeric, text, date, text);
create function price_propose(p_service uuid, p_amount numeric, p_currency text, p_effective_from date, p_reason text, p_starting boolean default false) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s services%rowtype;
  v_latest date;
  v_id uuid;
begin
  select * into s from services where id = p_service and deleted_at is null for update;
  if not found or not has_permission('pricing.propose', s.division_id) then
    raise exception 'pricing.propose is required for this service' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required for a price change' using errcode = '23514'; end if;
  if p_effective_from is null or p_effective_from < current_date then
    raise exception 'the effective date cannot be in the past' using errcode = '23514';
  end if;
  if s.pricing_model = 'quote_based' then
    if p_amount is not null then raise exception 'a quote-based service has no list price' using errcode = '23514'; end if;
  elsif p_amount is null or p_amount < 0 then
    raise exception 'a non-negative amount is required' using errcode = '23514';
  end if;
  select max(effective_from) into v_latest from service_prices where service_id = p_service and status = 'approved';
  if v_latest is not null and p_effective_from <= v_latest then
    raise exception 'the new price must take effect after the current version (%)', v_latest using errcode = '23514';
  end if;
  begin
    insert into service_prices (service_id, version, amount, currency, effective_from, reason, proposed_by, is_starting_price)
    values (p_service, coalesce((select max(version) from service_prices where service_id = p_service), 0) + 1,
            p_amount, upper(coalesce(p_currency, 'NAD')), p_effective_from, p_reason, current_staff_id(), coalesce(p_starting, false))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'a price change is already awaiting approval for this service' using errcode = '23505';
  end;
  perform notify_holders('pricing.approve', null, 'approval.required', 'Price change awaiting approval: ' || s.name,
                         p_reason, 'service_prices', v_id, s.ada_id);
  return v_id;
end $$;
revoke execute on function price_propose(uuid, numeric, text, date, text, boolean) from public, anon;
grant execute on function price_propose(uuid, numeric, text, date, text, boolean) to authenticated;

create or replace function public_api.services(p_key_hash text, p_division text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public_api.authorize(p_key_hash, 'services.read');
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', s.ada_id, 'name', s.name, 'category', s.category, 'summary', s.summary, 'description', s.description,
      'pricing_model', s.pricing_model, 'billing_unit', s.billing_unit,
      'division', case when d.public_state = 'published' then jsonb_build_object('code', d.key, 'name', d.name) end,
      'price', case when s.show_price and s.pricing_model <> 'quote_based' and (price_on(s.id)).id is not null
                    then jsonb_build_object('amount', (price_on(s.id)).amount, 'currency', (price_on(s.id)).currency,
                                            'effective_from', (price_on(s.id)).effective_from,
                                            'starting_price', (price_on(s.id)).is_starting_price) end)) order by d.sort_order, s.name)
    from services s join divisions d on d.id = s.division_id
    where s.status = 'published' and s.is_active and s.deleted_at is null and (p_division is null or d.key = p_division)), '[]'::jsonb);
end $$;
