'use server';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { back, friendly } from '@/lib/flash';
import { str } from '@/lib/format';

export async function createStaff(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from('staff').insert({
    full_name: str(fd.get('full_name')),
    email: str(fd.get('email')),
    work_phone: str(fd.get('work_phone')),
    position_id: str(fd.get('position_id')),
    primary_division_id: str(fd.get('primary_division_id')),
    start_date: str(fd.get('start_date')),
  });
  if (error) back('/staff/new', 'error', friendly(error));
  revalidatePath('/staff');
  back('/staff', 'ok', 'Staff record created.');
}
