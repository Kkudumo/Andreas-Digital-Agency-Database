import { createClient } from '@/lib/supabase/server';

export type Rec = Record<string, any>;
export type DbError = { code?: string; message?: string } | null;

/**
 * The only way the pilot interface talks to the database for anything beyond a plain read:
 * a named controlled function, called under the signed-in user's own session (RLS and the
 * function's own permission checks decide). No service-role key, no direct writes to protected tables.
 */
export async function call<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<{ data: T | null; error: DbError }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(fn, args);
  return { data: (data ?? null) as T | null, error };
}

/** Where a record lives in the interface. Anything without a dedicated page goes to the generic record page. */
export function pathFor(domain: string, key: string, institutionalId: string): string {
  switch (domain) {
    case 'clients': return `/clients/${key}`;
    case 'projects': return `/projects/${key}`;
    case 'quotes': return `/quotes/${key}`;
    case 'contracts': return `/contracts/${key}`;
    case 'invoices': return `/invoices/${key}`;
    case 'expenses': return `/expenses/${key}`;
    case 'credit_notes': return `/credit-notes/${key}`;
    default: return `/e/${institutionalId}`;
  }
}

/** A link target that works for any institutional ID or legacy ADA ID: the resolver decides where it goes. */
export const rid = (id?: string | null) => (id ? `/r/${encodeURIComponent(id)}` : '#');

export const money = (n?: number | string | null, cur?: string | null) =>
  n === null || n === undefined || n === '' ? '—' : `${cur ?? 'NAD'} ${Number(n).toLocaleString('en-GB', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
