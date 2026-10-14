import { createBrowserClient } from '@supabase/ssr';

// Browser-side client bound to the signed-in user's session. Used ONLY to move file bytes to and from the private `documents` bucket,
// whose policies ask the Documents module (document_can) who may do what. Everything else goes through server actions and controlled functions.
export function createBrowserSupabase() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) throw new Error('Supabase is not configured');
  return createBrowserClient(url, key);
}
