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

## طلعة مشتركة — shared outings and live location

Friends on one off-road outing see each other on one map while the outing screen is open. No background tracking.

```
/outings                 create an outing, current and past outings, edit my name
/outings/join#<token>    invite preview + join (token in the URL fragment: never sent to a server, wiped from the address bar)
/outings/:id             the live map: members, distance + direction, last update, invite, settings
```

**Server** (`apps/api/lib/outings/*`, `routes/outings.js`, `migrations/001_sary_outings.sql`)
- Identity without accounts: `POST /api/outings/me` issues a 256-bit device token, stored as SHA-256. Every call is `Authorization: Bearer`.
- **Account deletion («احذف حسابي», App Store 5.1.1(v))**: `DELETE /api/outings/me` (Bearer, rate limited per address, 5/h) → `200 { ok: true }`; afterwards the token is `401` everywhere (a repeat is `401` too). One transaction, **hard delete** of the `sary.users` row:
  1. every open outing the person is in is left with the normal leave rules — owner hand-over to a «مساعد», else the earliest member; the outing ends if nobody is left. Other members get the same live events as a leave (`member_left` with `reason: "left"`, `owner_changed`, `outing_status: ended`).
  2. ended outings they still own pass to another member (`owner_id` only; a member who had left does not become `role: owner`), or are deleted when nobody else was ever in them. `outings.owner_id` / `outing_invites.created_by` are `NOT NULL` without `ON DELETE`, so this is what makes the row deletable with no schema change; invite rows they created are re-attributed to the outing's current owner, so a group's live link keeps working.
  3. deleting the row cascades memberships, the latest fix, trip summaries, web push subscriptions and APNs tokens; the recovery code lives on the row; `rally_set_by` is set null. Memory-only state — notes, SOS, voice clips they sent, cached fixes, auth cache, open sockets — is dropped. `field_diagnostics` hold no user id and are untouched. There are no other account links.
  Other members' positions, notes, clips and summaries are not touched. Tests: `lib/outings-delete.test.js`.
- Membership is checked on the server for every read, write and socket. Non-members get `404`, removed members are kicked from their socket at once (`4403`) and cannot rejoin.
- Lifecycle: outing `created → active ⇄ paused → ended` (owner), member `active → left | removed`, per-member sharing on/off. If the owner leaves, the earliest member takes over.
- Storage: one row per member — the **latest** fix only, no history. Deleted on leave, removal, sharing off, pause and end. RLS on, no policies; `anon`/`authenticated` revoked.
- Realtime: WebSocket `/api/outings/live` on the same Express server (auth in the first frame), rooms per outing, ping/pong. HTTP polling fallback (`GET /:id/live`, `POST /:id/positions`, `POST /:id/heartbeat`) when sockets cannot get through.
- Connection heartbeats (no coordinates) are separate from fixes, so «no GPS» and «no network» are different states.

**Client** (`apps/web/src/lib/outings/*`, `components/outings/*`)
- Off-road send policy by speed: 2.5 s / 50 m above 90 km/h, 4 s / 35 m on road, 6 s / 15 m on sand, a fresh fix every 30 s parked. «موفّر» doubles, «دقيق» shortens.
- Glitch filter: a jump implying > ~200 km/h (after both fixes' accuracy) is held until the next fix confirms it.
- Freshness: **مباشر** (fix ≤ 15 s moving, ≤ 45 s parked) · **آخر موقع معروف** (reachable, older fix) · **انقطع الاتصال** (nothing for 60 s). Accuracy > 60 m is drawn as an approximate ring, never animated.
- Markers interpolate between real fixes (≤ 1 s), never extrapolate; jumps over 2 km snap.
- The last known picture is kept in session storage through outages and wiped when the outing ends.

**Notifications with the screen off** (`apps/api/lib/outings/push.js`, `migrations/006_sary_push_subscriptions.sql`, `apps/web/public/sw.js`)
- Web Push for a note over a car and for an `sos` event — never positions. `notifyMembers(outingId, exceptUserId, payload)` sends to active members of an open outing except the sender; members looking at the outing right now get the in-app alert instead (SOS reaches them too).
- Subscriptions belong to a device identity (max 5), are re-checked against membership at send time, deleted when the push service answers 404/410, and must point at a real browser push service (FCM, Mozilla, Apple, WNS).
- `GET /api/outings/push/config` → `{ enabled, public_key }`; `POST|DELETE /api/outings/push/subscribe`. Off without `VAPID_*`.
- **Native iOS push (APNs)** (`apps/api/lib/outings/apns.js`, `migrations/008_sary_apns_tokens.sql`) goes out wherever web push does, through the same `notifyMembers()` — same recipients (active members of an open outing, never the sender, viewers only for SOS). HTTP/2 with token auth (ES256 JWT from the `.p8`, renewed every 50 min), Node's built-in `http2`/`crypto` only. Production tokens → `api.push.apple.com`, sandbox → `api.sandbox.push.apple.com`; a token answered with 410 / `BadDeviceToken` / `Unregistered` is deleted. SOS is `time-sensitive` with the default sound (not `critical`: that needs an Apple entitlement); notes, voice clips and «أنا بخير» are `passive`. The web `tag` is the `apns-collapse-id` (so «أنا بخير» replaces the SOS), `thread-id` is `sary-outing-<id>`, and every payload carries `type`, `outing_id`, `url`.
  - `GET /api/outings/push/apns` → `{ ok, enabled, bundle_id }` (public).
  - `POST /api/outings/push/apns` (Bearer) `{ token: "<hex device token, 64+>", environment: "sandbox"|"production", bundle_id?: "sa.sary.albarq" }` → `201 { ok: true }`; `400 invalid_token|invalid_environment|invalid_bundle_id`; `503 apns_disabled`. Max 5 tokens per identity, re-registering moves a token to the new identity.
  - `DELETE /api/outings/push/apns` (Bearer) `{ token }` → `{ ok, removed }` (only your own).
  - Off without all four `APNS_*` (see below); it says so once in the log and nothing else changes.
- «فعّل التنبيهات» in the outing settings. iPhone: Safari delivers web push only to the home-screen app (iOS 16.4+), so a Safari tab shows the «إضافة إلى الشاشة الرئيسية» steps; `manifest.webmanifest` + `sw.js` make that install work.
- Also pushed: «أنا بخير» (a quiet `sos_clear` that replaces the SOS notification, same tag; refreshing an SOS with a newer fix does not ring again) and voice clips (quiet, like notes, expiring with the clip).
- Keep the screen on: while the outing is active and I am sharing, the screen wake lock is requested automatically (a saved «off» is respected) and re-acquired whenever the page is visible again; the hint «وصّل الشاحن» shows in the status line.
- **One service worker** (`apps/web/public/sw.js`) does push and offline areas. It stays registered while push is subscribed **or** an offline area is saved (`src/lib/sw/worker.ts`); deleting the last area clears the offline cache but only unregisters the worker when push does not need it. The offline fetch logic runs only while an area exists, and never touches `/api`, `/_api` or non-GET requests.

```bash
node apps/api/scripts/migrate-outings.js                                    # apply migrations by hand (boot does it too)
SARY_TEST_DATABASE_URL=postgres://… npm test -w @farq/map-api                # integration tests against real Postgres (drops the sary schema!)
NODE_PATH=<playwright> node scripts/e2e-outings.cjs --base http://127.0.0.1:5173   # two browsers, end to end
NODE_PATH=<playwright> node scripts/e2e-outings-combined.cjs --base http://127.0.0.1:5173 --tone tone.wav   # iPhone 14 / Pixel 7: every outing feature + overlap checks
```

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
- `SARY_DATABASE_URL` — shared outings (read/write); falls back to the comparison/`DATABASE_URL`
- `SARY_AUTO_MIGRATE` — `0` disables running `apps/api/migrations` at boot
- `OUTING_*` — optional tuning, see `.env.example`
- `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` — Web Push for outing notes/SOS (`npx web-push generate-vapid-keys`). Unset → push off. Private key: API only.
- `APNS_KEY_ID`, `APNS_TEAM_ID` (`MH7J92HV9N`), `APNS_PRIVATE_KEY` (the `.p8` contents; `\n`-escaped on one line is fine), `APNS_BUNDLE_ID` (`sa.sary.albarq`) — native iOS push. Any unset → APNs off. API only, never in the repo. Creating the key (account owner, once): Apple Developer → Certificates, IDs & Profiles → **Keys** → **+** → name it, tick **Apple Push Notifications service (APNs)** → Continue → Register → **Download** the `AuthKey_<KEYID>.p8` (Apple lets you download it only once — store it in the password manager) and note the **Key ID** shown on that page. One key serves both sandbox and production and every app in the team. The app itself needs the Push Notifications capability (`aps-environment` entitlement) for `sa.sary.albarq`.

Web, shared outings:

- `VITE_LIVE_WS_URL` — `wss://<api host>/api/outings/live`. Vercel rewrites cannot carry WebSockets; without it the client uses HTTP polling.

## What the map needs from upstream

The map never invents a number, so its honest gaps are the pipeline's gaps: no
delivery fee outside hungerstation, no per-item observation date anywhere, a read
layer rebuilt every few days, and one city's worth of data split across several
spellings of its name. [`docs/data-pipeline-spec.md`](docs/data-pipeline-spec.md)
states each of those as a measured defect with a column contract and an acceptance
test. None of it can be built in this repo.

No secrets belong in git. Copy `.env.example` and set values locally or in the Vercel/Railway projects for this repo.

## Data integrity

The map's worst failure is not an error page. It is a well-formed `200` carrying
an empty map, which tells a user there are no opportunities in their city — a
false statement about the world, served as success. Three layers exist to stop
that.

**Empty is classified, never assumed** (`apps/api/lib/result-integrity.js`).
Every city response is sorted into `ok`, `filtered-zero` (the user's own filter
removed everything — fine), `stale` (older than the staleness ceiling), or
`source-empty` (the read layer produced nothing for a city we serve). The last
one is **not** served as `200`: it answers `503` with `no-store`, because a blank
map is not a valid answer. The status also rides on the `X-Farq-Data-Status`
header, and counters are exposed at `/api/health`.

**A rebuild has to earn the right to replace what we are serving**
(`apps/api/lib/read-layer-guard.js`). When the ten-minute cache refetches, the
new snapshot is fingerprinted — row count, required-field null rates, providers
present, أحياء represented — and compared with the last one that passed. A
snapshot that has lost a third of its restaurants, or a required column, or most
of its providers, is **refused**: the previous snapshot keeps serving, stale and
correct rather than fresh and wrong. Refusals appear at `/api/health`.

The thresholds are set at catastrophe level on purpose. The layer rebuilds every
few days and only one snapshot was observable when they were chosen, so
rebuild-to-rebuild variance is not yet known; the guard catches a pipeline that
broke, not one that had a quiet week. Tighten them once two rebuilds have been
recorded — the reasoning and the measured baseline are in the module.

**Production is checked from outside** (`apps/api/scripts/synthetic-check.mjs`).
Ten assertions against the real service: health, a city that must not be empty,
the exact number of أحياء we ship, a named حي that must still count
opportunities, and a clean `404` for a city we do not serve. Every assertion is a
floor or a committed value, never an exact count of data that legitimately moves.

```bash
node apps/api/scripts/synthetic-check.mjs                        # production
node apps/api/scripts/synthetic-check.mjs --base http://localhost:4001
node apps/api/scripts/synthetic-check.mjs --json                 # for a scheduler
```

Exit `0` all passed · `1` an assertion failed · `2` the service was unreachable,
which is a different problem worth telling apart.

**It runs itself every fifteen minutes** (`.github/workflows/synthetic.yml`) and
turns a failure into a GitHub issue. No new alerting service: this repository
already runs Actions, and GitHub already notifies on issue open, comment and
close — which is exactly deduplication, a thread for a continuing outage, and a
recovery notification.

The cadence came from measurement. One cycle is four requests, ~512 KB gzipped
and ~1.4 s; at fifteen minutes that is 384 requests and ~1.5 GB of egress a
month, negligible against every limit involved, and Actions minutes are free on
a public repository. The one real cost is deliberate: fifteen minutes sits
outside the API's ten-minute cache, so each run exercises the read path for real
instead of reading a warm cache.

Two failure kinds, never mixed:

| Exit | Kind | Alert |
|---|---|---|
| `1` | the data is wrong | issue labelled `synthetic-data`, titled `[synthetic] production — data failure` |
| `2` | the service is unreachable | issue labelled `synthetic-availability` |

Each alert carries the time, environment, exit code, and for every failed
assertion its endpoint, what was expected and what was actually returned, plus
the last fully successful run.

**A four-hour outage produces one alert and four notes, not sixteen.** One issue
per kind is opened and reused; a still-failing run comments at most once an hour;
recovery closes the issue with a `SYNTHETIC RECOVERY` note, because a channel
that simply goes quiet cannot be told apart from a monitor that died. The
decision logic is pure and lives in `apps/api/lib/synthetic-alert.js`, so all of
that is tested without a running service — including the sixteen-runs-four-notes
case.

Try the alerting by hand without touching anything:

```bash
node apps/api/scripts/synthetic-alert.js --result result.json --exit-code 1 --dry-run
```

**Right now the scheduler is not GitHub Actions.** The account is locked for a
billing issue, so no workflow has run since this was set up — neither the
synthetic check nor CI, which means recent commits were verified locally and not
on GitHub. The workflow is correct and starts working the moment billing is
fixed; until then the same check runs from inside the API on the same
fifteen-minute cadence (`apps/api/lib/self-check.js`), by executing the same
script rather than reimplementing its assertions.

Enable it with `SELF_CHECK_ENABLED=1` and `SELF_CHECK_BASE_URL`. Results appear
under `self_check` at `/api/health`, and a failure is recorded through the same
integrity channel as everything else, so the endpoint answers 503.

Its blind spot is stated in the module and worth repeating: a monitor inside the
service cannot report that the service is down. That case is covered by the
platform, which probes `/version` with a restart policy. What this covers is the
failure it was built for — a healthy process serving wrong or empty data, which
no liveness probe can see.

Two things about GitHub's scheduler worth knowing: `schedule` is best-effort and
can be delayed by minutes under load, so treat it as "about every fifteen
minutes" rather than a heartbeat; and GitHub disables scheduled workflows after
60 days without repository activity.

### Three signals, kept apart

| Question | Where | Behaviour |
|---|---|---|
| Is the process up? | `GET /version` | **liveness** — the platform's probe (Railway polls it with an ON_FAILURE restart policy). Always 200 while serving. Says nothing about data, because a restart does not fix a stale read layer. |
| Is the data trustworthy? | `GET /api/health` | **readiness** — 503 when the read layer produced nothing or a rebuild was refused. Not a liveness probe. |
| Can a user actually get a correct result? | the synthetic check | from outside, every fifteen minutes |

## Place truth

Farq draws one pin per restaurant and attributes it to one حي. Both are claims
about identity, and upstream that identity is built by matching each delivery
app's listing to a shared canonical id. When that match lands on the **brand**
rather than the **branch**, one pin ends up standing for a chain.

Measured on production, 21 Aug 2026, over the restaurants we actually show in
Riyadh: 6,684 agree within 30 m, 1,390 within a block, 130 within a kilometre,
and **386 do not** — the worst spans 73 km. That is 4.5% of the places and 8.4%
of the comparable items.

So every place carries `branch_spread_m` and a `place_confidence`
(`single-address`, `same-block`, `suspect-merge`, `multi-branch-merge`,
`single-provider`, `unknown`), and a `multi-branch-merge` **is not assigned to a
حي**. It stays on the map, it stays in the city total, it keeps its own number —
it is only barred from being counted as belonging to one neighbourhood, under
the same rule that already governs a place falling in no polygon: a wrong حي is
worse than an uncounted one.

`apps/api/lib/place-identity.js` scores two records for sameness and reports
suspected duplicates **weakest match first**, because the honest way to judge a
threshold is to look at the worst pairs it still accepts, not at a random sample
dominated by easy ones.

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
