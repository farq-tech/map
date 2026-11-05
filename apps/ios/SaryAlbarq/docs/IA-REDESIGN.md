# سَرى البارق — Information architecture redesign («ترتيب الشاشة»)

> Brief: the owner's FARQ V8 spec (driving / stopped / exploration modes, one adaptive header,
> one action center, one alert at a time with history, map declutter, convoy intelligence,
> My Trips + four settings sections, staged delivery). This document is the plan; §6 says
> which stages ship in build 8 and which come next.

Build 8. Goal: the live outing screen felt crowded — every feature was visible at
once. This pass reorganises and simplifies with progressive disclosure, **without
removing a feature**: everything stays reachable in at most two taps from the live
map, and the accessibility identifiers of every entry point are kept (UI tests walk
them, see `UITests/ReachabilityUITests.swift`).

Audit method: demo outing (`-demo -SaryWeatherDemo calm -SaryTrip underway`, plus
`-demoConvoy -demoSilent -SarySafety stuck-friend -SaryWeatherDemo rain` for the alert
burst, `-SaryNavDemo -SaryNavTo … -SaryNavState guide -SaryDrive 1` for guidance),
iPhone 17 Pro Max simulator, light/dark/drive. "Controls" = separately tappable
things on screen (buttons, chips, pills, cards with actions, rows); read-only
indicators (dots, speedometer, Mapbox ornaments) are listed apart. Screenshots:
`~/code/map-wt/ios-declutter-shots/{before,after}/` (not committed).

## 1. Audit (build 7)

### Live screen, stopped, sheet at peek (`before/live-stopped-light`)
| Area | What is there | Controls |
|---|---|---|
| Top | back · status capsule (name + 3 dots, expands warnings) | 2 |
| Under it | plan strip, horizontally scrolling: weather chip · «اتبع الخطة» · destination pill (menu) · «الخطة» · «بحث» (last two off-screen) | 5 |
| Side | cluster: «موقعي» · «المجموعة» · «رسالة» · «طريق العودة» · «المزيد» | 5 |
| Bottom | SOS · push-to-talk · speedometer (read-only, shown while parked) | 2 (+1 indicator) |
| Sheet peek | people summary row · trip progress strip (second row) | 2 |
| Map | edge arrows (no cap), waypoint labels at every zoom, friends' trails | 0–6 |
| **Total** | | **16** + edge arrows + 4 indicators |

### Live screen with an alert burst (`before/live-alerts-light`)
Same as above **plus** 2 stacked alert cards (stuck friend: 3 answers + close; silent
friend: close) and a «+٢ تنبيهات» pill: **+7 → 23 controls**; the plan strip and the
two cards push the map down to ~45 % of the screen.

### Live screen, navigating in drive mode (`before/live-nav-drive`)
maneuver banner · status capsule (back + capsule) · weather chip · nav cluster
(overview · voice · steps) · speed + limit · SOS · PTT · guidance bar («إنهاء») +
a second trip-progress row: **11 controls**, two stacked top bars (banner *and* capsule).

### «المزيد» menu (`before/more-menu-light`)
7 flat rows (أقرب محطة، غرّزت، ملاحة، يوتيوب، أضف نقطة، انسخ موقعي، ابحث) beside the 5
cluster buttons: **12 controls on screen**, no grouping, «ابحث» duplicated by the plan
strip's «بحث», «طريق العودة» duplicated by the sheet's «مساري» card.

### Sheet tabs (`before/sheet-half-light`, `before/sheet-full-light`)
Tabs: «المشاركون» · «الدعوة» · «الإعدادات».
* «المشاركون» (default) mixed four jobs in one scroll: my sharing, the trip card, phone
  banner, rally, safety (timer + stuck), weather, convoy, my trail, YouTube, the people,
  shared points — **~24 controls** before you reach the people list.
* «الدعوة»: QR, copy, share, revoke — 4.
* «الإعدادات»: sharing ×3, channel mute, trail ×5, speed ×3, offline, drive, night, my
  phone, pause/end/leave — **~20**.
* Peek: two rows (people + trip).

### Home «طلعاتي» (`before/home-light`)
settings · profile · «طلعة جديدة» · «انضم برابط» (two equal-weight CTAs) · every outing
an equal card with open + «i» (4 × 2) · footer note: **12 controls**; the active outing
looks like the others.

### Settings (`before/settings-light`)
2 untitled sections: المظهر، الخصوصية، التنبيهات، الخرائط بلا إنترنت | ملفي، حول — **6
rows**; diagnostics (GPX export) hidden behind 5 taps on the version, route provider
behind 7 taps (Release).

### Create wizard (`before/create-light`)
close · search/coordinate field · «اختر من الخريطة» · step header — **3 controls** on
step 1. Already one decision per step; left as is.

## 2. New information architecture

### 2.1 Context modes on the live screen
`LiveContext` = **driving** | **stopped**, chosen automatically, overridable in
«المزيد» → «شكل الشاشة» (تلقائي / قيادة / متوقف).
* **driving** when navigation is active, or the car moves > 15 km/h (hysteresis: back
  to stopped after ≤ 5 km/h for 20 s), or drive mode is on — and the sheet is at peek.
* **stopped** otherwise, and always while the sheet is raised (the person is reading).

| Element | Driving | Stopped |
|---|---|---|
| Top bar | maneuver banner when guiding (else the trip header); «طريق العودة» panel replaces it while backtracking | trip header (+ banner / backtrack panel under it when active) |
| Floating group | «موقعي» · «المجموعة» (nav: camera · voice · steps) | «موقعي» · «المجموعة» · «+» |
| Contextual | «طريق العودة» chip after arrival / off the route | same |
| Bottom | SOS (left) · PTT (right) · speed + limit sign above PTT | SOS · PTT (no speed) |
| Alerts | one card, only high priority (SOS → convoy); the rest on the bell | one card; the rest on the bell |
| Map | edge arrows only for members in an alert state, max 3; friends' trails off | edge arrows max 3 (alert first, then nearest) |

### 2.2 One «trip header»
Replaces status capsule + weather chip + plan strip + peek progress:

`‹ back · [dot] destination name / «باقي ١٢ كم · نوصل ٧:١١» · ☀︎ ٢٩° · 🔔 ٢`

* name = destination (outing name when none); second line = remaining · ETA, or the
  trip phase («لم تبدأ», «وصلت»), or follow-plan status when following.
* status dot = worst of connection / GPS / sharing; tap → details (the old capsule's
  warnings + nearby cars) folding open under the header.
* weather = icon + temperature; tap → the weather sheet (as the old chip).
* bell = queued alerts count; tap → the queue opens under the header.
* tap anywhere else → the sheet opens at half on «الرحلة».

### 2.3 Map controls: «موقعي» · «المجموعة» · «+»
«+» (`outing-actions`) opens one grouped action sheet (`outing-actions-sheet`):

| Group | Entries (identifier kept) |
|---|---|
| الطريق | ملاحة (`outing-navigate`) · ابحث أو إحداثية (`outing-search`) · طريق العودة (`outing-backtrack`) · اتبع الخطة (`plan.follow`) |
| المجموعة | رسالة فوق سيارتي (`outing-note-open`) · غرّزت (`outing-stuck`) · أضف نقطة (`outing-waypoint-add`) · انسخ أو شارك موقعي (`outing-copyme`) |
| الخدمات | أقرب محطة (`outing-nearest-open`) · الطقس (`outing-weather`) |
| الترفيه | يوتيوب (`outing-youtube`) |

«طريق العودة» also appears by itself on the map after arrival or when off the
planned route; «غرّزت» stays one tap away in «الرحلة» → السلامة.

### 2.4 Sheet: three tabs
| Tab | Content |
|---|---|
| «الرحلة» (default) | my sharing / start call to action · trip card (progress, stats, arrival, end) · destination (open in Maps, copy) · weather at destination · plan & route + checklist (plan editor, follow, search) · safety (return timer, «غرّزت») · my trail («طريق العودة») |
| «المجموعة» | members (distance / speed / arrival) · convoy · rally point · shared points · invite (QR, copy, share, revoke) |
| «المزيد» | my sharing & privacy (pause, battery, notifications, my phone) · walkie-talkie mute · my trail settings · speed · drive / night / «شكل الشاشة» · offline maps · YouTube channel · pause / end / leave |

Peek = one line: the people (avatars, «٤ في الطلعة · ٢ مباشر · الأقرب ٩٠ م»); while
guiding, the guidance bar only.

### 2.5 Alerts: one priority queue
`AlertPriority`: SOS (strips, unchanged) > stuck > silent > return-timer overdue /
sunset > convoy / drift > weather > note / voice > media. Toasts (feedback for the
person's own action) stay short-lived pills and never queue.
* one card on screen (the top of the queue); the rest = the bell count.
* driving: weather / notes / voice / media never take the card — bell only.
* the in-channel media notice lane joins the queue's lowest tier (hidden while driving).

### 2.6 Map clutter
* edge arrows: max 3, alert members first then nearest; driving shows only alert members.
* waypoint labels from zoom 14.5 (icons always).
* my trail line thinner (core 4 → 3 pt, casing 7 → 5 pt).
* friends' trails off while driving (the toggle still applies when stopped).

### 2.7 Home and settings
* «طلعاتي»: one primary «طلعة جديدة»; «انضم برابط» becomes a quiet text button; the
  active outing is a big card on top («افتح الخريطة»), the others compact rows.
* Settings in 4 titled sections: **الحساب** (ملفي، رمز الاسترجاع، التنبيهات) ·
  **الخصوصية والموقع** (الخصوصية) · **المظهر والقيادة** (المظهر) · **الخرائط والبيانات**
  (الخرائط بلا إنترنت، متقدم) + «حول». «متقدم» holds GPX export and the route provider
  (no more hidden taps).

### 2.8 Copy
Short imperative verbs, one name per thing: «ملاحة», «ابحث أو إحداثية», «طريق العودة»,
«رسالة فوق سيارتي», «غرّزت», «أضف نقطة», «انسخ أو شارك موقعي», «أقرب محطة», «الطقس»,
«يوتيوب». Tabs «الرحلة / المجموعة / المزيد». No entry point exists twice on the map.

## 3. Before → after (controls on screen, measured on build 8)

| Screen | Before (build 7) | After (build 8) |
|---|---|---|
| Live, stopped, peek | 16 + 4 indicators, two top rows | **10** (back · header · dot · weather · موقعي · المجموعة · + · SOS · PTT · peek), no indicators |
| Live, alert burst | 23 (2 cards + «+٢») | **15** (1 card + bell «٤») |
| Live, guiding (drive) | 11, banner **and** capsule | **7** (banner · camera · المجموعة · SOS · PTT · voice · steps · «إنهاء» in the bar) + speed & limit |
| Actions | 12 on the map (5 cluster + 7 flat rows) | 3 on the map; 11 entries in 4 named groups in their own sheet |
| Sheet, first tab | «المشاركون» ~24 | «الرحلة» ~12 (people moved to «المجموعة», settings to «المزيد») |
| Sheet peek | 2 rows | 1 row |
| Home | 12, two equal CTAs, all cards equal | 11, one primary CTA, active outing big on top, others compact rows |
| Settings | 6 rows in 2 untitled groups + 2 hidden tools | 8 rows in 4 titled sections + «حول»; tools under «متقدم» |
| Create step 1 | 3 | 3 (unchanged) |

## 4. Decisions worth knowing
* **SOS stays bottom-left, push-to-talk bottom-right** (as in build 7): moving the
  emergency button would break muscle memory for no gain; the spec's "start/end" was
  read as "the two bottom corners".
* **Driving hides «+»**: the map keeps «موقعي» · «المجموعة» only. Raising the sheet
  (one tap) switches to stopped, where «+» is back; «شكل الشاشة» pins either mode.
* **Guidance voice and steps** moved from the map into the guidance bar (the sheet's
  peek) so the floating group stays two buttons while navigating.
* **«طريق العودة»** is in «+» → الطريق, in «الرحلة» → مساري, and appears on the map by
  itself after arrival, while off the planned route, or while it runs.
* **Toasts** (feedback for the person's own action) are not alerts: short pill, never queued.
* **Route provider** is no longer behind 7 taps in Release: it is under «متقدم».
* Status capsule, plan strip and peek trip strip are gone from the live screen; their
  components stay in the design-system showcase.

## 5. Feature-preservation matrix

Every feature of the live screen in build 7 → where it is in build 8 → taps from the map
(stopped context). ✔ = asserted by `UITests/ReachabilityUITests` (identifier checked), † = by
another UI test, ‡ = unit-tested.

| Feature | Build 7 | Build 8 | Taps |
|---|---|---|---|
| Back to «طلعاتي» | status capsule | header «‹» (`outing-back`) | 1 ✔ |
| Connection / GPS / internet state, warnings | capsule dots + expand | header dot → details (`outing-link-state`) | 1 ✔ |
| Nearby cars (mesh) | capsule subtitle | header line when relevant + status details | 0–1 |
| Weather now / at destination | chip under capsule | header weather (`weather.chip`) → sheet; «+» → الخدمات → الطقس; «الرحلة» card | 1 ✔ |
| Trip progress, remaining, ETA | peek strip | header line; «الرحلة» trip card | 0 / 1 ✔ |
| Trip stats, arrival, «أنهِ الرحلة», summary, return trip | «المشاركون» trip card | «الرحلة» trip card | 2 † (TripUITests) |
| Locate me / follow | cluster | floating group (`outing-locate`) | 1 ✔ |
| Fit the group | cluster | floating group (`outing-fit`) | 1 ✔ |
| Note above my car | cluster | «+» → المجموعة (`outing-note-open`) | 2 ✔ |
| «طريق العودة» | cluster + «مساري» card | «+» → الطريق (`outing-backtrack`); map shortcut after arrival / off route; «الرحلة» → مساري | 1–2 ✔ † |
| Navigation (member / destination / rally / point) | «المزيد» | «+» → الطريق (`outing-navigate`) | 2 ✔ † |
| Search place / coordinates | «المزيد» + plan pill | «+» → الطريق (`outing-search`); «الرحلة» → ابحث | 2 ✔ |
| Follow the plan | plan pill | «+» → الطريق (`plan.follow`); «الرحلة» → الخطة | 2 ✔ |
| Plan editor + checklist | plan pill | «الرحلة» → «الخطة وقائمة التجهيز» (`plan.openEditor`) | 2 ✔ |
| Destination: open in Apple / Google Maps, copy | destination pill menu | «الرحلة» → الوجهة (`plan.destination`) | 2 ✔ |
| «غرّزت» | «المزيد» | «+» → المجموعة (`outing-stuck`); «الرحلة» → السلامة (`sheet-stuck`) | 2 ✔ † |
| Return timer | «المشاركون» | «الرحلة» → السلامة (`timer-card`) | 1 ✔ |
| Add waypoint | «المزيد» / long press | «+» → المجموعة (`outing-waypoint-add`); long press | 2 ✔ † |
| Copy / share my location | «المزيد» / long press on «أنت» | «+» → المجموعة (`outing-copyme`) | 2 ✔ † |
| Nearest station | cluster | «+» → الخدمات (`outing-nearest-open`) | 2 ✔ |
| YouTube («قناتي» / «قناة الطلعة») | «المزيد» + sheet card | «+» → الترفيه (`outing-youtube`); «المزيد» tab (`media.entry`) | 2 ✔ † |
| SOS | dock | dock (`outing-sos`) | 1 ✔ † |
| Push-to-talk | dock | dock (`outing-ptt`) | 1 ✔ |
| Speedometer | always | driving context only (`speedometer`) | 0 ✔ † |
| Posted speed limit | while guiding | while guiding (real nav data only) | 0 |
| Guidance camera / voice / steps | cluster | camera on the map; voice + steps in the guidance bar | 1 † |
| Members list (distance, speed, arrival) | «المشاركون» | «المجموعة» (`participant-row`) | 2 ✔ † |
| Convoy mode | «المشاركون» | «المجموعة» (`convoy.section`) | 2 ✔ † |
| Rally point | «المشاركون» | «المجموعة» (`rally-card`) | 2 ✔ |
| Shared waypoints | «المشاركون» | «المجموعة» | 2 † (WaypointsUITests) |
| Invite (QR, copy, share, revoke) | «الدعوة» tab | «المجموعة» → ادعُ ربعك (`invite-section`) | 2 ✔ |
| My sharing (start / stop) | «المشاركون» + «الإعدادات» | «الرحلة» top + «المزيد» (`settings-pause-sharing`) | 1–2 ✔ † |
| Battery, notifications, my phone | «الإعدادات» | «المزيد» | 2 ✔ |
| Channel mute | «الإعدادات» | «المزيد» (`settings-ptt-mute`) | 2 ✔ |
| Trail settings, friends' trails | «الإعدادات» + «مساري» | «المزيد» / «الرحلة» → مساري | 2 ✔ |
| Speed alert settings | «الإعدادات» | «المزيد» (`speed.alert`) | 2 ✔ † |
| Drive / night mode | «الإعدادات» | «المزيد» → القيادة والعرض | 2 ✔ |
| Screen mode override (new) | — | «المزيد» → «شكل الشاشة» (`settings-context`) | 2 ✔ |
| Offline maps | «الإعدادات» | «المزيد» (`settings-offline`); app settings | 2 ✔ |
| Pause / end / leave outing | «الإعدادات» | «المزيد» (`settings-leave`) | 2 ✔ |
| Alerts (stuck, silent, timer, convoy, weather, notes, voice) | lane, 2 cards + «+N» | 1 card + bell queue (`alerts.bell`) | 0–1 † ‡ |
| Alert history (new) | — | bell → السجل | 1 ‡ |
| Media «في قناة الطلعة» notice | own lane | lowest tier: shown when nothing else / on the bell | 0–1 |
| Edge arrows to off-screen friends | all | max 3, alert members first | 0 ‡ |
| GPX export, route provider | hidden taps on «حول» | Settings → «متقدم» | 2 |

### Build 9 additions (stages 4–5)

| Feature | Build 8 | Build 9 | Taps |
|---|---|---|---|
| Exploration mode (new) | — | header «استكشاف» (`trip.explore`); «+» → الخريطة (`outing-explore`); auto after panning > 5 km from every live car while stopped; never while driving; «ارجع للرحلة» (`explore-exit`) | 1 ✔ |
| Layer switcher: satellite / standard / topographic (new) | satellite only | exploration → «الطبقات» (`explore-layers` → `layer.*`) | 2 ✔ |
| 3D terrain view (new) | terrain always at 1.15, flat camera | exploration → (`explore-terrain`), also in «الطبقات» (`explore-terrain3d`) | 2 ✔ |
| Elevation at the crosshair (new) | — | exploration readout (`explore.elevation`), Mapbox Terrain-DEM only, «غير متاح» otherwise | 1 ✔ ‡ |
| Coordinates at the crosshair, decimal / DMS, copy (new) | point card only | exploration readout (`explore-coord-format`, `explore-copy`); point card unchanged | 1–2 ✔ |
| Saved places «أماكني المحفوظة» (new) | — | exploration (`explore-places`, `explore-save`); point card «احفظ في أماكني» (`point.save`); rename / icon / delete / navigate / share / copy per row | 2 ✔ ‡ |
| GPX tracks list + on map (new) | import/export inside the plan editor only | exploration → «مسارات GPX» (`explore-tracks`); plan import/export also lands there | 2 ✔ ‡ |
| Offline maps | «المزيد» / Settings | + exploration → «الطبقات» → `explore-offline`; areas can include the topographic layer (`offline.topo`); «عادي» says it needs internet | 2–3 ✔ |
| Distance from the leader, stopped duration per member (new) | — | «المجموعة» rows (`participant.convoy`) | 2 ✔ ‡ |
| Separation / unexpected-stop alerts (new) | convoy order alerts only | one card + bell; leaders get «ارجعوا لنقطة التجمع» on the card (`convoy.recall`) | 0 ✔ ‡ |
| «تنبيهات القافلة» rules (new) | — | «المزيد» tab (`settings-convoy-alerts`); Settings → الحساب (`settings.convoyAlerts`) | 2 ✔ ‡ |
| Return to the meeting point (new) | rally «اتجه» only | rally card «ارجعوا لنقطة التجمع» (`rally.recall`, leaders) → members get a prompt with «اتجه» (`convoy.goRally`); who is at the rally (`rally.arrived`) | 2 ✔ ‡ |

### Build 10–11 additions («دقة المسار» + «إنجاد»)

| Feature | Build 9 | Build 10–11 | Taps |
|---|---|---|---|
| One track style (new) | thin trail, plain GPX lines | every track (my live trail, «طريق العودة», summary, story preview, GPX, followed track): darker casing, round joins, speed `line-gradient` (light slow → deep fast; GPX one colour), start / end dots; display-only Douglas–Peucker 2.5 m + outlier rejection (> 25 m accuracy, > 70 m/s jumps) | 0 ‡ |
| Clean satellite (new) | POI / transit / road labels off, place labels on | when a track is the subject (exploration on satellite, «طريق العودة», follow, summary, track detail): place + road labels off too; while navigating: road + place names on; track framing to z19 | 0 |
| Trip stats card (new) | stats grid (km, moving time, top / average speed) | summary «مساري»: track on clean satellite + dark card «المسافة · أعلى سرعة · مدة القيادة» (`track.stats`, «—» when unknown) + «اسلك هذا المسار» (`track.follow`); «كبّر» → full-screen track detail (`summary.trackOpen` → `track.detail`) | 0–1 † ‡ |
| «اسلك هذا المسار» follow mode (new) | «طريق العودة» on my own trail only | any saved track: summary / track detail (`track.follow` → stand-alone `follow.screen`), GPX rows in exploration (`tracks.follow` → detail), a member's recent trail (`participant.followTrail`); panel `follow.panel`: distance left along the track, progress, «اعكس الاتجاه» (`follow.reverse`), «إنهاء» (`follow.exit`); one «خرجت عن المسار» card (`alert.offTrack`, > 50 m for > 10 s); > 2 km away: «وجّهني لأقرب نقطة» (`follow.approach`, online only); driving: the panel is the one header | 1–2 † ‡ |
| «اطلب إنجاد» (new) | — | «غرّزت؟» confirm → «اطلب إنجاد (واتساب)»; stuck strip «إنجاد» (`stuck-enjad`); «السلامة» stuck row (`sheet-stuck-enjad`); sent-SOS strip «إنجاد» (`sos-enjad`) → sheet `enjad.sheet`: WhatsApp (`enjad.whatsapp`, SMS fallback), «اتصل بإنجاد» (`enjad.call`), SMS (`enjad.sms`); the person sends it | 2 † ‡ |

## 6. Stages

| Stage | Scope | Build 8 |
|---|---|---|
| 1 | Inventory, matrix, before/after counts (this doc) | ✅ shipped |
| 2 | Driving / stopped modes, adaptive header, action center, 3 tabs, one alert + bell, map declutter, home, settings | ✅ shipped, unit + UI tested |
| 3 | Notification history behind the bell | ✅ shipped, unit tested |
| 4 | **Exploration mode**: layer switcher (satellite / standard / topographic from Mapbox Outdoors or Terrain-DEM hillshade + contours), elevation readout, coordinates + saved locations, GPX/route exploration, offline management entry | ✅ build 9 (see §7) |
| 5 | **Convoy intelligence**: distance from the leader per vehicle, stopped / disconnected states on rows and cars, separation + unexpected-stop alerts with grace periods and configurable thresholds (settings), return-to-meeting-point flow | ✅ build 9 (see §8) |

Main experience **Map · Group · Trip**: in build 8 «الخريطة» is the live map itself (header,
floating group, «+»), and the sheet carries «الرحلة» and «المجموعة»; the third tab «المزيد»
holds this outing's settings. Stage 4 turns it into «الخريطة» (layers, exploration, offline).

## 7. Exploration (build 9)

* **Third context mode.** `LiveContext.exploring`: entered from the header (`trip.explore`), «+» → الخريطة,
  or automatically when a pan settles more than 5 km from every *live* car while stopped (sheet down,
  not picking). Real driving (guidance or motion > 15 km/h) always wins: exploration is never entered and
  is left at once while driving (toast «رجعنا لشاشة القيادة»). «ارجع للرحلة» is one tap.
* **Layers** are real Mapbox styles with Arabic names: Standard Satellite (the trip map), Standard,
  Outdoors v12 (contours + hillshade from mapbox-terrain-v2; contour labels rewritten to
  `number-format` with the `ar-SA` locale → «٢٬٢٥٠ م»). The chosen layer and the 3D view apply in
  exploration only; the trip map stays on satellite (the layer offline areas always cover). Cars, chips,
  trails, the plan, navigation and exploration layers are re-added on every style load.
* **Elevation** = `MapboxMap.elevation(at:)` ÷ the terrain exaggeration, only when the DEM tile is loaded;
  otherwise «الارتفاع غير متاح». Nothing is estimated.
* **Saved places / GPX tracks** are on-device JSON (Application Support), never sent.
* **Offline honesty.** Areas can now include the topographic layer (an Outdoors tileset descriptor + style
  pack, opt-in); each area lists its layers; «عادي» says it always needs internet.

## 8. Convoy intelligence (build 9)

* Reference = «المقدمة» when convoy mode names one, else «أمير الرحلة» (the outing owner).
* Rows: «عن أمير الرحلة ١٫٢ كم» from two live positions only; «واقف منذ ٤ د» after 60 s at ≤ 3 km/h;
  speed, last update and «انقطع منذ …» as before.
* Rules (Settings → «تنبيهات القافلة», defaults): separation > 2 km for > 60 s (clears under 80 % —
  hysteresis); unexpected stop: was > 20 km/h within 2 min before stopping, ≤ 3 km/h for 3 min, another
  live car > 15 km/h, not within 300 m of the destination / rally / waypoints, never my own car; disconnected
  = the server's member_silent at 10 or 30 min; behind the tail = the existing alert with an optional grace
  (default 0, as before). Reminders at most every 5 min, 2 min quiet after a clear; stale positions reset.
* Priority: unexpected stop = silent tier (may need help); separation = convoy tier.
* Return to the meeting point: leaders send «↩︎ ارجعوا لنقطة التجمع» through the existing note channel
  (older builds see a note above the leader's car); this build turns a leader's recall note into a
  prompt with «اتجه» (in-app navigation to the rally point; the routed options sheet shows the real ETA)
  and the straight-line distance; the rally card shows who is there.
