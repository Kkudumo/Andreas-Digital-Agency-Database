import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'ADA IRM',
  description: 'Andreas Digital Agency — internal operations platform',
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
