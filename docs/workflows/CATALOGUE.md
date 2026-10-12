# Service catalogue (build step 2)

The real services and prices of the four divisions, taken from the price lists the websites publish today (reviewed 5-6 October 2026), ready to load into ADA Core.

* **Source of truth:** `supabase/seed_data/catalogue.csv` (open it in a spreadsheet; one row per sellable service).
* **Generated load script:** `supabase/seed_data/catalogue.sql`, made by `node scripts/gen-catalogue-sql.mjs`. Never edit the SQL; edit the CSV and regenerate. A test fails if the two disagree.
* **Run it:** Supabase SQL editor of the ADA Core project (`uyhwcbjfvfkqsixthxkn`), as the project owner, one run. **First apply migration `0053_starting_prices.sql`** (the script stops with a clear message if you forget). It is safe to run twice: it only adds what is missing and never changes an existing service or price.

## What the load does (and does not do)

* Creates the services with status **approved**. **Nothing is published**: publishing is a separate act (build step 4, when the public API exists), so nothing reaches a website by this load.
* Loads each price as version 1, approved, effective the day it runs. This is the owner's bootstrap load. ADA Core has one staff member, and the pricing rule "you cannot approve your own request" would otherwise make a first catalogue impossible. The audit trail records the reason. From now on every price change goes through ADA Hub (`price_propose` then `price_decide`) with its history.
* Quote-based services get no price; they can still go on a quote with a custom price.
* Marks the 22 prices the websites show as "From N$x" as **starting prices** (`service_prices.is_starting_price`, migration 0053). The public catalogue returns `"starting_price": true` for them so a website can print "from". The flag belongs to the price version and is immutable once approved.
* Currency NAD. No VAT: ADA is not VAT registered, and the sites say so.

## The catalogue


### ADA Tech (27 services, 21 priced)

| Category | Service | Basis | Price |
|---|---|---|---|
| Windows installation packages | Windows Ready | fixed / job | N$649 |
| Windows installation packages | Windows + Office Complete | fixed / job | N$849 |
| Windows installation packages | Complete Device Refresh | fixed / job | N$1,049 |
| Computer and laptop repair | Standard device diagnostic | fixed / job | N$99 |
| Remote support | Remote quick support | fixed / job | from N$149 |
| Windows and software setup | PC tune-up and optimisation | fixed / job | N$249 |
| Windows and software setup | Driver or software fault | fixed / job | from N$179 |
| Windows and software setup | Windows Update repair | fixed / job | from N$249 |
| BIOS and firmware | BIOS or UEFI update | fixed / job | from N$249 |
| BIOS and firmware | BIOS recovery or boot fault | fixed / job | from N$449 |
| Windows and software setup | Microsoft Office setup | fixed / job | from N$249 |
| Windows and software setup | Printer setup | fixed / job | from N$179 |
| Computer and laptop repair | RAM or SSD fitting (labour) | fixed / job | from N$179 |
| Windows and software setup | Data backup or transfer | fixed / job | from N$249 |
| Wi-Fi and networking | Router and Wi-Fi setup | fixed / job | from N$349 |
| Monthly care plans | First Aid Essential | monthly / month | N$249 a month |
| Monthly care plans | First Aid Plus | monthly / month | N$399 a month |
| Monthly care plans | First Aid Family | monthly / month | N$699 a month |
| Monthly care plans | Micro Business Care | monthly / month | N$1,249 a month |
| Monthly care plans | Business Care | monthly / month | N$2,449 a month |
| Monthly care plans | Managed IT | monthly / month | from N$3,949 a month |
| Computer and laptop repair | Computer and laptop repair | quote-based / project | quoted |
| Wi-Fi and networking | Office networks and cabling | quote-based / project | quoted |
| Security and backups | Security and backups | quote-based / project | quoted |
| CCTV | CCTV installation | quote-based / project | quoted |
| Servers and infrastructure | Servers and infrastructure | quote-based / project | quoted |
| Business IT setup | Business IT setup | quote-based / project | quoted |

### ADA Web (9 services, 5 priced)

| Category | Service | Basis | Price |
|---|---|---|---|
| Websites | One-page website | fixed / project | from N$1,199.99 |
| Websites | Business website | fixed / project | from N$2,629.99 |
| Websites | Growth website or online store | fixed / project | from N$4,669.99 |
| Websites | Website redesign | fixed / project | from N$2,629.99 |
| Care plans | Care Essential | monthly / month | from N$349.99 a month |
| Websites | Booking and web systems | quote-based / project | quoted |
| Search visibility | Search visibility (SEO) | quote-based / project | quoted |
| Care plans | Care Growth | quote-based / month | quoted |
| Care plans | ADA Partner | quote-based / month | quoted |

### ADA Marketing (6 services, 0 priced)

| Category | Service | Basis | Price |
|---|---|---|---|
| Advertising | Advertising campaigns | quote-based / campaign | quoted |
| Marketing | Social media management | quote-based / project | quoted |
| Marketing | Branding and design | quote-based / project | quoted |
| Marketing | Content creation | quote-based / project | quoted |
| Marketing | Search visibility | quote-based / project | quoted |
| Marketing | Marketing systems | quote-based / project | quoted |

### ADA Consulting (14 services, 14 priced)

| Category | Service | Basis | Price |
|---|---|---|---|
| Consulting | Business Check-up | fixed / session | N$199 |
| Consulting | Customer and Competitor Study | fixed / study | from N$1,499 |
| Consulting | One-Year Plan | fixed / plan | N$899 |
| Consulting | Business Plan | fixed / plan | from N$2,499 |
| Consulting | Costing and Pricing | fixed / session | N$699 |
| Consulting | Records Setup | fixed / visit | N$599 |
| Consulting | Process Review | fixed / review | from N$1,299 |
| Consulting | Technology Plan | fixed / plan | from N$1,299 |
| Consulting | One-Year Plan (team session) | fixed / session | from N$1,999 |
| Consulting | Business Plan (extended) | fixed / plan | from N$4,499 |
| Consulting | Monthly Review | monthly / month | N$349 a month |
| Packs | Start-up Pack | fixed / pack | N$2,899 |
| Packs | Steady Growth Pack | fixed / pack | N$2,999 |
| Packs | Funding Pack | fixed / pack | N$4,199 |

## Not loaded, on purpose

* ADA Web **Community Access** (an application-based programme, not a priced service), the free first conversation / digital check, written quotes and the free worksheets and checks.
* ADA Marketing has **no fixed prices**: a campaign is planned from the client's budget by a published split (60/40 under N$5,000 a month, 65/35 from N$5,000, 70/30 from N$15,000; smallest campaign N$1,499.99). That is a rule, not a price per service, so Advertising campaigns is quote-based and carries the rule in its description.

## Please check (these are decisions for the owner)

1. **The audit of 8 October.** The handover says it holds the canonical price table; it is not in any repository I can reach. These prices come from the published pages. Compare the two before running the load; if they differ, change the CSV.
2. **"From" prices.** Done: migration 0053 adds the flag and the load sets it for the 22 "From" prices. When you propose a price in future, say whether it is a starting price (`price_propose(..., p_starting)`; default is a fixed price).
3. **Self-approval.** The load bypasses the four-eyes rule once, as the owner. If you would rather have a second person approve, create the first division lead or finance officer first and approve the prices through ADA Hub.
4. **Care Essential** (ADA Web) is "N$349.99 a month" in the table and "start at" in the summary; it is loaded as a starting price.
5. **Pack arithmetic** matches the website (Start-up Pack N$2,899 against N$3,296 booked separately; Steady Growth N$2,999 against N$3,443; Funding N$4,199 against N$4,697). The packs are loaded as their own services; they do not yet link to the services inside them.
6. **After this** the division sites still carry their own copies of these prices until build steps 3-4 replace them.
