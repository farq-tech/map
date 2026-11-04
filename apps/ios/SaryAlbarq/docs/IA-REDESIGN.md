# سَرى البارق — Information architecture redesign («ترتيب الشاشة»)

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
