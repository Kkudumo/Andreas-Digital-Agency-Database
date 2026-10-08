import { signIn } from './actions';
import { Flash } from '@/components/ui';

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <main className="center">
      <div className="card login">
        <div className="brand">ADA IRM<small>Andreas Digital Agency · internal system</small></div>
        <Flash error={error} />
        <form action={signIn} className="stack">
          <label>Email<input name="email" type="email" autoComplete="username" required /></label>
          <label>Password<input name="password" type="password" autoComplete="current-password" required /></label>
          <button className="primary" type="submit">Sign in</button>
        </form>
        <p className="muted small" style={{ marginTop: '1rem' }}>
          Access is by invitation only. Every action in this system is recorded.
        </p>
      </div>
    </main>
  );
}
