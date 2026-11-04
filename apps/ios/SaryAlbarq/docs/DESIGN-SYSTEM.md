# Sary Albarq design system (iOS)

Everything lives in `Sources/UI`. Screens read ONE resolved theme from the
environment and never hard-code colours, sizes or glass.

```
Sources/UI/DesignSystem   tokens, theme, AppearanceSettings, glass abstraction
Sources/UI/Components     buttons, map controls, status capsule, alert lane, SOS,
                          push-to-talk, sheet, participant row/card, rally/station,
                          map overlays, states, inputs, dialogs, appearance panel
Sources/UI/Contracts      screen contracts (unchanged from the WIP commit)
Sources/UI/Showcase       DEBUG-only Design Showcase + procedural desert map stage
```

## Wiring (for the app engineer)

```swift
@State private var appearance = AppearanceSettings()   // one per app, persisted
RootView()
    .saryAppearance(appearance)        // theme, RTL, Arabic locale, Tajawal, text-size step
// feed the automatic modes:
appearance.autoDrive = speed > 7       // m/s
appearance.autoNight = sunIsDown
```

In a view: `@Environment(\.sary) private var theme`, then `theme.palette.*`,
`theme.space(.m)`, `.saryText(.headline)`, `.saryNumber(.subhead)` (tabular
digits for anything that ticks), `.saryGlass(Capsule(), role: .control)`,
`theme.animation(.smooth)` (honours Reduce Motion and the app's motion setting).

Map overlays are placed in physical screen points: wrap them in
`SaryMapOverlayLayer { … .saryMapPoint(x, y) }` — plain `.position` is mirrored
under RTL.

The live sheet: `.sheet { content.sarySheetPresentation(detent: $detent) }` —
native detents (minimised / medium / large), map stays interactive up to
medium, not swipe-dismissible.

## Glass

`saryGlass` draws Liquid Glass (`glassEffect`, tinted to the theme so it stays
legible over bright sand) on iOS 26+, and material + tint + hairline on 17–25.
Drive mode, increased contrast and the «معتم» intensity are always opaque.
Glass is used only for chrome over the map; cards, rows and content are opaque.

## Design Showcase

DEBUG builds launched with `-SaryShowcase` show the showcase instead of the app.
The hook is ONE line in `Sources/App/SaryAlbarqApp.swift`
(`.saryShowcaseIfRequested()`, marked `DESIGN-SHOWCASE HOOK`); it compiles to
nothing in Release.

Arguments: `-SaryShowcaseSection <tokens|buttons|controls|status|alerts|sos|ptt|sheet|participants|rally|overlays|states|inputs|dialogs|appearance|stage>`,
`-SaryShowcaseScheme light|dark`, `-SaryShowcaseNight 1`, `-SaryShowcaseDrive 1`,
`-SaryShowcaseFallback 1` (renders the iOS 17–25 path on iOS 26+),
`-SaryShowcaseType AX5` (any Dynamic Type size), `-SaryShowcaseScroll <n>`,
`-SaryShowcaseSheet peek|half|full`, `-SaryShowcaseBare 1`.

Screenshots: build, then `scripts/design-shots.sh <udid> <name> [args…]`.
Current shots are in `docs/design-shots/`.

## Decisions

- Car colours: 12, identical to the web (`carColors.ts`) and `Core/CarColors`;
  the owner's 10 are the first 10. Tested.
- Live numbers use SF (tabular Arabic-Indic digits); Tajawal's digits are
  proportional and would jitter. Tested.
- Stale / paused never look live: grey ring (dashed when stale), desaturated
  car, age label «قبل ٤ د», pause glyph.
- Drive mode: ≥ 64 pt targets, opaque surfaces, 2 map controls, 1 alert, no
  note bubbles, stronger secondary text.
- Map chrome (status capsule, alert lane, sheet summary) caps Dynamic Type at
  AX1 so it can never bury the map; sheets and screens scale fully.

## The live screen (wired)

`Views/LiveOutingScreen.swift` + `Views/LiveSheet.swift` compose these
components over the real Mapbox map (`Map/OutingMapboxView.swift`). Views hold
no logic: `Live/LiveOutingController.swift` owns screen state and turns the
contract's actions into session/API calls, and `Live/LiveOutingPresenter.swift`
maps `OutingView` + GPS into `LiveOutingUIState` (unit-tested).

- Name chips and note bubbles are design-system views in our own overlay over
  the map (`ChipOverlayView`), re-laid out on every camera frame and glide step
  by `Map/ChipLayout.swift` (pure, unit-tested in `Tests/ChipLayoutTests.swift`):
  chips that collide are stacked in a column above their cars with leader
  lines; more than 3 (2 in drive mode) fold the friends into a group chip
  «٣ سيارات» that, on tap, lists them in a column (and zooms in when that
  separates them); «أنت» is never folded, sits nearest its car and is drawn on
  top; a note bubble shows only where it has room (zoom ≥ 13.5), otherwise it
  collapses to a small note indicator on the chip.
- Mapbox's logo and attribution («i») stay together and visible (Mapbox's
  terms) but move to the first free spot (bottom centre, bottom corners, top
  corners) that does not cover the rally label or a chip (`OrnamentSpot`).
- Edge arrows are SwiftUI (`SaryMapOverlayLayer`), placed from the map's
  projection (`EdgeArrows.place`), kept clear of the cluster, SOS dock, status
  capsule, alert lane, rally flag, «أنت» and visible friends.
- Chrome frames are measured (window coordinates) and passed to the map as
  insets, so keep-group framing stays clear of the capsule, alert lane,
  controls and the sheet's real top edge.
- Place labels are Arabic: the Standard Satellite style is fetched once and
  its labels pointed at `name_ar` (`ArabicBasemap`).
- Real screenshots: `docs/live-shots/`. DEBUG launch overrides:
  `-SaryScheme light|dark`, `-SaryDrive 1|0`, `-SaryNight 1|0`, `-SaryFallback 1`;
  `-demo -demoCrowd` adds three friends parked together (the declutter case).

## The other screens (wired)

`Sources/Screens/` — every page outside the live map, built only from the
components above (`SaryPage` header + scroll, `SarySection`, `SaryNavRow`,
`SaryTextField`, `SaryStateView`, `SaryDialog` via `.saryDialog`):

| Screen | File | Notes |
| --- | --- | --- |
| Splash | `OnboardingFlow.swift` (`SplashView`) | same colour as the launch screen, app mark drawn in code (`SaryMark`) |
| Onboarding | `OnboardingFlow.swift` | idea → name ≤ 40 + optional photo + optional Saudi mobile → location explainer, THEN the system prompt |
| Restore / recovery code | `RecoveryScreens.swift` | no passwords: `POST /me/recovery` (shown once, QR) and `POST /me/recover` (typed or scanned) |
| «طلعاتي» | `HomeView.swift` | active / paused / not started / ended, empty, loading skeleton, offline strip, error + retry |
| New outing, join by link, invite preview | `OutingSheets.swift` | invite: valid / expired / invalid / retryable error |
| Outing details, trip summary, history | `OutingDetailsView.swift` | summary: shared totals from `GET /:id`, my totals from this device (`TripLog`), «شارك ملخصي» = `PUT /:id/summary` |
| «قصة الطلعة» (trip story) | `Story/` | from the ended outing's summary: 9:16 / square image and a ~7 s video (trail draws itself), Mapbox satellite snapshot, picked photos from the outing window; by default the first/last 500 m are cut (privacy zones) and companions are a count; built on the device, shared only via the share sheet / «احفظ في الصور». Renders: `docs/app-shots/story-*.jpg` (`SARY_STORY_SHOTS=1` unit + UI tests) |
| Profile, settings, appearance, privacy, notifications, about | `SettingsScreens.swift` | privacy: share precision, battery, what is sent and when, «احذف حسابي» → `DeleteAccountView` (typed confirmation, DELETE /api/outings/me) |
| Trip plan, checklist, destination, coordinates | `Plan/*` | details: plan preview + «قائمة التجهيز» (any member adds / assigns / ticks, «٧ من ١٠», live via `checklist_updated`, polled every 15 s off the map); editor: tap to add, drag, undo, GPX/KML import (streamed, capped, simplified ≤ 5000), GPX export; dashed plan line on the live map, «اتبع الخطة» (off-route like «طريق العودة»), «الوجهة» with «اتجه»; long-press anywhere = the one coordinate card (copy decimal / DMS in Western digits, share Google / Apple link, «اجعلها الوجهة», «أضف نقطة», «نقطة تجمع», «الطقس هنا» hook); «انسخ موقعي» in the control cluster; «ابحث أو أدخل إحداثية». 404/405 → «غير متاح بعد». |

Push: `App/PushRegistrar.swift` (unit-tested with a fake server) registers the
APNs token at `POST /api/outings/push/apns` (sandbox in Debug, production in
Release), replaces it when Apple rotates it, removes it on «إيقاف» and sign-out,
and treats `503 apns_disabled` as «داخل التطبيق فقط حاليًا», not an error. The
system prompt only follows our explainer (after a first join, or from settings).
A tapped notification opens its outing (`outing_id` / `url`).

Screenshots: `scripts/app-shots.sh <udid> <name> -demo -SaryScreen <screen> -SaryScheme light|dark`
(`-SaryOffline` forces the offline state). Screens: `splash onboarding onboarding-profile
onboarding-location story recovery-restore recovery-code recovery-code-shown home details summary
history profile settings appearance privacy notifications offline-maps about create join
invite-valid invite-expired invite-invalid invite-error notify-explainer dialog-leave privacy-account delete-account delete-account-typed account-deleted account-wiped plan-details plan-editor plan-search plan-point plan-me-stale`
(`-demoPlanEmpty`, `-demoPlanUnavailable`; `-SaryPlanFollow` turns «اتبع الخطة» on in the live demo).
Shots: `docs/app-shots/`.

## Safety pack (wired)

`Sources/Safety/` — «مؤقت الرجوع», «غرّزت» and the sunset / way-back warning.
`SafetyController` owns the state (server via `SafetyBackend`, nil in the demo),
`ReturnTimer.swift` / `Stuck.swift` / `SunsetWayBack.swift` are pure and unit-tested
(`Tests/SafetyTests.swift`, plus an opt-in end-to-end test with
`TEST_RUNNER_SARY_E2E_BASE=http://127.0.0.1:<port>` against a local API).
Cards go into the shared alert lane as `.safety(SafetyAlertUI)`; the «السلامة»
section sits in the participants tab; «غرّزت» is in the cluster's «المزيد» menu (and one tap in that section).
A 404/405 without an error code means the server has no such route yet: the UI
says «غير متاح بعد», never pretends. DEBUG: `-SarySafety timer|overdue|stuck-me|stuck-friend|sunset|unavailable|confirm-stuck|editor`,
`-SarySafetySheet half|full`. Shots: `docs/app-shots/safety-*.jpg`.
## Weather (wired)

`Sources/Weather/`: Open-Meteo forecast + air-quality (dust, PM10), no key. The
outing area is rounded to 0.1° before it is sent; a destination / «الطقس هنا»
point is sent as chosen; members' live positions never. Responses are cached on
disk per area; data older than an hour is never labelled «الآن». Thresholds are
in `WeatherThresholds` (tested). The live map adds an invisible Streets v8
`waterway` probe; `WadiProximity` turns it into the «احذر السيول في الأودية»
hint (an estimate; the app links to the NCM for official warnings).
DEBUG screenshot flags: `-SaryWeatherDemo rain|dust|calm`, `-SaryWeatherDemoAge <min>`,
`-SaryDemoDestination "lat,lng,name"`, `-SaryDemoShift "dLat,dLng"`,
`-SaryLiveSheet half|full`, `-SaryLiveModal weather`, `-SaryScreen weather-here`.
Shots: `docs/app-shots/weather-*.jpg`.
