# Release readiness (iOS 1.0.0, build 2)

## Build

- `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 2` (`project.yml`).
- Release compiles for a generic iOS device without signing:

  ```sh
  xcodebuild -project SaryAlbarq.xcodeproj -scheme SaryAlbarq -configuration Release \
    -destination 'generic/platform=iOS' -archivePath /tmp/SaryAlbarq.xcarchive \
    CODE_SIGNING_ALLOWED=NO archive
  ```

- The Mapbox token comes from the gitignored `Config/Secrets.xcconfig`
  (`MBXAccessToken` in Info.plist). It is never committed.

## Permissions (Info.plist, Arabic base + `en.lproj`)

| Key | Why |
| --- | --- |
| `NSLocationWhenInUseUsageDescription` | the outing map and sharing, only after «شارك موقعي» |
| `NSMicrophoneUsageDescription` | «اضغط وتكلم», only while held |
| `NSCameraUsageDescription` | scanning a QR (invite / recovery code); a photo for a shared waypoint, only when the person takes one |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | keep sharing my live position with my outing's members with the screen locked, after «شارك موقعي»; and the on-device «مساري» trail |
| `UIBackgroundModes: location` | the same two, and nothing else |

### Background location: live sharing with the outing (owner decision, 2026-11)

The owner reversed the earlier "foreground-only" rule: once a member chose to
share in an outing, sharing must keep going with the screen locked, in another
app, on CarPlay and on a poor signal, until they stop it, leave, are removed, or
the outing ends.

- **User-initiated and explicit.** Nothing is sent before the member presses
  «شارك موقعي» inside an active outing and accepts our consent sheet, which says
  in Arabic that sharing continues in the background / with the screen locked
  until they stop, leave or the outing ends — and only then asks iOS for
  «دائمًا». With «أثناء الاستخدام» only, sharing works while the app is on
  screen and a persistent one-line hint under «موقعك مُشارَك» deep-links to
  Settings to choose «دائمًا».
- **Visible.** `showsBackgroundLocationIndicator` (the blue pill) is on whenever
  sharing runs off screen; the share row stays on the live screen; the privacy
  screen and the consent sheet say exactly this.
- **Stoppable at once.** «أوقف», leave, removed (404 / socket 4403), outing
  paused or ended, sharing switched off on the server (409 `sharing_off`), sign
  out / account deletion, or iOS permission downgraded → background updates,
  significant-change and region monitoring stop immediately and the existing
  stop signal (`PATCH /:id/me {sharing:false}`, which deletes the server's last
  fix) is sent, wrapped in a UIKit background task.
- **Gate.** `SendGate.allowsPosition` = consent ∧ iOS permission ∧ «شارك موقعي»
  ∧ server sharing ∧ outing active ∧ not closed ∧ (on screen ∨ «دائمًا»).
  `allowsBackgroundPosition` is the off-screen half. Both are asked again at the
  last step (`LiveChannel` on screen, `BackgroundPositionSender` off screen).
- **Transport off screen.** iOS suspends WebSockets, so off screen each fix is
  one `POST /api/outings/:id/positions` (URLSession + background task). Only the
  latest fix is kept (coalescing); a fix older than 55 s is dropped, never sent
  late as if live (`age_ms` is real). Cadence (`BackgroundCadence`): every 15 s
  when driving, 20 s slow, 60 s parked, or after 50 m (≥5 s apart); doubled in
  Low Power Mode (the hint says so). Retry: 2 s → 60 s exponential backoff with
  jitter, ≥30 s after a 429. Worst case 12 POSTs a minute, under the server's
  120 writes/min/person (`routes/outings.js`), 1 s min interval and 60 s max
  fix age (`lib/outings/service.js`, `validate.js`).
- **Kept alive.** `allowsBackgroundLocationUpdates`,
  `pausesLocationUpdatesAutomatically = false`, activity type
  `.otherNavigation` (navigation-class like `.automotiveNavigation`, without
  road-snapping a car that is off-road), `CLBackgroundActivitySession` (iOS 17+),
  `CLServiceSession(authorization: .always)` (iOS 18+), significant-location-change
  monitoring and a 200 m exit region re-armed as the car moves. If iOS
  terminates the app, those two relaunch it in the background
  (`launchOptions[.location]`); `AppBoot` builds the model without UI and the
  share for that identity/outing resumes from disk (`ShareMemory`), fetching the
  outing over HTTP before anything is sent. Accuracy: best when moving, 100 m
  when parked.
- **What iOS still won't do.** If the person force-quits the app from the app
  switcher, Apple documents that the system does not relaunch it for standard
  location updates; we do not rely on significant-change / region relaunch after
  a force-quit either. The app says gently «لا تقفل التطبيق من قائمة التطبيقات
  أثناء الطلعة». A phone that is switched off sends nothing; others then see
  «آخر موقع» with its real age.

**Verified (simulator, iOS 27.2, 2026-11-04)** against a local copy of the API
and a throwaway Postgres: `BackgroundShareE2ETests` (skipped unless
`TEST_RUNNER_SARY_API_BASE` + `TEST_RUNNER_SARY_JOIN_LINK` are set; DEBUG
`-SaryAPIBase` points the app at the local server) joined an outing, shared
with «دائمًا» pre-granted, and the app was sent to the home screen for 100 s
while `xcrun simctl location … start` drove a route at 15 m/s: the server
received a new position every 5–7 s over `POST /positions` the whole time.
Back on screen, «أوقف» removed the position at once, and 40 s more in the
background after stopping delivered nothing. DEBUG builds log the share path
(`category == "share"`). Not verifiable on a simulator: relaunch after iOS
terminates the app (significant change / region exit) — covered by unit tests
of the resume path (`BackgroundSessionTests`), to be checked on a device.

**App Review notes (paste into "Notes" in App Store Connect):**

> Sary Albarq (سَرى البارق) is for groups driving together on off-road outings.
> Background location is used to share the user's live position with the
> members of the outing they are in — and nobody else — after the user taps
> "Share my location" (شارك موقعي) inside an active outing and accepts an
> in-app consent screen that explains it continues with the screen locked. It
> stops when the user taps Stop, leaves the outing, is removed, or the outing
> ends. iOS shows the blue location indicator the whole time. With "While Using"
> only, sharing stops when the app leaves the screen. Background location also
> records the user's own trail on the device only (never uploaded) for a
> "way back" guide. The server keeps only the latest position and deletes it when
> sharing stops or the outing ends. To test: create an outing, start it, tap
> Share my location, accept, choose "Allow While Using" then "Change to Always
> Allow", lock the phone; a second device in the same outing keeps seeing the
> position move.

### «مساري» (on-device trail)

The breadcrumb trail kept on this phone: switch «سجّل مساري والشاشة مقفلة» is
on by default; with «دائمًا» it records off screen while an outing they belong
to is active or paused, uses a 15 m distance filter and coarse accuracy when
parked, and stops at once on leave / end / removal / sign-out / account deletion
/ switch off. Trail points go into the trail file and nowhere else
(`TrailSessionTests` proves no socket frame or HTTP request carries a trail
point). With «أثناء الاستخدام» only, locked stretches are drawn as honest dashed gaps.

Photos: the profile photo uses `PhotosPicker`, which
runs out of process and needs no photo-library permission string.
The app explains location in onboarding before iOS asks, and notifications
after a first join (or from settings) before iOS asks — never at launch.

## Privacy manifest (`Resources/PrivacyInfo.xcprivacy`)

No tracking, no tracking domains. Collected, linked to the identity, for app
functionality only: precise location, name, phone (optional), photo
(optional), other user content (notes), audio (push-to-talk), other data
(opt-in battery level, opt-in trip totals). Location is collected on screen and,
with «دائمًا» after «شارك موقعي», off screen too — same data, same purpose. «مساري» (the trail) is **not**
collected: it never leaves the device, so it is not declared. Required-reason APIs:
UserDefaults `CA92.1`, system boot time `35F9.1` (`CACurrentMediaTime` for
animation timing). Mapbox ships its own manifest inside its framework.

## Entitlements

`aps-environment` (development; Xcode signs production for App Store),
`com.apple.developer.usernotifications.time-sensitive` (SOS),
associated domains for invite links. **The owner** must enable Push
Notifications, Time Sensitive Notifications and Associated Domains on the App ID
`sa.sary.albarq` and sign in Xcode.

## Mapbox telemetry

Left at the SDK default (on). «الخصوصية» ← «ساهم في تحسين خرائط Mapbox» writes
`MGLMapboxMetricsEnabled`, the key the SDK itself registers and observes (the
same switch as the «i» attribution menu's telemetry opt-out), so turning it off
stops Mapbox's events collection immediately. The logo and attribution are
always visible on every map (moved to a free spot, never hidden).

## Offline maps (Mapbox OfflineManager + TileStore)

- A style pack for `mapbox://styles/mapbox/standard-satellite` (style, sprites,
  glyphs) and one tile region per area: zooms 11–16 of the style's tilesets plus
  `mapbox.mapbox-terrain-dem-v1` (terrain) and `mapbox.mapbox-streets-v8` (the
  roads cars are matched to). Zoom 11 is the floor because Mapbox loads tiles in
  batches that cover the parent tile (a 6–10 batch is a ~600 km square).
- Size: Mapbox's own estimate before downloading, live progress and bytes while
  downloading. Cap: 1 GB for all areas and 60 × 60 km per area, explained on
  the screen; the picker refuses an area over either.
- The live map uses the default TileStore, so saved tiles are used whenever the
  network is missing. The Arabic version of the style is kept on disk so an
  offline launch draws the same style.

What was proven on the simulator (iPhone 17 Pro Max, iOS 27.2,
`UITests/OfflineMapsUITests`): a 2 × 2 km area over the demo outing was estimated
(≈ 90 MB) and downloaded to completion (listed «جاهزة بلا إنترنت»); then the app
was relaunched with Mapbox's network cut (`OfflineSwitch` → disconnected,
`-SaryMapboxOffline`) and the ambient cache cleared (`-SaryClearAmbient`), and the
live map still drew the satellite imagery from the saved region
(`docs/app-shots/offline-live-map.jpg`). Network Link Conditioner / turning the
Mac's network off was not available, so the device's own network was not cut —
only Mapbox's stack was.

## Account deletion

Settings → الخصوصية → «احذف حسابي» (App Store guideline 5.1.1(v)) opens a page
that says exactly what is deleted from the server, what is wiped from this
device and what stays, asks the person to type «احذف», then calls
`DELETE /api/outings/me` (farq-tech/map PR #27). That endpoint leaves every
outing with the normal leave rules (ownership passes on) and hard-deletes the
identity. On success the app forgets its APNs token and calls
`unregisterForRemoteNotifications`, deletes the Keychain identity, sharing
consent, trip logs, saved invite links, the share-precision/battery choices and
the onboarding flag, and goes back to onboarding with a notice. Downloaded
offline map areas stay (map tiles only, not about anyone), and the notice says
so. Until the API is deployed, a `404`/`405` falls back to the older partial
wipe (phone, photo, shared summaries, leave every current outing, forget the
identity here), and the notice says plainly that the account itself was not
deleted yet. Any other error deletes nothing and says so on the page.
**The owner** must deploy PR #27 before submission.
