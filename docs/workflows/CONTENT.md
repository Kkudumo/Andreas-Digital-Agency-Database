# Website content (news, testimonials, FAQs, site settings)

Migration `0054_content.sql`, suite `121_content.sql`. ADA Hub screens: **Website content** and **Website facts**.

## What lives here
| Record | Table | Public through |
|---|---|---|
| News, announcements, updates | `content_posts` | `GET /api/public/posts`, `/posts/{slug}` (capability `content.read`) |
| Testimonials | `testimonials` | `GET /api/public/testimonials` (`content.read`) |
| FAQs | `faqs` | `GET /api/public/faqs` (`content.read`) |
| Company facts and planner rules | `site_settings` | `GET /api/public/settings` (`settings.read`) |

Each of the first three is for the **whole agency** (no division) or **one division**; a division's site receives its own records plus the agency-wide ones.

## Publishing (same rules as services)
`draft → pending_approval → approved → published → unpublished/archived`, only through `content_transition()`.
* `content.create` / `content.update` (CEO, administration officer, division leads in their division) write drafts and submit them; `content.publish` (CEO) approves, publishes, unpublishes and archives. Agency-wide content needs an organization-wide role.
* **Editing the public wording of an approved or published item returns it to draft** (it leaves the website until approved again). In Hub, "keep it published after saving" does the re-approval in one step for someone who may publish.
* A post's address (`slug`) is made from its title (made unique with `-2`, `-3`) and is **frozen while the post is approved or published**, so links never break.
* A **testimonial cannot be published until the person's consent is recorded** with a note on how it was given. The consent note is never returned by the API.
* Publish, unpublish and archive emit `content_post.*`, `testimonial.*`, `faq.*` events, so subscribed websites refresh; Hub also pings the rebuild hooks.

## Site settings
One value per key, optionally per division; typed (`text`, `number`, `url`, `email`, `phone`) and validated by the database. Only `settings.update` (CEO) changes them, every change is audited and emits `settings.changed`. A setting is **public** (returned by the API) or **internal**.
Seeded: the agency phone, company line, place, main website, each division's email, and **ADA Marketing's budget rule** (smallest campaign, the Grow and Scale thresholds, ADA's share per level) — so the planner's numbers live in the database rather than in the site's code.

## Not here
Long guides and articles stay as the division sites' page files. Editorial records have an `ADA-NWS-…`/`ADA-TST-…`/`ADA-FAQ-…` ID but are not part of the institutional registry or staff search.
