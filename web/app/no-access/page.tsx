import { signOut } from '../login/actions';

export default function NoAccess() {
  return (
    <main className="center">
      <div className="card login">
        <h1>No ADA access</h1>
        <p className="muted">
          You are signed in, but this login is not linked to an active ADA staff record
          (or the account is suspended). Ask an ADA administrator to link or reactivate it.
        </p>
        <form action={signOut}><button className="primary" type="submit">Sign out</button></form>
      </div>
    </main>
  );
}
