# ADA Hub visual assets

## Official logo sources

ADA's approved logo library is https://www.andreasdigitalagency.com/media/logos

- Primary white, dark backgrounds: https://www.andreasdigitalagency.com/media/logos/ada-primary-white-logo
- Primary blue, light backgrounds: https://www.andreasdigitalagency.com/media/logos/ada-primary-blue-logo

Do **not** redraw or generate logo variants.

The web UI supports the following **public build-time URL variables**:

- `NEXT_PUBLIC_ADA_PRIMARY_WHITE_LOGO_URL`: the actual direct URL of the approved white logo **file** (SVG/PNG/WebP).
- `NEXT_PUBLIC_ADA_PRIMARY_BLUE_LOGO_URL`: the actual direct URL of the approved blue logo **file** (SVG/PNG/WebP).

The official logo detail pages are HTML, not file URLs. They must **not** be set directly as the variables. Download verified original brand files from the official library and host them alongside the ADA Hub application (preferred) or at a trusted static URL, then point the variables at those files. Without these variables the sign-in and sidebar retain a textual ADA placeholder rather than rendering a broken image.

No Supabase credentials are required to configure the public brand assets.

## Real photograph used for decorative hero backgrounds

Photographer: **Pic Kaca**, via Unsplash.

Source: https://unsplash.com/photos/modern-office-building-interior-at-night-with-lights-on-dxKoOnSgsEI

Image endpoint: `https://images.unsplash.com/photo-1762271458610-5f402f8dedf3`.

License: Unsplash License, marked free to use on the source page. The photo represents **generic architecture**, *not* ADA's premises.

The CSS currently serves the photo from Unsplash. Before production, prefer downloading and optimizing a licensed original into `web/public/media/` and substituting a local URL, so the visual is stable without reliance on a third-party image host.

## Acceptance checks

Verify phone widths of 320, 375 and 430px; tablet at 768px; desktop at 1280px and 1440px; no horizontal body overflow. Check contrast of text on the real photo and image-loading fallback, correct official logo contrast, main navigation, keyboard focus, and authenticated CEO permissions. Never substitute demo data or fictional financial metrics in production.
