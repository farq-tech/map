# Release readiness (iOS 1.0.0, build 1)

## Build

- `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1` (`project.yml`).
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
| `NSLocationWhenInUseUsageDescription` | the outing map and sharing, only after «شارك موقعي», app in front |
| `NSMicrophoneUsageDescription` | «اضغط وتكلم», only while held |
| `NSCameraUsageDescription` | scanning a QR (invite / recovery code) |

No `NSLocationAlwaysAndWhenInUseUsageDescription`, no `UIBackgroundModes`
(no background location). Photos: the profile photo uses `PhotosPicker`, which
runs out of process and needs no photo-library permission string.
The app explains location in onboarding before iOS asks, and notifications
after a first join (or from settings) before iOS asks — never at launch.

## Privacy manifest (`Resources/PrivacyInfo.xcprivacy`)

No tracking, no tracking domains. Collected, linked to the identity, for app
functionality only: precise location, name, phone (optional), photo
(optional), other user content (notes), audio (push-to-talk), other data
(opt-in battery level, opt-in trip totals). Required-reason APIs:
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

The API has no "delete my account" endpoint. «امسح بياناتي» removes what the API
allows (phone, photo, shared summaries, leaves every current outing, which
deletes the latest position, then forgets the identity on the device). App
Store guideline 5.1.1(v) asks for in-app account deletion when an app creates
accounts: **the owner** needs a server endpoint that deletes the user row (name,
memberships) before submission.
