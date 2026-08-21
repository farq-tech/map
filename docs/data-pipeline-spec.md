# What the map needs from the pipeline

The map is a read-only client. Every number on it comes from `comparison.*` in
Supabase, and the map's rule is that it never invents one: no price, no distance,
no fee, no date it did not read from a row. That rule is what makes the product
trustworthy, and it is also what makes the map's honest gaps visible — the
freshness chip says «محدَّث ١٦ أغسطس» for every restaurant in Riyadh because that
is the only date the database holds.

This document is the pipeline's side of that contract. Nothing here can be built
in this repo; all of it is upstream, in the crawlers and the read-layer refresh.
Each requirement states the defect as measured, what the map does the day the
data arrives, the column contract, and the test that proves it landed.

**Measured 21 August 2026** against production (`comparison` schema). Re-run the
probes in the appendix before trusting any number below — they are facts with a
date on them, not permanent truths.

---

## Where the read layer stands today

| | measured |
|---|---|
| Read layer last generated | **16 Aug 2026, 06:40 UTC** — 5 days before this document |
| `refresh_mode` | `full`; `last_delta_at` is **null** |
| `read_layer_change_queue` | **0 rows, 0 processed, never enqueued** |
| Provider rows with `observed_at` | **0 of 47,955** |
| Provider rows with `delivery_fee` | **14,129 of 47,955** — all of them hungerstation |
| Distinct values of `freshness_status` | **one**: `provider_level_only`, on 47,955 provider rows and 1,156,078 menu offers |
| Product-ready restaurants with `latest_price_observed_at` | **0 of 28,251** |
| Grocery offers with `observed_at` | **163,335 of 163,335** |

The last two rows are the whole argument. Per-offer timestamps are not a research
problem for this company — the grocery half of the same database has them on
every single row. The restaurant half has the columns and leaves them empty.

---

## R1 — A timestamp per observation, not per layer

**Defect.** `restaurant_providers.observed_at` is null on all 47,955 rows.
`product_ready_restaurants.latest_price_observed_at` is null on all 28,251.
`menu_item_offers` has no timestamp column at all. `freshness_status` is the
constant `provider_level_only` on 1.16M offers, so it carries no information —
a column with one value is not a signal.

The single date in `read_layer_meta.generated_at` is therefore the only
freshness fact in the system, and it describes when the *matview was rebuilt*,
not when anyone last looked at a price. A restaurant crawled in June and a
restaurant crawled this morning are indistinguishable, and both are labelled
with the refresh date. That is the one place where the map currently shows
something truer-sounding than what it knows.

**What the map does with it.** A price older than the threshold stops being a
headline. The freshness chip moves from the layer to the card and states the
item's own date. Stale rows drop out of the ranking rather than competing with
fresh ones on equal footing, and the card can say «رُصد قبل ٣ أيام» — the
sentence a person needs before acting on a number.

**Contract.**

- `menu_item_offers.observed_at timestamptz not null` — when *this offer's price*
  was read from the provider, not when the row was written or the view refreshed.
- `restaurant_providers.observed_at timestamptz` — when the storefront (fee, min
  order, ETA, availability) was last read.
- `product_ready_restaurants.latest_price_observed_at` = `max(observed_at)` over
  the restaurant's trusted offers. The column already exists; populate it.
- `freshness_status` must take more than one value, or be dropped. If it stays,
  it should be derived from `observed_at` against a stated threshold, and the
  threshold belongs in `read_layer_meta` so the client reads it instead of
  hard-coding one.

**Acceptance.** `count(observed_at) = count(*)` on both relations; at least three
distinct `freshness_status` values across the corpus; `max(observed_at)` moves
between two consecutive refreshes.

---

## R2 — Delivery fees for every provider, or none

**Defect.** Of eight providers, exactly one reports a delivery fee:

| provider | rows | with fee | with min order | with ETA |
|---|---:|---:|---:|---:|
| jahez | 17,008 | **0** | 0 | 0 |
| hungerstation | 14,145 | 14,129 | 14,145 | 14,129 |
| mrsool | 7,450 | **0** | 0 | 0 |
| ninja | 4,316 | **0** | 0 | 0 |
| thechefz | 2,485 | **0** | 0 | 2,323 |
| toyou | 2,077 | **0** | 0 | 0 |
| keeta | 425 | **0** | 0 | 0 |
| brand_app | 49 | **0** | 0 | 0 |

A fee on one side of a comparison is worse than no fee at all: the cheaper app
looks dearer purely because it is the only one that admitted to a delivery
charge. This is exactly the shape of the bug already fixed on the read side of
the map, where `Number(null) === 0` turned a missing fee into **free delivery**
on 5,075 rows. The map now treats a missing fee as missing — `deliveryAdjustedGap`
returns null unless *both* sides are observed — which is honest and means the
delivery-adjusted comparison currently almost never runs.

**What the map does with it.** The number people actually pay. A 12-riyal item
gap is erased by a 15-riyal fee difference, and today the map cannot say so. With
fees on both sides, the card's headline becomes the total, the fee appears as its
own line, and «الأرخص فعلاً» stops being a claim about menu prices only.

**Contract.** `restaurant_providers.delivery_fee numeric` and `min_order numeric`
populated for every provider, in SAR, for the storefront's base fee — the number
shown before any promotion. If a provider's fee is genuinely dynamic (distance
or basket dependent), it must be null, not a guess: the map treats null as
"unknown" and says so. A fabricated flat fee is the one outcome worse than
nothing.

**Acceptance.** `count(delivery_fee) / count(*) >= 0.95` per provider for the top
four by row count, or an explicit, documented null for a provider whose fee is
not knowable.

---

## R3 — A refresh cadence people can feel

**Defect.** `refresh_mode = 'full'`, `last_delta_at` is null, and
`read_layer_change_queue` has never held a row. The delta machinery exists and
has never run; every refresh is a full rebuild, which is why they are five days
apart. Restaurant menus change faster than that, and a price the map shows on a
Thursday was read the previous Saturday.

**What the map does with it.** It stops needing a disclaimer. The 10-minute API
cache and the ETag path are already built for a layer that moves; they are
currently caching something that changes twice a week.

**Contract.**

- A **daily** full refresh at a fixed hour, and `last_full_refresh_at` stamped.
- A **delta** refresh driven by `read_layer_change_queue` running at least hourly:
  enqueue on price change, stamp `last_delta_at`, and set `processed_at` per row.
  A queue that only fills is a queue that is not being read.
- `read_layer_meta` gains the threshold R1 needs, so the client stops guessing.

**Acceptance.** `last_full_refresh_at` within 26 hours at any moment;
`last_delta_at` within 2 hours; `read_layer_change_queue` shows rows both enqueued
and processed over any 24-hour window.

---

## R4 — A second city, which is first a naming problem

**Defect.** The map ships boundaries for six cities — Riyadh, Jeddah, Madinah,
Makkah, Dammam, Khobar — and has data for one. But the shortfall is not only
crawl coverage. `city` is free text, and the same city is spelled several ways:

| bucket | places | product-ready |
|---|---:|---:|
| `riyadh` | 15,336 | 8,590 |
| `الرياض` | 4,169 | 155 |
| *(null)* | 7,999 | 16 |
| `jeddah` | 175 | 6 |
| `جدة` | 1 | 0 |

and beyond those, `dammam`/`الدمام`, `taif`/`الطائف`, `madinah`/`المدينة المنورة`,
`tabuk`/`تبوك`, `khobar`/`al-khobar`, `khamis`/`khamis-mushait`. **12,168 of the
27,504 product-ready rows — 44% — sit outside the canonical bucket for the city
they are in**, and the map, which filters by an exact string, cannot see them.

Normalising costs nothing and moves rows the crawl has already paid for. It will
not by itself produce a second city — Jeddah has 175 places and 6 comparable
cards, so Jeddah is genuinely uncrawled — but it must happen first, or the crawl
will pour new rows into the same split buckets.

**What the map does with it.** The city switcher becomes real, and the district
layer already built for six cities starts paying for itself. Nothing in the web
app needs to change: it reads whatever cities the API reports.

**Contract.**

- A canonical `city_slug` — lowercase ASCII, one per city, matching the district
  file names in `apps/api/data/districts/` (`riyadh`, `jeddah`, `madinah`,
  `makkah`, `dammam`, `khobar`). Arabic display names belong in their own column.
- Rows whose city cannot be determined keep `city_slug` null. **Do not assign a
  city by guessing from coordinates upstream** — the map already resolves a
  district from a point using MOMRAH polygons, and two different guesses
  disagreeing is worse than one honest null.
- Then: crawl Jeddah to comparable depth. The threshold that makes a city worth
  shipping is roughly **500 product-ready restaurants with ≥2 providers**, below
  which the ranked list is too thin to be interesting and the district layer paints
  mostly empty polygons.

**Acceptance.** Every non-null city resolves to one of the canonical slugs;
`select count(*) from product_ready_restaurants where city_slug='jeddah' and
product_ready` clears 500.

---

## Order, and what each one unlocks

1. **City normalisation** (R4a) — hours of work, no crawl, moves 44% of rows.
2. **Delivery fees** (R2) — the biggest single upgrade to what the map can claim,
   because it changes the headline number from menu price to what you pay.
3. **Per-item timestamps** (R1) — the difference between a map that is fresh and
   a map that says it is.
4. **Cadence** (R3) — makes 1 and 2 stay true.
5. **Jeddah** (R4b) — the expensive one, and worth nothing until 1–4 hold, because
   a second city built on the same gaps just doubles them.

## What the map will not do while waiting

It will not fill a null with a zero, average a missing fee, infer an observation
date from a refresh date, or show a city it cannot rank. Each of those makes the
screen look better and the product worth less. The gaps above are visible in the
UI on purpose: a chip that admits «محدَّث ١٦ أغسطس» is the reason a number beside
it can be believed.

## Appendix — re-running the measurements

Every figure here came from one query against the `comparison` schema. Credentials
belong in the environment, never in this file or in git:

```sql
-- freshness and cadence
select * from comparison.read_layer_meta;
select count(*) rows, count(processed_at) processed from comparison.read_layer_change_queue;

-- what is actually observed
select provider_code, count(*) rows, count(delivery_fee) with_fee,
       count(min_order) with_min, count(eta) with_eta, count(observed_at) with_ts
from comparison.restaurant_providers group by 1 order by 2 desc;

select freshness_status, count(*) from comparison.menu_item_offers group by 1;

select count(*) , count(latest_price_observed_at)
from comparison.product_ready_restaurants;

-- the naming split
select city, count(*) places, count(*) filter (where product_ready) ready
from comparison.product_ready_restaurants group by 1 order by 2 desc;

-- the in-house proof that per-offer timestamps are solved
select count(*), count(observed_at), max(observed_at) from comparison.grocery_product_offers;
```
