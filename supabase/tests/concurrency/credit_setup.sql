-- Owner-level fixture for the parallel credit-note test (scripts/test-db.sh). Not run by the normal suite glob.
do $$
declare
  v_client uuid; v_div uuid; v_acct uuid; v_bi uuid; v_inv uuid; v_cn uuid; v_big uuid; v_pay uuid; i integer; j integer; k text;
begin
  select id into v_div from divisions where key = 'web';
  insert into auth.users (id, email) values (md5('conc-credit-user')::uuid, 'conccredit@ada.test');
  insert into staff (user_id, full_name, email, account_status) values (md5('conc-credit-user')::uuid, 'Conc Credit', 'conccredit@ada.test', 'active');
  insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'conccredit@ada.test' and r.key = 'ceo';
  insert into clients (name, owner_division_id) values ('Credit Race Client', v_div) returning id into v_client;
  insert into bank_accounts (name, bank_name, currency) values ('Credit race account', 'FNB', 'NAD') returning id into v_acct;

  -- five issued invoices: CAP (1000), X (500), Y (500), Z (300) and BASE (5000, the invoice the unapplied credit notes were raised against)
  for k in select unnest(array['CAP', 'X', 'Y', 'Z', 'BASE']) loop
    insert into billable_items (client_id, division_id, source, description, quantity, unit_price, currency, manual_reason)
    values (v_client, v_div, 'manual', 'credit race ' || k, 1, case k when 'CAP' then 1000 when 'Z' then 300 when 'BASE' then 5000 else 500 end, 'NAD', 'concurrency test') returning id into v_bi;
    insert into invoices (client_id, division_id, currency, po_reference) values (v_client, v_div, 'NAD', 'CR-' || k) returning id into v_inv;
    insert into invoice_lines (invoice_id, billable_item_id, description, quantity, unit_price) values (v_inv, v_bi, 'credit race ' || k, 1, case k when 'CAP' then 1000 when 'Z' then 300 when 'BASE' then 5000 else 500 end);
    update billable_items set status = 'invoiced' where id = v_bi;
    update invoices set status = 'pending_approval' where id = v_inv;
    update invoices set status = 'approved' where id = v_inv;
    update invoices set status = 'issued', issue_date = current_date, due_date = current_date + 30 where id = v_inv;
  end loop;

  -- eight draft credit notes of 400 against CAP (only two can ever be submitted: 800 of 1000)
  for i in 1..8 loop
    insert into credit_notes (invoice_id, client_id, division_id, currency, reason_code) select id, client_id, division_id, currency, 'goodwill' from invoices where po_reference = 'CR-CAP' returning id into v_cn;
    insert into credit_note_lines (credit_note_id, description, quantity, unit_price) values (v_cn, 'race ' || i, 1, 400);
  end loop;

  -- one issued credit note of 600 with nothing applied (customer credit), and one of 300 for the payment race
  for k in select unnest(array['BIG', 'ZED']) loop
    insert into credit_notes (invoice_id, client_id, division_id, currency, reason_code) select id, client_id, division_id, currency, 'goodwill' from invoices where po_reference = 'CR-BASE' returning id into v_cn;
    insert into credit_note_lines (credit_note_id, description, quantity, unit_price) values (v_cn, 'unapplied ' || k, 1, case k when 'BIG' then 600 else 300 end);
    update credit_notes set status = 'pending_approval' where id = v_cn;
    update credit_notes set status = 'approved' where id = v_cn;
    update credit_notes set status = 'issued', issue_date = current_date, issued_at = now() where id = v_cn;
    if k = 'BIG' then v_big := v_cn; end if;
  end loop;
  insert into payments (client_id, received_account_id, method, amount, currency) values (v_client, v_acct, 'bank_transfer', 300, 'NAD');
end $$;
