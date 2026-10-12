-- Owner-level fixture for the parallel billing-schedule test (scripts/test-db.sh). Not run by the normal suite glob.
-- One staff member (CEO) acts through the real commands; the commercial steps that would need several people (an accepted quote; a signed, active contract)
-- are reached by owner-level status updates exactly as pilot_setup.sql does. Two active contracts: SCHED-A (a line of 10) and SCHED-B (a line of 4).
do $$
declare
  v_client uuid; v_div uuid; v_svc uuid; v_price uuid; v_q uuid; v_c uuid; v_line uuid; v_n text; v_qty numeric;
begin
  select id into v_div from divisions where key = 'web';
  insert into auth.users (id, email) values (md5('conc-sched-user')::uuid, 'concsched@ada.test');
  insert into staff (user_id, full_name, email, account_status) values (md5('conc-sched-user')::uuid, 'Conc Sched', 'concsched@ada.test', 'active');
  insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'concsched@ada.test' and r.key = 'ceo';
  perform set_config('request.jwt.claim.sub', md5('conc-sched-user'), false);

  insert into services (division_id, name, summary, description, status, published_at) values (v_div, 'Sched Race Service', 's', 'd', 'published', now()) returning id into v_svc;
  insert into service_prices (service_id, version, amount, currency, effective_from, status, reason) values (v_svc, 1, 100, 'NAD', current_date, 'approved', 'race') returning id into v_price;
  insert into clients (name, owner_division_id) values ('Sched Race Client', v_div) returning id into v_client;

  for v_n, v_qty in select * from (values ('A', 10), ('B', 4)) t(n, q) loop
    insert into quotes (client_id, division_id, title, valid_until) values (v_client, v_div, 'sched quote ' || v_n, current_date + 30) returning id into v_q;
    insert into quote_lines (quote_id, service_id, price_id, description, quantity, unit_price) values (v_q, v_svc, v_price, 'Sched Race ' || v_n, v_qty, 100);
    update quotes set status = 'pending_approval' where id = v_q;
    update quotes set status = 'approved' where id = v_q;
    update quotes set status = 'sent' where id = v_q;
    update quotes set status = 'accepted' where id = v_q;
    v_c := contract_create_from_quote(v_q);
    update contracts set title = 'SCHED-' || v_n where id = v_c;
    update contract_versions set status = 'internal_review' where contract_id = v_c and status = 'draft';
    update contract_versions set status = 'approved' where contract_id = v_c and status = 'internal_review';
    update contract_versions set status = 'sent' where contract_id = v_c and status = 'approved';
    update contract_versions set status = 'signed' where contract_id = v_c and status = 'sent';
    update contracts set status = 'internal_review' where id = v_c;
    update contracts set status = 'approved' where id = v_c;
    update contracts set status = 'sent' where id = v_c;
    update contracts set status = 'signed' where id = v_c;
    update contracts set status = 'active' where id = v_c;
    select l.id into v_line from contract_lines l join contract_versions v on v.id = l.version_id where v.contract_id = v_c;
    perform billing_schedule_create(v_c, v_line, 1, date '2026-01-01', 1);
  end loop;
  perform set_config('request.jwt.claim.sub', '', false);
end $$;
