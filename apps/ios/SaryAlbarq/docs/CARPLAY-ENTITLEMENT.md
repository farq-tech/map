# CarPlay — entitlement request and how to switch it on

سَرى البارق on CarPlay is a **Navigation** app (`com.apple.developer.carplay-maps`), the only
CarPlay category that may draw its own map. Apple grants this entitlement per developer
account, on request. Until Apple grants it:

- the **Simulator** build carries the entitlement (CarPlay works there without Apple);
- **device builds, archives and TestFlight do not** carry it, so signing never fails because the
  provisioning profile lacks it. The CarPlay code and the Info.plist scene are still in the app;
  iOS simply never connects the CarPlay scene without the entitlement.

## How the switch works

| Setting (Config/Base.xcconfig) | Value | Entitlements file used |
|---|---|---|
| `CARPLAY_ENABLED` (devices, archives) | `NO` (default) | `Sources/App/SaryAlbarq.entitlements` |
| `CARPLAY_ENABLED[sdk=iphonesimulator*]` | `YES` | `Sources/App/SaryAlbarq-CarPlay.entitlements` |

`project.yml` sets `CODE_SIGN_ENTITLEMENTS = $(SARY_ENTITLEMENTS_$(CARPLAY_ENABLED))`.
`SaryAlbarq-CarPlay.entitlements` = the base file + `com.apple.developer.carplay-maps`; keep the two
in sync (run `scripts/check-entitlements.sh`; it fails if they drift).

## After Apple approves

1. developer.apple.com → Certificates, IDs & Profiles → Identifiers → `sa.sary.albarq` →
   check that the CarPlay Navigation capability shows as granted (Apple adds it to the account;
   for some accounts it appears under "Additional Capabilities").
2. Regenerate / refresh the provisioning profiles (Xcode automatic signing does this on the
   next build; for manual profiles, re-download the App Store profile).
3. In `Config/Base.xcconfig` change `CARPLAY_ENABLED = NO` to `CARPLAY_ENABLED = YES`.
4. Build to a device, plug into a CarPlay car or a CarPlay head unit, check the app appears.
5. Archive → the archive now carries `com.apple.developer.carplay-maps`. Verify with
   `codesign -d --entitlements - <App>.app`.

If the profile does not yet include the entitlement, a signed build with `CARPLAY_ENABLED = YES`
fails with "Provisioning profile doesn't include the com.apple.developer.carplay-maps entitlement":
set it back to `NO` and wait for Apple.

## Steps to request it

1. Sign in as the Account Holder / Admin of team `MH7J92HV9N`.
2. Open https://developer.apple.com/contact/carplay/ (CarPlay entitlement request form).
3. Choose the category **Navigation (maps)** and the bundle ID `sa.sary.albarq`.
4. Paste the text below into the description field; attach 2–3 screenshots of the iPhone app
   (`docs/app-shots/live-*.jpg`, `backtrack-*.jpg`) and, if wanted, the CarPlay previews
   (`docs/app-shots/carplay-preview-*.jpg`).
5. Submit. Apple usually answers by email; the capability then appears on the App ID.

## Ready-to-paste request text (English)

> **App:** Sary Albarq (سَرى البارق), bundle ID `sa.sary.albarq`, team MH7J92HV9N.
> **Requested category:** CarPlay Navigation (`com.apple.developer.carplay-maps`).
>
> Sary Albarq is a group navigation and safety app for desert and off-road outings in Saudi
> Arabia. Several cars drive together, often far from paved roads and mobile coverage, and the
> driver needs to know where the rest of the group is and how to get back safely.
>
> On CarPlay the app shows a full-screen map (Mapbox) that follows the driver heading-up, with:
>
> - **Turn-by-turn road navigation with voice guidance** (Mapbox Navigation SDK) to the outing's
>   destination or meeting point, shown with CPManeuver / CPTravelEstimates.
> - **Live group map:** every car of the group in its colour with a short name. A position that is
>   no longer live is labelled with its age ("last seen 5 min ago") and is never shown as live.
> - **Way back ("طريق العودة"):** guidance back to the starting point along the trail the phone
>   recorded on the way in — distance remaining along the trail, an arrow to follow, and an
>   off-route alert when the driver leaves the trail. This is the main safety feature where there
>   are no roads at all.
> - **Destination / meeting point** guidance when no road route exists (direction and distance,
>   clearly labelled as approximate).
> - **Safety alerts:** when a member of the group sends an SOS or reports being stuck, a CarPlay
>   navigation alert with "Show" and "Call". Sending one's own SOS requires two deliberate steps.
>
> The CarPlay interface uses only the Map template (map buttons, navigation bar buttons,
> navigation session, navigation alerts) plus short list and alert templates (group members,
> trip choice, confirmations). There is no typing, no video and no dense text while driving.
> Location is shared with the group only by the user's explicit choice; the recorded trail stays
> on the phone.

## Risk: Apple may say it is not a "navigation" app

Apple's Navigation category is meant for apps that give **turn-by-turn guidance**. Before the
Mapbox Navigation SDK work (branch `feat/ios-navigation`) lands, our CarPlay guidance is:
the recorded trail (way back), and straight-line direction + distance to the meeting point /
destination. A reviewer could read that as "a group-tracking map", which Apple has historically
not granted the Navigation entitlement for.

What we do about it:

1. **Ship the turn-by-turn route first** (Mapbox Navigation SDK, voice guidance) and request the
   entitlement with it visible in screenshots. The CarPlay layer already has the seam:
   `CarPlayRoadNavigationSource` (Sources/CarPlay/CarPlayFeatures.swift) — while a road route is
   active, CPManeuvers / CPTravelEstimates come from that provider; the trail and straight-line
   guidance are the fallback when no road route exists.
2. If Apple asks for changes: make road navigation the default action of «إلى الوجهة / نقطة التجمع»
   on CarPlay, put voice prompts on the way-back trail too (turn cues at trail bends), and keep the
   group map as context around the route rather than the main purpose.
3. If Apple still declines Navigation: the fallback is **no CarPlay map**. The only other fitting
   categories (e.g. Driving Task, iOS 16+) allow simple list / grid / information templates, not a
   custom map: we would then offer «الأصحاب» (members with distance and age), SOS / stuck alerts and
   way-back distance + direction as text. That is a code change in `Sources/CarPlay` only.

## Privacy note (owner decision)

The CarPlay screen showing the app counts as "the app is open in front of you"
(`AppModel.carPlayVisible`): with CarPlay up, the session stays visible even with the phone
locked, so the member's share keeps sending while the driver sees the live map in the car. Every other
`SendGate` condition still applies (consent, the share switch, an active outing). If the owner
prefers the phone-only rule, remove the call in `CarPlayHub.setActive` and CarPlay will only show
(not send) while the phone is locked.

## Testing in the Simulator

The Debug simulator build has the entitlement. In Xcode's simulator window: I/O → External
Displays → CarPlay (Xcode 27: the CarPlay display is attached from Device Hub). DEBUG launch
arguments for repeatable screens:

- `-demo -demoTrail` demo outing with a recorded trail;
- `-SaryCarPlayRally`, `-SaryCarPlayDestination`, `-SaryCarPlayFriendSOS` sample data (demo only);
- `-SaryCarPlayShow members|trips|wayback|rally|destination|sos|pan|group` opens that CarPlay
  screen 4 s after CarPlay connects; `-SaryCarPlayNight 1` forces the night map;
- `-SaryCarPlayPreview map|members|wayback|sos|mysos` draws the CarPlay map and the CarPlay
  presenters' text on the PHONE (for screenshots when no CarPlay display can be attached; it is not
  the CarPlay template UI).
