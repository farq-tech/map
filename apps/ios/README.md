# iOS apps

| Folder | What it is |
|---|---|
| `SaryAlbarq/` | **سَرى البارق**: shared desert outings. Keeps sharing your location with the screen locked, but only inside an outing where you chose to share. SwiftUI + Mapbox Maps SDK v11 (the web's map), iOS 17+. Needs a Mapbox public token in a gitignored xcconfig. |
| `FarqNavigate/` + `FarqNavigate.xcodeproj` | The older Farq price/navigation prototype (Mapbox + MapLibre + Ferrostar, iOS 17). It is left as it was. |

## Why a separate project and not a target in FarqNavigate

FarqNavigate is a different product (price comparison and turn-by-turn). A separate project ships under its own bundle ID and shares nothing with it at build time.

**The map is Mapbox, like the web.** The owner wants the app to look exactly like the web outing map, so `Sources/Map/OutingMapboxView.swift` uses the Mapbox Maps SDK v11 (pinned exactly in `project.yml`; SPM downloads it without any secret token) with the same `standard-satellite` style and Standard config as the web, the same generated 3D 4×4 per member (`SuvModel.swift`, a port of `suvModel.ts`), the same scale-by-zoom, road snapping and keep-the-group camera. `OutingMapboxView` takes plain data (members, rally point, camera requests, chrome insets) and reports taps, so any screen can embed it.

**Mapbox token.** Copy `SaryAlbarq/Config/Secrets.example.xcconfig` to `SaryAlbarq/Config/Secrets.xcconfig` (gitignored) and put the Mapbox *public* token there. `Config/Base.xcconfig` includes it optionally and `Info.plist` passes it to Mapbox as `MBXAccessToken`. Without it the app still builds, but the map shows no tiles. Never commit the token.

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
  Sources/Map/                Mapbox map: OutingMapboxView, SuvModel (generated glTF), Vehicle (scale,
                              rotation, motion, sun light, group framing), RoadSnap (ports of the web's sary/ code)
  Sources/Views/              SwiftUI screens
  Config/                     Base.xcconfig + Secrets.example.xcconfig (Secrets.xcconfig is gitignored)
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

Simulated location: `xcrun simctl location booted set 24.7136,46.6753`, or `xcrun simctl location booted start --speed=5 <lat,lng> <lat,lng> …` to drive a route. Locking the simulator (⌘L) must stop the fixes: sharing is foreground only.

## How it behaves (owner's rules)

- **Honest positions.** Freshness uses the same thresholds as the web, measured on the server's clock (we keep the offset from `server_now`): «مباشر» means a fix from the last 15 s while moving or 45 s while parked; «آخر موقع» means old but reachable; «انقطع» means nothing heard for 60 s. Old cars are faded (opacity 0.7 / 0.4, as on the web), their name chip says «آخر موقع» or «انقطع», and they never glide: only a live, confident fix is animated, and only up to the real fix. A fix worse than 60 m is drawn as a spot marked «تقريبي», never as a car.
- **Latest fix only.** While offline only the newest fix is kept, and it is dropped once it is older than 55 s (the server refuses anything over 60 s). The server stores only the latest fix anyway.
- **Joining is the consent; sharing is forced on while a member (build 14).** The invite screen says who invited you and, under «انضم للطلعة», that members see your live location until the trip ends or you leave. That one tap makes the identity silently (the inviter's name for a personal invite), asks iOS for «أثناء الاستخدام» (precise) and — granted — joins and enters the live trip already sharing. Refused or imprecise: not joined, one calm «افتح الإعدادات» screen that joins by itself when iOS says yes (`JoinMachine`). There is no «شارك موقعي» / «أوقف» switch in a trip; «غادر الطلعة» (confirmed) stops it. Consent is recorded per identity and per outing (`ShareMemory`), so a later sign-in never inherits it; the server's own `sharing` flag is still never treated as consent.
- **Visible indicator.** The status capsule's GPS dot and «موقعك مُشارَك الآن مع أعضاء الطلعة» in the sheet show sharing; a «خلّ الشاشة شغالة» note says that locking the screen stops it.
- **Stops automatically** when you stop, leave, are removed, the owner pauses or ends the outing, the socket closes with 4401/4403/4404/4410, you sign out, or location permission is revoked. Going back to the outing list while sharing asks first, because it stops sharing.
- **Foreground only (owner rule).** `allowsBackgroundLocationUpdates` is never turned on, there is no significant-change monitoring, no «دائمًا» request and no `location` background mode. When the app leaves the screen the session stops the GPS and drops any fix held for the network; friends then see your last position with its age («آخر موقع»).
- **One send gate.** `SendGate` (Core) is the only rule for putting a position on the wire: this identity's consent + iOS permission + the share press + server sharing on + outing active + app in the foreground + session open. `LiveChannel` asks it at the last step (also for a fix held across a reconnect). An SOS carries a position only when the same gate is open. Locked by `PrivacyTests` and `LiveChannelTests`.
- **Permissions.** When-In-Use is requested when you open an outing map (for your own dot and distances). The microphone is asked the first time you hold «اضغط وتكلم». Nothing else.
- **`pausesLocationUpdatesAutomatically = false`.** iOS's auto-pause triggers when the phone looks stationary. A parked convoy (tea stop, stuck in sand) is exactly when the others need to see you, and auto-paused updates only resume when the app comes back to the foreground. Battery is managed by the share mode instead: accuracy drops when parked, saver mode kicks in automatically on Low Power Mode or under 20 % charge, and the send policy limits network use. `activityType = .otherNavigation`, because off-road driving should not be road-snapped.
- **Send policy.** Same as the web: fast, normal and slow tiers (2.5 s or 50 m, 4 s or 35 m, 6 s or 15 m), scaled by mode (precise ×0.6, saver ×2), a 1 s floor, and a parked heartbeat every 30 s (60 s in saver). There is also a coordinate-free link heartbeat every 15 s.
- **Live link.** `URLSessionWebSocketTask` authenticates in the first frame (never in the URL). It reconnects with equal-jitter backoff (1 s base, 30 s cap), falls back to HTTP polling after 3 failed attempts while still retrying the socket, and replaces a half-open socket after 45 s of silence.
- **No secrets in the app.** The identity token is issued by the server per device and kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`). Invite tokens are sent in request bodies, never in URLs. The Mapbox public token comes from the gitignored `SaryAlbarq/Config/Secrets.xcconfig`.

## What the owner must provide

1. **Apple Developer Team ID:** done. `MH7J92HV9N` (the same account as FarqNavigate) is set in `project.yml` and in the AASA file.
2. **Bundle ID.** It is `sa.sary.albarq` (nothing else in the repo uses it). Register it in the developer portal (Identifiers → App IDs) with the **Associated Domains** capability enabled. If you change it, change it in `project.yml` and in the AASA file.
3. **Universal Links.** `apps/web/public/.well-known/apple-app-site-association` already names `MH7J92HV9N.sa.sary.albarq`. Deploy the web app, then check that `https://farq-map-investor.vercel.app/.well-known/apple-app-site-association` returns JSON (`vercel.json` sets the content type). Apple's CDN caches it, so allow up to a day. Until then, the `saryalbarq://join#<token>` scheme and «انضم برابط» (paste a link) both work.
4. **App icon.** `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` is a generated placeholder. Replace it with the real 1024×1024 artwork.
5. **Privacy policy URL** for App Store Connect, covering location, name, optional phone and notes, all shown only to fellow outing members, with only the latest fix kept and deleted when the outing ends.

## Run on a device

1. Open `SaryAlbarq.xcodeproj` and select the SaryAlbarq target. Under Signing & Capabilities, pick your team. Automatic signing creates the profile.
2. Connect the iPhone, turn on Developer Mode (Settings → Privacy & Security), choose it as the run destination, and press ⌘R.
3. For a real test, join an outing from a second phone or the web, start sharing and drive with the app open. Lock the phone: the other side should switch you to «آخر موقع» with its age, never keep you «مباشر».

## TestFlight

1. In App Store Connect, create the app (My Apps → +, bundle ID `sa.sary.albarq`, primary language Arabic).
2. In Xcode, set the scheme destination to **Any iOS Device**, then Product → Archive. In the Organizer, choose Distribute App → App Store Connect → Upload.
3. In App Store Connect → TestFlight, fill in the test information, add internal testers (no review needed), or create an external group (needs a short beta review). Paste the review notes below.
4. Bump `CURRENT_PROJECT_VERSION` in `project.yml` for every upload.

## App Review notes (what to tell Apple)

> Sary Albarq lets a group of friends driving together in the desert see each other's cars on one map during an "outing" they created and joined by invite link. Location is used only while the app is open (When In Use); there is no background location. A position is shared only after the user taps "Share my location" inside an active outing and accepts an in-app Arabic explanation. Positions go only to members of that outing; the server keeps only the latest one and deletes it when the outing ends. Push-to-talk clips are recorded only while the button is held and are deleted from the server after 10 minutes. No ads, no tracking. The map is drawn with the Mapbox Maps SDK.

App Store Connect privacy labels: Precise Location, Name, Phone Number (optional) and Other User Content (notes). All are linked to the user, used for App Functionality, and not used for tracking. These match `PrivacyInfo.xcprivacy`.
