import { redirect } from 'next/navigation';

type PgError = { code?: string; message?: string } | null | undefined;

const SAFE_CODES = new Set(['42501', '23514', 'P0002']); // our own triggers raise readable messages with these codes

/** Turns a database error into a short message that is safe to show. */
export function friendly(error: PgError): string {
  if (!error) return 'Something went wrong.';
  if (error.code === '42501') {
    const m = error.message ?? '';
    return m.startsWith('new row violates') || m.startsWith('permission denied')
      ? 'You do not have permission to do that.'
      : m || 'You do not have permission to do that.';
  }
  if (SAFE_CODES.has(error.code ?? '') && error.message) return error.message;
  if (error.code === '23505') return 'A record with those details already exists.';
  if (error.code === '23503') return 'That references a record that does not exist.';
  if (error.code === '23502' || error.code === '22P02') return 'Please complete all required fields correctly.';
  return 'The change could not be saved.';
}

export function back(path: string, kind: 'error' | 'ok', message: string): never {
  const sep = path.includes('?') ? '&' : '?';
  redirect(`${path}${sep}${kind}=${encodeURIComponent(message)}`);
}
