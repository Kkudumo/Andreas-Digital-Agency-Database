'use server';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

export async function verifyMfa(formData: FormData) {
  const factorId = String(formData.get('factorId') ?? '');
  const code = String(formData.get('code') ?? '').replace(/\s/g, '');
  const supabase = await createClient();
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code });
  if (error) redirect('/mfa?error=' + encodeURIComponent('That code did not work. Check the time on your phone and try the newest code.'));
  redirect('/dashboard');
}
