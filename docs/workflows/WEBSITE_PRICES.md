# How a price change reaches the websites

The logic: **change the price once, in ADA Hub; the websites follow without anyone editing a page.**

```
ADA Hub → Services & prices → "Change the price" → Save
        └─ price_propose + price_decide (approved at once for someone who may approve, e.g. the CEO)  → a new immutable price version
        └─ ADA Hub tells the websites to rebuild (deploy hooks)
Division sites (static)  → their build asks the public API for the current prices → pages are regenerated → live in about a minute
Main site / apps          → read the public API when a page is requested (short cache)
```

## What happens in ADA Hub
* **Services & prices** lists every service with its price now. Open one to edit its wording, **change its price**, see the price history, and publish or take it off the websites.
* A price change is a **new version with its own effective date** (never an edit): quotes and invoices keep the price they were made at. Tick "starting price" for a price shown as "from".
* Someone who may approve prices (the CEO) has the change approved when they save; anyone else leaves it waiting in the approver's inbox.
* After a price or publication change Hub calls the deploy hooks listed in `ADA_REBUILD_HOOKS` (Hub's environment: comma-separated Vercel Deploy Hook URLs, one per static site). They are secrets; the owner adds them in Vercel. If none are set, Hub says so and the sites pick the change up on their next build.

## What a division site does (`build/ada_prices.py`)
* Every price in the site's generator is a lookup by the service's **name in ADA Core** (`P.money('Business Check-up')`), not a typed number.
* At build time it reads `GET /api/public/services?division=…` (needs `ADA_API_URL` and `ADA_API_KEY` in that Vercel project's environment; the key comes from ADA Hub → Websites) and uses ADA Core's price and its "from" flag.
* **It never breaks and never goes blank.** If the API is unreachable, or a service is not published yet, it uses the committed snapshot (`build/prices.json`, taken from the reviewed catalogue) and prints which. A service name that exists in neither stops the build loudly.
* **Renaming a service in ADA Hub** changes the name the site looks up: update the name in the site (one place) or the build warns and uses the snapshot.
* `python3 build/ada_prices.py <division> build/prices.json --refresh` rewrites the snapshot from the API so the repository matches ADA Core.

## Honest limits
* Static sites update when they **rebuild** (a minute or two after saving), not at the instant of saving; a refresh before the rebuild finishes shows the old price.
* Only prices (and the "from" flag) come from ADA Core in this step. Service wording on the division sites is still in their page files.
* Services must be **published** in ADA Core for the API to return them; until then sites keep the snapshot price.
