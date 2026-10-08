-- Pre-0038 data: clients and suppliers as they existed before organizations (no organization_id column yet).
insert into clients (name, registration_number, created_at) values
  ('Legacy Alpha (Pty) Ltd', 'LA-1', now() - interval '500 days'), ('Legacy Beta', 'LB-1', now() - interval '480 days'), ('Legacy Gamma', null, now() - interval '470 days'),
  ('Totally Other Name', 'LD-9', now() - interval '460 days');
insert into clients (name, created_at, updated_at, deleted_at, deletion_reason) values ('Legacy Alpha', now() - interval '450 days', now() - interval '300 days', now() - interval '440 days', 'closed');
insert into clients (name, classification) values ('Hidden Hotel', 'confidential');
insert into suppliers (name, registration_number, created_at) values
  ('LEGACY ALPHA', 'la-1', now() - interval '400 days'), ('Legacy Beta Ltd', 'LB-2', now() - interval '390 days'), ('Legacy Gamma', null, now() - interval '380 days'),
  ('Legacy Delta Traders', 'LD-9', now() - interval '370 days'), ('Hidden Hotel', null, now() - interval '360 days'),
  ('Legacy Sigma Works', 'SW-1', now() - interval '355 days'), ('Legacy Sigma Workz', 'sw-1', now() - interval '350 days');
