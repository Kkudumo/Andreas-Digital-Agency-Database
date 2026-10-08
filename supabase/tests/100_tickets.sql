-- PERMANENT: Tickets on the institutional foundation - identity, references (no copies), origin vs ownership, SLA, comments,
-- escalation, classification, restricted-client behaviour, audit.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('tech_staff2', 'division_staff', 'tech');
create temp table fake as select 'ZZZZZZZZ' || id_check_char('ZZZZZZZZ') as id;
insert into tests.ids values ('x:random', gen_random_uuid());
select tests.check('web staff register an asset-less ticket category-tagged ticket for a client, service and requester',
  (tests.scalar('ceo', format($q$ select add_client_contact(%L, 'Rita Requester', 'rita@abc.example')::text $q$, tests.id('client:abc'))) is not null)::text, 'true');
insert into tests.ids select 'person:rita', id from people where email = 'rita@abc.example';
select tests.mk_asset('web_lead', 'lap', 'Client laptop', 'web', 'Lenovo', 'T-1', null, 'in_stock', 'client:abc', 'project:abc');

-- Identity and registry ------------------------------------------------------------------------------------------------------------------------------
select tests.remember('t:1', tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'Screen flickers', p_description => 'Intermittent', p_asset => %L, p_category => 'hardware', p_requester => %L, p_service => %L, p_channel => 'phone', p_priority => 'high')::text $q$,
   tests.id('asset:lap'), tests.id('person:rita'), tests.id('svc:web'))));
select tests.check('the ticket is a registered entity with a generated institutional ID (and its legacy alias), family operations',
  (select concat_ws('|', (institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$')::text, (ada_id ~ '^ADA-TKT-')::text, entity_family, entity_type, table_name, (origin_division_id = tests.id('div:web'))::text, origin_kind) from entity_registry where entity_id = tests.id('t:1')), 'true|true|operations|ticket|tickets|true|created');
select tests.check('tickets have no ID input and no generator of their own', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'tickets' and column_name ~ 'institutional|ticket_no|number'), 'none');
select tests.check('the ticket type is in the codebook and is never publishable', (select (c.code = t.id_code and not t.publishable)::text from entity_types t join id_codebook c on c.kind = 'type' and c.meaning = t.key where t.key = 'ticket'), 'true');
select tests.check('the publication flag exists and marks the types that may one day be public (and not finance, assets, tickets)',
  (select string_agg(key, ',' order by key) from entity_types where publishable), 'cohort,course,division,document,module,portfolio,profile,programme,service,vacancy');
select tests.check('the ticket resolves through the registry for those who may see it',
  tests.scalar('web_staff', format($q$ select (entity_resolve(%L) ->> 'entity_type') $q$, (select institutional_id from entity_registry where entity_id = tests.id('t:1')))), 'ticket');
select tests.check('...and not for another division', tests.scalar('tech_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = tests.id('t:1')))), 'null');

-- References, not copies ---------------------------------------------------------------------------------------------------------------------------
select tests.check('the ticket REFERENCES requester, client, project, asset, service, category, division by id',
  (select (requester_person_id = tests.id('person:rita') and client_id = tests.id('client:abc') and project_id = tests.id('project:abc') and asset_id = tests.id('asset:lap') and service_id = tests.id('svc:web')
           and category_id = (select id from ticket_categories where key = 'hardware') and division_id = tests.id('div:web') and origin_channel = 'phone')::text from tickets where id = tests.id('t:1')), 'true');
select tests.check('no identity is copied into tickets, comments or events (no name / email / phone columns)',
  (select coalesce(string_agg(table_name || '.' || column_name, ','), 'none') from information_schema.columns where table_schema = 'public' and table_name in ('tickets', 'ticket_comments', 'ticket_events', 'ticket_categories', 'ticket_sla_policies')
    and column_name ~ '(name|email|phone)' and column_name not in ('name')), 'none');
insert into people (full_name, email) values ('Hidden Applicant Person', 'hidden.person@example.test');
insert into tests.ids select 'person:hidden', id from people where email = 'hidden.person@example.test';
select tests.check('requester: a person the creator cannot see behaves like a random id', tests.same_for('web_staff', $q$ select ticket_create(p_title => 'x', p_division => (select id from tests.ids where key = 'div:web'), p_requester => %L)::text $q$, tests.id('person:hidden'), tests.id('x:random')), 'same');
select tests.check('a service the creator cannot see, a website of another division, an unknown category are refused',
  tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'x', p_division => %L, p_service => %L)::text $q$, tests.id('div:web'), tests.id('x:random'))) ||
  tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'x', p_division => %L, p_category => 'spaceships')::text $q$, tests.id('div:web'))), 'ERR:P0002ERR:23514');
select tests.check('the requester''s person record is visible to those who can see the ticket (the relationship carries the privacy)',
  tests.scalar('web_staff', format('select count(*)::text from people where id = %L', tests.id('person:rita'))), '1');
select tests.check('a ticket cannot claim a different client than its asset', tests.scalar('web_staff', format($q$ select ticket_create(p_title => 'x', p_asset => %L, p_client => %L)::text $q$, tests.id('asset:lap'), tests.id('client:C_web'))), 'ERR:23514');
select tests.check('a ticket''s requester and creation time are permanent', tests.try_owner(format('update tickets set requester_person_id = null where id = %L', tests.id('t:1'))) || tests.try_owner(format($q$ update tickets set created_at = now() - interval '9 days' where id = %L $q$, tests.id('t:1'))), 'ERR:42501ERR:42501');

-- SLA ----------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('SLA targets were agreed from the policy for HIGH priority at creation (2h first response, 24h resolution)',
  (select (first_response_due_at = created_at + interval '120 minutes' and resolution_due_at = created_at + interval '1440 minutes' and sla_policy_id is not null)::text from tickets where id = tests.id('t:1')), 'true');
select tests.check('a division-specific policy wins in its division', tests.try('ceo', format($q$ insert into ticket_sla_policies (priority, division_id, first_response_minutes, resolution_minutes) values ('normal', %L, 15, 60) $q$, tests.id('div:tech'))), 'ok');
select tests.remember('t:tech', tests.scalar('tech_lead', format($q$ select ticket_create(p_title => 'Tech normal', p_division => %L)::text $q$, tests.id('div:tech'))));
select tests.check('...so a normal Tech ticket gets 15 / 60 minutes', (select (first_response_due_at = created_at + interval '15 minutes' and resolution_due_at = created_at + interval '60 minutes')::text from tickets where id = tests.id('t:tech')), 'true');
select tests.check('only tickets.configure holders change categories and policies', tests.try('web_lead', $q$ update ticket_sla_policies set resolution_minutes = 1 $q$) || tests.try('web_lead', $q$ insert into ticket_categories (key, name) values ('x', 'x') $q$), 'ok0ERR:42501');
select tests.check('SLA state is derived: not breached now; no stored breach flag exists',
  (select (not first_response_breached and not resolution_breached)::text from ticket_sla_status where ticket_id = tests.id('t:1')) || (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name = 'tickets' and column_name ~ 'breach'), 'truenone');
update tickets set first_response_due_at = now() - interval '1 hour', resolution_due_at = now() - interval '1 minute' where id = tests.id('t:1');
select tests.check('once the targets pass without a response or resolution, the view shows the breach', (select (first_response_breached and resolution_breached and minutes_to_resolution_due < 0)::text from ticket_sla_status where ticket_id = tests.id('t:1')), 'true');
update tickets set first_response_due_at = now() + interval '1 hour', resolution_due_at = now() + interval '1 day' where id = tests.id('t:1');

-- Comments ---------------------------------------------------------------------------------------------------------------------------------------------
select tests.check('an internal note by the handler does not count as a response', tests.try('web_lead', format($q$ select ticket_comment_add(%L, 'Looks like the cable') $q$, tests.id('t:1'))), 'ok');
select tests.check('...no first response yet', (select (first_response_at is null)::text from tickets where id = tests.id('t:1')), 'true');
select tests.check('a comment by the reporter does not count either', tests.try('web_staff', format($q$ select ticket_comment_add(%L, 'It is getting worse', false) $q$, tests.id('t:1'))), 'ok');
select tests.check('...still no first response', (select (first_response_at is null)::text from tickets where id = tests.id('t:1')), 'true');
select tests.check('the first public staff reply is the first response', tests.try('web_lead', format($q$ select ticket_comment_add(%L, 'We are on it', false) $q$, tests.id('t:1'))), 'ok');
select tests.check('...recorded', (select (first_response_at is not null)::text from tickets where id = tests.id('t:1')) || (select count(*)::text from ticket_events where ticket_id = tests.id('t:1') and kind = 'sla'), 'true1');
select tests.check('comments cannot be edited or deleted', tests.try_owner('update ticket_comments set body = ''x''') || tests.try_owner('delete from ticket_comments') || tests.try_owner('delete from ticket_events'), 'ERR:42501ERR:42501ERR:42501');
select tests.check('someone with no access cannot comment (indistinguishable from a missing ticket)', tests.same_for('tech_lead', $q$ select ticket_comment_add(%L, 'probe')::text $q$, tests.id('t:1'), tests.id('x:random')), 'same');

-- Assignment, escalation, priority ----------------------------------------------------------------------------------------------------------------------
select tests.check('web lead assigns it', tests.try('web_lead', format('select ticket_assign(%L, %L)', tests.id('t:1'), tests.id('staff:web_staff'))), 'ok');
select tests.check('priority cannot be changed without a reason, or to itself', tests.scalar('web_lead', format($q$ select ticket_set_priority(%L, 'urgent', ' ')::text $q$, tests.id('t:1'))) || tests.scalar('web_lead', format($q$ select ticket_set_priority(%L, 'high', 'same')::text $q$, tests.id('t:1'))), 'ERR:23514ERR:23514');
select tests.check('raising the priority is an ESCALATION: recorded, and the handlers are notified', tests.try('web_lead', format($q$ select ticket_set_priority(%L, 'urgent', 'Client is blocked') $q$, tests.id('t:1'))), 'ok');
select tests.check('...event, notification', (select count(*)::text from ticket_events where ticket_id = tests.id('t:1') and kind = 'escalation' and from_value = 'high' and to_value = 'urgent') || (select (count(*) > 0)::text from notifications where type = 'ticket.escalated'), '1true');
select tests.check('...and the SLA targets were re-derived from the creation time (urgent: 30 min / 8 h)', (select (first_response_due_at = created_at + interval '30 minutes' and resolution_due_at = created_at + interval '480 minutes')::text from tickets where id = tests.id('t:1')), 'true');
select tests.check('lowering is a plain priority change, not an escalation', tests.try('web_lead', format($q$ select ticket_set_priority(%L, 'normal', 'Workaround found') $q$, tests.id('t:1'))), 'ok');
select tests.check('...recorded as a priority event', (select count(*)::text from ticket_events where ticket_id = tests.id('t:1') and kind = 'priority'), '1');
select tests.check('a staff member of another division cannot change priority (indistinguishable from a missing ticket)', tests.same_for('tech_staff', $q$ select ticket_set_priority(%L, 'low', 'x')::text $q$, tests.id('t:1'), tests.id('x:random')), 'same');

-- Origin vs ownership: transfer ----------------------------------------------------------------------------------------------------------------------------
create temp table before_t as select institutional_id i, origin_division_id o from entity_registry where entity_id = tests.id('t:1');
select tests.check('web staff cannot transfer', tests.scalar('web_staff', format($q$ select ticket_transfer(%L, %L, 'x')::text $q$, tests.id('t:1'), tests.id('div:tech'))), 'ERR:42501');
select tests.check('a lead cannot hand a ticket to a division where they hold no ticket rights', tests.scalar('web_lead', format($q$ select ticket_transfer(%L, %L, 'Needs Tech')::text $q$, tests.id('t:1'), tests.id('div:tech'))), 'ERR:42501');
select tests.check('the division cannot be changed any other way (owner)', tests.try_owner(format('update tickets set division_id = %L where id = %L', tests.id('div:tech'), tests.id('t:1'))), 'ERR:42501');
select tests.check('management transfers it to Tech (reason required)', tests.scalar('ceo', format($q$ select ticket_transfer(%L, %L, ' ')::text $q$, tests.id('t:1'), tests.id('div:tech'))), 'ERR:23514');
select tests.check('...with a reason', tests.try('ceo', format($q$ select ticket_transfer(%L, %L, 'Network issue: Tech owns it') $q$, tests.id('t:1'), tests.id('div:tech'))), 'ok');
select tests.check('the permanent ID and the ORIGIN division are unchanged; the current division and ownership moved; the assignee was cleared',
  (select (r.institutional_id = b.i and r.origin_division_id = b.o and r.origin_division_id = tests.id('div:web') and r.current_division_id = tests.id('div:tech') and t.division_id = tests.id('div:tech') and t.assignee_staff_id is null)::text
   from entity_registry r, before_t b, tickets t where r.entity_id = tests.id('t:1') and t.id = r.entity_id), 'true');
select tests.check('the movement is on record in both histories', (select count(*)::text from ticket_events where ticket_id = tests.id('t:1') and kind = 'transfer') || (select string_agg(coalesce((select key from divisions where id = to_division_id), '-'), '>' order by id) from entity_location_history where institutional_id = (select i from before_t)), '1web>tech');
select tests.check('Web''s lead no longer sees it, Tech''s does, and the reporter still does',
  tests.scalar('web_lead', format('select count(*)::text from tickets where id = %L', tests.id('t:1'))) || tests.scalar('tech_lead', format('select count(*)::text from tickets where id = %L', tests.id('t:1'))) || tests.scalar('web_staff', format('select count(*)::text from tickets where id = %L', tests.id('t:1'))), '011');
select tests.check('the reporter (no longer in the handling division) sees the public conversation but NOT the internal notes',
  tests.scalar('web_staff', format('select (select count(*) from ticket_comments where ticket_id = %L and is_internal)::text || (select count(*) from ticket_comments where ticket_id = %L and not is_internal)', tests.id('t:1'), tests.id('t:1'))), '02');
select tests.check('...and the handlers see everything', tests.scalar('tech_lead', format('select (select count(*) from ticket_comments where ticket_id = %L)::text', tests.id('t:1'))), '3' );
select tests.check('the reporter may still add a public comment but not an internal note',
  tests.try('web_staff', format($q$ select ticket_comment_add(%L, 'Thanks', false) $q$, tests.id('t:1'))), 'ok');
select tests.check('...but not an internal note', tests.scalar('web_staff', format($q$ select ticket_comment_add(%L, 'secret', true)::text $q$, tests.id('t:1'))), 'ERR:42501');

-- Lifecycle through to closure ------------------------------------------------------------------------------------------------------------------------
select tests.check('resolving needs a note, and a resolved ticket is not "breached" if it met its target', tests.scalar('tech_lead', format($q$ select ticket_transition(%L, 'resolved')::text $q$, tests.id('t:1'))), 'ERR:23514');
select tests.scalar('tech_lead', format($q$ select ticket_transition(%L, 'resolved', 'Router replaced')::text $q$, tests.id('t:1')));
select tests.check('...resolved before the target: no resolution breach', (select (not resolution_breached)::text from ticket_sla_status where ticket_id = tests.id('t:1')), 'true');
select tests.scalar('tech_lead', format($q$ select ticket_transition(%L, 'closed')::text $q$, tests.id('t:1')));
select tests.check('a closed ticket takes no more comments, priority changes or transfers',
  tests.scalar('tech_lead', format($q$ select ticket_comment_add(%L, 'late')::text $q$, tests.id('t:1'))) || tests.scalar('tech_lead', format($q$ select ticket_set_priority(%L, 'low', 'x')::text $q$, tests.id('t:1'))) || tests.scalar('ceo', format($q$ select ticket_transfer(%L, %L, 'x')::text $q$, tests.id('t:1'), tests.id('div:web'))), 'ERR:23514ERR:23514ERR:23514');
select tests.check('the full history is on record, in order', (select string_agg(kind || ':' || coalesce(to_value, '-'), ' > ' order by id) from ticket_events where ticket_id = tests.id('t:1') and kind <> 'comment'),
  'created:open > sla:first_response > assignment:' || tests.id('staff:web_staff')::text || ' > escalation:urgent > priority:normal > transfer:' || tests.id('div:tech')::text || ' > status:resolved > status:closed');

-- Predicates must never return NULL (plpgsql treats NULL as "not true", so a NULL in a denial test means "allowed") --------------------------------------
create function pg_temp.null_visibility() returns text language plpgsql as $$
declare r record; n bigint; bad text[] := '{}';
begin
  for r in select * from (values ('can_view_ticket', 'tickets'), ('can_view_asset', 'assets'), ('can_view_client', 'clients'), ('can_edit_client', 'clients'), ('can_view_project', 'projects'), ('can_edit_project', 'projects'),
      ('can_view_contract', 'contracts'), ('can_view_invoice', 'invoices'), ('can_view_payment', 'payments'), ('can_view_quote', 'quotes'), ('can_view_service', 'services'), ('can_view_student', 'students'),
      ('can_view_person', 'people'), ('can_edit_person', 'people'), ('can_work_ticket', 'tickets'), ('can_edit_asset', 'assets')) v(f, t) loop
    execute format('select count(*) from %I where %I(id) is null', r.t, r.f) into n;
    if n > 0 then bad := bad || r.f::text; end if;
  end loop;
  return case when cardinality(bad) = 0 then 'none' else array_to_string(bad, ',') end;
end $$;
select tests.check('no access predicate returns NULL for any row, as the owner', pg_temp.null_visibility(), 'none');
select tests.check('...nor for an unprivileged login, a division staff member, a recruiter or a login with no staff record',
  (select string_agg(tests.scalar(u, 'select (select count(*) from tickets where can_view_ticket(id) is null)::text || (select count(*) from tickets where can_work_ticket(id) is null) || (select count(*) from assets where can_view_asset(id) is null) || (select count(*) from clients where can_view_client(id) is null) || (select count(*) from projects where can_view_project(id) is null)'), ',' order by u) from unnest(array['outsider', 'recruiter', 'tech_staff', 'web_staff']) u), '00000,00000,00000,00000');

-- Restricted clients ----------------------------------------------------------------------------------------------------------------------------------------
select tests.remember('client:R', tests.mkclient_id('ceo', 'Secret Ticket Holdings'));
update clients set classification = 'restricted' where id = tests.id('client:R');
select tests.remember('t:R', tests.scalar('ceo', format($q$ select ticket_create(p_title => 'Secret ticket', p_division => %L, p_client => %L, p_requester => %L)::text $q$, tests.id('div:web'), tests.id('client:R'), tests.id('person:rita'))));
select tests.check('a ticket for a restricted client inherits the restriction and is invisible to ordinary users',
  (select effective_classification::text from tickets where id = tests.id('t:R')) || tests.scalar('web_lead', format('select (select count(*) from tickets where id = %L)::text || (select count(*) from ticket_events where ticket_id = %L) || (select count(*) from ticket_comments where ticket_id = %L) || (select count(*) from ticket_sla_status where ticket_id = %L)', tests.id('t:R'), tests.id('t:R'), tests.id('t:R'), tests.id('t:R'))), 'restricted0000');
select tests.check('probes: ticket_assign', tests.same_for('web_lead', $q$ select ticket_assign(%L, (select id from tests.ids where key = 'staff:web_staff'))::text $q$, tests.id('t:R'), tests.id('x:random')), 'same');
select tests.check('probes: ticket_transition', tests.same_for('web_lead', $q$ select ticket_transition(%L, 'in_progress')::text $q$, tests.id('t:R'), tests.id('x:random')), 'same');
select tests.check('probes: ticket_comment_add', tests.same_for('web_lead', $q$ select ticket_comment_add(%L, 'probe')::text $q$, tests.id('t:R'), tests.id('x:random')), 'same');
select tests.check('probes: ticket_set_priority', tests.same_for('web_lead', $q$ select ticket_set_priority(%L, 'urgent', 'probe')::text $q$, tests.id('t:R'), tests.id('x:random')), 'same');
select tests.check('probes: ticket_transfer', tests.same_for('web_lead', $q$ select ticket_transfer(%L, (select id from tests.ids where key = 'div:tech'), 'probe')::text $q$, tests.id('t:R'), tests.id('x:random')), 'same');
select tests.check('probes: ticket_create for the restricted client', tests.same_for('web_lead', $q$ select ticket_create(p_title => 'probe', p_division => (select id from tests.ids where key = 'div:web'), p_client => %L)::text $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('probes: reads by client and by requester', tests.same_for('web_lead', $q$ select count(*)::text from tickets where client_id = %L $q$, tests.id('client:R'), tests.id('x:random')), 'same');
select tests.check('probes: can_view_ticket and the registry', tests.same_for('web_lead', $q$ select can_view_ticket(%L)::text $q$, tests.id('t:R'), tests.id('x:random')) || tests.outcome('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') $q$, (select institutional_id from entity_registry where entity_id = tests.id('t:R')))), 'sameok:null');
select tests.check('control: management sees it and resolves it', tests.scalar('ceo', format('select count(*)::text from tickets where id = %L', tests.id('t:R'))), '1');
select tests.check('ticket tables carry no public/publication state: tickets never cross the public boundary', (select coalesce(string_agg(column_name, ','), 'none') from information_schema.columns where table_name in ('tickets', 'ticket_comments', 'ticket_events') and column_name ~ '(public|publish)'), 'none');
select tests.check('the registry mirrors the ticket (status, division, classification)', (select count(*)::text from entity_registry r join tickets t on t.id = r.entity_id and r.table_name = 'tickets' where (r.status, r.current_division_id, r.classification) is distinct from (t.status::text, t.division_id, t.effective_classification)), '0');
select tests.check('ticket history and lifecycle are audited', (select (count(*) filter (where table_name = 'tickets') > 3 and count(*) filter (where table_name = 'ticket_comments') >= 3)::text from audit_log where table_name in ('tickets', 'ticket_comments')), 'true');

select tests.finish();
rollback;
