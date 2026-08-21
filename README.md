# Farq Map

The Farq spatial decision experience: a map of observed price gaps between delivery apps for the same item at the same restaurant, with a list that is the same result set and a copilot that answers from that set and moves the map. This repository is **only** the map experience — not the Farq monolith, and not [farq.sa](https://farq.sa).

**GitHub:** https://github.com/farq-tech/map

## Layout

```
apps/web     Vite + React 19 + Mapbox GL JS v3 (`/` and `/map` are the same experience)
apps/api     Express read API over the comparison read layer (Supabase Postgres), plus the copilot
```

## How it fits together

```
comparison.discovery_cards + item_price_spread   (Postgres matviews; refreshed by Farq's pipeline)
        │
        ▼  one set-based query per city, cached 10 min, warmed at boot, ETag + gzip
GET /api/intelligence/map/city/:city/opportunities     every opportunity in the city (≈5k rows, ≈380 KB gz)
GET /api/intelligence/map/city/:city/areas             H3 res-8 cells: count, biggest gap, which app was cheapest how often
GET /api/intelligence/map/city/:city/districts         the city's أحياء (MOMRAH polygons, apps/api/data/districts) with the same aggregates
GET /api/intelligence/map/places/:id                   one place (image, menu link, representative gap)
GET /api/intelligence/map/places/:id/items             the evidence: every compared item, priced per app
POST /api/analytics                                    allow-listed product events; never free text
POST /api/copilot                                      sentence → intent (code) → tools over the cached city → answer + ONE validated map action
        │
        ▼
Web: the city is loaded once and kept in memory. Panning and zooming are filters, not requests.
     Mapbox clusters the opportunities in a worker; the list, the headline and the pins are one ranked set.
     Phone: the map is the screen; the list is a bottom sheet (peek / half / full).
     Desktop: split — map + aside.
     The search field takes words (filter) and sentences (copilot). The copilot's action is executed by
     the same code paths a tap uses; it can only point at ids the server returned.
```

Product rules that are encoded, not implied:

- A restaurant's representative opportunity is its largest observed gap among items priced ≤ **200 SAR** **that one person plausibly orders**. The price cap alone was not enough: 7.1% of Riyadh's gapped items are share boxes and bulk packs, and their average gap is 15.6 SAR against 5.5 for everything else, so they owned the top of every list. `apps/api/lib/consumer-items.js` demotes them by a measured lexicon and says why (`demote_reason: 'share' | 'retail'`); nothing is hidden, and a restaurant with only a share box still shows it, labelled. Terms were counted against the live read layer before being accepted — `سعره N` looked like a scraped price but is a **calorie** count on 10,248 items (18% of the city), so it is not in the lexicon.
- Each restaurant also carries its best gap **per food category** (`category_gaps`), so filtering برجر ranks a restaurant by its burger rather than by whatever item happened to be its largest. The category list is the one the copilot already uses — one vocabulary, whether typed, spoken, or filtered.
- `brand_key` travels with every place: 5,222 of Riyadh's 8,745 cards are extra branches of a chain, so the **list** shows a brand once while the **map** keeps every branch pin, because every branch is a real place you can order from.
- A **delivery-adjusted gap** is only computed when a fee is observed for *both* the cheapest and the dearest provider. Today that is zero restaurants (2,813 have one side, 3,157 the other, none both), so the number is null everywhere — the rule and the plumbing exist so the honest figure appears by itself the day both are recorded, and nobody is tempted to fill the gap with an average.
- Freshness is on screen, not in a tooltip: one honest timestamp for the whole read layer, said as «محدّث قبل ٤ أيام» (`apps/web/src/lib/farqFreshness.ts`).
- The district colour has two lenses: how many opportunities a حي holds, or **which app was cheapest there** — the second only where the server has ≥ 8 observed comparisons, otherwise the حي stays unpainted.
- The camera lands flat (pitch 0, bearing 0) and honours `prefers-reduced-motion` by arriving instead of travelling.
- Product analytics (`POST /api/analytics`, `apps/web/src/lib/farqAnalytics.ts`) records **that** something happened, never what was typed: event types are allow-listed, `meta` keys are allow-listed per event, string values must be slug-shaped, and the endpoint is gated behind `ANALYTICS_WRITE_ENABLED`.
- Tiers: **Hero ≥ 36 · Strong 15–35 · Regular 5–14 · Faint < 5 SAR** (`apps/web/src/lib/farqOpportunityTiers.ts`, mirrored in the API).
- "Which app is cheapest here" is answered only from **8 comparisons** up, and always with its sample size.
- Freshness is a property of the whole read layer (`generated_at`); the source has no per-place observation time, so none is shown.
- Digits drawn on the map are Western; UI text follows the locale.
- Nothing is invented: no coordinates, prices, providers, places or neighbourhoods that are not in the source. Unknown places are refused in the person's own words.
- A حي is geography, not a name match: every city opportunity carries the `district_id` whose official polygon contains its coordinates (null outside every one). At city zoom the أحياء are the field (tinted only by observed count; H3 cells are the fallback for a city without boundaries); `?neighborhood=<district_id>` scopes the list, the headline and the map together, and the copilot resolves "في حي النرجس" against that polygon before it ever asks a geocoder.

## How to run

```bash
cp .env.example .env.local
# fill values in .env.local — never commit secrets

npm install
npm run dev:api    # http://127.0.0.1:4001  (warms the Riyadh cache at boot)
npm run dev:web    # http://127.0.0.1:5173  (proxies /api to the API)
```

Dev builds expose the map instance on `window.__farqMap` for browser QA scripts.

```bash
npm test -w @farq/map-api   # node --test: city read model, copilot contract prompts, reply policy, geocoding
npm test -w @farq/map-web   # vitest: tiles, tiers, viewport stats, URL camera, pins, sheet helpers
npm run build               # type-check + bundle
```

CI runs all three on every push and pull request (`.github/workflows/ci.yml`).

## The copilot

`POST /api/copilot` with `{ message, session_id?, language?, context: { bbox, zoom, selected_place_id, user_lat, user_lng, city } }` returns `{ answer, action, results, intent, session_id }`.

- Intent is decided in code after Arabic normalisation (digits, hamza, taa marbuta, diacritics). Follow-ups — الأرخص؟ · ليش؟ · خذني له — resolve against a 30-minute server session.
- Scope, in order: a named neighbourhood (geocoded), the person's position (2 km), the viewport, the city. The answer names which.
- Actions: `NOOP · FOCUS_PLACE · SHOW_RESULTS · FIT_BOUNDS · SET_FILTER · SET_CATEGORY · SET_SEARCH · RETURN_TO_USER`. Every id is validated against the returned rows.
- Every intent has a template answer in Arabic and English, so the copilot works with **no model**. With `GEMINI_API_KEY` set, Gemini may rephrase the template (JSON schema, rows in the user turn, model failover `gemini-3.5-flash-lite → gemini-flash-lite-latest`, ordered by what actually answers inside a shared 6 s budget — a reasoning model spends that budget thinking and returns nothing); its text is used only if every number in it exists in the rows.

`/api/chat`, the previous assistant, is gone. It had no caller left in this repo, and with a current model it failed on `thought_signature` in its function-calling turn — a broken duplicate of `/api/copilot`. Its number guard survives as `apps/api/lib/reply-policy.js`, which the copilot uses.

## Environment variable names

Web (Vite, prefix `VITE_`):

- `VITE_MAPBOX_ACCESS_TOKEN` (public token; restrict it by URL in the Mapbox dashboard)
- `VITE_API_BASE_URL` (empty locally → proxied)

API:

- `PORT`
- `SUPABASE_COMPARISON_READ_ENABLED=1`
- `SUPABASE_COMPARISON_DB_URL` or `COMPARISONS_DB_URL` or `DATABASE_URL`
- `MENU_CATALOG_ENABLED`, `SUPABASE_MENU_READ_ENABLED`, `UNIFIED_MENU_ENABLED`, `SUPABASE_BASKET_COMPARE_ENABLED`
- `MAPBOX_ACCESS_TOKEN` (server-side geocoding for named places; falls back to `VITE_MAPBOX_ACCESS_TOKEN`)
- `FARQ_API_ORIGIN` (optional catalog proxy)
- `GEMINI_API_KEY` (or `GOOGLE_GENAI_API_KEY` / `GOOGLE_GENERATIVE_AI_API_KEY`) — optional; the copilot and the map work without it
- `GEMINI_MODEL` — optional comma-separated failover list
- `CORS_ORIGINS`

## What the map needs from upstream

The map never invents a number, so its honest gaps are the pipeline's gaps: no
delivery fee outside hungerstation, no per-item observation date anywhere, a read
layer rebuilt every few days, and one city's worth of data split across several
spellings of its name. [`docs/data-pipeline-spec.md`](docs/data-pipeline-spec.md)
states each of those as a measured defect with a column contract and an acceptance
test. None of it can be built in this repo.

No secrets belong in git. Copy `.env.example` and set values locally or in the Vercel/Railway projects for this repo.

## Deploy

Vercel builds `apps/web` and rewrites `/api/*` to the Railway API (`vercel.json`).

**Both halves deploy from git, and only from `main`.**

- **Web** — Vercel builds every push to `main` from `farq-tech/map`.
- **API** — the Railway service `api` in project `farq-map-investor-api` is connected
  to the same repo and branch, with `rootDirectory = apps/api` and
  `watchPatterns = ["apps/api/**"]`, so an API deploy is triggered by an API commit
  and nothing else.

### No deploy outside `main`

Do not run `railway up`, `vercel --prod`, or any other push from a working tree.
It looks faster and it is how production drifted 13 commits behind this repo: a
working-tree deploy ships whatever is on that laptop at that moment — uncommitted
edits, a stale branch, a half-finished experiment — and leaves no commit anyone
can read, revert, or bisect. Nothing on the deployed site could be traced back to
a line of code.

The rule: **what is on `main` is what users see, and the only way to change what
users see is to merge to `main`.** A deploy is then a consequence of a commit, not
an action someone takes.

If a git-driven deploy is genuinely broken — the trigger does not fire, the build
cannot reach the repo — fix the connection. Reach for a working-tree deploy only
after that fails, only with the owner's explicit go-ahead for that one deploy, and
push the same commit to `main` immediately afterwards so the two never disagree.

Rollback is `git revert` plus a push, for the same reason: it goes through `main`.
