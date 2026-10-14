-- 0058_site_rebuilds: republish a division website when its public prices or services change.
--
-- The static division sites (web, tech, marketing, consulting) read prices from the public API only while they are built.
-- This step rebuilds them automatically:
--   * a change that a website can see (a price version approved or ended, a service published, unpublished or edited while
--     published) marks that division's site in site_rebuilds as requested;
--   * send_site_rebuilds(), run every minute by pg_cron, waits until a site has been quiet for 30 seconds (so a burst of
--     changes is one rebuild) and then calls the site's Vercel deploy hook;
--   * request_due_price_rebuilds(), run daily just after midnight in Namibia, requests a rebuild for sites with a price
--     version that starts today (prices can be approved ahead of their start date).
--
-- A deploy hook URL works like a password. It is never stored in a table: site_rebuilds holds only the NAME of a Supabase
-- Vault secret (for example deploy_hook_web), which the owner creates in the Supabase dashboard. Until it exists the site is
-- simply not rebuilt and last_status says so.
--
-- (Numbered 0058 because 0055-0057 are taken by the documents/content work on other branches.)

create table site_rebuilds (
  division_key text primary key references divisions (key) on update cascade,
  hook_secret  text not null unique check (hook_secret ~ '^[a-z][a-z0-9_]*$'),
  requested_at timestamptz,
  sent_at      timestamptz,
  last_status  text,
  updated_at   timestamptz not null default now()
);
comment on table site_rebuilds is 'Purpose: which division website needs rebuilding after a public price or service change, and the name of the Vault secret holding its deploy hook. The hook URL itself is never stored here. [class: restricted]';
create trigger site_rebuilds_updated before update on site_rebuilds for each row execute function set_updated_at();

insert into site_rebuilds (division_key, hook_secret)
select key, 'deploy_hook_' || key from divisions where key in ('web', 'tech', 'marketing', 'consulting')
on conflict do nothing;

alter table site_rebuilds enable row level security;
revoke all on site_rebuilds from anon, authenticated;
grant select on site_rebuilds to authenticated;
create policy site_rebuilds_select on site_rebuilds for select to authenticated using (has_permission('websites.view'));

-- Mark a division's website as needing a rebuild. Divisions without a static website are ignored.
create function request_site_rebuild(p_division uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update site_rebuilds set requested_at = now() where division_key = (select key from divisions where id = p_division)
$$;
revoke execute on function request_site_rebuild(uuid) from public, anon, authenticated;

create function site_rebuilds_on_price() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- only changes a website can see: a version becoming approved, or an approved version being ended or replaced
  if (tg_op = 'INSERT' and new.status = 'approved')
     or (tg_op = 'UPDATE' and (new.status is distinct from old.status or new.effective_to is distinct from old.effective_to)
         and 'approved' in (new.status::text, old.status::text)) then
    perform request_site_rebuild((select division_id from services where id = new.service_id));
  end if;
  return null;
end $$;
create trigger site_rebuilds_price_trg after insert or update on service_prices for each row execute function site_rebuilds_on_price();

create function site_rebuilds_on_service() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'published' then perform request_site_rebuild(new.division_id); end if;
  elsif (new.status = 'published') is distinct from (old.status = 'published')
     or (new.status = 'published' and (new.name, new.pricing_model, new.billing_unit, new.show_price, new.is_active, new.deleted_at)
                                       is distinct from (old.name, old.pricing_model, old.billing_unit, old.show_price, old.is_active, old.deleted_at)) then
    perform request_site_rebuild(new.division_id);
  end if;
  return null;
end $$;
create trigger site_rebuilds_service_trg after insert or update on services for each row execute function site_rebuilds_on_service();

-- Daily: a price approved ahead of time becomes visible on its start date, so rebuild those sites that day.
create function request_due_price_rebuilds() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  update site_rebuilds r set requested_at = now()
   where exists (select 1 from service_prices p join services s on s.id = p.service_id join divisions d on d.id = s.division_id
                  where d.key = r.division_key and p.status = 'approved' and p.effective_from = current_date);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function request_due_price_rebuilds() from public, anon, authenticated;

-- Every minute: call the deploy hook of each site that asked for a rebuild and has been quiet for 30 seconds.
create function send_site_rebuilds() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_url text; n integer := 0;
begin
  for r in select * from site_rebuilds
            where requested_at is not null and (sent_at is null or sent_at < requested_at)
              and requested_at <= now() - interval '30 seconds'
            for update skip locked
  loop
    select decrypted_secret into v_url from vault.decrypted_secrets where name = r.hook_secret;
    if v_url is null or v_url !~ '^https://api\.vercel\.com/' then
      update site_rebuilds set last_status = 'waiting: no Vercel deploy hook saved in Vault as ' || r.hook_secret
       where division_key = r.division_key;
      continue;
    end if;
    perform net.http_post(url := v_url, body := '{}'::jsonb, timeout_milliseconds := 10000);
    update site_rebuilds set sent_at = now(), last_status = 'rebuild requested ' || to_char(now() at time zone 'Africa/Windhoek', 'YYYY-MM-DD HH24:MI')
     where division_key = r.division_key;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function send_site_rebuilds() from public, anon, authenticated;

-- Schedules (only where the Supabase extensions exist; local test databases do without them).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net')
     and exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_net with schema extensions;
    create extension if not exists pg_cron;
    perform cron.schedule('ada-site-rebuilds', '* * * * *', 'select public.send_site_rebuilds()');
    perform cron.schedule('ada-site-rebuilds-daily', '5 22 * * *', 'select public.request_due_price_rebuilds()'); -- 00:05 in Namibia
  end if;
end $$;
