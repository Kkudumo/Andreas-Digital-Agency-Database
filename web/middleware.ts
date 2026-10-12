import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

// Refreshes the Supabase session and keeps signed-out visitors on /login.
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
  if (!data.user && path !== '/login') {
    return NextResponse.redirect(new URL('/login', request.url));
  }
  if (data.user) {
    // Second factor required: until the session is aal2, the only places a signed-in user may go are the
    // authenticator step and sign-out (the login page's sign-out action posts to /login).
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    const twoStep = aal?.currentLevel === 'aal2';
    if (!twoStep && path !== '/mfa' && path !== '/login') {
      return NextResponse.redirect(new URL('/mfa', request.url));
    }
    if (twoStep && (path === '/login' || path === '/' || path === '/mfa')) {
      return NextResponse.redirect(new URL('/search', request.url));
    }
  }
  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)'],
};
