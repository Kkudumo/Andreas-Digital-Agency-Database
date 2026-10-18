import { createHash } from 'node:crypto';

// Pure helpers, kept apart from the HTTP server so they can be tested without a database.
export const hashKey = (key: string) => createHash('sha256').update(key).digest('hex');

// SQLSTATE -> HTTP, as set out in docs/api/PUBLIC_API.md
export function statusFor(code?: string): number {
  switch (code) {
    case '42501': return 403;
    case 'P0002': return 404;
    case '22023': case '23514': return 422;
    case '23505': case '23P01': case 'P0001': return 409;   // taken / duplicate / not allowed in the booking's current state
    case '54000': return 422;
    default: return 500;
  }
}

export class RateLimiter {
  private hits = new Map<string, { n: number; reset: number }>();
  constructor(private max: number, private windowMs: number) {}
  allow(id: string, now = Date.now()): boolean {
    const h = this.hits.get(id);
    if (!h || h.reset <= now) { this.hits.set(id, { n: 1, reset: now + this.windowMs }); return true; }
    h.n += 1; return h.n <= this.max;
  }
  sweep(now = Date.now()) { for (const [k, v] of this.hits) if (v.reset <= now) this.hits.delete(k); }
}

export const clip = (v: unknown, max: number): string | null => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null);
export const UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];
export function cleanUtm(v: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (v && typeof v === 'object') for (const k of UTM_KEYS) { const s = clip((v as any)[k], 200); if (s) out[k] = s; }
  return out;
}
