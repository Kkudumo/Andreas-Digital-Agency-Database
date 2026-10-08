# Leads and website enquiries

```
PUBLIC WEBSITE ─► ENQUIRY ─► LEAD ─► CLIENT MATCH ─► CONTACT MATCH ─► QUALIFICATION ─► QUOTE ─► APPROVAL ─► ACCEPTANCE ─► PROJECT ─► (invoice, payment: next)
```
Not every enquiry becomes a client. It may come from an existing client, a new person, a new organization, or an anonymous prospect; each is a valid state.

## 1. Enquiry (`public_api.submit_enquiry`, `enquiry_record`)
A connected website calls `submit_enquiry` with its key hash (capability `enquiries.submit`). Staff record phone, email and walk-in enquiries with `enquiry_record` (`leads.create`). The central record keeps: ADA ID (`ADA-ENQ-…`), **source website** (taken from the API identity, never from the request), source division, source page, referrer, UTM campaign data, timestamp, the requested service (only a published service is linked; anything else is kept as text), message, budget, assigned staff, status, and links to person, client and lead once known.

The sender's name, email, phone and organization are stored as **explicit SNAPSHOTS** (`submitted_*`): a stranger has no central record yet. They are history of what was submitted, never the live identity, and they are redacted from the audit trail.

**The website gets only a reference.** The response never depends on what ADA already knows (not whether the person, the client or a restricted record matched).

Routing: the division that owns the requested service; else the website's division; else Management (organization intake).

## 2. Resolution (automatic, conservative)
- **Person:** an email gives a confident identity: reuse the person with that email or create one. No email = an anonymous prospect; no person record is invented.
- **Client:** linked automatically **only** on a confident match to a *discoverable* client: the normalised organization name is identical, or (with no organization named) the person is an active contact of exactly one client.
- **Ambiguity goes to a human:** several possible clients, a similar-but-different name, or a contact at more than one client leave the client unlinked, status `needs_review`, with the candidates listed for the handler. `enquiry_resolve_candidate` links one or says "none of these".
- **Genuinely different entities are never merged.** Similar names are only ever candidates. Two clients with provably different registration numbers keep separate records (`client_create` asks for a distinguishing name).
- **Restricted clients are never revealed.** They are never auto-linked or offered as candidates to the handler; an enquiry that matches one looks exactly like one that matches nothing. Management (`matching.review`) sees hidden candidates and review items.
- **Lead:** the enquiry attaches to the same person's open lead in the same division (last 30 days), otherwise opens a new one. The lead's title never contains personal data.

## 3. Lead (`lead_assign`, `lead_transition`, `lead_set_person`, `lead_qualify`)
`new → contacted → qualified → converted` (and `unqualified`, `lost`). `qualified` only through `lead_qualify`; `converted` only when its quote is accepted.
- `lead_set_person` attaches an anonymous prospect's details through the same find-or-create-by-email path (never a duplicate person).
- `lead_qualify` settles the client through the controlled paths: the lead's linked client, an existing discoverable client you choose, or a new one named (via `client_create`: exact existing name links the existing record; a similar name is refused unless you give a reason). It joins the lead's division to the client, links the person as the client's contact (reusing an existing contact), and needs both `leads.update` and `clients.create` in the division.

## 4. Quote (`quote_create_from_lead`, `quote_create(… p_lead)`)
A quote may name the lead it answers; the lead must be qualified and belong to the quote's client. `quote_create_from_lead` takes the lead's client, contact and division and adds the requested service at the price in force. Accepting the quote converts the lead and emits `lead.converted`. Quote → approval → acceptance → project follows [QUOTES_PRICING.md](QUOTES_PRICING.md); invoices and payments come next.

## Visibility
Enquiries and leads are visible per division (`leads.view`); the recruiter, finance and auditors see none. A person reached through a lead is visible only to people who can see that lead, and never reveals the person's applications or other relationships. Leads and enquiries of a restricted client inherit its classification.

Acceptance tests: `84_leads_enquiries.sql`, `85_existence_leakage.sql`, `91_enquiry_to_quote_scenario.sql`.
