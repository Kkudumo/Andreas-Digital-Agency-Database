import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { Flash } from '@/components/ui';
import { signOut } from '../login/actions';
import { verifyMfa } from './actions';

// Second step of sign-in. Everyone must use an authenticator app (TOTP): the first time, this page
// enrols one and shows its QR code; afterwards it asks for the current 6-digit code. The middleware
// sends every signed-in user here until their session is at assurance level aal2.
export default async function MfaPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect('/login');

  const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (aal?.currentLevel === 'aal2') redirect('/dashboard');

  const { data: factors } = await supabase.auth.mfa.listFactors();
  const verified = (factors?.totp ?? []).find((f) => f.status === 'verified');

  let enrolment: { factorId: string; qr: string; secret: string } | null = null;
  if (!verified) {
    // Remove half-finished enrolments so each visit shows one fresh QR code.
    for (const f of factors?.all ?? []) {
      if (f.factor_type === 'totp' && f.status !== 'verified') await supabase.auth.mfa.unenroll({ factorId: f.id });
    }
    const { data, error: enrolError } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'ADA Hub authenticator' });
    if (enrolError || !data) {
      return (
        <main className="center"><div className="card login">
          <h1>Authenticator setup</h1>
          <Flash error="The authenticator could not be set up. Please try again in a minute." />
          <form action={signOut}><button type="submit">Sign out</button></form>
        </div></main>
      );
    }
    enrolment = { factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret };
  }

  return (
    <main className="center">
      <div className="card login">
        <div className="brand">ADA Hub<small>Andreas Digital Agency · second step</small></div>
        <Flash error={error} />
        {enrolment ? (
          <>
            <p>Set up your authenticator app (Google Authenticator, Microsoft Authenticator or similar): scan this code, then type the 6-digit number it shows.</p>
            {/* The QR code is an SVG data URL produced by Supabase Auth. */}
            <img src={enrolment.qr} alt="Authenticator QR code" width={200} height={200} style={{ background: '#fff', padding: 8 }} />
            <p className="muted small">Can&apos;t scan? Enter this key in the app: <code>{enrolment.secret}</code></p>
          </>
        ) : (
          <p>Open your authenticator app and type the current 6-digit code for ADA Hub.</p>
        )}
        <form action={verifyMfa} className="stack">
          <input type="hidden" name="factorId" value={enrolment ? enrolment.factorId : verified!.id} />
          <label>Code<input name="code" inputMode="numeric" pattern="[0-9]{6}" maxLength={6} autoComplete="one-time-code" required /></label>
          <button className="primary" type="submit">Continue</button>
        </form>
        <form action={signOut} style={{ marginTop: '1rem' }}><button type="submit">Sign out</button></form>
      </div>
    </main>
  );
}
