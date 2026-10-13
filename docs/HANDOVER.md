# Handover: where the ADA Core work stands

> Copy of the owner's planning note, kept in the repo so any session can continue. Contains no passwords or keys.


Updated 13 October 2026. Repos: `Kkudumo/Andreas-Digital-Agency-Database` (ADA Core, default branch `claude/pensive-planck-k9zod1`) and the six website repos.

## Where we are

- **ADA Core is live.** It runs in its own Supabase project: organization "ADA Core", account hello@andreasdigitalagency.com, project ref `uyhwcbjfvfkqsixthxkn`, region Frankfurt.
  - All 52 database steps were applied on 12 October 2026, and every one succeeded first time.
  - Checked on the real server: 139 tables, all with row-level security; the public has no table access; the website-only functions are closed to the web.
  - **ADA Hub is live** at https://hub.andreasdigitalagency.com (Vercel project `ada-hub`, root `web/`, functions in Frankfurt). Env: `NEXT_PUBLIC_SUPABASE_URL` (plain), `NEXT_PUBLIC_SUPABASE_ANON_KEY` (publishable key, added by the owner, production only). DNS: Namecheap CNAME `hub` → `cname.vercel-dns.com.`
  - Sign-in requires an authenticator app (TOTP, aal2). This is pull request #4 (`claude/hub-mfa-deploy`). Production was deployed from that branch; **#4 must be merged** or the next push to the default branch will republish ADA Hub without the authenticator step.
  - **First staff member:** Kudumo Kupembona Andreas, role CEO, login ceo@andreasdigitalagency.com (auth user `6854c8f2-…`), created with `bootstrap_first_admin` on 12 October 2026. No other data yet.
  - Pull request #3 (deployment notes) is open for review.
- **The websites still use their old database.** The main site's `/admin` uses a separate Supabase project with its own tables: `admin_profiles`, `career_opportunities`, `career_applications`, `content_posts`, analytics and consent. The division sites are static pages with prices written into the page files.
- **ADA Core already has the staff app (ADA Hub, the `web/` folder).** It has search, clients, projects, quotes, contracts, invoices, payments, expenses, credit notes, billing, reports, dashboard and staff. It shows or hides each action using the signed-in person's permissions, read from the database (`my_access()`).

## The goal (owner, 12 October 2026)

> Everything on all our websites should come from the database. When I create a user, their login and level of access should come from the database. When the CEO logs in there are things only a CEO sees: invoices, employees, prices, everything in the database.

## How it will work

### 1. One login for every staff member, decided by the database

- **Login.** Everyone signs in to **ADA Hub** (planned address: hub.andreasdigitalagency.com) with Supabase Auth in the ADA Core project. MFA (authenticator app) is required, like the current admin.
- **Who someone is.** Each login is linked to a `staff` record with `link_staff_account()`.
- **What they may do.** This comes from their role, given org-wide or for one division. The roles already exist:

  | Role | Typical access |
  |---|---|
  | CEO | everything: finance, staff, prices, approvals, audit, roles |
  | Administration Officer | staff records, organization, documents |
  | Finance Officer | invoices, payments, expenses, credit notes, finance reports |
  | Division Lead (per division) | that division's clients, projects, quotes; approvals within limits |
  | Division Staff (per division) | that division's day-to-day work |
  | Auditor | read-only, including the audit log |
  | Recruiter | vacancies and applications |

- **The full list** of 155 permissions is `supabase/seed_data/permission_matrix.csv`. Changing who sees what means editing that matrix through a new migration, never code.
- **Enforcement.** The database refuses anything a person may not do, even if a screen shows the button by mistake. Hidden records look like records that don't exist.
- **Adding a new employee.**
  1. Create the staff record in ADA Hub.
  2. Invite their email.
  3. They set their own password and authenticator.
  4. Assign a role.

  Their access follows from step 4.
- **The website `/admin` retires.** "Administrator Login" on the Portals page points to ADA Hub, and `admin_profiles` is no longer used.

### 2. Websites read their facts from ADA Core

- **One public API service** reads from ADA Core. It is designed in `docs/api/PUBLIC_API.md` but not built yet.
- **Each website has its own key**, registered in the `websites` table, and may only read what is published.
- **It answers with these facts:** divisions and their status, services, current prices, vacancies, team profiles, portfolio projects, company statistics and published documents such as policies.
- **The forms send into ADA Core** and get back only a reference number:
  - contact and quote forms become `enquiries` (ADA-ENQ-…), then leads and clients;
  - job applications become `applications` (ADA-APP-…).
- **The main site (Next.js)** reads the API when a page is requested, with a short cache.
- **The four division sites (static)** pull the API while they build. A change in ADA Core (for example a new price) sends an event, which triggers a rebuild of that site within minutes. There is no manual editing of page files for facts.

### 3. What still needs a home in ADA Core

| Website content | Plan |
|---|---|
| News, announcements, updates (`content_posts`, also fed to division sites by `/api/updates`) | new **content** module, built on the publication layer design |
| Company facts shown in every footer (phones, emails, address, social links) | new **site settings** records |
| Testimonials, FAQs | content module |
| Long guides and articles on the division sites | stay as page files for now (they rarely change); can move into the content module later |
| Website analytics and cookie-consent records | can stay in the website project; they are not business records |

## Build order

1. **ADA Hub online with the CEO login.** Done 12–13 October 2026, apart from merging pull request #4 and the owner's first sign-in (QR code). Still to do: an invite / set-password page so new staff can be invited (today a login is made in Supabase with "Create new user"), rename the screens from "ADA IRM" to "ADA Hub", add the first real staff and division details.
2. **Real catalogue.**
   - Enter the services and prices from the websites into `services` and `service_prices`.
   - The audit of 8 October has the canonical price table for every division.
3. **Public API service.** Build it and register the six websites with keys.
4. **Prices and services on the websites come from ADA Core.**
   - Division sites at build time; main site at request time.
   - Rebuild on change.
5. **Forms go to ADA Core.**
   - Contact and quote forms on www and ADA Web; old edge functions run in parallel for a week.
6. **Careers.**
   - Vacancy and application screens in ADA Hub.
   - Copy the existing vacancies, applications and CVs across.
   - The careers pages read `public_api.vacancies`.
7. **Content module.**
   - News, settings and testimonials move in.
   - Website `/admin` retired.

## Things to watch

- ADA Core and the old website project both have tables called `events` and `projects` with different meanings. This is why ADA Core has its own project.
- The website project's real schema is not in git. Dump it before copying data.
- Free Supabase plan: 2 free projects per account. ADA Core is on the new account (hello@); the two older projects are on kkudumo65@gmail.com.

## How to continue in a new session

1. Read this document and `docs/README.md`, `docs/operations/DEPLOYMENT.md` in the ADA Core repo.
2. Check that pull request #4 is merged; if not, ask the owner to merge it.
3. Database changes on the live project: run them in the Supabase SQL editor of project `uyhwcbjfvfkqsixthxkn` (signed in as hello@andreasdigitalagency.com), one migration per transaction plus its row in `supabase_migrations.schema_migrations`, as `scripts/supabase-apply.mjs` does. Never type passwords or keys; the owner enters those.
4. Next step is build order step 2 (real catalogue), then step 3 (public API).
