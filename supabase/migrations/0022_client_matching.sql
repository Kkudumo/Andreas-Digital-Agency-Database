-- 0022_client_matching: controlled client creation and matching that NEVER reveals a restricted client.
--
-- Two kinds of client exist for matching purposes:
--   discoverable  (classification public/internal) - may be found, named in messages and claimed by a division
--   hidden        (restricted/confidential)        - must be indistinguishable from "does not exist" to anyone
--                                                    without access: no error text, no lookup hit, no uniqueness
--                                                    failure, no helper-function answer.
-- Uniqueness is therefore enforced among discoverable clients only. When a new or changed client collides with a
-- hidden one, the creator is told nothing; management gets a review item instead (matching_reviews).
-- Clients can no longer be INSERTed directly by users: client_create() is the controlled path.

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- Uniqueness among discoverable clients only
-- ---------------------------------------------------------------------------
drop index clients_name_key_unique;
drop index clients_registration_unique;
create unique index clients_name_key_unique on clients (name_key)
  where deleted_at is null and classification in ('public', 'internal');
create unique index clients_registration_unique on clients (lower(btrim(registration_number)))
  where registration_number is not null and btrim(registration_number) <> '' and deleted_at is null and classification in ('public', 'internal');
create index clients_name_key_trgm on clients using gin (name_key extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Review queue for collisions the creator must not hear about
-- ---------------------------------------------------------------------------
create table matching_reviews (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null default 'client_duplicate_suspect',
  left_client_id  uuid not null references clients (id),
  right_client_id uuid not null references clients (id),
  reason          text not null,
  score           real,
  status          text not null default 'open' check (status in ('open', 'resolved_distinct', 'resolved_same', 'dismissed')),
  created_at      timestamptz not null default now(),
  resolved_by     uuid references staff (id),
  resolved_at     timestamptz,
  resolution_note text,
  check (left_client_id <> right_client_id)
);
create unique index matching_reviews_open_pair on matching_reviews (least(left_client_id, right_client_id), greatest(left_client_id, right_client_id)) where status = 'open';
comment on table matching_reviews is 'Purpose: possible duplicate clients that involve a restricted/confidential record. Visible only to matching.review holders so the existence of hidden clients is never disclosed to the people who triggered the match. [class: restricted]';

create table client_distinct_pairs (
  client_a   uuid not null references clients (id),
  client_b   uuid not null references clients (id),
  reason     text not null,
  decided_by uuid references staff (id),
  decided_at timestamptz not null default now(),
  primary key (client_a, client_b),
  check (client_a < client_b)
);
comment on table client_distinct_pairs is 'Purpose: pairs a human has confirmed are genuinely different legal entities, so they are not flagged again. [class: restricted]';

-- ---------------------------------------------------------------------------
-- Candidate finder (internal: sees everything, tells the caller only what it may know)
-- ---------------------------------------------------------------------------
create function client_candidates(p_name text, p_registration text, p_email text, p_person uuid, p_exclude uuid default null)
returns table (client_id uuid, reason text, score real, discoverable boolean)
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  with k as (select client_name_key(p_name) as key)
  select c.id, 'exact_name'::text, 1.0::real, c.classification in ('public', 'internal')
    from clients c, k where c.deleted_at is null and c.id is distinct from p_exclude and k.key <> '' and c.name_key = k.key
  union all
  select c.id, 'registration'::text, 1.0::real, c.classification in ('public', 'internal')
    from clients c where c.deleted_at is null and c.id is distinct from p_exclude and p_registration is not null and btrim(p_registration) <> ''
      and lower(btrim(c.registration_number)) = lower(btrim(p_registration))
  union all
  select c.id, 'similar_name'::text, similarity(c.name_key, k.key)::real, c.classification in ('public', 'internal')
    from clients c, k where c.deleted_at is null and c.id is distinct from p_exclude and k.key <> '' and c.name_key <> k.key
      and similarity(c.name_key, k.key) >= 0.55
  union all
  select c.id, 'contact_email'::text, 0.9::real, c.classification in ('public', 'internal')
    from clients c join client_contacts cc on cc.client_id = c.id and cc.is_active join people pe on pe.id = cc.person_id
   where c.deleted_at is null and c.id is distinct from p_exclude and p_email is not null and lower(pe.email) = lower(btrim(p_email))
  union all
  select c.id, 'person_is_contact'::text, 0.8::real, c.classification in ('public', 'internal')
    from clients c join client_contacts cc on cc.client_id = c.id and cc.is_active
   where c.deleted_at is null and c.id is distinct from p_exclude and p_person is not null and cc.person_id = p_person
$$;
revoke execute on function client_candidates(text, text, text, uuid, uuid) from public, anon, authenticated;

-- Flag collisions involving a hidden client, silently.
create function clients_flag_hidden_duplicates() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  if new.deleted_at is not null then return null; end if;
  for r in select * from client_candidates(new.name, new.registration_number, null, null, new.id)
            where reason in ('exact_name', 'registration', 'similar_name') loop
    if (not r.discoverable or new.classification not in ('public', 'internal'))
       and not exists (select 1 from client_distinct_pairs where client_a = least(new.id, r.client_id) and client_b = greatest(new.id, r.client_id)) then
      insert into matching_reviews (left_client_id, right_client_id, reason, score)
      values (new.id, r.client_id, r.reason, r.score) on conflict do nothing;
    end if;
  end loop;
  return null;
end $$;
create trigger clients_flag_hidden_duplicates_trg after insert or update of name, registration_number, classification on clients
  for each row execute function clients_flag_hidden_duplicates();

create function matching_resolve(p_review uuid, p_outcome text, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m matching_reviews%rowtype;
begin
  if not has_permission('matching.review') then raise exception 'matching.review is required' using errcode = '42501'; end if;
  if p_outcome not in ('distinct', 'same', 'dismissed') then raise exception 'outcome must be distinct, same or dismissed' using errcode = '22023'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'a note is required' using errcode = '23514'; end if;
  select * into m from matching_reviews where id = p_review and status = 'open' for update;
  if not found then raise exception 'review not found or already resolved' using errcode = 'P0002'; end if;
  update matching_reviews set status = case p_outcome when 'distinct' then 'resolved_distinct' when 'same' then 'resolved_same' else 'dismissed' end,
         resolved_by = current_staff_id(), resolved_at = now(), resolution_note = p_note where id = p_review;
  if p_outcome = 'distinct' then
    insert into client_distinct_pairs (client_a, client_b, reason, decided_by)
    values (least(m.left_client_id, m.right_client_id), greatest(m.left_client_id, m.right_client_id), p_note, current_staff_id()) on conflict do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Controlled creation. The response shape never depends on hidden records.
-- ---------------------------------------------------------------------------
create function client_create(p_name text, p_division uuid, p_type client_type default 'company', p_registration text default null,
                              p_email text default null, p_phone text default null, p_distinct_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_key text;
  v_exact record;
  v_similar jsonb;
  v_id uuid;
  v_ada text;
  v_reg text := nullif(btrim(coalesce(p_registration, '')), '');
begin
  if not has_permission('clients.create', p_division) then
    raise exception 'clients.create is required%', case when p_division is null then ' (organization-wide)' else ' in that division' end using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then raise exception 'a valid name is required' using errcode = '22023'; end if;
  v_key := client_name_key(p_name);
  if v_key = '' then raise exception 'the name needs a distinguishing word' using errcode = '22023'; end if;

  select c.ada_id, c.name, c.status::text as status, nullif(btrim(c.registration_number), '') as registration into v_exact
    from clients c
   where c.deleted_at is null and c.classification in ('public', 'internal')
     and (c.name_key = v_key or (v_reg is not null and lower(btrim(c.registration_number)) = lower(v_reg)))
   order by (lower(btrim(c.registration_number)) is not distinct from lower(v_reg)) desc, c.created_at limit 1;
  if found then
    -- Same normalised name but both sides state DIFFERENT registration numbers: provably different legal entities.
    -- They are never merged, but the system cannot hold two clients with the same normalised name either, so the
    -- creator is asked for a distinguishing name (for example the town or trading name).
    if v_reg is not null and v_exact.registration is not null and lower(v_exact.registration) <> lower(v_reg) then
      return jsonb_build_object('status', 'name_conflict',
                                'next', 'a different legal entity already uses this name; choose a distinguishing name (for example add the town or trading name)');
    end if;
    return jsonb_build_object('status', 'exists', 'client', v_exact.ada_id, 'name', v_exact.name, 'next', 'claim_client_for_division');
  end if;

  select jsonb_agg(jsonb_build_object('client', x.ada_id, 'name', x.name, 'status', x.status, 'similarity', round(x.score::numeric, 2)) order by x.score desc)
    into v_similar
    from (select c.ada_id, c.name, c.status::text as status, max(cc.score) as score, c.id
            from client_candidates(p_name, v_reg, null, null) cc join clients c on c.id = cc.client_id
           where cc.discoverable and cc.reason = 'similar_name' group by c.id, c.ada_id, c.name, c.status) x;
  if v_similar is not null and coalesce(btrim(p_distinct_reason), '') = '' then
    return jsonb_build_object('status', 'similar', 'candidates', v_similar,
                              'next', 'use an existing client, or repeat with p_distinct_reason explaining why this is a different legal entity');
  end if;

  insert into clients (name, client_type, registration_number, email, phone, owner_division_id)
  values (btrim(p_name), p_type, v_reg, nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''), p_division)
  returning id, ada_id into v_id, v_ada;

  if v_similar is not null then
    insert into client_distinct_pairs (client_a, client_b, reason, decided_by)
    select least(v_id, c.id), greatest(v_id, c.id), p_distinct_reason, current_staff_id()
      from clients c where c.ada_id in (select e ->> 'client' from jsonb_array_elements(v_similar) e) on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'created', 'client', v_ada, 'id', v_id);
end $$;

-- Lookup shows DISCOVERABLE clients only; a hidden client yields exactly what a non-existent one does: nothing.
create or replace function client_lookup(p_name text default null, p_registration text default null, p_email text default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
begin
  if not has_permission_anywhere('clients.create') then
    raise exception 'clients.create is required' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('client', c.ada_id, 'name', c.name, 'status', c.status::text, 'match', m.reason, 'shareable', true) order by m.score desc)
    from (select cc.client_id, (array_agg(cc.reason order by cc.score desc))[1] as reason, max(cc.score) as score
            from client_candidates(p_name, p_registration, p_email, null) cc
           where cc.discoverable and cc.reason in ('exact_name', 'registration', 'similar_name', 'contact_email') group by cc.client_id) m
    join clients c on c.id = m.client_id), '[]'::jsonb);
end $$;

-- The duplicate message for UPDATE/rename only speaks about discoverable clients.
create or replace function client_duplicate_message(p_name text, p_reg text, p_self uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not has_permission_anywhere('clients.create') then null
              else format('a client "%s" already exists (%s); link your division to it with claim_client_for_division() instead of creating a second record', c.name, c.ada_id) end
  from clients c
  where c.deleted_at is null and c.id is distinct from p_self and c.classification in ('public', 'internal')
    and (c.name_key = client_name_key(p_name)
         or (p_reg is not null and btrim(p_reg) <> '' and lower(btrim(c.registration_number)) = lower(btrim(p_reg))))
  order by c.created_at limit 1
$$;

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------
revoke insert on clients from authenticated;                 -- creation only through client_create()
alter table matching_reviews     enable row level security;
alter table client_distinct_pairs enable row level security;
revoke all on matching_reviews, client_distinct_pairs from anon, authenticated;
grant select on matching_reviews, client_distinct_pairs to authenticated;
create policy matching_reviews_select on matching_reviews for select to authenticated using (has_permission('matching.review'));
create policy client_distinct_pairs_select on client_distinct_pairs for select to authenticated using (has_permission('matching.review'));

revoke execute on function client_create(text, uuid, client_type, text, text, text, text), matching_resolve(uuid, text, text) from public, anon;
grant execute on function client_create(text, uuid, client_type, text, text, text, text), matching_resolve(uuid, text, text) to authenticated;

do $$ begin perform attach_audit('matching_reviews'); end $$;
do $$ begin perform attach_audit('client_distinct_pairs'); end $$;
