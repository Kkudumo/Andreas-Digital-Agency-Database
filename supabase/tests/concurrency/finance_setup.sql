-- Owner-level fixture for the parallel allocation test (scripts/test-db.sh). Not run by the normal suite glob.
do $$
declare
  v_client uuid; v_div uuid; v_acct uuid; v_bi uuid; v_inv uuid; i integer;
begin
  select id into v_div from divisions where key = 'web';
  insert into clients (name) values ('Concurrency Client') returning id into v_client;
  insert into bank_accounts (name, bank_name, currency) values ('Concurrency account', 'FNB', 'NAD') returning id into v_acct;
  -- nine issued invoices of 1000: i1..i8 race for one payment; i9 is paid in small slices by many sessions
  for i in 1..9 loop
    insert into billable_items (client_id, division_id, source, description, quantity, unit_price, currency, manual_reason)
    values (v_client, v_div, 'manual', 'conc ' || i, 1, 1000, 'NAD', 'concurrency test') returning id into v_bi;
    insert into invoices (client_id, division_id, currency) values (v_client, v_div, 'NAD') returning id into v_inv;
    insert into invoice_lines (invoice_id, billable_item_id, description, quantity, unit_price) values (v_inv, v_bi, 'conc ' || i, 1, 1000);
    update billable_items set status = 'invoiced' where id = v_bi;
    update invoices set status = 'pending_approval' where id = v_inv;
    update invoices set status = 'approved' where id = v_inv;
    update invoices set status = 'issued', issue_date = current_date, due_date = current_date + 30 where id = v_inv;
  end loop;
  insert into payments (client_id, received_account_id, method, amount, currency) values (v_client, v_acct, 'bank_transfer', 1000, 'NAD');   -- the contested payment
  for i in 1..14 loop                                               -- fourteen payments of 100 racing to settle the ninth invoice (1000)
    insert into payments (client_id, received_account_id, method, amount, currency) values (v_client, v_acct, 'bank_transfer', 100, 'NAD');
  end loop;
end $$;
