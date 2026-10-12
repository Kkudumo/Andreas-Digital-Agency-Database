// After a price or a publication change, tell the static websites to rebuild so their pages pick it up (they read the public API when they build).
// ADA_REBUILD_HOOKS is a comma-separated list of deploy-hook URLs (Vercel: project -> Settings -> Git -> Deploy Hooks), set by the owner in the host's
// environment. The URLs are secrets: never logged, never shown. A failure never blocks the save; the page says whether the websites were told.
export async function rebuildWebsites(): Promise<'sent' | 'none' | 'partial'> {
  const hooks = (process.env.ADA_REBUILD_HOOKS ?? '').split(',').map((s) => s.trim()).filter((s) => /^https:\/\//.test(s));
  if (hooks.length === 0) return 'none';
  const results = await Promise.all(hooks.map(async (url) => {
    try { const r = await fetch(url, { method: 'POST', signal: AbortSignal.timeout(4000) }); return r.ok; } catch { return false; }
  }));
  return results.every(Boolean) ? 'sent' : 'partial';
}
