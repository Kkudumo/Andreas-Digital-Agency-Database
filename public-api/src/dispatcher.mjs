// The delivery worker behind ADA Core's events outbox: asks the database for due deliveries (grouped per subscription), POSTs one signed request per
// subscription, and reports success or failure back. The database owns the schedule, back-off and give-up rules (dispatch_claim / dispatch_report);
// this file only moves bytes. It connects as the ada_dispatcher role, which can run those two functions and read no table.
//
// A request carries identifiers and states only:  { "website": "<domain>", "events": [ { id, type, occurred_at, entity: { table, id, ada_id }, payload } ] }
// Signed (when the subscription names a secret):   X-ADA-Timestamp: <unix seconds>   X-ADA-Signature: v1=<hex hmac-sha256 of "<timestamp>.<body>">
// The secret itself lives in THIS process's environment under the name stored in the subscription's secret_ref (e.g. WEBHOOK_SECRET_TECH); the database
// holds only the name. A subscription whose secret is not configured here is NOT sent unsigned: it fails and retries until the secret is set.
import { createHmac } from 'node:crypto';
import net from 'node:net';

const SECRET_NAME = /^[A-Z][A-Z0-9_]{2,60}$/;

/** Webhook targets are chosen by staff, so refuse anything that points inside our own network. (DNS can still point a public name inward; the platform's egress rules are the second line.) */
export function targetProblem(rawUrl, { allowPrivate = false } = {}) {
  let u; try { u = new URL(rawUrl); } catch { return 'invalid address'; }
  if (u.protocol !== 'https:') return 'not https';
  if (allowPrivate) return null;
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.internal') || h.endsWith('.local')) return 'private address';
  if (net.isIP(h)) {
    if (net.isIPv6(h)) return /^(::1?$|f[cd]|fe80|::ffff:)/i.test(h) ? 'private address' : null;
    const [a, b] = h.split('.').map(Number);
    if (a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127)) return 'private address';
  }
  return null;
}

export const sign = (secret, timestamp, body) => 'v1=' + createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex');

async function defaultPost(url, { headers, body, timeoutMs }) {
  const r = await fetch(url, { method: 'POST', headers, body, redirect: 'error', signal: AbortSignal.timeout(timeoutMs) });
  return { status: r.status };
}

/**
 * claim(maxSubscriptions, debounceSeconds) -> [{ subscription_id, url, secret_ref, domain, delivery_ids, events }]
 * report(deliveryIds, ok, error) -> number
 */
export async function runOnce({ claim, report, post = defaultPost, env = process.env, now = () => Date.now(), debounceSeconds = 20, maxSubscriptions = 10, allowPrivate = false, timeoutMs = 10000, log = () => {} }) {
  const batches = await claim(maxSubscriptions, debounceSeconds);
  const out = { batches: batches.length, delivered: 0, failed: 0 };
  for (const b of batches) {
    const fail = async (why) => { out.failed++; log(`delivery to ${b.domain} failed: ${why}`); await report(b.delivery_ids, false, why); };
    try {
      const problem = targetProblem(b.url, { allowPrivate });
      if (problem) { await fail(problem); continue; }
      const body = JSON.stringify({ website: b.domain, events: b.events });
      const headers = { 'content-type': 'application/json', 'user-agent': 'ADA-Core-Dispatcher/1' };
      if (b.secret_ref) {
        const secret = SECRET_NAME.test(b.secret_ref) ? env[b.secret_ref] : undefined;
        if (!secret) { await fail('signing secret is not configured'); continue; }
        const ts = String(Math.floor(now() / 1000));
        headers['x-ada-timestamp'] = ts; headers['x-ada-signature'] = sign(secret, ts, body);
      }
      const { status } = await post(b.url, { headers, body, timeoutMs });
      if (status >= 200 && status < 300) { out.delivered++; await report(b.delivery_ids, true, null); }
      else await fail(`HTTP ${status}`);
    } catch (e) {
      // never put the URL (a deploy-hook URL is a secret) or the error's message into the stored error
      try { await fail(`request failed (${e?.name ?? 'error'})`); } catch (e2) { log(`could not report a failure: ${e2?.name}`); }
    }
  }
  return out;
}
