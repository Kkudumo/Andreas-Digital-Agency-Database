import { requireAccess, canAnywhere, can } from '@/lib/access';
import { signOut } from '../login/actions';
import { HubShell } from '@/components/hub-shell';

export default async function IrmLayout({ children }: { children: React.ReactNode }) {
  const access = await requireAccess();
  // The menu only reflects what the database will allow; it is not what enforces it.
  const items = [
    { href: '/search', label: 'Search ADA Hub', show: true, group: '' },
    { href: '/dashboard', label: 'Dashboard', show: true, group: '' },
    { href: '/organization', label: 'Organization', show: true, group: 'Organization' },
    { href: '/staff', label: 'Staff', show: true, group: 'Organization' },
    { href: '/organization/reviews', label: 'Duplicates', show: canAnywhere(access, 'matching.review'), group: 'Organization' },
    { href: '/clients', label: 'Clients', show: canAnywhere(access, 'clients.view'), group: 'Operations' },
    { href: '/projects', label: 'Projects', show: canAnywhere(access, 'projects.view'), group: 'Operations' },
    { href: '/expenses', label: 'Expenses', show: canAnywhere(access, 'expenses.view'), group: 'Finance' },
    { href: '/credit-notes', label: 'Credit notes', show: canAnywhere(access, 'credit_notes.view'), group: 'Finance' },
    { href: '/billing', label: 'Billing runs', show: canAnywhere(access, 'invoices.view'), group: 'Finance' },
    { href: '/reports', label: 'Reports', show: true, group: 'Finance' },
    { href: '/access', label: 'Access control', show: can(access, 'roles.view'), group: 'Governance' },
    { href: '/audit', label: 'Audit log', show: can(access, 'audit.view'), group: 'Governance' },
  ].filter((i) => i.show);

  return <HubShell
    items={items}
    person={access.staff.full_name}
    staffId={access.staff.ada_id}
    position={access.staff.position ?? 'Team member'}
    division={access.staff.division_name}
    signout={<form action={signOut}><button type="submit">Sign out <span aria-hidden="true">↗</span></button></form>}
  >{children}</HubShell>;
}
