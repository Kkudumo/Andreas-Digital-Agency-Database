# Telling the websites when something changed (event dispatch)

Migration `0055_event_dispatch.sql`; worker `public-api/src/dispatcher.mjs`; screen: ADA Hub → Websites → "Tell a website when things change".

## Flow
1. A change in ADA Core (a price approved, a service or post published or unpublished, a setting changed) writes a row to `events` and, for each **active subscription** that wants it, a pending row in `event_deliveries`.
2. The **dispatcher** asks the database (`dispatch_claim`) for due deliveries **grouped per subscription**. Fifty changes in a minute become **one** request, after a short debounce (default 20 s).
3. It POSTs `{ "website": "<domain>", "events": [ { id, type, occurred_at, entity: {table, id, ada_id}, payload } ] }` to the subscription's address and reports the outcome (`dispatch_report`). Identifiers and states only; never record contents.
4. The website (or its host) reacts: a **Vercel deploy hook** rebuilds a static division site; the main site's endpoint revalidates its cache.

## Guarantees
* **Retries:** a failed delivery waits 1, 2, 4 … minutes (capped at 60) and is **abandoned as failed after 8 attempts**. A worker that crashes mid-delivery loses nothing: in-flight deliveries come back after 5 minutes.
* **Signed:** if the subscription names a secret (`secret_ref`, e.g. `WEBHOOK_SECRET_TECH`), the request carries `X-ADA-Timestamp` and `X-ADA-Signature: v1=<hex HMAC-SHA256 of "<timestamp>.<body>">`; the receiver recomputes it and rejects old timestamps. The **secret value lives only in the dispatcher's environment**; the database stores the name. A subscription whose secret is missing is **never sent unsigned**; it fails and retries until the secret is set. A Vercel deploy hook needs no secret (its address is the secret).
* **Targets:** https only, and nothing that points inside our own network (localhost, private ranges, link-local/metadata addresses).
* **Least privilege:** the worker connects as the `ada_dispatcher` role, which can run the two functions and read no table. Error text stored for a failure never contains the address.
* A suspended website or a paused subscription receives nothing; what it missed is sent when it is active again.

## Running it (owner steps)
1. `alter role ada_dispatcher login password '<long random password>';` in the SQL editor; build its connection string (pooler user `ada_dispatcher.<project-ref>`).
2. Run the worker where Node 20+ runs: `ADA_DISPATCHER_DATABASE_URL=… WEBHOOK_SECRET_…=… node public-api/src/dispatch-cli.mjs` (a loop; `--once` for a scheduler). **Or** on Vercel: deploy `public-api/` (already needed for the public API), set `ADA_DISPATCHER_DATABASE_URL` and `CRON_SECRET`, and schedule `GET /api/dispatch` (Vercel Cron; per-minute schedules need a plan that allows them, otherwise use a free external scheduler that sends `Authorization: Bearer <CRON_SECRET>`).
3. In ADA Hub → Websites, add a notification per website: its deploy-hook (or webhook) address and the events it cares about (a division site: `service.*`, `price.changed`, `content_post.*`, `faq.*`, `testimonial.*`, `settings.changed`).

Hub's older **rebuild hooks** (`ADA_REBUILD_HOOKS`) keep working; with dispatch in place you can leave them unset, so every change source (Hub, scripts, another tool) rebuilds the sites the same way.
