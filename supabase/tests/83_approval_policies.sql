-- Configurable approvals: self-approval is a recorded, policy-controlled exception - never a hardcoded privilege.
begin;
select tests.setup();
select tests.setup_hr();

-- two services to price
select tests.remember('svc:a', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Policy Service A', 's', 'd' from divisions where key = 'web' returning id::text $q$));
select tests.remember('svc:b', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Policy Service B', 's', 'd' from divisions where key = 'web' returning id::text $q$));

-- Default policy: a SOLE approver may approve their own request - and it is recorded ------------------------------------
select tests.check('default policies exist for price changes, quotes, contracts, invoices and payment reversals/refunds', (select string_agg(kind, ',' order by kind) from approval_policies), 'contract,invoice,payment_reversal,price_change,quote,refund');
select tests.check('the CEO proposes a price (CEO holds pricing.propose)', tests.try('ceo', $q$ select price_propose((select id from tests.ids where key = 'svc:a'), 1000, 'NAD', current_date, 'first price') $q$), 'ok');
insert into tests.ids select 'price:a1', id from service_prices where service_id = tests.id('svc:a');
select tests.check('while the CEO is the only qualified approver, the CEO may approve their own price',
  tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:a1'), true)).status::text $q$), 'approved');
select tests.check('the self-approval is recorded on the request', (select self_approved::text from approval_requests where entity_id = tests.id('price:a1')), 'true');
select tests.check('...and on the individual decision', (select is_self::text from approval_decisions d join approval_requests r on r.id = d.request_id where r.entity_id = tests.id('price:a1')), 'true');
select tests.check('an ordinary approval is NOT marked as self-approval', (select count(*)::text from approval_requests where self_approved and entity_id <> tests.id('price:a1')), '0');

-- A second qualified approver appears: separation of duties becomes mandatory with NO configuration change ---------------
insert into roles (key, name) values ('second_approver', 'Second pricing approver');
insert into role_permissions (role_id, permission_id) select r.id, p.id from roles r, permissions p where r.key = 'second_approver' and p.key = 'pricing.approve';
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'admin@ada.test' and r.key = 'second_approver';
select tests.check('the CEO proposes another price', tests.try('ceo', $q$ select price_propose((select id from tests.ids where key = 'svc:b'), 2000, 'NAD', current_date, 'second') $q$), 'ok');
insert into tests.ids select 'price:b1', id from service_prices where service_id = tests.id('svc:b');
select tests.check('now that another qualified approver exists, the CEO can no longer approve their own request',
  tests.try_msg('ceo', $q$ select price_decide((select id from tests.ids where key = 'price:b1'), true) $q$), '42501: you cannot decide your own request: another qualified approver exists, so separation of duties applies');
select tests.check('the second approver can', tests.scalar('admin', $q$ select (price_decide((select id from tests.ids where key = 'price:b1'), true)).status::text $q$), 'approved');
select tests.check('that approval is not a self-approval', (select self_approved::text from approval_requests where entity_id = tests.id('price:b1')), 'false');

-- Policy switches: allow_self_approval = false means never ---------------------------------------------------------------------
update approval_policies set allow_self_approval = false where kind = 'price_change';
update staff_roles set staff_id = staff_id where false;
delete from staff_roles where role_id = (select id from roles where key = 'second_approver');           -- back to a sole approver
select tests.remember('svc:c', tests.scalar('web_lead', $q$ insert into services (division_id, name, summary, description) select id, 'Policy Service C', 's', 'd' from divisions where key = 'web' returning id::text $q$));
select tests.try('ceo', $q$ select price_propose((select id from tests.ids where key = 'svc:c'), 3000, 'NAD', current_date, 'third') $q$);
insert into tests.ids select 'price:c1', id from service_prices where service_id = tests.id('svc:c');
select tests.check('with allow_self_approval = false even a sole approver cannot approve their own request',
  tests.try_msg('ceo', $q$ select price_decide((select id from tests.ids where key = 'price:c1'), true) $q$), '42501: you cannot decide your own request: separation of duties applies');
select tests.check('...nor reject their own request', tests.try('ceo', $q$ select price_decide((select id from tests.ids where key = 'price:c1'), false, 'no') $q$), 'ERR:42501');
update approval_policies set allow_self_approval = true where kind = 'price_change';

-- Several approvers, thresholds, division scope ---------------------------------------------------------------------------------
insert into roles (key, name) values ('quote_approver', 'Quote approver');
insert into role_permissions (role_id, permission_id) select r.id, p.id from roles r, permissions p where r.key = 'quote_approver' and p.key = 'quotes.approve';
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'admin@ada.test' and r.key = 'quote_approver';
insert into approval_policies (kind, min_amount, required_permission, allow_self_approval, min_approvers, note) values ('quote', 10000, 'quotes.approve', false, 2, 'large quotes need two approvers');

-- a client to quote (created directly as trusted setup; client creation rules are tested elsewhere)
insert into clients (name, owner_division_id) select 'Policy Client', id from divisions where key = 'web';
insert into tests.ids select 'client:pol', id from clients where name = 'Policy Client';
select tests.remember('q:big', tests.scalar('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:pol'), (select id from tests.ids where key = 'div:web'), 'Large quote')::text $q$));
select tests.scalar('web_lead', $q$ select quote_add_line((select id from tests.ids where key = 'q:big'), (select id from tests.ids where key = 'svc:a'), 12)::text $q$);
select tests.check('submit a quote worth N$12,000', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:big'), 'pending_approval')::text $q$), 'pending_approval');

select tests.check('policy lookup by amount: small quotes use the default (1 approver), large ones the threshold rule (2)',
  (select (approval_policy('quote', tests.id('div:web'), 500)).min_approvers::text || (approval_policy('quote', tests.id('div:web'), 12000)).min_approvers::text), '12');
select tests.check('a quote over the threshold needs two approvers: the first approval is recorded but the quote stays pending',
  tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'q:big'), 'approved')::text $q$), 'pending_approval');
select tests.check('...the status really is still pending', (select status::text from quotes where id = tests.id('q:big')), 'pending_approval');
select tests.check('...with one approval on record and two required', (select count(*)::text || '/' || max(r.required_approvals)::text from approval_decisions d join approval_requests r on r.id = d.request_id where r.entity_id = tests.id('q:big') and d.decision = 'approve'), '1/2');
select tests.check('the same approver cannot approve twice', tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'q:big'), 'approved')::text $q$), 'ERR:23505');
select tests.check('the preparer, who holds no approval permission, cannot supply the second approval', tests.scalar('web_lead', $q$ select quote_transition((select id from tests.ids where key = 'q:big'), 'approved')::text $q$), 'ERR:42501');
select tests.check('a second qualified approver completes it', tests.scalar('admin', $q$ select quote_transition((select id from tests.ids where key = 'q:big'), 'approved')::text $q$), 'approved');
select tests.check('the queue entry closes as approved with both decisions kept',
  (select status::text || '/' || (select count(*) from approval_decisions where request_id = r.id) from approval_requests r where r.entity_id = tests.id('q:big')), 'approved/2');

update approval_policies set min_approvers = 3 where kind = 'quote' and min_amount = 10000;
select tests.scalar('web_lead', $q$ select quote_create((select id from tests.ids where key = 'client:pol'), (select id from tests.ids where key = 'div:web'), 'Another large quote')::text $q$);
select tests.scalar('web_lead', $q$ select quote_add_line((select id from quotes where title = 'Another large quote'), (select id from tests.ids where key = 'svc:a'), 20)::text $q$);
select tests.scalar('web_lead', $q$ select quote_transition((select id from quotes where title = 'Another large quote'), 'pending_approval')::text $q$);
select tests.check('...refused with a clear message', tests.try_msg('ceo', $q$ select quote_transition((select id from quotes where title = 'Another large quote'), 'approved') $q$), '23514: policy requires 3 approvers but only 2 qualified approver(s) exist');
update approval_policies set min_approvers = 2 where kind = 'quote' and min_amount = 10000;

-- Division scope and deactivation -------------------------------------------------------------------------------------------------------
insert into approval_policies (kind, division_id, required_permission, allow_self_approval, min_approvers, note)
  select 'quote', id, 'quotes.approve', false, 2, 'every Web quote needs two approvers' from divisions where key = 'web';
select tests.check('a division-specific policy outranks the generic one',
  (select (approval_policy('quote', tests.id('div:web'), 500)).min_approvers::text || (approval_policy('quote', tests.id('div:tech'), 500)).min_approvers::text), '21');
update approval_policies set is_active = false where division_id is not null;
select tests.check('a deactivated policy is ignored', (select (approval_policy('quote', tests.id('div:web'), 500)).min_approvers::text), '1');

-- Self-approval of a QUOTE follows the same rule, and is recorded -------------------------------------------------------------------------
delete from staff_roles where role_id = (select id from roles where key = 'quote_approver');
select tests.remember('q:own', tests.scalar('ceo', $q$ select quote_create((select id from tests.ids where key = 'client:pol'), (select id from tests.ids where key = 'div:web'), 'CEO quote')::text $q$));
select tests.scalar('ceo', $q$ select quote_add_line((select id from tests.ids where key = 'q:own'), null, 1, 500, null, 'Consulting')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'q:own'), 'pending_approval')::text $q$);
select tests.check('a sole approver may approve their own small quote', tests.scalar('ceo', $q$ select quote_transition((select id from tests.ids where key = 'q:own'), 'approved')::text $q$), 'approved');
select tests.check('...and it is flagged as self-approved for later review', (select self_approved::text from approval_requests where entity_id = tests.id('q:own')), 'true');
insert into staff_roles (staff_id, role_id) select s.id, r.id from staff s, roles r where s.email = 'admin@ada.test' and r.key = 'quote_approver';
select tests.scalar('ceo', $q$ select quote_create((select id from tests.ids where key = 'client:pol'), (select id from tests.ids where key = 'div:web'), 'CEO quote 2')::text $q$);
select tests.scalar('ceo', $q$ select quote_add_line((select id from quotes where title = 'CEO quote 2'), null, 1, 500, null, 'Consulting')::text $q$);
select tests.scalar('ceo', $q$ select quote_transition((select id from quotes where title = 'CEO quote 2'), 'pending_approval')::text $q$);
select tests.check('once a second approver exists, the same CEO cannot approve their own quote',
  tests.scalar('ceo', $q$ select quote_transition((select id from quotes where title = 'CEO quote 2'), 'approved')::text $q$), 'ERR:42501');

-- Rejection ------------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('price:rej', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:a'), 1500, 'NAD', current_date + 5, 'rise')::text $q$));
select tests.check('an approver rejects with a note', tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'price:rej'), false, 'too soon')).status::text $q$), 'rejected');
select tests.check('the rejection is a recorded decision', (select d.decision || ':' || coalesce(d.note, '') from approval_decisions d join approval_requests r on r.id = d.request_id where r.entity_id = tests.id('price:rej')), 'reject:too soon');
select tests.check('decisions are append-only', tests.try_owner($q$ update approval_decisions set decision = 'approve' $q$) || tests.try_owner($q$ delete from approval_decisions $q$), 'ERR:42501ERR:42501');

-- Who may configure policy ---------------------------------------------------------------------------------------------------------------------------
select tests.check('ordinary staff cannot read the policies', tests.scalar('web_lead', 'select count(*)::text from approval_policies'), '0');
select tests.check('administration (no approvals.configure) cannot change them', tests.try('admin', $q$ update approval_policies set allow_self_approval = true $q$) || tests.scalar('admin', $q$ with u as (update approval_policies set allow_self_approval = true returning 1) select count(*)::text from u $q$), 'ok00');
select tests.check('only management can add a policy', tests.try('web_lead', $q$ insert into approval_policies (kind, required_permission) values ('quote', 'quotes.approve') $q$), 'ERR:42501');
select tests.check('a policy must name a real permission', tests.try('ceo', $q$ insert into approval_policies (kind, required_permission, min_amount) values ('expense', 'made.up', 100) $q$), 'ERR:23514');
select tests.check('management can add a threshold policy for a future kind', tests.try('ceo', $q$ insert into approval_policies (kind, min_amount, required_permission, min_approvers, allow_self_approval) values ('expense', 5000, 'finance.approve', 2, false) $q$), 'ok');
select tests.check('policies cannot be deleted - deactivate instead', tests.try('ceo', $q$ delete from approval_policies $q$), 'ERR:42501');
select tests.check('policy changes are audited with the actor', (select count(*)::text from audit_log where table_name = 'approval_policies' and new_data ->> 'kind' = 'expense' and actor_ada_id = (select ada_id from staff where email = 'ceo@ada.test') and action = 'INSERT'), '1');
select tests.check('the gate itself is not callable by users', tests.try('ceo', $q$ select approval_gate('quote', 'quotes', gen_random_uuid(), null, 1, null, 'quotes.approve', true, null) $q$), 'ERR:42501');

select tests.finish();
rollback;
