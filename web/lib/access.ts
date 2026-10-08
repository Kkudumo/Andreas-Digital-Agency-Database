import { cache } from 'react';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

export type Grant = { key: string; division_id: string | null };
export type Access = {
  staff: { id: string; ada_id: string; full_name: string; email: string; position: string | null; division_id: string | null; division_name: string | null };
  roles: { key: string; name: string; division_id: string | null; division_name: string | null }[];
  permissions: Grant[];
};

// Identity + effective permissions, computed by the database (my_access()). Used only to shape
// the interface; the database re-checks every request.
export const getAccess = cache(async (): Promise<Access | null> => {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return null;
  const { data, error } = await supabase.rpc('my_access');
  if (error || !data) return null;
  return data as Access;
});

export async function requireAccess(): Promise<Access> {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect('/login');
  const access = await getAccess();
  if (!access) redirect('/no-access');
  return access;
}

/** Held organization-wide, or (when a division is given) scoped to that division. */
export function can(access: Access, key: string, divisionId?: string | null): boolean {
  return access.permissions.some((g) => g.key === key && (g.division_id === null || g.division_id === divisionId));
}
/** Held in any scope: "is this module relevant to me?" */
export function canAnywhere(access: Access, key: string): boolean {
  return access.permissions.some((g) => g.key === key);
}
/** Divisions in which the user holds a permission; `null` means every division (org-wide). */
export function divisionsFor(access: Access, key: string): string[] | null {
  const grants = access.permissions.filter((g) => g.key === key);
  if (grants.some((g) => g.division_id === null)) return null;
  return grants.map((g) => g.division_id as string);
}
