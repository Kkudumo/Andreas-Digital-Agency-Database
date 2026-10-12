# Recurring invoicing

Migration `0049_billing_schedules.sql`, suite `116_billing_schedules.sql`, concurrency block `concurrent_billing_schedules`.

## What it is

A **billing schedule** says: bill *this contract line*, *N units* every *1, 3, 6 or 12 months*, from *this date* (billed in advance, on the period start), optionally until an end date.
It does not invent a second way to bill. Each period becomes an ordinary **billable item** created by `billable_from_contract`, so everything that already protects contract billing applies unchanged:

* the contract must be `signed` or `active`;
* the line must be part of the terms currently in force (amendments keep working through `origin_line_id`);
* the quantity billed across **all** billing of that line (scheduled, manual, any invoice) can never exceed the line's quantity;
* discounts are prorated exactly as for manual billing.

## Commands (all `SECURITY DEFINER`, audited, permission `invoices.create` in the contract's division)

| Function | Does |
|---|---|
| `billing_schedule_create(contract, line, interval_months, first_period_start, quantity=1, end_on=null)` | Creates a schedule. One live schedule per line; refused on a fully billed line or a contract that cannot be billed. |
| `billing_schedule_set_status(schedule, 'paused'/'active'/'ended', reason, skip_missed=false)` | Pause / resume / end. A reason is required to pause or end. Resuming bills the periods missed unless `skip_missed` moves it to the first period after today. An ended schedule is final. |
| `billing_schedule_run(as_of=current_date, create_invoices=false)` | Bills every period whose start is `<= as_of` (max 12 per schedule per run). Returns one outcome per schedule: `billed`, `ended`, `paused` or `failed`. With `create_invoices` it also prepares **one draft invoice per schedule** from the periods just billed. It never issues anything. |

## Guarantees

* **No period is billed twice.** `(schedule, period start)` is unique in the append-only run log, and a run takes a row lock on each schedule (`for update skip locked`), so parallel runs never double-bill. Proven by 16 parallel sessions.
* **Never beyond the contract.** The cap is the line's quantity; the last period is trimmed to what remains and the schedule then ends (`the line is fully billed`). Ordinary billing racing the schedule cannot push the total past it.
* **Failures are isolated.** Each schedule is processed in its own sub-transaction: if it fails, everything it did in that run is undone and the others carry on. If the contract or line no longer allows billing (terminated, expired, line out of the terms), the schedule is **paused with the reason** rather than failing on every run.
* **Derived progress.** `billing_schedule_progress` (a `security_invoker` view) shows periods billed, quantity billed and the line's remaining quantity; none of it is stored.
* **Fixed terms.** Interval, quantity, line and start date cannot be edited (end it and create a new schedule). Schedules are never deleted.

## Visibility

A schedule is exactly as visible as its contract and needs `invoices.view` in its division. A restricted client's schedules and runs are invisible to everyone without access, and commands on them answer exactly as for an id that does not exist. A run only touches schedules the caller may see and may bill; anyone else's run is simply empty.

## Not built (by design)

No automatic scheduler: a run is a command someone (or a future job) calls. No price indexation or proration of part-periods. UI: a Recurring billing section on the contract page and a Billing runs page.
