import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

const LOGIN_PATH = '/IMR/login';

// Refreshes the Supabase session and keeps signed-out visitors on the ADA IRM login.
// This is a convenience redirect, not the security boundary: the database enforces access.
export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return new NextResponse('IRM is not configured: missing Supabase environment variables.', { status: 500 });

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  const { data } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;
  const isLoginPath = path === LOGIN_PATH || path === '/login';

  if (!data.user && !isLoginPath) {
    return NextResponse.redirect(new URL(LOGIN_PATH, request.url));
  }

  // Keep the legacy path working while making /IMR/login the canonical entry point.
  if (!data.user && path === '/login') {
    return NextResponse.redirect(new URL(LOGIN_PATH, request.url));
  }

  if (data.user && (isLoginPath || path === '/')) {
    return NextResponse.redirect(new URL('/search', request.url));
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)'],
};
