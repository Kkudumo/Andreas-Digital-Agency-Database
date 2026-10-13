'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { call, rid } from '@/lib/db';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';

// Every action below is one controlled database operation (or a short sequence of them) run as the signed-in user.
// Authorization, business rules, approvals and audit are the database's; this file only passes the user's input through.

const where = (fd: FormData) => {
  const p = String(fd.get('return') ?? '/search');
  return p.startsWith('/') && !p.startsWith('//') ? p : '/search';
};
const num = (v: FormDataEntryValue | null) => { const s = str(v); return s === null ? null : Number(s); };

async function run(fd: FormData, fn: string, args: Record<string, unknown>, ok: string) {
  const { data, error } = await call(fn, args);
  const path = where(fd);
  if (error) back(path, 'error', friendly(error));
  revalidatePath(path);
  return { data, path, ok };
}
const done = (r: { path: string; ok: string }) => back(r.path, 'ok', r.ok);

// --- client / organization -----------------------------------------------------------------------------------------------------------
export async function createClientAction(fd: FormData) {
  const { data, error } = await call('client_create', {
    p_name: str(fd.get('name')), p_division: str(fd.get('division')), p_registration: str(fd.get('registration')),
    p_email: str(fd.get('email')), p_phone: str(fd.get('phone')), p_distinct_reason: str(fd.get('distinct_reason')),
  });
  const name = encodeURIComponent(String(str(fd.get('name')) ?? ''));
  if (error) back(`/clients/new?name=${name}`, 'error', friendly(error));
  const r = (data ?? {}) as any;
  if (r.status === 'created') redirect(`/clients/${r.id}?ok=${encodeURIComponent('Client created. The organization behind it is registered once, for every division.')}`);
  if (r.status === 'exists') redirect(`${rid(r.client)}`);
  back(`/clients/new?name=${name}`, 'error', r.next ?? 'That name needs review before a client can be created.');
}
export async function claimClientAction(fd: FormData) {
  done(await run(fd, 'claim_client_for_division', { p_client: str(fd.get('client')), p_division: str(fd.get('division')) }, 'Your division now works with this client.'));
}
export async function addContactAction(fd: FormData) {
  done(await run(fd, 'add_client_contact', {
    p_client: str(fd.get('client')), p_name: str(fd.get('name')), p_email: str(fd.get('email')), p_phone: str(fd.get('phone')),
    p_role_title: str(fd.get('role')), p_primary: fd.get('primary') === 'on', p_billing: fd.get('billing') === 'on',
  }, 'Contact added (an existing person with the same details is reused, never copied).'));
}

// --- project ---------------------------------------------------------------------------------------------------------------------------
export async function createProjectAction(fd: FormData) {
  const { data, error } = await call('project_intake_create', {
    p_client: str(fd.get('client')),
    p_division: str(fd.get('division')),
    p_name: str(fd.get('name')),
    p_description: str(fd.get('description')),
    p_type: str(fd.get('project_type')),
    p_priority: str(fd.get('priority')) ?? 'normal',
    p_start: str(fd.get('start_date')),
    p_due: str(fd.get('due_date')),
    p_quoted_amount: num(fd.get('quoted_amount')),
    p_budget: num(fd.get('budget')),
    p_finance_notes: str(fd.get('finance_notes')),
  });
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/projects/${data}?ok=${encodeURIComponent('Project created with delivery and commercial details (status: proposed).')}`);
}
export async function projectTransitionAction(fd: FormData) {
  done(await run(fd, 'project_transition', { p_id: str(fd.get('project')), p_to: str(fd.get('to')), p_reason: str(fd.get('note')) }, 'Project status changed.'));
}
export async function addProjectServiceAction(fd: FormData) {
  done(await run(fd, 'project_add_service', { p_project: str(fd.get('project')), p_service: str(fd.get('service')), p_quantity: num(fd.get('quantity')) ?? 1 }, 'Service added at the current approved price.'));
}
export async function createTaskAction(fd: FormData) {
  done(await run(fd, 'task_create', {
    p_project: str(fd.get('project')),
    p_title: str(fd.get('title')),
    p_description: str(fd.get('description')),
    p_assignee: str(fd.get('assignee')),
    p_due: str(fd.get('due_date')),
  }, 'Task created.'));
}

// --- quote -> approval -> contract -----------------------------------------------------------------------------------------------------
export async function createQuoteAction(fd: FormData) {
  const { data, error } = await call('quote_create', {
    p_client: str(fd.get('client')), p_division: str(fd.get('division')), p_title: str(fd.get('title')),
    p_contact: str(fd.get('contact')), p_project: str(fd.get('project')),
  });
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/quotes/${data}?ok=${encodeURIComponent('Quote created. Add lines from the service catalogue.')}`);
}
export async function addQuoteLineAction(fd: FormData) {
  done(await run(fd, 'quote_add_line', {
    p_quote: str(fd.get('quote')), p_service: str(fd.get('service')), p_quantity: num(fd.get('quantity')) ?? 1,
    p_unit_price: num(fd.get('unit_price')), p_override_reason: str(fd.get('override_reason')), p_description: str(fd.get('description')),
    p_discount: num(fd.get('discount')) ?? 0,
  }, 'Line added. The price is the approved catalogue price, copied into the quote.'));
}
export async function quoteTransitionAction(fd: FormData) {
  done(await run(fd, 'quote_transition', { p_id: str(fd.get('quote')), p_to: str(fd.get('to')), p_note: str(fd.get('note')) }, 'Quote status changed.'));
}
export async function convertQuoteAction(fd: FormData) {
  const { data, error } = await call('quote_convert_to_project', { p_quote: str(fd.get('quote')), p_project_name: str(fd.get('name')) });
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/projects/${data}?ok=${encodeURIComponent('Quote linked to the project; its priced services are now on the project.')}`);
}
export async function createContractAction(fd: FormData) {
  const { data, error } = await call('contract_create_from_quote', { p_quote: str(fd.get('quote')), p_title: str(fd.get('title')) });
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/contracts/${data}?ok=${encodeURIComponent('Contract created from the accepted quote.')}`);
}
export async function contractTransitionAction(fd: FormData) {
  done(await run(fd, 'contract_transition', { p_contract: str(fd.get('contract')), p_to: str(fd.get('to')), p_note: str(fd.get('note')) }, 'Contract status changed.'));
}
export async function linkContractProjectAction(fd: FormData) {
  done(await run(fd, 'contract_link_project', { p_contract: str(fd.get('contract')), p_project: str(fd.get('project')) }, 'Contract linked to the project.'));
}

// --- invoice -> payment ----------------------------------------------------------------------------------------------------------------
export async function billContractLineAction(fd: FormData) {
  const a = await call('billable_from_contract', { p_contract: str(fd.get('contract')), p_line: str(fd.get('line')) });
  if (a.error || !a.data) back(where(fd), 'error', friendly(a.error));
  const b = await call('invoice_create', { p_items: [a.data] });
  if (b.error || !b.data) back(where(fd), 'error', friendly(b.error));
  redirect(`/invoices/${b.data}?ok=${encodeURIComponent('Draft invoice created from the contract line.')}`);
}
export async function invoiceTransitionAction(fd: FormData) {
  done(await run(fd, 'invoice_transition', { p_id: str(fd.get('invoice')), p_to: str(fd.get('to')), p_note: str(fd.get('note')) }, 'Invoice status changed.'));
}
export async function recordPaymentAction(fd: FormData) {
  done(await run(fd, 'payment_record', {
    p_client: str(fd.get('client')), p_account: str(fd.get('account')), p_amount: num(fd.get('amount')), p_method: str(fd.get('method')) ?? 'bank_transfer',
    p_received_on: str(fd.get('received_on')), p_reference: str(fd.get('reference')), p_invoice: str(fd.get('invoice')),
  }, 'Payment recorded. The balance is recalculated from the allocations.'));
}
export async function allocatePaymentAction(fd: FormData) {
  done(await run(fd, 'payment_allocate', { p_payment: str(fd.get('payment')), p_invoice: str(fd.get('invoice')), p_amount: num(fd.get('amount')) }, 'Payment allocated.'));
}

// --- attach: document, communication, ticket, asset ----------------------------------------------------------------------------------
// `links` is the institutional id(s) of the client / project the new record belongs to (comma separated).
const links = (fd: FormData) => String(fd.get('links') ?? '').split(',').map((s) => s.trim()).filter(Boolean);

export async function registerDocumentAction(fd: FormData) {
  const d = await call<{ id: string }>('document_register', { p_title: str(fd.get('title')), p_type: str(fd.get('type')) ?? 'other', p_division: str(fd.get('division')), p_description: str(fd.get('description')) });
  if (d.error || !d.data) back(where(fd), 'error', friendly(d.error));
  for (const l of links(fd)) {
    const r = await call('document_link_add', { p_doc: d.data!.id, p_entity: l });
    if (r.error) back(where(fd), 'error', `Document registered, but linking failed: ${friendly(r.error)}`);
  }
  revalidatePath(where(fd));
  back(where(fd), 'ok', 'Document registered and linked. Versions and content go through the document module.');
}
export async function startCommunicationAction(fd: FormData) {
  const t = await call<{ id: string }>('communication_start', { p_division: str(fd.get('division')), p_subject: str(fd.get('subject')) });
  if (t.error || !t.data) back(where(fd), 'error', friendly(t.error));
  const body = str(fd.get('body'));
  if (body) {
    const m = await call('communication_message_add', { p_thread: t.data!.id, p_type: str(fd.get('type')) ?? 'email', p_direction: str(fd.get('direction')) ?? 'inbound', p_occurred_at: new Date().toISOString(), p_body: body });
    if (m.error) back(where(fd), 'error', `Thread started, but recording the message failed: ${friendly(m.error)}`);
  }
  for (const l of links(fd)) {
    const r = await call('communication_link_add', { p_thread: t.data!.id, p_entity: l });
    if (r.error) back(where(fd), 'error', `Thread started, but linking failed: ${friendly(r.error)}`);
  }
  revalidatePath(where(fd));
  back(where(fd), 'ok', 'Communication recorded and linked. Its body is not shown on client or project pages.');
}
export async function createTicketAction(fd: FormData) {
  done(await run(fd, 'ticket_create', {
    p_title: str(fd.get('title')), p_description: str(fd.get('description')), p_client: str(fd.get('client')), p_project: str(fd.get('project')),
    p_asset: str(fd.get('asset')), p_division: str(fd.get('division')),
  }, 'Ticket raised against the client / project.'));
}
export async function ticketTransitionAction(fd: FormData) {
  done(await run(fd, 'ticket_transition', { p_ticket: str(fd.get('ticket')), p_to: str(fd.get('to')), p_note: str(fd.get('note')) }, 'Ticket status changed.'));
}
export async function ticketCommentAction(fd: FormData) {
  done(await run(fd, 'ticket_comment_add', { p_ticket: str(fd.get('ticket')), p_body: str(fd.get('body')) }, 'Comment added.'));
}
export async function createAssetAction(fd: FormData) {
  done(await run(fd, 'asset_create', {
    p_name: str(fd.get('name')), p_category: str(fd.get('category')) ?? 'other', p_division: str(fd.get('division')), p_serial: str(fd.get('serial')),
    p_client: str(fd.get('client')), p_project: str(fd.get('project')), p_status: 'in_stock',
  }, 'Asset registered with a permanent institutional ID.'));
}
export async function assignAssetAction(fd: FormData) {
  done(await run(fd, 'asset_assign', { p_asset: str(fd.get('asset')), p_project: str(fd.get('project')), p_note: str(fd.get('note')) }, 'Asset assigned to the project.'));
}

// --- expenses ----------------------------------------------------------------------------------------------------------------------------
export async function createExpenseAction(fd: FormData) {
  const { data, error } = await call('expense_create', {
    p_division: str(fd.get('division')), p_category: str(fd.get('category')), p_description: str(fd.get('description')), p_amount_net: num(fd.get('amount')),
    p_tax: num(fd.get('tax')) ?? 0, p_expense_date: str(fd.get('expense_date')), p_supplier: str(fd.get('supplier')),
    p_supplier_reference: str(fd.get('supplier_reference')), p_project: str(fd.get('project')),
  });
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/expenses/${data}?ok=${encodeURIComponent('Expense recorded as a draft.')}`);
}
export async function expenseTransitionAction(fd: FormData) {
  done(await run(fd, 'expense_transition', { p_expense: str(fd.get('expense')), p_to: str(fd.get('to')), p_note: str(fd.get('note')) }, 'Expense status changed.'));
}
export async function payExpenseAction(fd: FormData) {
  done(await run(fd, 'expense_pay', { p_expense: str(fd.get('expense')), p_account: str(fd.get('account')), p_paid_on: str(fd.get('paid_on')), p_reference: str(fd.get('reference')) }, 'Payment recorded; the expense is final.'));
}
export async function voidExpenseAction(fd: FormData) {
  done(await run(fd, 'expense_void', { p_expense: str(fd.get('expense')), p_reason: str(fd.get('reason')) }, 'Expense voided.'));
}

// --- credit notes ------------------------------------------------------------------------------------------------------------------------
export async function createCreditNoteAction(fd: FormData) {
  const { data, error } = await call('credit_note_create', { p_invoice: str(fd.get('invoice')), p_reason_code: str(fd.get('reason_code')), p_reason_note: str(fd.get('reason_note')) });
  if (error || !data) back(where(fd), 'error', friendly(error));
  redirect(`/credit-notes/${data}?ok=${encodeURIComponent('Credit note drafted. Add the lines being credited.')}`);
}
export async function creditNoteLineAction(fd: FormData) {
  done(await run(fd, 'credit_note_add_line', { p_credit_note: str(fd.get('credit_note')), p_invoice_line: str(fd.get('invoice_line')), p_quantity: num(fd.get('quantity')) }, 'Line added (blank quantity credits the whole remaining line).'));
}
export async function creditNoteCustomLineAction(fd: FormData) {
  done(await run(fd, 'credit_note_add_custom_line', { p_credit_note: str(fd.get('credit_note')), p_description: str(fd.get('description')), p_quantity: num(fd.get('quantity')) ?? 1, p_unit_price: num(fd.get('unit_price')) }, 'Free-form line added.'));
}
export async function creditNoteRemoveLineAction(fd: FormData) {
  done(await run(fd, 'credit_note_remove_line', { p_line: str(fd.get('line')) }, 'Line removed.'));
}
export async function creditNoteTransitionAction(fd: FormData) {
  done(await run(fd, 'credit_note_transition', { p_id: str(fd.get('credit_note')), p_to: str(fd.get('to')), p_note: str(fd.get('note')) }, 'Credit note status changed.'));
}
export async function creditNoteAllocateAction(fd: FormData) {
  done(await run(fd, 'credit_note_allocate', { p_credit_note: str(fd.get('credit_note')), p_invoice: str(fd.get('invoice')), p_amount: num(fd.get('amount')) }, 'Credit applied.'));
}
export async function creditNoteUnallocateAction(fd: FormData) {
  done(await run(fd, 'credit_note_unallocate', { p_allocation: str(fd.get('allocation')), p_reason: str(fd.get('reason')) }, 'Application released.'));
}

// --- recurring invoicing -----------------------------------------------------------------------------------------------------------------
export async function createScheduleAction(fd: FormData) {
  done(await run(fd, 'billing_schedule_create', {
    p_contract: str(fd.get('contract')), p_line: str(fd.get('line')), p_interval_months: num(fd.get('interval')), p_first_period_start: str(fd.get('start')),
    p_quantity: num(fd.get('quantity')) ?? 1, p_end_on: str(fd.get('end_on')),
  }, 'Billing schedule created. Nothing is billed until a run.'));
}
export async function scheduleStatusAction(fd: FormData) {
  done(await run(fd, 'billing_schedule_set_status', { p_schedule: str(fd.get('schedule')), p_status: str(fd.get('to')), p_reason: str(fd.get('note')), p_skip_missed: fd.get('skip') === 'on' }, 'Billing schedule updated.'));
}
export async function runBillingAction(fd: FormData) {
  const { data, error } = await call<any[]>('billing_schedule_run', { p_as_of: str(fd.get('as_of')) ?? new Date().toISOString().slice(0, 10), p_create_invoices: fd.get('invoices') === 'on' });
  if (error) back(where(fd), 'error', friendly(error));
  const out = data ?? [];
  const periods = out.reduce((n, o) => n + (o.periods_billed ?? 0), 0);
  const problems = out.filter((o) => ['failed', 'paused'].includes(o.outcome)).map((o) => o.message).filter(Boolean);
  revalidatePath(where(fd));
  back(where(fd), problems.length ? 'error' : 'ok', `${out.length} schedule(s) processed, ${periods} period(s) billed.${problems.length ? ' Needs attention: ' + problems.join('; ') : ''}`);
}

export async function setBillingRunnerAction(fd: FormData) {
  done(await run(fd, 'billing_runner_set', { p_staff: str(fd.get('staff')) }, 'Billing runner updated.'));
}

// --- organization duplicates (merge) -----------------------------------------------------------------------------------------------------
export async function resolveOrganizationReviewAction(fd: FormData) {
  const keep = str(fd.get('outcome')) ?? '';
  const same = keep === 'same_left' || keep === 'same_right';
  done(await run(fd, 'organization_review_resolve', {
    p_review: str(fd.get('review')), p_outcome: same ? 'same' : keep, p_note: str(fd.get('note')),
    p_survivor: same ? str(fd.get(keep === 'same_left' ? 'left' : 'right')) : null,
  }, same ? 'Merged. The absorbed organization keeps its ID as a tombstone pointing to the survivor.' : 'Review resolved.'));
}
