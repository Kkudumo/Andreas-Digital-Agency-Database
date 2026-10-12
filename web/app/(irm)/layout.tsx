import { requireAccess, canAnywhere, can } from '@/lib/access';
import { signOut } from '../login/actions';
import { Nav } from '@/components/nav';

export default async function IrmLayout({ children }: { children: React.ReactNode }) {
  const access = await requireAccess();
  // The menu only reflects what the database will allow; it is not what enforces it.
  const items = [
    { href: '/search', label: 'Search ADA Hub', show: true, group: '' },
    { href: '/dashboard', label: 'Dashboard', show: true, group: '' },
    { href: '/organization', label: 'Organization', show: true, group: 'Organization' },
    { href: '/staff', label: 'Staff', show: true, group: 'Organization' },
    { href: '/clients', label: 'Clients', show: canAnywhere(access, 'clients.view'), group: 'Operations' },
    { href: '/projects', label: 'Projects', show: canAnywhere(access, 'projects.view'), group: 'Operations' },
    { href: '/expenses', label: 'Expenses', show: canAnywhere(access, 'expenses.view'), group: 'Finance' },
    { href: '/credit-notes', label: 'Credit notes', show: canAnywhere(access, 'credit_notes.view'), group: 'Finance' },
    { href: '/billing', label: 'Billing runs', show: canAnywhere(access, 'invoices.view'), group: 'Finance' },
    { href: '/reports', label: 'Reports', show: true, group: 'Finance' },
    { href: '/access', label: 'Access control', show: can(access, 'roles.view'), group: 'Governance' },
    { href: '/audit', label: 'Audit log', show: can(access, 'audit.view'), group: 'Governance' },
  ].filter((i) => i.show);

  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">ADA IRM<small>Andreas Digital Agency</small></div>
        <Nav items={items} />
        <div className="who">
          <b>{access.staff.full_name}</b>
          <span className="id">{access.staff.ada_id}</span>
          <div>{access.staff.position ?? 'No position set'}{access.staff.division_name ? ` · ${access.staff.division_name}` : ''}</div>
          <form action={signOut}><button type="submit">Sign out</button></form>
        </div>
      </aside>
      <main className="main">
        <form action="/search" method="get" role="search" style={{ marginBottom: '1.2rem' }}>
          <input name="q" placeholder="Search ADA Hub — a name, an ID, type:client Zeta, related:<id>" aria-label="Search ADA Hub" />
        </form>
        {children}
      </main>
    </div>
  );
}
