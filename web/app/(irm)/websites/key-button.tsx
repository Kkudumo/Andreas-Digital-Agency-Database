'use client';
import { useActionState, useState } from 'react';
import { issueKeyAction } from './actions';
import type { KeyState } from '@/lib/websites';

// Creates (or replaces) a website's access key and shows it once. Leaving or reloading the page loses it;
// only its first characters stay visible in the list. Replacing a key stops the old one immediately.
export function KeyButton({ id, site, hasKey }: { id: string; site: string; hasKey: boolean }) {
  const [state, action, pending] = useActionState<KeyState, FormData>(issueKeyAction, {});
  const [copied, setCopied] = useState(false);
  if (state.key) {
    return (
      <div className="keybox" role="status">
        <b>Access key for {state.site}. Copy it now: it will not be shown again.</b>
        <code className="keyvalue">{state.key}</code>
        <button type="button" onClick={async () => { await navigator.clipboard.writeText(state.key!); setCopied(true); }}>
          {copied ? 'Copied' : 'Copy key'}
        </button>
        <div className="muted small">Paste it into that website&apos;s Vercel settings as <code>ADA_API_KEY</code>.</div>
      </div>
    );
  }
  return (
    <form action={action} onSubmit={(e) => { if (hasKey && !confirm(`Replace the key for ${site}? The old key stops working at once.`)) e.preventDefault(); }}>
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="site" value={site} />
      <button type="submit" disabled={pending}>{pending ? 'Creating…' : hasKey ? 'Replace key' : 'Create access key'}</button>
      {state.error && <div className="flash error" role="alert">{state.error}</div>}
    </form>
  );
}
