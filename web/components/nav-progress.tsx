'use client';
import { useEffect, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';

// A thin bar across the top while a clicked link's page is loading, so a slow screen never looks like a dead click.
export function NavProgress() {
  const path = usePathname();
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => { setBusy(false); if (timer.current) clearTimeout(timer.current); }, [path]);
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!a || a.target === '_blank' || a.hasAttribute('download')) return;
      const u = new URL(a.href, location.href);
      if (u.origin !== location.origin || (u.pathname === location.pathname && u.search === location.search) || u.hash && u.pathname === location.pathname) return;
      setBusy(true);
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => setBusy(false), 10000);
    };
    document.addEventListener('click', onClick, true);   // capture: runs before the link's own handler
    return () => document.removeEventListener('click', onClick, true);
  }, []);
  return busy ? <div className="nav-progress" role="progressbar" aria-label="Loading page" data-testid="nav-progress" /> : null;
}
