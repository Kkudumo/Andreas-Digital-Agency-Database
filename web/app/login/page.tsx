import Link from 'next/link';
import { signIn } from './actions';
import { Flash } from '@/components/ui';

const officialWhiteLogo=process.env.NEXT_PUBLIC_ADA_PRIMARY_WHITE_LOGO_URL;
const officialBlueLogo=process.env.NEXT_PUBLIC_ADA_PRIMARY_BLUE_LOGO_URL;

export default async function LoginPage({searchParams}:{searchParams:Promise<{error?:string}>}) {
 const {error}=await searchParams;
 return <main className="ada-login-page">
  <section className="ada-login-story" aria-label="ADA Hub overview">
   <Link href="/login" className="ada-login-logo">{officialWhiteLogo ? <img src={officialWhiteLogo} alt="Andreas Digital Agency official white logo" className="ada-login-official-logo"/> : <span>A</span>}<strong>ADA Hub</strong></Link>
   <div className="ada-login-story-body">
    <p className="ada-eyebrow">ANDREAS DIGITAL AGENCY</p>
    <h1>One agency.<br/><em>One connected workspace.</em></h1>
    <p>Clients, projects, people, finances and institutional decisions — managed with clarity, accountability and one source of truth.</p>
    <div className="ada-login-features"><span>Institutional operations</span><span>Secure role-based access</span><span>Six connected divisions</span></div>
   </div>
   <p className="ada-login-copyright">ADA Core Architecture · Internal institutional platform</p>
  </section>
  <section className="ada-login-panel">
   <div className="ada-login-mobile-brand">{officialBlueLogo ? <img src={officialBlueLogo} alt="Andreas Digital Agency official blue logo" className="ada-login-official-logo"/> : <span>A</span>}<strong>ADA Hub</strong></div>
   <div className="ada-login-form-wrap">
    <div className="ada-login-heading"><p className="ada-eyebrow">STAFF PORTAL</p><h2>Welcome back</h2><p>Sign in with your authorized agency account to continue.</p></div>
    <Flash error={error}/>
    <form action={signIn} className="ada-login-form">
     <label htmlFor="ada-email">Work email address<input id="ada-email" name="email" type="email" inputMode="email" autoComplete="username" placeholder="you@andreasdigitalagency.com" required/></label>
     <label htmlFor="ada-password">Password<input id="ada-password" name="password" type="password" autoComplete="current-password" placeholder="Enter your password" required/></label>
     <button className="ada-login-submit" type="submit">Sign in to ADA Hub <span aria-hidden="true">→</span></button>
    </form>
    <div className="ada-login-security"><span aria-hidden="true">◈</span><p>Private staff workspace. Access is by invitation and permissions are enforced by ADA Core.</p></div>
   </div>
   <p className="ada-login-help">Having trouble signing in? Contact your ADA system administrator.</p>
  </section>
 </main>;
}
