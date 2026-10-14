# HANDOFF — read this first (written 2026-10-13)

For the next Claude session on this project. The user is the CEO (Kudumo, kkudumo65@gmail.com). Credit on their account was running low, so work may continue under another account.

## Objective

**ADA Hub / ADA Core**: one organised Supabase database (project "ADA Core", id `uyhwcbjfvfkqsixthxkn`) plus a Next.js Hub (`web/`, live at https://hub.andreasdigitalagency.com) that the CEO and staff log into to run the agency. Authorization is RLS plus `has_permission(key, division)`; roles: CEO sees everything; administration and finance see projects; finance sees financial records.

The goal in the user's words: build this **step by step**; the database stays **organised in sections** (careers/applications/staff, divisions as workspaces, live website data such as prices, positions, staff names and news). What is edited in the Hub must show on the websites (e.g. change a minimum price to 1199.99 and the site shows it). The old website "Administrator" system (`/admin` in repo `Kkudumo/ada-main-website`, old Supabase project on another account) is being replaced by the Hub. Its only real data was 3 published `journal_posts`.

UI rule: the Hub uses the website Administrator look (square, flat, navy). **Never** rounded/soft styling.

Repo: `/home/user/Andreas-Digital-Agency-Database`, GitHub `Kkudumo/Andreas-Digital-Agency-Database`. Branch: **`claude/hub-documents`** (not merged to the default branch, so the live Hub does not show the new UI yet; merging is the user's decision).

## Done and live in Supabase (migrations 0001–0056)

Authorization, Documents workspace (0055: storage bucket `documents`, Word/Excel/PDF), database sections and 126 FK indexes (0056, 14th section comes in 0057).

## In progress: migration 0057 (Content + careers) — PARTLY APPLIED LIVE

File: `supabase/migrations/0057_content.sql` (committed locally as `2d17149`; push it). The full test suite passes locally (`./scripts/test-db.sh`, takes ~4 min, run it in the background).

**Applied live so far, via `execute_sql`, NOT recorded in the migrations table:** lines 13–136 of the file — the 5 `content.*` permissions + role grants, entity type `post` (PST/T7) + codebook row, table `content_posts` with indexes, `attach_entity`, audit, triggers, `can_view_post`, `content_posts_guard` and its trigger.

**NOT yet applied (lines 147–end):** (RLS + policies for content_posts, lines 137–145, WERE applied live afterwards; continue from line 147, `content_transition`), `content_transition`, search source, `websites_capabilities_check` replacement (adds `content.read`), `public_api.post_dto/posts/post`, vacancy careers columns + `vacancies_guard` + `vacancy_dto`, `application_profiles` + `public_api.submit_application_profile`, section 14 `content` registry rows.

Next steps for this:
1. Verify live state first (`select to_regclass('content_posts'), relrowsecurity ...`, check the permissions exist). Do NOT re-run lines 13–136 (they would fail/duplicate).
2. Apply lines 137–end in small pieces (MCP calls time out ~60 s): split at the comment-line boundaries (137, 194, 200, 241, 305, 365).
3. Record the migration: insert version `0057` name `content` into `supabase_migrations.schema_migrations` the same way 0055/0056 were recorded (check `list_migrations`).
4. Verify as CEO and anonymous: `select database_sections()` shows 14 sections; `public_api.posts` works only for a website key holding `content.read`.
5. Push: `git push -u origin claude/hub-documents`.

## Next builds (all approved by the user with "proceed")

1. **Hub Content screens** (`web/app/(irm)/content/...`): list, new, edit with a block editor (`body` = list of `{id,type,text}`), workflow buttons calling `content_transition` (submit, approve, publish, unpublish, archive). Add a Content card to division workspaces (`web/app/(irm)/divisions/[key]/page.tsx`) and the menu in `app/(irm)/layout.tsx`. Follow the existing patterns in `web/app/(irm)/documents/*`, `loading.tsx` skeletons, server actions.
2. **Careers screens/fields** in the Hub for vacancies (new fields: slug, location, responsibilities, qualifications, experience, application_instructions, featured) and show `application_profiles` on an application.
3. **Import the 3 real journal posts** as `kind='journal'`, executed as the CEO through `content_transition` so triggers/audit run; keep original `display_date`s and website cover paths. Source CSV: `/root/.claude/uploads/fc7784aa-d715-501f-9562-b4c66fee5713/4d9487ad-journal_posts_rows.csv` (may be gone in a new session — ask the user to re-upload, or use these facts):
   - "The Journal — a record of the work behind the work", slug `the-journal-a-record-of-the-work-behind-the-work`, Personal Milestone, cover `/portraits/kudumo-editorial.webp`, featured, 2026-08-22 18:00+00
   - "Shipping a client website: Voice of Impact Institute", slug `shipping-a-client-website-voice-of-impact-institute`, Achievement, `/portraits/kudumo-blue.webp`, external https://voi-institute.vercel.app/, 2026-08-06 16:00+00
   - "ADA Web Division: from idea to a live platform", slug `ada-web-division-from-idea-to-live-platform`, Project, `/portraits/kudumo-chair.webp`, external https://ada-web-division.vercel.app/, 2026-08-18 16:00+00
4. Docs: update `docs/architecture/DATABASE_SECTIONS.md`, add a CONTENT workflow doc, document `posts`/`post`/`submit_application_profile` and `content.read` in the public API doc; run `scripts/gen-docs.sh`.
5. Browser journey for Content; run all journeys (`scripts/pilot-live/run.sh`, `JOURNEY=<name>`, needs PostgREST at `/tmp/pgrst/postgrest` — may need re-downloading — and `CHROMIUM_PATH=/opt/pw-browsers/chromium-1194/chrome-linux/chrome`), and `node scripts/check-web-links.mjs`.

## Still open after that (user will say the order)

- Logins for administrator/finance/web/marketing staff (needs names + emails; the user creates the auth users in Supabase).
- Real client/service/price data entry (e.g. the N$10,000 client: security website, mini market, cleaning service, loan services; web development + marketing divisions).
- Repoint the website's "Administrator Login" to the Hub (`ada-main-website` repo, read-only here); the enquiries industry/timeline fields were deliberately not added yet.
- Packages table, public API HTTP layer / event dispatcher, merge `claude/hub-documents` → default branch.

## Practical notes

- Local Postgres 16: `pg_ctlcluster 16 main start`. Scratch DB rebuild: all migrations in order after `supabase/tests/00_supabase_shim.sql`, then `01_helpers.sql`, then run suites with psql. A new session must recreate these helper scripts (they lived in /tmp).
- Tests: `scripts/test-db.sh`; `node scripts/check-migrations.mjs`; `node scripts/check-protected-tests.mjs` (new test names go in `supabase/tests/PROTECTED.txt`).
- Don't open a pull request unless the user asks. Commit trailers per the session's attribution reminder.
- Full earlier conversation transcript (if the same machine): `/root/.claude/projects/-home-user/fc7784aa-d715-501f-9562-b4c66fee5713.jsonl`.
