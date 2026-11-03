# iOS apps

| Folder | What it is |
|---|---|
| `SaryAlbarq/` | **سَرى البارق**: shared desert outings. Keeps sharing your location with the screen locked, but only inside an outing where you chose to share. SwiftUI + MapKit, iOS 16+, no third-party SDKs, no keys. |
| `FarqNavigate/` + `FarqNavigate.xcodeproj` | The older Farq price/navigation prototype (Mapbox + MapLibre + Ferrostar, iOS 17). It is left as it was. |

## Why a separate project and not a target in FarqNavigate

FarqNavigate is a different product (price comparison and turn-by-turn). It downloads the Mapbox SDK through SPM, which needs a Mapbox secret token in `~/.netrc`, and it needs a public token in `Secrets.xcconfig`. The outings app needs none of that. A separate project means it builds on a fresh Mac with nothing but Xcode, has no secrets in the app, and ships under its own bundle ID. The two projects share nothing at build time.

**Why MapKit and not Mapbox:** no SDK key to ship or rotate, no SPM download that needs credentials, Apple's hybrid imagery works over sand, and the background-location App Review story is simpler without a third-party SDK. The web app's Farq map style is not available in MapKit. If the native map ever has to match the web style exactly, switch `OutingMapView` to MapLibre. It is one file.

## Layout

```
SaryAlbarq/
  project.yml                 XcodeGen spec (the generated .xcodeproj is committed too)
  Sources/Core/               pure logic, no UIKit — everything the tests cover
    Policy.swift              send tiers, FixFilter, freshness, bearing (port of web policy.ts)
    ServerRules.swift         fix / phone / text rules (mirror of api/lib/outings/validate.js)
    CarColors.swift           palette + join-order rule (port of web carColors.ts)
    Backoff.swift             reconnect backoff, close codes, latest-fix-only slot
    OutingState.swift         snapshot + live-event reducer (port of web outingState.ts)
    InviteLink.swift          Universal Link / saryalbarq:// / pasted-link parsing
  Sources/Net/                REST client, Keychain identity, WebSocket LiveChannel
  Sources/Location/           LocationSharer (the only CLLocationManager) + LocationTuning
  Sources/App/                App entry, AppModel, OutingSession, Info.plist, entitlements
  Sources/Views/              SwiftUI screens, MKMapView wrapper with car annotations
  Resources/                  Assets (placeholder icon), PrivacyInfo.xcprivacy, InfoPlist.strings (ar, en)
  Tests/                      XCTest unit tests
  UITests/                    XCUITest: onboarding + live map (demo outing)
```

## Build and test

Requires Xcode 16 or newer (built here with Xcode 27.2) and an **iOS Simulator runtime** (Xcode → Settings → Components, or `xcodebuild -downloadPlatform iOS`).

```sh
cd apps/ios/SaryAlbarq
# optional: regenerate after editing project.yml
xcodegen generate

# compile everything, including tests (no simulator runtime needed)
xcodebuild -project SaryAlbarq.xcodeproj -scheme SaryAlbarq \
  -destination 'generic/platform=iOS Simulator' build-for-testing

# unit + UI tests on a simulator
xcodebuild -project SaryAlbarq.xcodeproj -scheme SaryAlbarq \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Launch arguments: `-demo` opens a fixed, clearly labelled demo outing near Riyadh. It never talks to the server, and it is what the UI test and screenshots use. `-resetState` wipes identity, consent and the active share.

Simulated location: `xcrun simctl location booted set 24.7136,46.6753`. To test background sharing, start sharing, press ⌘L to lock the simulator, and watch the fixes arrive (`xcrun simctl location booted start …` plays a route).

## How it behaves (owner's rules)

- **Honest positions.** Freshness uses the same thresholds as the web, measured on the server's clock (we keep the offset from `server_now`): «مباشر» means a fix from the last 15 s while moving or 45 s while parked; «آخر موقع» means old but reachable; «انقطع» means nothing heard for 60 s. Old cars are faded and dashed, and only live cars get a heading arrow.
- **Latest fix only.** While offline only the newest fix is kept, and it is dropped once it is older than 55 s (the server refuses anything over 60 s). The server stores only the latest fix anyway.
- **Consent before sharing.** Joining an outing shares nothing. «شارك موقعي» first shows an Arabic consent sheet that says who sees your location, that sharing continues with the screen locked, when it stops, the battery cost, and the optional "Always" permission. Consent is remembered per outing.
- **Visible indicator.** A green «تشارك موقعك الآن» banner is shown while sharing, and the iOS blue location pill is on (`showsBackgroundLocationIndicator = true`).
- **Stops automatically** when you stop, leave, are removed, the owner pauses or ends the outing, the socket closes with 4401/4403/4404/4410, you sign out, or location permission is revoked. Going back to the outing list while sharing asks first, because it stops sharing.
- **Background location scope.** `allowsBackgroundLocationUpdates` is set to true in exactly one place (`LocationSharer.startSharing`) and back to false in `stopSharing`. It is only called while the outing is `active`, the server says your sharing is on, and you consented.
- **Permissions.** When-In-Use is requested when you open an outing map (for your own dot and distances). "Always" is requested only after you accept the consent sheet. It is optional and only lets iOS relaunch the app through significant-location-change if the app was terminated mid-outing. Sharing with the screen locked works with When-In-Use, because updates start in the foreground with background updates allowed.
- **`pausesLocationUpdatesAutomatically = false`.** iOS's auto-pause triggers when the phone looks stationary. A parked convoy (tea stop, stuck in sand) is exactly when the others need to see you, and auto-paused updates only resume when the app comes back to the foreground. Battery is managed by the share mode instead: accuracy drops when parked, saver mode kicks in automatically on Low Power Mode or under 20 % charge, and the send policy limits network use. `activityType = .otherNavigation`, because off-road driving should not be road-snapped.
- **Send policy.** Same as the web: fast, normal and slow tiers (2.5 s or 50 m, 4 s or 35 m, 6 s or 15 m), scaled by mode (precise ×0.6, saver ×2), a 1 s floor, and a parked heartbeat every 30 s (60 s in saver). There is also a coordinate-free link heartbeat every 15 s.
- **Live link.** `URLSessionWebSocketTask` authenticates in the first frame (never in the URL). It reconnects with equal-jitter backoff (1 s base, 30 s cap), falls back to HTTP polling after 3 failed attempts while still retrying the socket, and replaces a half-open socket after 45 s of silence.
- **No secrets in the app.** The identity token is issued by the server per device and kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`, so a locked-screen relaunch can read it). Invite tokens are sent in request bodies, never in URLs.

## What the owner must provide

1. **Apple Developer Team ID.** Set `DEVELOPMENT_TEAM` in `project.yml` (or in Xcode → target → Signing & Capabilities). FarqNavigate uses `MH7J92HV9N`. If that is the same account, use it.
2. **Bundle ID.** The placeholder is `sa.sary.albarq`. Register it in the developer portal (Identifiers → App IDs) with the **Associated Domains** capability enabled. If you change it, change it in `project.yml` and in the AASA file.
3. **Universal Links.** Edit `apps/web/public/.well-known/apple-app-site-association` and replace `TEAMID_PLACEHOLDER` with the Team ID, so it reads `ABCDE12345.sa.sary.albarq`. Deploy the web app, then check that `https://farq-map-investor.vercel.app/.well-known/apple-app-site-association` returns JSON (`vercel.json` sets the content type). Apple's CDN caches it, so allow up to a day. Until then, the `saryalbarq://join#<token>` scheme and «انضم برابط» (paste a link) both work.
4. **App icon.** `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` is a generated placeholder. Replace it with the real 1024×1024 artwork.
5. **Privacy policy URL** for App Store Connect, covering location, name, optional phone and notes, all shown only to fellow outing members, with only the latest fix kept and deleted when the outing ends.

## Run on a device

1. Open `SaryAlbarq.xcodeproj` and select the SaryAlbarq target. Under Signing & Capabilities, pick your team. Automatic signing creates the profile.
2. Connect the iPhone, turn on Developer Mode (Settings → Privacy & Security), choose it as the run destination, and press ⌘R.
3. For a real background test, join an outing from a second phone or the web, start sharing, lock the phone, and drive. The other side should keep showing «مباشر».

## TestFlight

1. In App Store Connect, create the app (My Apps → +, bundle ID `sa.sary.albarq`, primary language Arabic).
2. In Xcode, set the scheme destination to **Any iOS Device**, then Product → Archive. In the Organizer, choose Distribute App → App Store Connect → Upload.
3. In App Store Connect → TestFlight, fill in the test information, add internal testers (no review needed), or create an external group (needs a short beta review). Paste the review notes below.
4. Bump `CURRENT_PROJECT_VERSION` in `project.yml` for every upload.

## App Review notes for background location (what to tell Apple)

Paste something like this in *App Review Information → Notes*, together with a demo outing invite link and a short screen recording of the consent sheet and the locked-screen sharing:

> Sary Albarq lets a group of friends driving together in the desert see each other's cars on one map during an "outing" they created and joined by invite link.
>
> **Why background location:** On desert trips drivers keep the phone locked on the dashboard. If sharing stopped when the screen locked, the group would lose a car exactly when it is out of sight behind dunes. This is the app's core feature.
>
> **Scope:** Location is shared only after the user taps "Share my location" inside an active outing and accepts an in-app Arabic explanation (who sees it, that it continues while locked, how it stops). Background updates are enabled only during that sharing and are switched off automatically when the user stops, leaves the outing, or the organiser pauses or ends it. The blue location indicator is always shown while sharing, and the app shows its own "you are sharing" banner.
>
> **Data:** Positions go only to members of that outing. The server keeps only the latest position per member (no history) and deletes it when the outing ends. No ads, no tracking, no third-party SDKs.
>
> **"Always" permission** is optional and requested only after the user has started sharing. It lets iOS relaunch the app to continue an ongoing share if it was terminated. Without it, the app works with "While Using".
>
> **To test:** open the attached invite link on the device (or use «انضم برابط» and paste it), enter a name, tap «شارك موقعي», accept, then lock the phone. The other test device (or the web page at the same link) keeps showing the car as «مباشر».

App Store Connect privacy labels: Precise Location, Name, Phone Number (optional) and Other User Content (notes). All are linked to the user, used for App Functionality, and not used for tracking. These match `PrivacyInfo.xcprivacy`.
