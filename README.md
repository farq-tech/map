# Farq Map

Investor preview of the Farq comparison street map. This repository is **only** the map experience — not the Farq monolith, and not [farq.sa](https://farq.sa).

**GitHub:** https://github.com/farq-tech/map

## Layout

```
apps/web     Vite + React map UI (`/` and `/map`)
apps/api     Express: comparison pins + optional restaurant menu proxy
```

## How to run

```bash
cp .env.example .env.local
# fill names in .env.local — never commit secrets

npm install
npm run dev:api    # http://127.0.0.1:4001
npm run dev:web    # http://127.0.0.1:5173
```

`/` and `/map` are the same map. Pin click opens `/merchant/restaurant/:id`.

Map chat (`POST /api/chat`) interprets **visible viewport gaps only** via one server tool, `get_visible_opportunities`. It does not browse the web. If the Gemini key is missing, chat returns 503 and the map still works.

```bash
npm test            # adversarial chat + slim-JSON tests (tool/policy layer)
```

## Environment variable names

Web (Vite, prefix `VITE_`):

- `VITE_MAPBOX_ACCESS_TOKEN`
- `VITE_API_BASE_URL`
- `VITE_FEATURE_FLAGS`

API:

- `PORT`
- `SUPABASE_COMPARISON_READ_ENABLED`
- `SUPABASE_MENU_READ_ENABLED`
- `MENU_CATALOG_ENABLED`
- `UNIFIED_MENU_ENABLED`
- `SUPABASE_BASKET_COMPARE_ENABLED`
- `SUPABASE_COMPARISON_DB_URL`
- `COMPARISONS_DB_URL`
- `FARQ_API_ORIGIN`
- `GEMINI_API_KEY` or `GOOGLE_GENERATIVE_AI_API_KEY` (map chat only; map works without it)
- `GEMINI_MODEL` (optional; default `gemini-2.5-flash`)

No secrets belong in git. Copy `.env.example` and set values locally or in the Vercel project for this repo (a **new** Vercel project — not Farq production).

## Vercel

This app is meant to be a separate Vercel project from Farq. Link from this directory only. Set the web `VITE_*` names on that project. The comparison API can stay on this Express process or `FARQ_API_ORIGIN` can point at an existing Farq API host.
