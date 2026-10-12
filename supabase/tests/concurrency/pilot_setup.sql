-- Owner-level fixture for the parallel pilot-workflow test (scripts/test-db.sh). Not run by the normal suite glob.
-- One staff member (CEO) acts through the real commands; the commercial state that would need several people (an approved, accepted quote; a signed contract;
-- an uninvoiced billable item) is reached by owner-level status updates exactly as finance_setup.sql does.
do $$
declare
  v_client uuid; v_div uuid; v_svc uuid; v_price uuid; v_q uuid; v_q2 uuid; v_q3 uuid; v_bi uuid;
begin
  select id into v_div from divisions where key = 'web';
  insert into auth.users (id, email) values (md5('conc-pilot-user')::uuid, 'concpilot@ada.test');
  insert into staff (user_id, full_name, email, account_status) values (md5('conc-pilot-user')::uuid, 'Conc Pilot', 'concpilot@ada.test', 'active');
  insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'concpilot@ada.test' and r.key = 'ceo';

  insert into services (division_id, name, summary, description, status, published_at) values (v_div, 'Pilot Race Service', 's', 'd', 'published', now()) returning id into v_svc;
  insert into service_prices (service_id, version, amount, currency, effective_from, status, reason) values (v_svc, 1, 1000, 'NAD', current_date, 'approved', 'race') returning id into v_price;

  insert into clients (name, owner_division_id) values ('Pilot Race Client', v_div) returning id into v_client;
  -- three accepted quotes: one raced into a project, one raced into a contract, one raced into an invoice
  for i in 1..3 loop
    insert into quotes (client_id, division_id, title, valid_until) values (v_client, v_div, 'race quote ' || i, current_date + 30) returning id into v_q;
    insert into quote_lines (quote_id, service_id, price_id, description, quantity, unit_price) values (v_q, v_svc, v_price, 'Pilot Race Service', 1, 1000);
    update quotes set status = 'pending_approval' where id = v_q;
    update quotes set status = 'approved' where id = v_q;
    update quotes set status = 'sent' where id = v_q;
    update quotes set status = 'accepted' where id = v_q;
  end loop;
end $$;
