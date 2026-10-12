// ADA Hub pilot console. A thin screen over the controlled database operations: every button calls POST /rpc/<function>; nothing here decides
// who may see or do what (the database does, for every call), and nothing is stored in the browser.
const $ = (s, r = document) => r.querySelector(s);
const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) { if (k === 'class') n.className = v; else if (k.startsWith('on')) n.addEventListener(k.slice(2), v); else if (v !== false && v != null) n.setAttribute(k, v === true ? '' : v); }
  for (const kid of kids.flat()) if (kid != null && kid !== false) n.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return n;
};

class RpcError extends Error { constructor(b, status) { super(b && b.message || 'Request failed'); this.code = b && b.code; this.status = status; } }
async function rpc(fn, args = {}) {
  const r = await fetch('/rpc/' + fn, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text(); const b = t ? JSON.parse(t) : null;
  if (r.status === 401) { await showLogin(); throw new RpcError(b, 401); }
  if (!r.ok) throw new RpcError(b, r.status);
  return b;
}
function notice(msg, kind = 'ok') { const n = $('#notice'); n.replaceChildren(el('div', { class: kind, 'data-kind': kind }, msg)); if (kind === 'ok') setTimeout(() => { if (n.textContent === msg) n.replaceChildren(); }, 8000); }
// What a person is told for a refused or failed operation. A refusal never says whether the record exists.
function friendly(e) {
  if (e.status === 403 || e.code === '42501') return 'You are not permitted to do that (or it is not available to you).';
  if (e.code === 'P0002') return 'Not found, or not available to you.';
  if (e.code === '23505') return 'That already exists.';
  return e.message || 'Something went wrong.';
}

// ---- identity caches --------------------------------------------------------------------------------------------------------------------
const uuidCache = new Map();
async function resolve(id) { if (!id) return null; if (!uuidCache.has(id)) uuidCache.set(id, await rpc('entity_resolve', { p_id: id })); return uuidCache.get(id); }
async function uuidOf(id) { const r = await resolve(id); return r ? r.authoritative_record_key : null; }
let me = null, cat = null;
const LEGACY = /^ADA-[A-Z]{3}-\d{4}-\d{4}$/, INST = /^[0-9A-Z]{9}$/;

// ---- sign-in (development stand-in) ----------------------------------------------------------------------------------------------------
async function showLogin() {
  me = null; $('#who').replaceChildren();
  const people = await (await fetch('/auth/people')).json();
  $('#main').replaceChildren(el('div', { class: 'card people' }, el('h1', {}, 'Sign in'), el('p', { class: 'muted' }, 'Development stand-in for the real sign-in. Choose a pilot account.'),
    people.map((p) => el('button', { 'data-email': p.email, onclick: async () => { await fetch('/auth/login', { method: 'POST', body: JSON.stringify({ email: p.email }), headers: { 'content-type': 'application/json' } }); await boot(); } }, `${p.full_name}`, el('br'), el('small', { class: 'muted' }, p.roles || 'no role'))),
    el('button', { 'data-email': 'outsider@pilot.test', onclick: async () => { await fetch('/auth/login', { method: 'POST', body: JSON.stringify({ email: 'outsider@pilot.test' }), headers: { 'content-type': 'application/json' } }); await boot(); } }, 'Outsider (signed in, not staff)')));
}
async function boot() {
  const r = await fetch('/auth/me');
  if (r.status === 401) return showLogin();
  me = await r.json();
  cat = await rpc('pilot_catalogue');
  $('#who').replaceChildren(el('span', { id: 'whoname' }, me.staff ? me.staff.full_name : 'Signed in (no staff record)'), ' ', el('button', { id: 'signout', onclick: async () => { await fetch('/auth/logout', { method: 'POST' }); uuidCache.clear(); await showLogin(); } }, 'Sign out'));
  route();
}

// ---- generic rendering of authoritative records -----------------------------------------------------------------------------------------
const isId = (v) => typeof v === 'string' && (LEGACY.test(v));
const money = (v) => typeof v === 'number' ? v.toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : v;
function cell(v, k) {
  if (v == null) return el('span', { class: 'muted' }, '-');
  if (isId(v)) return el('a', { href: '#/e/' + v }, v);
  if (typeof v === 'boolean') return v ? 'yes' : 'no';
  if (typeof v === 'number') return money(v);
  if (typeof v === 'object') return el('span', { class: 'pre' }, JSON.stringify(v));
  if (/_at$|^at$/.test(k || '') && /^\d{4}-\d\d-\d\dT/.test(v)) return v.replace('T', ' ').slice(0, 16);
  return String(v);
}
function table(rows, skip = []) {
  if (!rows.length) return el('p', { class: 'muted' }, 'None.');
  const keys = [...new Set(rows.flatMap((r) => typeof r === 'object' ? Object.keys(r) : []))].filter((k) => !skip.includes(k));
  if (!keys.length) return el('p', {}, rows.map(String).join(', '));
  return el('table', {}, el('tr', {}, keys.map((k) => el('th', {}, k.replace(/_/g, ' ')))), rows.map((r) => el('tr', {}, keys.map((k) => el('td', {}, cell(r[k], k))))));
}
function facts(o, skip = []) {
  const e = Object.entries(o || {}).filter(([k, v]) => !skip.includes(k) && !(v && typeof v === 'object' && !Array.isArray(v) && !Object.keys(v).length));
  return el('table', {}, e.map(([k, v]) => el('tr', {}, el('th', {}, k.replace(/_/g, ' ')), el('td', {}, Array.isArray(v) ? table(v) : (v && typeof v === 'object') ? el('span', { class: 'pre' }, JSON.stringify(v)) : cell(v, k)))));
}
function sections(data, skip = []) {
  const out = [];
  for (const [k, v] of Object.entries(data || {})) {
    if (skip.includes(k) || v == null) continue;
    if (Array.isArray(v)) out.push(el('details', { open: k !== 'activity', 'data-section': k }, el('summary', {}, el('b', {}, k.replace(/_/g, ' ')), ` (${v.length})`), table(v)));
    else if (typeof v === 'object') out.push(el('details', { open: true, 'data-section': k }, el('summary', {}, el('b', {}, k.replace(/_/g, ' '))), facts(v)));
  }
  return out;
}

// ---- action forms ----------------------------------------------------------------------------------------------------------------------
// A field: {n, l, t: text|textarea|number|date|bool|select|ref, req, opts:[{v,l}], v}. 'ref' options carry institutional/legacy ids resolved on submit.
function actionForm(a, ctx, after) {
  const inputs = {};
  const form = el('form', { class: 'act', 'data-action': a.id });
  for (const f of a.fields) {
    let inp;
    if (f.t === 'select' || f.t === 'ref') { inp = el('select', { name: f.n }, (f.req ? [] : [el('option', { value: '' }, '-')]), (f.opts || []).map((o) => el('option', { value: o.v }, o.l))); if (f.v != null) inp.value = f.v; }
    else if (f.t === 'textarea') inp = el('textarea', { name: f.n, rows: 3 });
    else if (f.t === 'bool') inp = el('input', { type: 'checkbox', name: f.n });
    else if (f.t === 'file') inp = el('input', { type: 'file', name: f.n });
    else { inp = el('input', { type: f.t === 'number' ? 'number' : f.t === 'date' ? 'date' : 'text', name: f.n, step: f.t === 'number' ? 'any' : false }); if (f.v != null) inp.value = f.v; }
    if (f.req) inp.required = true;
    inputs[f.n] = inp;
    form.append(f.t === 'bool' ? el('div', { class: 'row' }, inp, el('label', {}, f.l)) : el('div', {}, el('label', {}, f.l + (f.req ? ' *' : '')), inp));
  }
  form.append(el('p', {}, el('button', { class: 'primary', type: 'submit' }, a.label)));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const vals = {};
    for (const f of a.fields) {
      const i = inputs[f.n];
      if (f.t === 'bool') vals[f.n] = i.checked;
      else if (f.t === 'file') vals[f.n] = i.files[0] || null;
      else if (i.value !== '') vals[f.n] = f.t === 'number' ? Number(i.value) : i.value;
    }
    try {
      const res = a.run ? await a.run(vals, ctx) : await rpc(a.fn, await a.args(vals, ctx));
      notice(a.done ? a.done(res, vals) : `${a.label}: done.`); await after(res);
    } catch (e) { if (e.status !== 401) notice(`${a.label}: ${friendly(e)}`, 'err'); }
  });
  return el('details', { class: 'action', 'data-action-box': a.id }, el('summary', {}, a.label), form);
}
const refs = async (a, ctx) => Object.fromEntries(await Promise.all(Object.entries(a).map(async ([k, v]) => [k, v && (LEGACY.test(v) || INST.test(v)) ? await uuidOf(v) : v])));
const opt = (rows, v, l) => rows.map((r) => ({ v: r[v], l: typeof l === 'function' ? l(r) : r[l] }));
const divOpts = () => opt(cat.divisions, 'id', 'name');
const enumOpts = (xs) => xs.map((x) => ({ v: x, l: x.replace(/_/g, ' ') }));
const mine = () => (me && me.access && me.access.divisions) || [];

// Actions are plain descriptions of controlled operations; the argument names are the database function's own.
function clientActions(c) {
  const contacts = c.data.contacts.map((x) => ({ v: x.contact, l: `${x.name}${x.billing ? ' (billing)' : ''}` }));
  const projects = c.data.projects.map((x) => ({ v: x.id, l: x.name }));
  const invoices = c.data.invoices.map((x) => ({ v: x.id, l: `${x.id} ${x.status}` }));
  return [
    { id: 'contact', label: 'Add contact', fn: 'add_client_contact', fields: [{ n: 'p_name', l: 'Full name', req: true }, { n: 'p_email', l: 'E-mail' }, { n: 'p_phone', l: 'Phone' }, { n: 'p_role_title', l: 'Role / title' }, { n: 'p_primary', l: 'Primary contact', t: 'bool' }, { n: 'p_billing', l: 'Billing contact', t: 'bool' }], args: (v) => ({ p_client: c.uuid, ...v }) },
    { id: 'claim', label: 'Claim this client for a division', fn: 'claim_client_for_division', fields: [{ n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }], args: (v) => ({ p_client: c.uuid, ...v }) },
    { id: 'project', label: 'Create project', fn: 'project_create', fields: [{ n: 'p_division', l: 'Lead division', t: 'select', req: true, opts: divOpts() }, { n: 'p_name', l: 'Project name', req: true }, { n: 'p_description', l: 'Description', t: 'textarea' }, { n: 'p_start', l: 'Start', t: 'date' }, { n: 'p_due', l: 'Due', t: 'date' }], args: (v) => ({ p_client: c.uuid, ...v }), done: (r) => r.status === 'exists' ? 'That project already exists - opened the existing one.' : 'Project created.' },
    { id: 'quote', label: 'Create quote', fn: 'quote_create', fields: [{ n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'p_title', l: 'Title', req: true }, { n: 'p_contact', l: 'Addressed to', t: 'ref', opts: contacts }, { n: 'p_project', l: 'Project', t: 'ref', opts: projects }, { n: 'p_valid_until', l: 'Valid until', t: 'date' }], args: async (v) => ({ p_client: c.uuid, ...(await refs(v)) }) },
    { id: 'payment', label: 'Record payment (finance)', fn: 'payment_record', fields: [{ n: 'p_account', l: 'Received into', t: 'select', req: true, opts: opt(cat.bank_accounts, 'id', 'name') }, { n: 'p_amount', l: 'Amount', t: 'number', req: true }, { n: 'p_method', l: 'Method', t: 'select', req: true, opts: enumOpts(['bank_transfer', 'cash', 'card', 'cheque', 'mobile_money', 'other']) }, { n: 'p_received_on', l: 'Received on', t: 'date' }, { n: 'p_reference', l: 'Reference' }, { n: 'p_invoice', l: 'Apply to invoice', t: 'ref', opts: invoices }], args: async (v) => ({ p_client: c.uuid, ...(await refs(v)) }) },
    ...commonActions(c, { client: c.uuid, clientRef: c.id, project: null, contacts }),
  ];
}
function projectActions(c) {
  const clientId = c.data.client && c.data.client.id;
  return [
    { id: 'division', label: 'Add participating division', fn: 'project_add_division', fields: [{ n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }], args: (v) => ({ p_project: c.uuid, ...v }) },
    { id: 'member', label: 'Add team member', fn: 'project_add_member', fields: [{ n: 'p_staff', l: 'Staff member', t: 'select', req: true, opts: opt(cat.staff, 'id', 'name') }, { n: 'p_role', l: 'Role' }], args: (v) => ({ p_project: c.uuid, ...v }) },
    { id: 'pcontact', label: 'Add client contact to project', fields: [{ n: 'p_contact', l: 'Contact', t: 'ref', req: true, opts: c.clientContacts }, { n: 'p_role', l: 'Role' }], fn: 'project_add_contact', args: async (v) => ({ p_project: c.uuid, ...(await refs(v)) }) },
    { id: 'task', label: 'Add task', fn: 'task_create', fields: [{ n: 'p_title', l: 'Task', req: true }, { n: 'p_description', l: 'Details', t: 'textarea' }, { n: 'p_assignee', l: 'Assignee', t: 'select', opts: opt(cat.staff, 'id', 'name') }, { n: 'p_due', l: 'Due', t: 'date' }], args: (v) => ({ p_project: c.uuid, ...v }) },
    { id: 'ptransition', label: 'Change project status', fn: 'project_transition', fields: [{ n: 'p_to', l: 'New status', t: 'select', req: true, opts: enumOpts(['approved', 'active', 'on_hold', 'completed', 'cancelled', 'archived']) }, { n: 'p_reason', l: 'Reason' }], args: (v) => ({ p_id: c.uuid, ...v }) },
    { id: 'quote', label: 'Create quote for this project', fn: 'quote_create', fields: [{ n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'p_title', l: 'Title', req: true }, { n: 'p_contact', l: 'Addressed to', t: 'ref', opts: c.clientContacts }, { n: 'p_valid_until', l: 'Valid until', t: 'date' }], args: async (v) => ({ p_client: await uuidOf(clientId), p_project: c.uuid, ...(await refs(v)) }) },
    ...commonActions(c, { client: clientId ? null : null, clientRef: clientId, project: c.uuid, contacts: c.clientContacts }),
  ];
}
// documents, communications, tickets, assets, domains - each is created for a client or a project and linked to it by reference
function commonActions(c, k) {
  const link = async (ref) => ref || c.id;
  const target = c.id;                                      // the institutional/legacy id of the page's own entity
  const clientU = async () => k.client || (k.clientRef ? await uuidOf(k.clientRef) : null);
  return [
    { id: 'document', label: 'Attach document', fields: [{ n: 'title', l: 'Title', req: true }, { n: 'type', l: 'Type', t: 'select', req: true, opts: enumOpts(['report', 'requirements', 'proposal', 'contract', 'correspondence', 'deliverable', 'minutes', 'legal', 'other']) }, { n: 'division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'file', l: 'File', t: 'file', req: true }],
      run: async (v) => {
        const buf = await v.file.arrayBuffer();
        const o = await (await fetch('/dev/object/upload', { method: 'PUT', body: buf })).json();
        const d = await rpc('document_register', { p_title: v.title, p_type: v.type, p_division: v.division });
        const doc = d.id || d.document_id;
        await rpc('document_add_version', { p_doc: doc, p_provider: o.provider, p_key: o.key, p_hash: o.hash, p_size: o.size, p_mime: v.file.type || 'application/octet-stream', p_filename: v.file.name });
        await rpc('document_link_add', { p_doc: doc, p_entity: target });
        return d;
      }, done: () => 'Document registered, stored by reference and linked.' },
    { id: 'communication', label: 'Record communication (metadata)', fields: [{ n: 'subject', l: 'Subject', req: true }, { n: 'division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'kind', l: 'Kind', t: 'select', req: true, opts: enumOpts(['email', 'call', 'meeting', 'message', 'note']) }, { n: 'direction', l: 'Direction', t: 'select', req: true, opts: enumOpts(['inbound', 'outbound', 'internal']) }, { n: 'body', l: 'Summary / content' }],
      run: async (v) => {
        const t = await rpc('communication_start', { p_division: v.division, p_subject: v.subject });
        const th = t.id || t.thread_id;
        await rpc('communication_message_add', { p_thread: th, p_type: v.kind, p_direction: v.direction, p_occurred_at: new Date().toISOString(), p_body: v.body || null });
        await rpc('communication_link_add', { p_thread: th, p_entity: target });
        if (k.project && k.clientRef) await rpc('communication_link_add', { p_thread: th, p_entity: k.clientRef });
        return t;
      }, done: () => 'Communication recorded and linked.' },
    { id: 'ticket', label: 'Raise ticket', fn: 'ticket_create', fields: [{ n: 'p_title', l: 'Title', req: true }, { n: 'p_description', l: 'Details', t: 'textarea' }, { n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'p_kind', l: 'Kind', t: 'select', opts: enumOpts(['incident', 'request', 'maintenance', 'question']) }, { n: 'p_priority', l: 'Priority', t: 'select', opts: enumOpts(['low', 'normal', 'high', 'urgent']) }],
      args: async (v) => ({ ...v, p_client: await clientU(), p_project: k.project }) },
    { id: 'asset', label: 'Register asset', fn: 'asset_create', fields: [{ n: 'p_name', l: 'Name', req: true }, { n: 'p_category', l: 'Category', t: 'select', req: true, opts: enumOpts(['laptop', 'desktop', 'server', 'network', 'mobile', 'peripheral']) }, { n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'p_serial', l: 'Serial' }],
      args: async (v) => ({ ...v, p_client: await clientU(), p_project: k.project }) },
    { id: 'domain', label: 'Register domain', fields: [{ n: 'name', l: 'Domain name', req: true }, { n: 'division', l: 'Division', t: 'select', req: true, opts: divOpts() }],
      run: async (v) => { const d = await rpc('domain_create', { p_name: v.name, p_division: v.division }); await rpc('domain_relation_add', { p_domain: d.id, p_relation: k.project ? 'project' : 'client', p_entity: target, p_reason: 'pilot' }); return d; }, done: () => 'Domain registered and related.' },
  ];
}
const NEXT = { quote: { draft: ['pending_approval', 'cancelled'], pending_approval: ['approved', 'rejected', 'cancelled'], approved: ['sent', 'cancelled'], sent: ['accepted', 'rejected', 'expired', 'cancelled'] },
  contract: { draft: ['internal_review', 'approved', 'cancelled'], internal_review: ['approved', 'rejected', 'draft'], approved: ['sent', 'cancelled'], sent: ['signed', 'rejected'], signed: ['active'], active: ['terminated', 'expired'] },
  invoice: { draft: ['pending_approval', 'cancelled'], pending_approval: ['approved', 'draft', 'cancelled'], approved: ['issued', 'cancelled'], issued: ['cancelled'], partially_paid: ['cancelled'] } };
function recordActions(c) {
  const r = c.record, t = c.type, out = [];
  const nxt = ((NEXT[t] || {})[r && r.status]) || [];
  if (t === 'quote') {
    out.push({ id: 'qline', label: 'Add line from the catalogue', fn: 'quote_add_line', fields: [{ n: 'p_service', l: 'Service', t: 'select', req: true, opts: cat.services.map((s) => ({ v: s.id, l: `${s.name} - ${s.price ? money(s.price.amount) + ' ' + s.price.currency : 'no price in force'}` })) }, { n: 'p_quantity', l: 'Quantity', t: 'number', v: 1 }, { n: 'p_discount', l: 'Discount', t: 'number' }, { n: 'p_unit_price', l: 'Override price (needs a reason)', t: 'number' }, { n: 'p_override_reason', l: 'Override reason' }], args: (v) => ({ p_quote: c.uuid, ...v }) });
    out.push({ id: 'qtransition', label: 'Move quote forward / decide', fn: 'quote_transition', fields: [{ n: 'p_to', l: 'To', t: 'select', req: true, opts: enumOpts(nxt) }, { n: 'p_note', l: 'Note' }], args: (v) => ({ p_id: c.uuid, ...v }) });
    if (r && r.status === 'accepted') {
      out.push({ id: 'qcontract', label: 'Create contract from this accepted quote', fn: 'contract_create_from_quote', fields: [{ n: 'p_title', l: 'Contract title' }], args: (v) => ({ p_quote: c.uuid, ...v }) });
      out.push({ id: 'qproject', label: 'Convert into a project (if none yet)', fn: 'quote_convert_to_project', fields: [{ n: 'p_project_name', l: 'Project name' }], args: (v) => ({ p_quote: c.uuid, ...v }) });
    }
  }
  if (t === 'contract') {
    out.push({ id: 'ctransition', label: 'Move contract forward / decide', fn: 'contract_transition', fields: [{ n: 'p_to', l: 'To', t: 'select', req: true, opts: enumOpts(nxt) }, { n: 'p_note', l: 'Note' }, { n: 'p_date', l: 'Date (signing / effective)', t: 'date' }], args: (v) => ({ p_contract: c.uuid, ...v }) });
    out.push({ id: 'clink', label: 'Link a project', fn: 'contract_link_project', fields: [{ n: 'p_project', l: 'Project', t: 'ref', req: true, opts: c.clientProjects }], args: async (v) => ({ p_contract: c.uuid, ...(await refs(v)) }) });
    out.push({ id: 'cbill', label: 'Bill a contract line (creates a draft invoice)', fields: [{ n: 'line', l: 'Contract line', t: 'select', req: true, opts: ((r && r.lines) || []).map((l) => ({ v: l.id, l: `${l.description || l.service} - ${money(l.line_total)}` })) }, { n: 'contact', l: 'Billing contact', t: 'ref', opts: c.clientContacts }],
      run: async (v) => { const b = await rpc('billable_from_contract', { p_contract: c.uuid, p_line: v.line }); return rpc('invoice_create', { p_items: [b], ...(v.contact ? { p_contact: await uuidOf(v.contact) } : {}) }); }, done: () => 'Draft invoice created from the contract line.' });
  }
  if (t === 'invoice') {
    out.push({ id: 'itransition', label: 'Move invoice forward / decide', fn: 'invoice_transition', fields: [{ n: 'p_to', l: 'To', t: 'select', req: true, opts: enumOpts(nxt) }, { n: 'p_note', l: 'Note' }], args: (v) => ({ p_id: c.uuid, ...v }) });
    out.push({ id: 'ipay', label: 'Record payment against this invoice (finance)', fn: 'payment_record', fields: [{ n: 'p_account', l: 'Received into', t: 'select', req: true, opts: opt(cat.bank_accounts, 'id', 'name') }, { n: 'p_amount', l: 'Amount', t: 'number', req: true }, { n: 'p_method', l: 'Method', t: 'select', req: true, opts: enumOpts(['bank_transfer', 'cash', 'card', 'cheque', 'mobile_money', 'other']) }, { n: 'p_received_on', l: 'Received on', t: 'date' }, { n: 'p_reference', l: 'Reference' }], args: (v) => ({ p_client: r.client_id, p_invoice: c.uuid, ...v }) });
  }
  if (t === 'ticket') {
    out.push({ id: 'ttransition', label: 'Change ticket status', fn: 'ticket_transition', fields: [{ n: 'p_to', l: 'To', t: 'select', req: true, opts: enumOpts(['in_progress', 'waiting', 'resolved', 'closed', 'cancelled']) }, { n: 'p_note', l: 'Note' }], args: (v) => ({ p_ticket: c.uuid, ...v }) });
    out.push({ id: 'tassign', label: 'Assign ticket', fn: 'ticket_assign', fields: [{ n: 'p_staff', l: 'Assignee', t: 'select', req: true, opts: opt(cat.staff, 'id', 'name') }], args: (v) => ({ p_ticket: c.uuid, ...v }) });
    out.push({ id: 'tcomment', label: 'Add comment', fn: 'ticket_comment_add', fields: [{ n: 'p_body', l: 'Comment', t: 'textarea', req: true }], args: (v) => ({ p_ticket: c.uuid, ...v }) });
  }
  if (t === 'asset') {
    out.push({ id: 'atransition', label: 'Change asset status', fn: 'asset_transition', fields: [{ n: 'p_to', l: 'To', t: 'select', req: true, opts: enumOpts(['acquired', 'in_stock', 'in_maintenance', 'returned', 'retired']) }, { n: 'p_note', l: 'Note' }], args: (v) => ({ p_asset: c.uuid, ...v }) });
    out.push({ id: 'aassign', label: 'Assign asset', fn: 'asset_assign', fields: [{ n: 'p_staff', l: 'To staff member', t: 'select', opts: opt(cat.staff, 'id', 'name') }, { n: 'p_project', l: 'To project', t: 'ref', opts: c.clientProjects }, { n: 'p_note', l: 'Note' }], args: async (v) => ({ p_asset: c.uuid, ...(await refs(v)) }) });
  }
  if (t === 'payment') {
    out.push({ id: 'pallocate', label: 'Allocate to an invoice (finance)', fn: 'payment_allocate', fields: [{ n: 'p_invoice', l: 'Invoice', t: 'ref', req: true, opts: c.clientInvoices }, { n: 'p_amount', l: 'Amount (blank = as much as fits)', t: 'number' }], args: async (v) => ({ p_payment: c.uuid, ...(await refs(v)) }) });
  }
  return out;
}

// ---- pages -----------------------------------------------------------------------------------------------------------------------------
const head = (c) => el('div', {}, el('h1', {}, c.title), el('p', { class: 'idline', 'data-ids': true }, el('span', { class: 'tag' }, c.type.replace(/_/g, ' ')), ` ID ${c.res.institutional_id}`, c.res.legacy_identifier ? ` / ${c.res.legacy_identifier}` : '', ' ', c.res.status ? el('span', { class: 'tag' }, c.res.status) : '', el('span', { class: 'tag' }, c.res.classification)));
function nextSteps(c) {
  const d = c.data || {}, n = [];
  if (c.type === 'client') {
    if (!d.contacts.length) n.push('Add a contact (a person at the client).');
    if (!d.projects.length) n.push('Create a project for this client.');
    else if (!d.quotes.length) n.push('Create a quote (from the project page the project is attached automatically).');
    for (const q of d.quotes) if (q.status === 'accepted' && !d.contracts.length) n.push(`Quote ${q.id} is accepted: open it and create the contract.`);
    for (const i of d.invoices) if (i.balance > 0 || i.status === 'issued') n.push(`Invoice ${i.id} is ${i.status}${i.balance != null ? `, balance ${money(i.balance)}` : ''}.`);
    for (const p of d.pending || []) n.push(`Awaiting decision: ${typeof p === 'string' ? p : JSON.stringify(p)}`);
  }
  if (c.type === 'project') {
    if (!d.quotes.length) n.push('Create a quote for this project.');
    if (d.quotes.some((q) => q.status === 'accepted') && !d.contracts.length) n.push('A quote is accepted: open it and create the contract.');
    if (d.contracts.length && !d.invoices.length) n.push('Open the contract to bill a line.');
  }
  return n.length ? el('div', { class: 'card next', 'data-next': true }, el('b', {}, 'Next'), el('ul', {}, n.map((x) => el('li', {}, x)))) : null;
}
async function loadEntity(id) {
  const res = await resolve(id);
  if (!res) return null;
  const t = res.entity_type, uuid = res.authoritative_record_key, c = { type: t, res, uuid, id: res.legacy_identifier || res.institutional_id, title: res.legacy_identifier || res.institutional_id };
  const v360 = { client: 'client_360', project: 'project_360', asset: 'asset_360', document: 'document_360', domain: 'domain_360', communication: 'communication_360', external_organization: 'organization_360', organization: 'organization_360' };
  const pr = ['quote', 'contract', 'invoice', 'payment', 'ticket', 'person'];
  if (v360[t]) { const arg = { client: 'p_client', project: 'p_project', asset: 'p_asset', document: 'p_doc', domain: 'p_domain', communication: 'p_thread', external_organization: 'p_org', organization: 'p_org' }[t]; c.data = await rpc(v360[t], { [arg]: uuid }); if (!c.data) return null; }
  else if (pr.includes(t)) { const x = await rpc('pilot_record', { p_id: res.institutional_id }); if (!x || !x.record) return null; c.record = x.record; }
  else { const x = await rpc('entity_get', { p_id: res.institutional_id }); if (!x) return null; c.data = x.record || {}; }
  const o = (c.data && c.data.overview) || c.record || {};
  c.title = o.name || o.title || o.full_name || (c.data && c.data.name) || c.title;
  // sibling lists for the selects on forms
  const cref = t === 'project' ? c.data.client && c.data.client.id : t === 'client' ? c.id : c.record && c.record.client_ref;
  if (cref && (t === 'project' || pr.includes(t))) {
    const cr = await resolve(cref);
    if (cr) { const cd = await rpc('client_360', { p_client: cr.authoritative_record_key }); if (cd) { c.clientContacts = cd.contacts.map((x) => ({ v: x.contact, l: x.name })); c.clientProjects = cd.projects.map((x) => ({ v: x.id, l: x.name })); c.clientInvoices = cd.invoices.map((x) => ({ v: x.id, l: `${x.id} ${x.status}` })); } }
  }
  c.clientContacts ||= []; c.clientProjects ||= []; c.clientInvoices ||= [];
  return c;
}
async function renderEntity(id) {
  const c = await loadEntity(id);
  if (!c) { $('#main').replaceChildren(el('div', { class: 'card', id: 'notfound' }, el('h1', {}, 'Not found'), el('p', {}, 'No such record, or it is not available to you.'))); return; }
  const reload = () => renderEntity(id);
  const acts = c.type === 'client' ? clientActions(c) : c.type === 'project' ? projectActions(c) : recordActions(c);
  const body = [head(c), nextSteps(c)];
  if (c.type === 'client' || c.type === 'project') {
    const ov = c.data.overview || {};
    body.push(el('div', { class: 'grid' }, el('div', { class: 'card' }, el('h3', {}, 'Overview'), facts(ov, ['id', 'social_links'])), el('div', { class: 'card' }, el('h3', {}, 'Actions'), acts.map((a) => actionForm(a, c, async (res) => {
      if (a.id === 'project' && res && res.id && res.status !== 'exists') { /* stay on the client; the project appears below */ }
      await reload(); }))), ));
    body.push(...sections(c.data, ['overview']));
  } else if (c.record) {
    body.push(el('div', { class: 'grid' }, el('div', { class: 'card' }, el('h3', {}, 'Record'), facts(c.record, ['lines', 'allocations', 'approvals', 'terms'].concat(Object.keys(c.record).filter((k) => k.endsWith('_id') || k.endsWith('_snapshot')))), ), el('div', { class: 'card' }, el('h3', {}, 'Actions'), acts.length ? acts.map((a) => actionForm(a, c, reload)) : el('p', { class: 'muted' }, 'No actions for this record.'))));
    for (const k of ['lines', 'allocations', 'approvals']) if (c.record[k]) body.push(el('details', { open: true, 'data-section': k }, el('summary', {}, el('b', {}, k), ` (${c.record[k].length})`), table(c.record[k], ['id', 'quote_id', 'invoice_id', 'version_id', 'service_id', 'price_id', 'billable_item_id', 'origin_line_id', 'quote_line_id', 'invoice_uuid', 'created_at'])));
    if (c.record.terms) body.push(el('details', { 'data-section': 'terms' }, el('summary', {}, el('b', {}, 'current terms')), facts(c.record.terms, ['id', 'contract_id', 'contact_id'])));
  } else {
    body.push(el('div', { class: 'grid' }, el('div', { class: 'card' }, el('h3', {}, 'Record'), c.data.overview ? facts(c.data.overview) : null), el('div', { class: 'card' }, el('h3', {}, 'Actions'), acts.length ? acts.map((a) => actionForm(a, c, reload)) : el('p', { class: 'muted' }, 'No actions here.'))));
    body.push(...sections(c.data, ['overview']));
  }
  body.push(el('p', {}, el('a', { href: '#/search/' + encodeURIComponent('related:' + c.res.institutional_id), id: 'relatedlink' }, 'Everything related to this record')));
  $('#main').replaceChildren(...body.filter(Boolean));
}
async function renderSearch(q) {
  $('#q').value = q;
  const r = await rpc('search', { p_query: q, p_facets: true });
  const rows = (r && r.results) || [];
  const f = r && r.facets;
  $('#main').replaceChildren(el('h1', {}, `Search: ${q}`), el('p', { class: 'muted', id: 'resultcount' }, `${r ? r.total : 0} result(s)`),
    f && f.entity_type ? el('p', {}, Object.entries(f.entity_type).map(([k, n]) => el('a', { class: 'tag', href: '#/search/' + encodeURIComponent(`type:${k} ${q.replace(/\btype:\S+\s*/g, '')}`) }, `${k.replace(/_/g, ' ')} ${n}`))) : null,
    rows.length ? el('table', { id: 'results' }, el('tr', {}, ['type', 'name', 'id', 'status'].map((h) => el('th', {}, h))), rows.map((x) => el('tr', { 'data-type': x.entity_type }, el('td', {}, (x.entity_type || '').replace(/_/g, ' ')), el('td', {}, el('a', { href: '#/e/' + (x.institutional_id || x.id) }, x.label || x.name || x.institutional_id)), el('td', { class: 'muted' }, `${x.institutional_id || ''}${x.legacy_identifier ? ' / ' + x.legacy_identifier : ''}`), el('td', {}, x.status || '')))) : el('p', {}, 'Nothing found. Check the spelling, or search by an ID.'));
}
async function renderHome() {
  $('#main').replaceChildren(el('h1', {}, 'Start here'),
    el('div', { class: 'card' }, el('p', {}, 'Search first - for a company, a person, a project, an invoice number, a domain or an ID. If it is not there, create it below.')),
    el('div', { class: 'card', id: 'newclient' }, el('h3', {}, 'Find or create a client'), clientCreateForm()));
}
function clientCreateForm() {
  const box = el('div');
  const mkForm = (extra) => actionForm({ id: 'client_create', label: 'Find or create client', fields: [{ n: 'p_name', l: 'Organization name', req: true }, { n: 'p_division', l: 'Division', t: 'select', req: true, opts: divOpts() }, { n: 'p_registration', l: 'Registration number' }, { n: 'p_email', l: 'E-mail' }, { n: 'p_phone', l: 'Phone' }, ...(extra ? [{ n: 'p_distinct_reason', l: 'Why is this a different organization?' }] : [])],
    run: async (v) => {
      const r = await rpc('client_create', v);
      if (r.status === 'similar' || r.status === 'name_conflict') {
        box.replaceChildren(el('div', { class: 'card', id: 'similar' }, el('b', {}, r.status === 'similar' ? 'Similar organizations already exist - check before creating another:' : 'An organization with that name already exists with different details:'), el('pre', { class: 'pre' }, JSON.stringify(r.candidates || r.matches || r, null, 1)), el('p', { class: 'muted' }, 'If this really is a different organization, give the reason and submit again.')), mkForm(true));
        throw Object.assign(new Error(r.status === 'similar' ? 'Similar organization exists - confirm it is different.' : 'Name conflict - confirm it is different.'), { code: 'REVIEW' });
      }
      return r;
    }, done: (r) => r.status === 'exists' ? 'That client already exists - opened it (no duplicate was made).' : 'Client created.' }, {}, async (r) => { location.hash = '#/e/' + r.client; });
  box.append(mkForm(false)); return box;
}

function route() {
  const h = decodeURIComponent(location.hash || '#/');
  const go = async () => {
    try {
      if (h.startsWith('#/e/')) await renderEntity(h.slice(4));
      else if (h.startsWith('#/search/')) await renderSearch(h.slice(9));
      else await renderHome();
    } catch (e) { if (e.status !== 401) $('#main').replaceChildren(el('div', { class: 'card' }, el('h1', {}, 'Not available'), el('p', {}, friendly(e)))); }
  };
  return go();
}
window.addEventListener('hashchange', () => { if (me) route(); });
$('#searchform').addEventListener('submit', (e) => { e.preventDefault(); const q = $('#q').value.trim(); if (q) location.hash = '#/search/' + encodeURIComponent(q); });
let sgTimer;
$('#q').addEventListener('input', () => { clearTimeout(sgTimer); sgTimer = setTimeout(async () => {
  const p = $('#q').value.trim(); if (p.length < 2 || !me) return;
  try { const s = await rpc('search_suggest', { p_prefix: p }); $('#suggestions').replaceChildren(...(Array.isArray(s) ? s : (s && s.suggestions) || []).map((x) => el('option', { value: typeof x === 'string' ? x : x.label || x.text || '' }))); } catch {}
}, 200); });
boot();
