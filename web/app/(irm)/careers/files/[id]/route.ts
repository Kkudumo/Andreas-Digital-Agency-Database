import { NextResponse, type NextRequest } from 'next/server';
import { createClient } from '@/lib/supabase/server';

// Opens an applicant's file with a link valid for one minute. Both the file record and the storage object are read
// under the signed-in user's own session, so the database decides (only those who may read the application).
export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.redirect(new URL('/login', request.url));
  const { data: f } = await supabase.from('application_files').select('storage_key, file_name').eq('id', id).maybeSingle();
  if (!f) return new NextResponse('Not found', { status: 404 });
  const { data, error } = await supabase.storage.from('applications').createSignedUrl(f.storage_key, 60, { download: f.file_name });
  if (error || !data?.signedUrl) return new NextResponse('Not found', { status: 404 });
  return NextResponse.redirect(data.signedUrl, { headers: { 'Cache-Control': 'no-store' } });
}
