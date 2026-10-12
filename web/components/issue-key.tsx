'use client';
import { useActionState, useState } from 'react';
import { issueWebsiteKeyAction, type IssueKeyState } from '@/app/(irm)/websites/actions';

/** Issues or rotates a website's API key. The key is shown here once, in this page's memory only: it is never put in a URL, a cookie or the database. */
export function IssueKey({ id, hasKey }: { id: string; hasKey: boolean }) {
  const [state, action, pending] = useActionState<IssueKeyState, FormData>(issueWebsiteKeyAction, {});
  const [copied, setCopied] = useState(false);
  return (
    <form action={action} onSubmit={(e) => { if (hasKey && !confirm('Issuing a new key stops the old one working immediately. Continue?')) e.preventDefault(); }}>
      <input type="hidden" name="website" value={id} />
      <button type="submit" disabled={pending}>{hasKey ? 'Rotate key' : 'Issue key'}</button>
      {state.error && <div className="flash error" role="alert">{state.error}</div>}
      {state.key && (
        <div className="flash ok" role="status">
          <b>Copy this key now. It is shown once and cannot be recovered.</b>
          <div className="mono" style={{ wordBreak: 'break-all', margin: '.4rem 0' }}>{state.key}</div>
          <button type="button" onClick={async () => { await navigator.clipboard.writeText(state.key!); setCopied(true); }}>{copied ? 'Copied' : 'Copy'}</button>
        </div>
      )}
    </form>
  );
}
