import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { REPORTS, range, runReport, toCsv } from '@/lib/reports';

// The CSV is the same function call as the page, under the caller's own session: it can only contain what the caller may read.
export async function GET(req: Request) {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return new NextResponse('Sign in required', { status: 401 });
  const u = new URL(req.url);
  const spec = REPORTS.find((r) => r.key === u.searchParams.get('report'));
  if (!spec) return new NextResponse('Unknown report', { status: 404 });
  const { from, to } = range({ from: u.searchParams.get('from') ?? undefined, to: u.searchParams.get('to') ?? undefined });
  const { data, error } = await runReport(spec, from, to);
  if (error) return new NextResponse('The report could not be produced', { status: 500 });
  return new NextResponse(toCsv(spec, data ?? []), {
    headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="${spec.key}-${to}.csv"`, 'cache-control': 'no-store' },
  });
}
