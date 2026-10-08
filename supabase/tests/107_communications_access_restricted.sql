-- PERMANENT: Communications - authorization per action, METADATA vs CONTENT, classification inheritance, restricted and critical NON-DISCLOSURE
-- (counts, lookups, errors, relationships, participants, attachments, registry, search, audit, security records, public API), bypass attempts,
-- registry consistency and definite predicates.
begin;
select tests.setup();
select tests.setup_hr();
select tests.finance_world();
select tests.add_staff('adm2', 'administration_officer');
insert into tests.ids values ('x:random', gen_random_uuid());
create temp table cids as select (select institutional_id from entity_registry where entity_id = tests.id('contact:john')) as john, (select institutional_id from entity_registry where entity_id = tests.id('client:abc')) as abc;

-- The action matrix ------------------------------------------------------------------------------------------------------------------------------------
select tests.mk_thread('ceo', 'm', 'Matrix thread');
select tests.say('ceo', 'm', 'm1', 'email', 'inbound', 'Matrix body');
select tests.check('view read attachment append edit comment share archive: the CEO', tests.cacts('ceo', 'thr:m'), '11111111');
select tests.check('...administration', tests.cacts('adm2', 'thr:m'), '11111111');
select tests.check('...the web lead (their division)', tests.cacts('web_lead', 'thr:m'), '11111111');
select tests.check('...division staff (their division: no edit, share or archive)', tests.cacts('web_staff', 'thr:m'), '11110100');
select tests.check('...finance and the auditor: METADATA only', tests.cacts('fin', 'thr:m') || tests.cacts('audit', 'thr:m'), '1000000010000000');
select tests.check('...another division, the recruiter, an outsider and a suspended account: nothing', tests.cacts('tech_staff', 'thr:m') || tests.cacts('tech_lead', 'thr:m') || tests.cacts('recruiter', 'thr:m') || tests.cacts('outsider', 'thr:m') || tests.cacts('suspended', 'thr:m'), repeat('00000000', 5));

-- METADATA is not CONTENT ---------------------------------------------------------------------------------------------------------------------------------
select tests.check('finance can DISCOVER the thread and its messages (type, direction, time, status) - that is all',
  tests.scalar('fin', format($q$ select (select count(*) from communication_threads where id = %L)::text || (select count(*) from communication_messages where thread_id = %L)::text || (select string_agg(type_key || direction, ',') from communication_messages where thread_id = %L) $q$, tests.id('thr:m'), tests.id('thr:m'), tests.id('thr:m'))), '11emailinbound');
select tests.check('...but the subject, bodies, hashes, source references, participants and notes are not granted to table readers at all (column privileges)',
  tests.scalar('fin', 'select subject::text from communication_threads limit 1') || tests.scalar('fin', 'select body from communication_messages limit 1') || tests.scalar('fin', 'select body_hash from communication_messages limit 1') ||
  tests.scalar('fin', 'select source_reference from communication_messages limit 1') || tests.scalar('fin', 'select count(*)::text from communication_participants') || tests.scalar('fin', 'select count(*)::text from communication_comments') ||
  tests.scalar('fin', 'select count(*)::text from (select * from communication_messages) x') || tests.scalar('fin', 'select count(*)::text from (select * from communication_threads) x'), repeat('ERR:42501', 8));
select tests.check('...the same for people WITH the content right: content leaves the database only through communication_read (which logs it)',
  tests.scalar('ceo', 'select body from communication_messages limit 1') || tests.scalar('web_lead', 'select subject::text from communication_threads limit 1') || tests.scalar('adm2', 'select count(*)::text from communication_participants'), 'ERR:42501ERR:42501ERR:42501');
select tests.check('communication_read answers the person who may read, with subject, body, hash and the participants - and logs the read', tests.scalar('web_staff', format($q$ select (communication_read(%L) -> 'messages' -> 0 ->> 'body') $q$, tests.id('thr:m'))), 'Matrix body');
select tests.check('...and a metadata-only reader gets null, exactly as for a thread that does not exist',
  tests.same_for('fin', $q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:m'), tests.id('x:random')), 'same');
select tests.check('...and both denials are recorded for investigators (the real one with the real identifier, as the established security model does)', (select count(*)::text || '|' || count(*) filter (where entity_exists)::text from security_events where actor_staff_id = tests.id('staff:fin') and requested_action = 'communication.read'), '2|1');
select tests.check('the CEO''s reads and the web staff member''s are logged without content', (select string_agg(coalesce((select ada_id from staff where id = actor_staff_id), '-') || ':' || (detail ->> 'messages'), ',' order by id) from communication_events where thread_id = tests.id('thr:m') and kind = 'read'),
  (select (select ada_id from staff where id = tests.id('staff:web_staff')) || ':1'));
select tests.check('finance does not see the read log either (it is for those who may audit or administer the thread)', tests.scalar('fin', format($q$ select count(*)::text from communication_events where thread_id = %L and kind = 'read' $q$, tests.id('thr:m'))) || tests.scalar('web_lead', format($q$ select count(*)::text from communication_events where thread_id = %L and kind = 'read' $q$, tests.id('thr:m'))), '01');
select tests.check('the 360 of the thread says what the caller may do but carries no content, for anyone', tests.scalar('fin', format($q$ select (communication_360(%L) -> 'access' ->> 'can_read') || ((communication_360(%L)::text) ~* 'Matrix body|Matrix thread')::text $q$, tests.id('thr:m'), tests.id('thr:m'))), 'falsefalse');
select tests.mk_thread('ceo', 'pp', 'Who took part');
select tests.say('ceo', 'pp', 'pp1', 'email', 'inbound', 'Participant body', format('[{"role":"from","entity":"%s"}]', (select john from cids))::jsonb);
select tests.check('participants are content: finance (metadata only) cannot find a thread by the contact who took part; nor can the participant helper be used to list them; the web staff member (who may read) finds it',
  tests.scalar('fin', format($q$ select jsonb_array_length(communications_for_entity(%L))::text $q$, (select john from cids))) || tests.scalar('fin', format($q$ select count(*)::text from communication_participant_hits(array[%L]) $q$, (select john from cids))) ||
  tests.scalar('web_staff', format($q$ select jsonb_array_length(communications_for_entity(%L))::text $q$, (select john from cids))), '001');

-- Explicit grants add to the model; they never override classification -----------------------------------------------------------------------------------
select tests.check('sharing needs a reason and communications.share; only view / read / attachment / comment can be granted; nobody can be given more than that',
  tests.scalar('web_staff', format($q$ select communication_share(%L, %L, null, array['read'], null, 'x')::text $q$, tests.id('thr:m'), tests.id('staff:fin'))) || tests.scalar('adm2', format($q$ select communication_share(%L, %L, null, array['read'], null, null)::text $q$, tests.id('thr:m'), tests.id('staff:fin'))) ||
  tests.scalar('adm2', format($q$ select communication_share(%L, %L, null, array['append'], null, 'x')::text $q$, tests.id('thr:m'), tests.id('staff:fin'))) || tests.scalar('adm2', format($q$ select communication_share(%L, %L, %L, array['read'], null, 'x')::text $q$, tests.id('thr:m'), tests.id('staff:fin'), tests.id('div:web'))), 'ERR:42501ERR:23514ERR:23514ERR:23514');
select tests.remember_ok('grant:fin', tests.scalar('adm2', format($q$ select communication_share(%L, %L, null, array['read', 'attachment'], now() + interval '1 day', 'finance reviews the dispute')::text $q$, tests.id('thr:m'), tests.id('staff:fin'))));
select tests.check('with a grant the finance officer can now read this thread (and only this thread), and the read is logged', tests.cacts('fin', 'thr:m') || tests.scalar('fin', format($q$ select (communication_read(%L) -> 'messages' -> 0 ->> 'body') $q$, tests.id('thr:m'))) || tests.cacts('fin', 'thr:pp'), '11100000Matrix body10000000');
select tests.check('...the grant is visible to those who may share, not to the grantee', tests.scalar('adm2', format($q$ select count(*)::text from communication_access where thread_id = %L $q$, tests.id('thr:m'))) || tests.scalar('fin', format($q$ select count(*)::text from communication_access where thread_id = %L $q$, tests.id('thr:m'))), '10');
select tests.check('a grant can only be revoked (not edited or deleted), and revoking returns the person to metadata only',
  tests.try_owner(format($q$ update communication_access set actions = array['view','read','comment'] where id = %L $q$, tests.id('grant:fin'))) || tests.try_owner(format($q$ delete from communication_access where id = %L $q$, tests.id('grant:fin'))) ||
  tests.try('adm2', format($q$ select communication_unshare(%L, 'dispute over') $q$, tests.id('grant:fin'))), 'ERR:42501ERR:42501ok');
select tests.check('...revoked', tests.cacts('fin', 'thr:m'), '10000000');
select tests.mk_thread('ceo', 'g', 'Grant to the Tech lead');
select tests.say('ceo', 'g', 'g1', 'email', 'inbound', 'Grant body');
select tests.remember_ok('grant:tl', tests.scalar('ceo', format($q$ select communication_share(%L, %L, null, array['read'], now() + interval '1 day', 'cross-division help')::text $q$, tests.id('thr:g'), tests.id('staff:tech_lead'))));
select tests.check('a grant works across divisions: the Tech lead reads a Web thread (and the grant gave them view with it)', tests.cacts('tech_lead', 'thr:g'), '11000000');
select tests.check('an expired grant grants nothing', tests.try_owner(format($q$ alter table communication_access disable trigger communication_access_guard_trg; update communication_access set expires_at = now() - interval '1 minute' where id = %L; alter table communication_access enable trigger communication_access_guard_trg $q$, tests.id('grant:tl'))) || tests.cacts('tech_lead', 'thr:g'), 'ok00000000');

-- Restricted client: the thread inherits and disappears for the uncleared ----------------------------------------------------------------------------------
select tests.mk_thread('web_lead', 'rc', 'Restricted client correspondence');
select tests.say('web_lead', 'rc', 'rc1', 'email', 'inbound', 'Highly sensitive client matter', format('[{"role":"from","entity":"%s"}]', (select john from cids))::jsonb);
select tests.say('web_lead', 'rc', 'rc2', 'meeting', 'mutual', null);
select tests.clink('web_lead', 'rc', 'clients', 'client:abc');
select tests.mk_doc('web_lead', 'rcdoc', 'Brief for the restricted client');
select tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:rc1'), tests.id('doc:rcdoc')));
select tests.mk_thread('web_lead', 'rp', 'Project-linked correspondence');
select tests.clink('web_lead', 'rp', 'projects', 'project:abc');
select tests.say('web_lead', 'rp', 'rp1', 'phone_call', 'outbound', null);
create temp table rcids as select (select institutional_id from entity_registry where entity_id = tests.id('thr:rc')) as thr, (select institutional_id from entity_registry where entity_id = tests.id('msg:rc1')) as msg,
                                  (select institutional_id from entity_registry where entity_id = tests.id('thr:rp')) as thr_p;
select tests.check('before: the web lead sees both, finance sees both (metadata)', tests.scalar('web_lead', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))) || tests.scalar('fin', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))), '22');
update clients set classification = 'restricted' where id = tests.id('client:abc');
select tests.check('the client becomes restricted: the thread linked to it AND the thread linked to its project inherit it (messages and registry follow)',
  (select string_agg(effective_classification::text, ',' order by id::text) from communication_threads where id in (tests.id('thr:rc'), tests.id('thr:rp'))) || '|' || (select string_agg(distinct classification::text, ',') from entity_registry where entity_id in (tests.id('thr:rc'), tests.id('thr:rp'), tests.id('msg:rc1'), tests.id('msg:rc2'), tests.id('msg:rp1'))),
  'restricted,restricted|restricted');
select tests.check('the web lead, division staff and finance see none of it (the auditor, cleared for restricted records, sees the metadata): threads, messages, links, events, attachments, access, holds, disposals',
  tests.scalar('web_lead', format($q$ select (select count(*) from communication_threads where id in (%L, %L))::text || (select count(*) from communication_messages where thread_id in (%L, %L)) || (select count(*) from communication_links where thread_id in (%L, %L))
        || (select count(*) from communication_events where thread_id in (%L, %L)) || (select count(*) from communication_attachments where thread_id in (%L, %L)) || (select count(*) from communication_access where thread_id in (%L, %L)) $q$,
        tests.id('thr:rc'), tests.id('thr:rp'), tests.id('thr:rc'), tests.id('thr:rp'), tests.id('thr:rc'), tests.id('thr:rp'), tests.id('thr:rc'), tests.id('thr:rp'), tests.id('thr:rc'), tests.id('thr:rp'), tests.id('thr:rc'), tests.id('thr:rp'))) ||
  tests.scalar('web_staff', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))) || tests.scalar('fin', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))) ||
  tests.scalar('audit', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))), '000000' || '002');
select tests.check('the CEO and administration still see them', tests.scalar('ceo', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))) || tests.scalar('adm2', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'))), '22');
select tests.check('every probe by an uncleared caller is indistinguishable from a random ID: 360, read, attach-open, record, close, transfer, classify, share, hold, link, update, set retention',
  tests.same_for('web_lead', $q$ select coalesce(communication_360(%L)::text, 'null') $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_message_add(%L, 'email', 'inbound', now(), 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_close(%L, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_transfer(%L, (select id from divisions where key = 'web'), 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_set_classification(%L, 'public', null, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_share(%L, (select id from staff where email = 'fin@ada.test'), null, array['read'], null, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_hold_place(%L, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_update(%L, '{"review_date":"2031-01-01"}')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_set_retention(%L, 'transient_1y', null, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_archive(%L, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_comment_add(%L, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_request_disposal(%L, 'x')::text $q$, tests.id('thr:rc'), tests.id('x:random')), repeat('same', 13));
select tests.age_message('msg:rc1');
select tests.check('...link, attach and participant INSERTs say nothing different either (no error is raised before row security)',
  tests.same_for('web_lead', $q$ select communication_link_add(%L, 'ZZZZZZZZZ')::text $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ select communication_attach_document(%L, (select id from documents limit 1))::text $q$, tests.id('msg:rc1'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ insert into communication_links (thread_id, entity_institutional_id) select %L, institutional_id from entity_registry limit 1 $q$, tests.id('thr:rc'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ insert into communication_participants (message_id, role, address_snapshot) values (%L, 'to', 'x@y.z') $q$, tests.id('msg:rc1'), tests.id('x:random')) ||
  tests.same_for('web_lead', $q$ insert into communication_attachments (thread_id, message_id, document_id) select m.thread_id, m.id, (select id from documents limit 1) from communication_messages m where m.id = %L $q$, tests.id('msg:rc1'), tests.id('x:random')), repeat('same', 5));
select tests.check('lookup of the thread or message by its ID: a hidden one answers exactly like one that never existed',
  tests.scalar('web_lead', format($q$ select coalesce(communication_lookup(%L)::text, 'null') $q$, (select thr from rcids))) || tests.scalar('web_lead', format($q$ select coalesce(communication_lookup(%L)::text, 'null') $q$, (select msg from rcids))) ||
  tests.scalar('web_lead', $q$ select coalesce(communication_lookup('ZZZZZZZZZ')::text, 'null') $q$), 'nullnullnull');
select tests.check('the cleared find them', tests.scalar('adm2', format($q$ select (communication_lookup(%L) ->> 'kind') $q$, (select thr from rcids))), 'thread');
select tests.check('the registry hides the threads and the messages: resolve, get, directory',
  tests.scalar('web_lead', format($q$ select coalesce(entity_resolve(%L)::text, 'null') || coalesce(entity_get(%L)::text, 'null') $q$, (select thr from rcids), (select msg from rcids))) ||
  tests.scalar('web_lead', format('select (select count(*) from entity_registry where entity_id in (%L, %L, %L))::text || (select count(*) from entity_directory where authoritative_record_key in (%L, %L))::text', tests.id('thr:rc'), tests.id('msg:rc1'), tests.id('thr:rp'), tests.id('thr:rc'), tests.id('msg:rc1'))), 'nullnull' || '00');
select tests.check('search has nothing to leak: communications carry no label, so no search-index row names them or their subject', (select count(*)::text from search_index where entity_id in (tests.id('thr:rc'), tests.id('msg:rc1'), tests.id('thr:rp'))) || (select (search_rebuild() is not null)::text) ||
  tests.scalar('web_lead', $q$ select (search_route('Restricted client correspondence') -> 'results')::text $q$) || tests.scalar('adm2', $q$ select (search_route('Restricted client correspondence') -> 'results')::text $q$), '0true[][]');
select tests.check('the entity''s own questions do not leak: "what communications does the restricted client have?" - null for the uncleared (the client is hidden), the list for the cleared',
  tests.scalar('web_lead', format($q$ select coalesce(communications_for_entity(%L)::text, 'null') $q$, (select abc from cids))) || tests.scalar('adm2', format($q$ select jsonb_array_length(communications_for_entity(%L, p_include_children => true))::text $q$, (select abc from cids))), 'null' || '2');
select tests.check('...and the project (which the lead may still see) lists nothing for the uncleared, the thread for the cleared', tests.scalar('web_lead', format($q$ select coalesce(communications_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true)::text, 'null') $q$, tests.id('project:abc'))) ||
  tests.scalar('adm2', format($q$ select jsonb_array_length(communications_for_entity((select institutional_id from entity_registry where entity_id = %L), p_include_children => true))::text $q$, tests.id('project:abc'))), '[]1');
select tests.check('the 360 views of the restricted client and project are null for the uncleared, and list the threads for the cleared',
  tests.scalar('web_lead', format($q$ select coalesce(client_360(%L)::text, 'null') $q$, tests.id('client:abc'))) || tests.scalar('web_lead', format($q$ select coalesce(project_360(%L)::text, 'null') $q$, tests.id('project:abc'))) ||
  tests.scalar('adm2', format($q$ select jsonb_array_length(client_360(%L) -> 'communications')::text $q$, tests.id('client:abc'))), 'nullnull' || '2');
select tests.check('the document attached to the restricted client''s thread shows no communication to a person who can see the document but not the thread', tests.scalar('web_lead', format($q$ select jsonb_array_length(document_360(%L) -> 'communications')::text $q$, tests.id('doc:rcdoc'))) || tests.scalar('adm2', format($q$ select jsonb_array_length(document_360(%L) -> 'communications')::text $q$, tests.id('doc:rcdoc'))), '01');

-- Soft-deleted clients, participants, explicit classification ---------------------------------------------------------------------------------------------
select tests.remember('client:gone', tests.mkclient_id('web_lead', 'Gone Client', 'web'));
select tests.mk_thread('web_lead', 'del', 'Deleted client matter');
select tests.say('web_lead', 'del', 'del1', 'email', 'inbound', 'About a client that was deleted');
select tests.clink('web_lead', 'del', 'clients', 'client:gone');
select tests.check('before the client is deleted the lead sees the thread', tests.cacts('web_lead', 'thr:del'), '11111111');
update clients set deleted_at = now(), deletion_reason = 'closed down' where id = tests.id('client:gone');
select tests.check('a soft-deleted client hides its correspondence from everyone without records.view_deleted (threads, messages, registry), the cleared still see it',
  tests.cacts('web_lead', 'thr:del') || tests.cacts('ceo', 'thr:del') || tests.scalar('web_lead', format($q$ select count(*)::text from communication_messages where thread_id = %L $q$, tests.id('thr:del'))) || (select client_deleted::text from communication_threads where id = tests.id('thr:del')), '00000000' || '11111111' || '0' || 'true');
update clients set deleted_at = null, deletion_reason = null where id = tests.id('client:gone');
select tests.check('...and restoring the client brings it back', tests.cacts('web_lead', 'thr:del'), '11111111');
select tests.mk_thread('web_lead', 'par', 'Participant inheritance');
select tests.say('web_lead', 'par', 'par1', 'email', 'inbound', 'Mentions a restricted party');
select tests.check('the CEO records a message with the (now restricted) client as a participant: the thread inherits the restriction from its participants too, and the lead - who could not name that party - is shut out',
  (tests.scalar('ceo', format($q$ select (communication_message_add(%L, 'email', 'outbound', now(), 'Reply to the restricted party', jsonb_build_array(jsonb_build_object('role', 'to', 'entity', %L))) ->> 'message_id') $q$, tests.id('thr:par'), (select abc from cids))) ~ '^[0-9a-f-]{36}$')::text, 'true');
select tests.check('...restricted, and hidden from the uncleared', (select effective_classification::text from communication_threads where id = tests.id('thr:par')) || tests.cacts('web_lead', 'thr:par'), 'restricted00000000');
select tests.check('an uncleared caller cannot name a restricted party as a participant: refused exactly like an unknown ID',
  (tests.say('web_lead', 'par', 'zz', 'email', 'inbound', 'x', format('[{"role":"from","entity":"%s"}]', (select abc from cids))::jsonb) = tests.say('web_lead', 'par', 'zz2', 'email', 'inbound', 'x', '[{"role":"from","entity":"ZZZZZZZZZ"}]'))::text, 'true');
select tests.mk_thread('web_lead', 'cls', 'Explicit classification');
select tests.say('web_lead', 'cls', 'cls1', 'email', 'inbound', 'x');
select tests.check('classifying needs records.classify: the lead cannot, the CEO can (reason required); a non-default class at start also needs it',
  tests.try('web_lead', format($q$ select communication_set_classification(%L, 'restricted', null, 'sensitive') $q$, tests.id('thr:cls'))) || tests.try('ceo', format($q$ select communication_set_classification(%L, 'restricted', null, null) $q$, tests.id('thr:cls'))) ||
  tests.try('ceo', format($q$ select communication_set_classification(%L, 'restricted', null, 'sensitive') $q$, tests.id('thr:cls'))) || tests.mk_thread('web_lead', 'cls2', 'x', 'web', 'restricted'), 'ERR:42501ERR:23514okERR:42501');
select tests.check('...the lead is shut out of what the CEO classified, and the change is in the history with its reason', tests.cacts('web_lead', 'thr:cls') || (select detail ->> 'reason' from communication_events where thread_id = tests.id('thr:cls') and kind = 'classification'), '00000000sensitive');

-- Critical communications ------------------------------------------------------------------------------------------------------------------------------
select tests.check('only a holder of communications.view_critical can start a critical communication', tests.mk_thread('web_lead', 'crit0', 'x', 'web', null, true) || (tests.mk_thread('ceo', 'crit', 'Critical matter', 'web', null, true) ~ '^[0-9a-f-]{36}$')::text, 'ERR:42501true');
select tests.say('ceo', 'crit', 'crit1', 'email', 'inbound', 'Critical content');
select tests.check('a critical thread is visible to its owner (the CEO) and to nobody else: not administration, not the lead, not the auditor - counts, messages, events included',
  tests.cacts('ceo', 'thr:crit') || tests.cacts('adm2', 'thr:crit') || tests.cacts('web_lead', 'thr:crit') || tests.cacts('audit', 'thr:crit') || tests.scalar('adm2', format($q$ select (select count(*) from communication_threads where id = %L)::text || (select count(*) from communication_messages where thread_id = %L) || (select count(*) from communication_events where thread_id = %L) $q$, tests.id('thr:crit'), tests.id('thr:crit'), tests.id('thr:crit'))),
  '11111111' || repeat('00000000', 3) || '000');
select tests.check('a lookup of a critical thread is recorded EXACTLY like a lookup of nothing (not even the investigators'' records show that it exists)',
  tests.scalar('web_lead', format($q$ select coalesce(communication_lookup(%L)::text, 'null') $q$, tests.inst('communication_threads', 'thr:crit'))) || tests.scalar('web_lead', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:crit'))), 'nullnull');
select tests.check('...the security records of those probes carry no trace of the thread''s existence', (select count(*)::text || '|' || count(*) filter (where entity_exists)::text || '|' || count(distinct (entity_exists, coalesce(entity_class::text, '-'), reason))::text from security_events where actor_staff_id = tests.id('staff:web_lead')
    and (requested_input = tests.inst('communication_threads', 'thr:crit') or requested_input = tests.id('thr:crit')::text) and requested_action in ('communication.lookup', 'communication.read')), '2|0|1');
select tests.check('the critical flag can be shared only with an expiry and never overrides classification: the CEO shares it with the Web lead for a day',
  tests.scalar('ceo', format($q$ select communication_share(%L, %L, null, array['read'], null, 'x')::text $q$, tests.id('thr:crit'), tests.id('staff:web_lead'))) , 'ERR:23514');
select tests.remember_ok('grant:crit', tests.scalar('ceo', format($q$ select communication_share(%L, %L, null, array['read'], now() + interval '1 day', 'needs to answer the client')::text $q$, tests.id('thr:crit'), tests.id('staff:web_lead'))));
select tests.check('...the grantee reads it; others still cannot', tests.cacts('web_lead', 'thr:crit') || tests.cacts('adm2', 'thr:crit'), '1100000000000000');
select tests.mk_doc('ceo', 'critdoc', 'Critical contract', 'legal', 'web', null, 'restricted', true);
select tests.mk_thread('ceo', 'cd', 'Thread that gets a critical attachment');
select tests.say('ceo', 'cd', 'cd1', 'email', 'inbound', 'See the critical contract');
select tests.check('a thread is as critical as any document attached to it: before, administration sees it', tests.cacts('adm2', 'thr:cd'), '11111111');
select tests.scalar('ceo', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:cd1'), tests.id('doc:critdoc')));
select tests.check('...after attaching the critical document it becomes critical and administration is shut out (a communication is never a weaker path around a critical document)', (select effective_critical::text from communication_threads where id = tests.id('thr:cd')) || tests.cacts('adm2', 'thr:cd'), 'true00000000');
select tests.check('...and a denial of the critical thread is recorded like nothing', tests.scalar('adm2', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:cd'))) || (select count(*) filter (where entity_exists)::text from security_events where actor_staff_id = tests.id('staff:adm2') and requested_action = 'communication.read'), 'null0');

-- Attachments cannot leak through the thread --------------------------------------------------------------------------------------------------------------
select tests.mk_doc('tech_lead', 'techdoc', 'Tech-only drawing', 'report', 'tech');
select tests.mk_doc('web_lead', 'aldoc', 'Web quote');
select tests.add_ver('web_lead', 'aldoc', 'aldocv1', 'bytes of the quote');
select tests.mk_thread('web_lead', 'al', 'Attachment visibility');
select tests.say('web_lead', 'al', 'al1', 'email', 'outbound', 'Attached: two files');
select tests.scalar('web_lead', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:al1'), tests.id('doc:aldoc')));
select tests.scalar('ceo', format($q$ select communication_attach_document(%L, %L)::text $q$, tests.id('msg:al1'), tests.id('doc:techdoc')));
select tests.check('the web lead (who may read the thread but cannot see the Tech document) is shown only the attachment they can see; the CEO sees both',
  tests.scalar('web_lead', format($q$ select jsonb_array_length(communication_read(%L) -> 'messages' -> 0 -> 'attachments')::text $q$, tests.id('thr:al'))) || tests.scalar('ceo', format($q$ select jsonb_array_length(communication_read(%L) -> 'messages' -> 0 -> 'attachments')::text $q$, tests.id('thr:al'))), '12');
select tests.check('...the attachment rows themselves, the 360 and the by-document search show the same', tests.scalar('web_lead', format($q$ select (select count(*) from communication_attachments where thread_id = %L)::text || jsonb_array_length(communication_360(%L) -> 'attachments')::text $q$, tests.id('thr:al'), tests.id('thr:al'))) ||
  tests.scalar('ceo', format($q$ select (select count(*) from communication_attachments where thread_id = %L)::text || jsonb_array_length(communication_360(%L) -> 'attachments')::text $q$, tests.id('thr:al'), tests.id('thr:al'))), '1122');
select tests.check('opening: the web lead cannot open the Tech document through the thread (null, like an unknown attachment); opening what they may see works; finance (no communication attachment right) cannot open either',
  tests.same_for('web_lead', $q$ select coalesce(communication_attachment_open(%L)::text, 'null') $q$, (select id from communication_attachments where document_id = tests.id('doc:techdoc')), tests.id('x:random')) ||
  tests.scalar('web_lead', format($q$ select (communication_attachment_open(%L) is not null)::text $q$, (select id from communication_attachments where document_id = tests.id('doc:aldoc')))) ||
  tests.scalar('fin', format($q$ select coalesce(communication_attachment_open(%L)::text, 'null') $q$, (select id from communication_attachments where document_id = tests.id('doc:aldoc')))), 'sametruenull');
select tests.check('a person with document rights but NO communication rights cannot see the thread (the Documents module''s authority does not widen into communications)', tests.cacts('tech_lead', 'thr:al') || tests.scalar('tech_lead', format($q$ select jsonb_array_length(document_360(%L) -> 'communications')::text $q$, tests.id('doc:techdoc'))), '000000000');
select tests.check('a removed attachment cannot be opened', tests.try('web_lead', format($q$ select communication_attachment_remove(%L, 'oops') $q$, (select id from communication_attachments where document_id = tests.id('doc:aldoc')))) ||
  tests.scalar('web_lead', format($q$ select coalesce(communication_attachment_open(%L)::text, 'null') $q$, (select id from communication_attachments where document_id = tests.id('doc:aldoc')))), 'oknull');

-- Cross-division ---------------------------------------------------------------------------------------------------------------------------------------
select tests.mk_thread('tech_lead', 'tech1', 'Tech division matter', 'tech');
select tests.say('tech_lead', 'tech1', 'tech1m', 'email', 'inbound', 'Tech body');
select tests.check('a Tech lead''s own thread is theirs (they act in Tech) and the Web lead and Web staff cannot see it - nor its messages, nor its registry rows',
  tests.cacts('tech_lead', 'thr:tech1') || tests.cacts('web_lead', 'thr:tech1') || tests.scalar('web_lead', format($q$ select (select count(*) from communication_messages where thread_id = %L)::text || (select count(*) from entity_registry where entity_id in (%L, %L))::text $q$, tests.id('thr:tech1'), tests.id('thr:tech1'), tests.id('msg:tech1m'))), '11111111' || '00000000' || '00');
select tests.check('...and the reverse: the Tech lead cannot see Web threads, and the ordinary matrix thread is invisible to Tech staff', tests.scalar('tech_lead', format($q$ select count(*)::text from communication_threads where id in (%L, %L) $q$, tests.id('thr:m'), tests.id('thr:a'))) ||
  tests.scalar('tech_staff', format($q$ select count(*)::text from communication_threads where id = %L $q$, tests.id('thr:m'))), '00');
select tests.check('the entity question does not leak across divisions: the Tech lead asking about a Web contact gets null (they cannot resolve it), and about the (restricted) client also null',
  tests.scalar('tech_lead', format($q$ select coalesce(communications_for_entity(%L)::text, 'null') $q$, (select john from cids))) || tests.scalar('tech_lead', format($q$ select coalesce(jsonb_array_length(communications_for_entity(%L))::text, 'null') $q$, (select abc from cids))), 'nullnull');

-- The audit log is not a back door -----------------------------------------------------------------------------------------------------------------------
insert into roles (key, name) values ('audit_basic_test', 'Auditor without restricted clearance (test)');
insert into role_permissions (role_id, permission_id) select (select id from roles where key = 'audit_basic_test'), id from permissions where key in ('audit.view', 'communications.view');
select tests.add_staff('audbasic', 'audit_basic_test');
select tests.check('an auditor without restricted clearance sees audit rows of ordinary threads, none of restricted ones, none of critical ones',
  tests.scalar('audbasic', format($q$ select (select count(*) from audit_log where table_name = 'communication_threads' and record_id = %L)::text || (select (count(*) > 0)::text from audit_log where table_name = 'communication_threads' and record_id = %L) || (select count(*) from audit_log where table_name = 'communication_threads' and record_id = %L)::text $q$, tests.id('thr:rc'), tests.id('thr:m'), tests.id('thr:crit'))), '0true0');
select tests.check('...nor the message / link / attachment rows of a restricted thread', tests.scalar('audbasic', format($q$ select count(*)::text from audit_log where table_name in ('communication_messages', 'communication_links', 'communication_attachments', 'communication_access', 'communication_holds', 'communication_disposals') and (new_data ->> 'thread_id') in (%L, %L, %L) $q$, tests.id('thr:rc'), tests.id('thr:rp'), tests.id('thr:crit'))), '0');
select tests.check('participants and notes are content: even for an ordinary thread, an auditor with metadata rights only sees no participant or note audit rows (the cleared auditor with read rights... none is granted to the auditor role)',
  tests.scalar('audbasic', format($q$ select count(*)::text from audit_log where table_name in ('communication_participants', 'communication_comments') and (new_data ->> 'thread_id') = %L $q$, tests.id('thr:pp'))), '0');
select tests.check('an administrator (audit rights, and read rights on the thread) does see them, redacted', tests.scalar('ceo', format($q$ select (count(*) > 0)::text from audit_log where table_name = 'communication_participants' and (new_data ->> 'thread_id') = %L $q$, tests.id('thr:pp'))), 'true');
select tests.check('without audit.view nobody reads the audit log at all', tests.scalar('web_lead', 'select count(*)::text from audit_log'), '0');
select tests.check('communications changes are audited with the acting staff member: threads, messages, links, attachments, access, holds, disposals',
  (select (count(*) filter (where table_name = 'communication_threads' and action = 'INSERT') > 0 and count(*) filter (where table_name = 'communication_messages') > 0 and count(*) filter (where table_name = 'communication_links') > 0
       and count(*) filter (where table_name = 'communication_attachments') > 0 and count(*) filter (where table_name = 'communication_access') > 0 and bool_and(actor_staff_id is not null))::text from audit_log where table_name like 'communication%'), 'true');

-- Security investigation integration -------------------------------------------------------------------------------------------------------------------
select tests.scalar('web_staff', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:rc'))) from generate_series(1, 6);
select tests.check('repeated denied reads of a hidden thread by one person raise a flag in the EXISTING security case model (no communications-only alarm exists)', (select concat_ws('|', status, severity) from security_cases where actor_staff_id = tests.id('staff:web_staff')) ||
  (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname ~ '^communication' and relname ~ 'secur|alert|suspic|anomal'), 'flagged|low0');
select tests.check('...the events name the lookup with the staff identity', (select count(*)::text from security_events where actor_staff_id = tests.id('staff:web_staff') and requested_action = 'communication.read'), '6');

-- Public API, anonymous access ---------------------------------------------------------------------------------------------------------------------------
select tests.check('there is no public API for communications at all, and neither type is publishable', (select count(*)::text from pg_proc where pronamespace = 'public_api'::regnamespace and proname ~* 'communic|thread|message') || (select count(*)::text from entity_types where key in ('communication', 'communication_message') and publishable), '00');
select tests.check('the public (anonymous) role can read and execute nothing here', tests.scalar_anon('select count(*)::text from communication_threads') || tests.scalar_anon('select count(*)::text from communication_messages') || tests.scalar_anon('select count(*)::text from communication_attachments') ||
  tests.scalar_anon('select communication_lookup(''ZZZZZZZZZ'')::text') || tests.scalar_anon('select communications_of(array[''x''])::text'), repeat('ERR:42501', 5));
select tests.check('a signed-in user who is not staff sees nothing and can do nothing, with the same answers', tests.cacts('outsider', 'thr:m') || tests.scalar('outsider', 'select count(*)::text from communication_threads') || tests.scalar('outsider', format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:m'))) ||
  tests.scalar('outsider', format($q$ select communication_message_add(%L, 'email', 'inbound', now(), 'x')::text $q$, tests.id('thr:m'))) || tests.scalar('outsider', format($q$ select communication_start(%L)::text $q$, tests.id('div:web'))), '00000000' || '0' || 'null' || 'ERR:P0002' || 'ERR:42501');
select tests.check('the website role is not an ADA staff identity either: a document publication does not carry communications', (select count(*)::text from information_schema.columns where table_schema = 'public' and table_name = 'document_publications' and column_name ~ 'communic'), '0');

-- Bypass attempts ----------------------------------------------------------------------------------------------------------------------------------------
select tests.check('the helper decisions are not callable by API users (an allow-list test also reviews every executable function)', tests.try('web_lead', format($q$ select communication_gate(%L, null, %L, false, 'read') $q$, tests.id('thr:m'), tests.id('div:web'))) || tests.try('web_lead', format($q$ select communication_require(%L, 'read') $q$, tests.id('thr:m'))) ||
  tests.try('web_lead', format($q$ select communication_log(%L, null, 'read', '{}') $q$, tests.id('thr:m'))) || tests.try('web_lead', format($q$ select communication_set_status(%L, 'close', 'closed', 'closed', 'x') $q$, tests.id('thr:m'))), repeat('ERR:42501', 4));
select tests.check('the service role (no staff identity) cannot use any command: reads answer null, writes are refused',
  tests.scalar_service(format($q$ select coalesce(communication_read(%L)::text, 'null') $q$, tests.id('thr:m'))) || tests.try_service(format($q$ select communication_message_add(%L, 'email', 'inbound', now(), 'x') $q$, tests.id('thr:m'))) || tests.try_service(format($q$ select communication_start(%L) $q$, tests.id('div:web'))), 'nullERR:P0002ERR:42501');
select tests.check('...and cannot step around the guards below the commands either (an immutable message, a disposal, a division move, a deletion)',
  tests.try_service(format($q$ update communication_messages set body = 'rewritten' where id = %L $q$, tests.id('msg:m1'))) || tests.try_service(format($q$ delete from communication_messages where id = %L $q$, tests.id('msg:m1'))) ||
  tests.try_service(format($q$ update communication_threads set status = 'disposed' where id = %L $q$, tests.id('thr:m'))) || tests.try_service(format($q$ update communication_threads set division_id = %L where id = %L $q$, tests.id('div:tech'), tests.id('thr:m'))), 'ERR:42501ERR:42501ERR:23514ERR:42501');
select tests.check('integrity checks and manifests are for the service role only', tests.try('ceo', 'select * from communication_integrity_drift()') || tests.try('ceo', 'select communication_backup_manifest()') || tests.try_service('select * from communication_integrity_drift()') || tests.try_service('select communication_backup_manifest()'), 'ERR:42501ERR:42501okok');
select tests.check('a message cannot be recorded into a thread by someone who may only see its metadata (and the refusal says only what they already know)', tests.scalar('fin', format($q$ select communication_message_add(%L, 'email', 'inbound', now(), 'x')::text $q$, tests.id('thr:m'))) ||
  tests.scalar('audit', format($q$ select communication_message_add(%L, 'email', 'inbound', now(), 'x')::text $q$, tests.id('thr:m'))), 'ERR:42501ERR:42501');

-- Definite predicates ----------------------------------------------------------------------------------------------------------------------------------
select tests.check('every access predicate answers a definite true / false, never NULL, for odd input (a NULL would silently grant in plpgsql)',
  tests.scalar('web_lead', format($q$ select concat_ws('|', coalesce(communication_can(NULL, 'view')::text, 'NULL'), coalesce(communication_can(%L, NULL)::text, 'NULL'), coalesce(communication_can(%L, 'view')::text, 'NULL'), coalesce(communication_can(%L, 'nonsense')::text, 'NULL'),
        coalesce(communication_can_row(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)::text, 'NULL'), coalesce(communication_can_row(%L, NULL, %L, 'internal', NULL, NULL, 'open', 'read')::text, 'NULL'), coalesce(communication_on_hold(NULL)::text, 'NULL')) $q$,
        tests.id('thr:m'), tests.id('x:random'), tests.id('thr:m'), tests.id('thr:m'), tests.id('div:web'))), 'false|false|false|false|false|false|false');
select tests.check('...also with no identity at all', tests.scalar_anon('select 1::text') || tests.scalar(null, format($q$ select concat_ws('|', communication_can(%L, 'view')::text, communication_can(%L, 'read')::text) $q$, tests.id('thr:m'), tests.id('thr:m'))), '1false|false');

-- Registry consistency; identity never reused -------------------------------------------------------------------------------------------------------------
select tests.check('every thread and every message has exactly one registry row, and no registry row of these types lacks its record',
  (select count(*)::text from communication_threads d where (select count(*) from entity_registry r where r.table_name = 'communication_threads' and r.entity_id = d.id) <> 1) || (select count(*)::text from communication_messages d where (select count(*) from entity_registry r where r.table_name = 'communication_messages' and r.entity_id = d.id) <> 1) ||
  (select count(*)::text from entity_registry r where r.table_name = 'communication_threads' and not exists (select 1 from communication_threads d where d.id = r.entity_id)) || (select count(*)::text from entity_registry r where r.table_name = 'communication_messages' and not exists (select 1 from communication_messages d where d.id = r.entity_id)), '0000');
select tests.check('the registry mirrors status, classification and the current division of every thread and message',
  (select count(*)::text from communication_threads d join entity_registry r on r.table_name = 'communication_threads' and r.entity_id = d.id where (r.status, r.classification, r.current_division_id) is distinct from (d.status::text, d.effective_classification, d.division_id)) ||
  (select count(*)::text from communication_messages d join entity_registry r on r.table_name = 'communication_messages' and r.entity_id = d.id where (r.status, r.classification, r.current_division_id) is distinct from (d.status, d.effective_classification, d.division_id)), '00');
select tests.check('IDs are unique, well formed, and each kind keeps its own counter (nothing is reused when a recording is refused)',
  (select count(distinct institutional_id) = count(*) and bool_and(institutional_id ~ '^[0-9A-HJKMNP-TV-Z]{9}$') from entity_registry where table_name in ('communication_threads', 'communication_messages'))::text, 'true');
create temp table ctr as select (select coalesce(sum(last_value), 0) from id_counters where type_code = (select id_code from entity_types where key = 'communication_message')) as msgs, (select count(*) from communication_messages) as n;
select tests.say('web_lead', 'a', 'refused1', 'telepathy', 'inbound', 'x');
select tests.check('a refused recording leaves no registry row and no counter gap: the message counter equals the number of messages, always', (select (msgs = n)::text from ctr) || (select (coalesce(sum(last_value), 0) = (select count(*) from communication_messages))::text from id_counters where type_code = (select id_code from entity_types where key = 'communication_message')), 'truetrue');
select tests.check('the thread counter equals the number of threads too', (select (coalesce(sum(last_value), 0) = (select count(*) from communication_threads))::text from id_counters where type_code = (select id_code from entity_types where key = 'communication')), 'true');
select tests.check('the backup manifest counts what exists and the drift checks are clean', (select (communication_backup_manifest() ->> 'threads')::int = (select count(*) from communication_threads) and (communication_backup_manifest() ->> 'messages')::int = (select count(*) from communication_messages))::text || (select count(*)::text from communication_integrity_drift()), 'true0');
select tests.finish();
rollback;
