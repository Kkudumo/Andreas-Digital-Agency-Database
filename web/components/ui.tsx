import Link from 'next/link';

export function Flash({ error, ok }: { error?: string; ok?: string }) {
  if (error) return <div className="flash error" role="alert">{error}</div>;
  if (ok) return <div className="flash ok" role="status">{ok}</div>;
  return null;
}

const TONE: Record<string, string> = {
  active: 'ok', completed: 'ok', done: 'ok', public: 'ok',
  on_hold: 'warn', blocked: 'warn', prospect: 'warn', proposed: 'warn', high: 'warn', restricted: 'warn', invited: 'warn',
  urgent: 'bad', cancelled: 'bad', suspended: 'bad', disabled: 'bad', terminated: 'bad',
};
export function Badge({ v }: { v?: string | null }) {
  if (!v) return <span className="muted">—</span>;
  if (v === 'confidential') return <span className="badge conf">confidential</span>;
  return <span className={`badge ${TONE[v] ?? ''}`}>{v.replace(/_/g, ' ')}</span>;
}

export function PageHead({ title, sub, action }: { title: string; sub?: string; action?: { href: string; label: string } | null }) {
  return (
    <div className="head">
      <div>
        <h1>{title}</h1>
        {sub && <div className="muted">{sub}</div>}
      </div>
      {action && <Link className="primary" href={action.href}>{action.label}</Link>}
    </div>
  );
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <div className="empty">{children}</div>;
}
