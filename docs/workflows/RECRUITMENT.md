# Recruitment workflow

**Position** = an organizational role with a `headcount` ("Web Developer ×2"). **Vacancy** = an opening for it ("ADA-VAC-2026-0007").
Availability is derived: `position_availability.filled` counts current holders; `position_open_capacity()` also subtracts openings
already promised to other approved/published vacancies. Approval is refused if it would exceed capacity.

## Vacancy (`vacancy_transition`)
```
draft ──submit──► pending_approval ──approve──► approved ──publish──► published ──close──► closed
  ▲                  │ return (reason)             │                      │  └─ pull back ─► draft
  └──────────────────┘◄────────────────────────────┴──────────────────────┘
any non-terminal ──cancel (reason)──► cancelled        accept_application fills the last opening ──► filled
```
Content (title, description, salary, openings, closing date…) is editable **only in draft**. `vacancies.update` (division-scoped) drafts and submits;
`vacancies.publish` (management) approves, publishes, closes. A vacancy past its closing date stops appearing publicly without any job.

## Application (`application_transition`, `make_offer`, `accept_application`)
```
submitted → screening → shortlisted → interview → final_review → offer → accepted
    └────────── rejected (reason) from any pre-offer stage ─────────┘     └─► offer_declined
    └────────── withdrawn from any open stage (incl. offer) ────────────────┘
```
- `applications.review` (recruiters, division leads for their division): screening → final_review, reject before final review, withdraw, record notes.
- `applications.decide` (management): make the offer; reject at final review.
- `applications.hire` (management): `accept_application`.
Every step is recorded in `application_status_history` (who, when, why) and audited. Each application keeps vacancy, applicant, source website (from the API identity), source page, referrer and UTM data.
One person has one `people` row however often they apply; one application per person per vacancy.

## Controlled hire — `accept_application(id)` (one transaction, idempotent)
1. Requires an open, unexpired offer; locks the application and vacancy.
2. Refuses if the position is already at headcount, or the person is already active ADA staff (**no duplicate employee**).
3. Creates the staff record (new `ADA-STF-…` ID) — or **rehires** a former employee onto their existing record (one staff record per person, ever).
4. Links position and division, sets start date, opens `staff_assignments` history, status active, account `invited` (no login yet).
5. Marks the application accepted; closes the vacancy as `filled` when all openings are filled.
6. Creates a **draft** public profile and five onboarding tasks; notifies onboarding managers; emits `application.accepted`, `staff.created`, `vacancy.closed`.
Calling it again returns the same staff record. Access is granted separately: an administrator invites the login and runs `link_staff_account()`.

## Public profile (`profile_transition`) — separate from the staff record
`draft → pending_approval → approved → published → unpublished` (→ `archived`). The owner or `profiles.edit` holders edit; only `profiles.publish` holders approve and publish.
Only the approved public fields are ever exposed. Editing a non-draft profile returns it to draft. A profile of someone no longer employed is never public.

## Departure — `terminate_staff(staff, end_date, reason)`
Requires `staff.offboard` and a reason. Marks employment terminated (account disabled → all access ends immediately), closes assignment history, unpublishes the public profile,
creates an offboarding checklist, emits `staff.deactivated`, and **tells management the position is vacant — it does not create a vacancy**. If a replacement is wanted, management drafts a new vacancy for the same position.

Acceptance test: [`supabase/tests/70_scenario_hiring.sql`](../../supabase/tests/70_scenario_hiring.sql) executes the whole master-spec §54 scenario.
