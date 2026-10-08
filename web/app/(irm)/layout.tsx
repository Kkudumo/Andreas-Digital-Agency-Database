import { requireAccess, canAnywhere, can } from '@/lib/access';
import { signOut } from '../login/actions';
import { Nav } from '@/components/nav';

export default async function IrmLayout({ children }: { children: React.ReactNode }) {
  const access = await requireAccess();
  // The menu only reflects what the database will allow; it is not what enforces it.
  const items = [
    { href: '/dashboard', label: 'Dashboard', show: true, group: '' },
    { href: '/organization', label: 'Organization', show: true, group: 'Organization' },
    { href: '/staff', label: 'Staff', show: true, group: 'Organization' },
    { href: '/clients', label: 'Clients', show: canAnywhere(access, 'clients.view'), group: 'Operations' },
    { href: '/projects', label: 'Projects', show: canAnywhere(access, 'projects.view'), group: 'Operations' },
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
      <main className="main">{children}</main>
    </div>
  );
}
