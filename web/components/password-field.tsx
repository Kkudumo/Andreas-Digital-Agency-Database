'use client';
import { useState } from 'react';

// Password input with a "Show" toggle, as on the ADA Admin sign-in.
export function PasswordField({ id, name }: { id: string; name: string }) {
  const [shown, setShown] = useState(false);
  return (
    <span className="pw-field">
      <input id={id} name={name} type={shown ? 'text' : 'password'} autoComplete="current-password" placeholder="Enter your password" required />
      <button type="button" onClick={() => setShown((v) => !v)} aria-pressed={shown} aria-label={shown ? 'Hide password' : 'Show password'}>{shown ? 'Hide' : 'Show'}</button>
    </span>
  );
}
