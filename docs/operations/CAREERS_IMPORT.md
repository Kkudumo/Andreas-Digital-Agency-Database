# Moving the careers records from the old website project

Migration `0056_careers_import.sql`, generator `scripts/import-careers.mjs`, suite `123_careers_import.sql`.

The old website project (separate Supabase project) holds `career_opportunities` (vacancies) and `career_applications` (applicants, with their CV files in the `career-documents` storage bucket). ADA Core's recruitment module replaces them.

## What is brought across
| Old | New |
|---|---|
| a vacancy (title, division, type, summary, description, responsibilities, requirements, qualifications, experience, how to apply, deadline, status) | a vacancy with a position made for it; the long text sections are joined into description and requirements; the location is the first line of the description; status and dates kept; **test vacancies are not imported** |
| an application | an application on the matching vacancy (or on one standing, closed "General applications" vacancy of its division for talent-pool / internship / general ones), a person matched by e-mail, the original status (`new → submitted`, `under_review → screening`, `archived → withdrawn`, others as they are), the original dates and a history entry |
| qualification, institution, skills, nationality, availability, portfolio, years of experience, internal notes … | `applications.details` (restricted like the application) — nothing is dropped |
| the CV / supporting file | **a reference only**: `legacy-storage:career-documents/<path>`. The files stay in the old project's bucket until the documents module takes them over. |

No notification and no website event is raised for an imported application. Re-running is safe (`legacy_imports` remembers what became what).

## Steps (owner)
1. In the **old** project's dashboard export the two tables as JSON (`career_opportunities.json`, `career_applications.json`). They contain **personal data**: keep them out of git and delete them afterwards.
2. `node scripts/import-careers.mjs --vacancies career_opportunities.json --applications career_applications.json --out careers-import.sql`. If a division, employment type or status is not recognised the script stops and lists the rows; nothing is written.
3. Read the top of the generated SQL, then run it once in the ADA Core SQL editor as the owner. The last result lists what was **not** imported (test records, an unusable e-mail, the same person twice for one vacancy).
4. Check Hub → recruitment, then delete the files.

The old website schema is not in git; the script maps the columns the website code uses (see the top of `scripts/import-careers.mjs`). If your export has different column names, change the mapping there.
