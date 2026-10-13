import Link from 'next/link';
import { signIn } from './actions';
import { Flash } from '@/components/ui';
import { PasswordField } from '@/components/password-field';

const officialWhiteLogo=process.env.NEXT_PUBLIC_ADA_PRIMARY_WHITE_LOGO_URL;
const officialBlueLogo=process.env.NEXT_PUBLIC_ADA_PRIMARY_BLUE_LOGO_URL;

export default async function LoginPage({searchParams}:{searchParams:Promise<{error?:string}>}) {
 const {error}=await searchParams;
 return <main className="ada-login-page">
  <section className="ada-login-story" aria-label="ADA Hub overview">
   <Link href="/login" className="ada-login-logo">{officialWhiteLogo ? <img src={officialWhiteLogo} alt="Andreas Digital Agency official white logo" className="ada-login-official-logo"/> : <span>ADA</span>}<strong>Andreas Digital Agency</strong></Link>
   <div className="ada-login-story-body">
    <p className="ada-eyebrow">Staff access</p>
    <h1>ADA Hub / ADA&nbsp;Core</h1>
    <p>Secure access to clients, projects, quotes, contracts, invoices, documents and the business records of the whole agency.</p>
    <div className="ada-login-features">
     <span data-n="01">Controlled access<small>Only authorised ADA staff accounts can continue.</small></span>
     <span data-n="02">Multi-factor security<small>Every sign-in requires an authenticator app verification step.</small></span>
     <span data-n="03">Protected records<small>What you see is decided by your role and division, and enforced by the database.</small></span>
    </div>
   </div>
   <p className="ada-login-copyright">Technology. Systems. Growth.</p>
  </section>
  <section className="ada-login-panel">
   <div className="ada-login-mobile-brand">{officialBlueLogo ? <img src={officialBlueLogo} alt="Andreas Digital Agency official blue logo" className="ada-login-official-logo"/> : <span>ADA</span>}<strong>Andreas Digital Agency</strong></div>
   <div className="ada-login-form-wrap">
    <div className="ada-login-heading"><p className="ada-eyebrow">Staff portal</p><h2>Staff sign in</h2><p>Enter the credentials for your authorised ADA account. A second security verification is required before ADA Hub opens.</p></div>
    <Flash error={error}/>
    <form action={signIn} className="ada-login-form">
     <label htmlFor="ada-email">Email address<input id="ada-email" name="email" type="email" inputMode="email" autoComplete="username" placeholder="name@andreasdigitalagency.com" required/></label>
     <label htmlFor="ada-password">Password<PasswordField id="ada-password" name="password"/></label>
     <button className="ada-login-submit" type="submit">Continue securely <span aria-hidden="true">→</span></button>
    </form>
    <div className="ada-login-security"><span aria-hidden="true">◈</span><p>Access is restricted to authorised ADA personnel. Public visitors should return to the main website.</p></div>
   </div>
   <p className="ada-login-help"><a href="https://www.andreasdigitalagency.com">← Back to the main website</a></p>
  </section>
 </main>;
}
