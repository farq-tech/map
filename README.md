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
GET /api/intelligence/map/places/:id                   one place (image, menu link, representative gap)
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

- A restaurant's representative opportunity is its largest observed gap among items priced ≤ **200 SAR** (catering and group meals are real but not what a person orders for dinner).
- Tiers: **Hero ≥ 36 · Strong 15–35 · Regular 5–14 · Faint < 5 SAR** (`apps/web/src/lib/farqOpportunityTiers.ts`, mirrored in the API).
- "Which app is cheapest here" is answered only from **8 comparisons** up, and always with its sample size.
- Freshness is a property of the whole read layer (`generated_at`); the source has no per-place observation time, so none is shown.
- Digits drawn on the map are Western; UI text follows the locale.
- Nothing is invented: no coordinates, prices, providers, places or neighbourhoods that are not in the source. Unknown places are refused in the person's own words.

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
npm test -w @farq/map-api   # node --test: city read model, copilot contract prompts, chat policy, geocoding
npm test -w @farq/map-web   # vitest: tiles, tiers, viewport stats, URL camera, pins, sheet helpers
npm run build               # type-check + bundle
```

CI runs all three on every push and pull request (`.github/workflows/ci.yml`).

## The copilot

`POST /api/copilot` with `{ message, session_id?, language?, context: { bbox, zoom, selected_place_id, user_lat, user_lng, city } }` returns `{ answer, action, results, intent, session_id }`.

- Intent is decided in code after Arabic normalisation (digits, hamza, taa marbuta, diacritics). Follow-ups — الأرخص؟ · ليش؟ · خذني له — resolve against a 30-minute server session.
- Scope, in order: a named neighbourhood (geocoded), the person's position (2 km), the viewport, the city. The answer names which.
- Actions: `NOOP · FOCUS_PLACE · SHOW_RESULTS · FIT_BOUNDS · SET_FILTER · SET_CATEGORY · SET_SEARCH · RETURN_TO_USER`. Every id is validated against the returned rows.
- Every intent has a template answer in Arabic and English, so the copilot works with **no model**. With `GEMINI_API_KEY` set, Gemini may rephrase the template (JSON schema, rows in the user turn, model-id failover `gemini-3.7-flash → gemini-3.5-flash-lite → gemini-2.5-flash`); its text is used only if every number in it exists in the rows.

`POST /api/chat` is the previous assistant and stays mounted until the new client is deployed everywhere; new work goes to `/api/copilot`.

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

No secrets belong in git. Copy `.env.example` and set values locally or in the Vercel/Railway projects for this repo.

## Deploy

Vercel builds `apps/web` and rewrites `/api/*` to the Railway API (`vercel.json`). Deploy from Git, not from a working tree: what is on `main` is what users see.
