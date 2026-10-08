'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

export function Nav({ items }: { items: { href: string; label: string; group: string }[] }) {
  const path = usePathname();
  let last = '';
  return (
    <nav className="nav" aria-label="Main">
      {items.map((i) => {
        const header = i.group && i.group !== last ? <div className="grp" key={`g-${i.group}`}>{i.group}</div> : null;
        last = i.group;
        const current = path === i.href || path.startsWith(i.href + '/');
        return (
          <span key={i.href} style={{ display: 'contents' }}>
            {header}
            <Link href={i.href} aria-current={current ? 'page' : undefined}>{i.label}</Link>
          </span>
        );
      })}
    </nav>
  );
}
