import { call } from '@/lib/db';

export type ReportKey = 'aging' | 'revenue' | 'expenses' | 'profitability' | 'pipeline';
type Col = { key: string; head: string; money?: boolean };
export type ReportSpec = { key: ReportKey; title: string; about: string; fn: string; ranged: boolean; cols: Col[] };

export const REPORTS: ReportSpec[] = [
  { key: 'aging', title: 'Receivables aging', fn: 'report_receivables_aging', ranged: false,
    about: 'Open balance of issued invoices by how late they are today, net of payments and credit notes.',
    cols: [{ key: 'client_name', head: 'Client' }, { key: 'currency', head: 'Cur.' }, { key: 'not_due', head: 'Not due', money: true }, { key: 'days_1_30', head: '1–30', money: true }, { key: 'days_31_60', head: '31–60', money: true }, { key: 'days_61_90', head: '61–90', money: true }, { key: 'days_over_90', head: '90+', money: true }, { key: 'total', head: 'Total', money: true }, { key: 'invoices', head: 'Invoices' }] },
  { key: 'revenue', title: 'Revenue by month', fn: 'report_revenue', ranged: true,
    about: 'Invoiced (issued invoices), credited (issued credit notes) and received (payments) per month.',
    cols: [{ key: 'month', head: 'Month' }, { key: 'currency', head: 'Cur.' }, { key: 'invoiced', head: 'Invoiced', money: true }, { key: 'credited', head: 'Credited', money: true }, { key: 'net_invoiced', head: 'Net invoiced', money: true }, { key: 'received', head: 'Received', money: true }] },
  { key: 'expenses', title: 'Expenses by category', fn: 'report_expenses', ranged: true,
    about: 'Approved and paid expenses per month and category. Drafts and rejected bills are not costs.',
    cols: [{ key: 'month', head: 'Month' }, { key: 'category', head: 'Category' }, { key: 'currency', head: 'Cur.' }, { key: 'bills', head: 'Bills' }, { key: 'total', head: 'Total', money: true }, { key: 'paid', head: 'Paid', money: true }, { key: 'unpaid', head: 'Unpaid', money: true }] },
  { key: 'profitability', title: 'Project profitability', fn: 'report_project_profitability', ranged: false,
    about: 'Invoiced revenue (net of tax and credit notes) against approved and paid expenses, per project. Invoices of no project are not counted.',
    cols: [{ key: 'project_ada_id', head: 'Project ID' }, { key: 'project_name', head: 'Project' }, { key: 'currency', head: 'Cur.' }, { key: 'invoiced', head: 'Invoiced', money: true }, { key: 'credited', head: 'Credited', money: true }, { key: 'cost', head: 'Cost', money: true }, { key: 'margin', head: 'Margin', money: true }] },
  { key: 'pipeline', title: 'Pipeline', fn: 'report_pipeline', ranged: true,
    about: 'Leads and quotes created in the period, by status and division.',
    cols: [{ key: 'stage', head: 'Stage' }, { key: 'status', head: 'Status' }, { key: 'division', head: 'Division' }, { key: 'currency', head: 'Cur.' }, { key: 'n', head: 'Count' }, { key: 'value', head: 'Value', money: true }] },
];

export const iso = (d: Date) => d.toISOString().slice(0, 10);
export function range(sp: { from?: string; to?: string }) {
  const to = sp.to && /^\d{4}-\d{2}-\d{2}$/.test(sp.to) ? sp.to : iso(new Date());
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : iso(new Date(Date.now() - 180 * 864e5));
  return { from, to };
}

export async function runReport(spec: ReportSpec, from: string, to: string) {
  return call<Record<string, any>[]>(spec.fn, spec.ranged ? { p_from: from, p_to: to } : {});
}

/** RFC 4180 CSV; cells that could be read as a spreadsheet formula are prefixed so they stay text. */
export function toCsv(spec: ReportSpec, rows: Record<string, any>[]): string {
  const cell = (v: unknown) => {
    let s = v === null || v === undefined ? '' : String(v);
    if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = "'" + s;
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [spec.cols.map((c) => cell(c.head)).join(','), ...rows.map((r) => spec.cols.map((c) => cell(r[c.key])).join(','))].join('\r\n') + '\r\n';
}
