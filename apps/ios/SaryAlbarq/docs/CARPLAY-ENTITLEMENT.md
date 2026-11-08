# CarPlay — entitlement request and how to switch it on

## Status (checked 2026-11-06)

- **Not granted.** None of the provisioning profiles on the build Mac carries
  `com.apple.developer.carplay-maps`. That includes the development profile for `sa.sary.albarq`,
  which Xcode regenerated on 2026-11-05, and the App Store profile.
- The build 16 archive has no CarPlay key (`codesign -d --entitlements`). Every uploaded build so
  far ships **without CarPlay**, so a real car shows nothing. This is expected: device builds use
  `CARPLAY_ENABLED = NO`.
- There is no record (repo, mail log or notes) that the request form was ever submitted. **The owner
  must submit it** (steps below) as Account Holder / Admin of team MH7J92HV9N.
- The Simulator build carries the entitlement, so all of CarPlay is developed and checked there.

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
5. Archive → the archive now carries `com.apple.developer.carplay-maps`. Verify BEFORE uploading:

   ```sh
   APP="$HOME/Library/Developer/Xcode/Archives/<date>/SaryAlbarq <date>.xcarchive/Products/Applications/SaryAlbarq.app"
   codesign -d --entitlements - --xml "$APP" | plutil -p - | grep carplay       # → "com.apple.developer.carplay-maps" => true
   security cms -D -i "$APP/embedded.mobileprovision" | grep -A1 carplay-maps    # the profile must allow it too
   ```

   Both must print the key. If only the first does, the profile is stale: refresh profiles (step 2).
   After export, check the IPA the same way (`unzip -q X.ipa -d x && codesign -d --entitlements - --xml x/Payload/SaryAlbarq.app`).

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

## Ready-to-paste request text (Arabic, for the owner — Apple wants the English one below)

> **التطبيق:** سَرى البارق (Sary Albarq)، المعرّف `sa.sary.albarq`، الفريق MH7J92HV9N.
> **الفئة المطلوبة:** CarPlay — تطبيقات الملاحة (`com.apple.developer.carplay-maps`).
>
> سَرى البارق تطبيق ملاحة جماعية وسلامة للطلعات البرية والكشتات في السعودية: عدة سيارات تمشي مع بعض،
> وغالبًا بعيد عن الطرق المعبّدة والتغطية، والسائق يحتاج يعرف وين ربعه وكيف يرجع بأمان.
>
> على CarPlay يعرض التطبيق خريطة كاملة تتبع اتجاه السائق، وفيها:
> - **ملاحة صوتية منعطف بمنعطف** (Mapbox Navigation SDK) إلى الوجهة أو نقطة التجمع أو أي مكان يبحث عنه السائق،
>   بمعاينة الرحلة (الأسرع / الأقصر)، وإرشاد المسارات، ووقت وصول حسب الزحمة، وإعادة حساب الطريق.
> - **خريطة المجموعة الحيّة:** كل سيارة بلونها واسمها المختصر، والموقع القديم يُكتب عمره ولا يظهر كأنه مباشر.
> - **طريق العودة** على المسار المسجّل في الجوال، مع تنبيه إذا خرج السائق عنه، وهي أهم ميزة سلامة في البر.
> - **تنبيهات السلامة:** إذا أرسل أحد الربع نداء استغاثة أو قال «غرّزت» يظهر تنبيه ملاحة فيه «اتجه له» و«اتصال».
>   ونداء الاستغاثة من السائق نفسه يحتاج خطوتين مقصودتين.
>
> الواجهة تستخدم قوالب CarPlay فقط: الخريطة وأزرارها وجلسة الملاحة وتنبيهاتها، والبحث، وقوائم قصيرة، وتأكيدات.
> لا فيديو ولا نصوص طويلة أثناء القيادة. مشاركة الموقع باختيار المستخدم فقط.

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
>   destination, the meeting point, a group member, or any place the driver searches for
>   (CPSearchTemplate). It includes a trip preview with alternative routes (fastest / shortest),
>   lane guidance, a traffic-aware ETA, and rerouting. All of it is shown with CPManeuver,
>   CPLaneGuidance and CPTravelEstimates.
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
> navigation session, trip previews, navigation alerts), the Search template, and short list and
> alert templates (destinations, group members, confirmations). There is no typing, no video and no dense text while driving.
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

## CarPlay v2 (feat/carplay-v2): what the car shows

| Area | CarPlay | Where |
|---|---|---|
| Map | the group's cars; a stale car's label shows its age, plus the reason when presence knows it (`carPlayPresenceReason`, PR #114); trail; rally; destination; route line | `CarPlayMapViewController` |
| Map buttons | «موقعي» (re-centre) · «الربع» (fit the group) · zoom in · zoom out; panning from «وين؟ → حرّك الخريطة» | `CarPlayCoordinator.mapButtons` |
| Nav bar | «طريق العودة» / «إنهاء» / «إلغاء» · «اضغط وسجّل» / «أرسل» · «وين؟» · «نداء» | `updateButtons` |
| Destinations | «وين نروح؟»: search; «العيال»; the outing (destination, rally point, «طريق العودة»); «روح لـفلان» (live members only); «الأخيرة» | `CarPlayDestinations` |
| Search | `CPSearchTemplate` over `PlaceSearch` (Mapbox v6, Saudi Arabia first). Swap in the merged Apple + Mapbox search when PR #111 lands: only `CarPlayCoordinator.search` calls it | `search(_:)` |
| Preview | `showTripPreviews`; route choices «الأسرع» / «الأقصر» / «طريق ثاني» with the router's time and distance; «يلّا» starts the phone's guidance on that route. If no road route arrives within 15 s, it falls back to the straight-line or trail trip | `updatePreview` |
| Guidance | `CPManeuver` (Arabic variants, symbol, dashboard variant, `maneuverType`, right-hand `trafficSide`); `CPLaneGuidance` on iOS 18+; traffic-aware trip and step estimates; `pauseTrip(.rerouting)` while rerouting | `CarPlayManeuverMapper` |
| Voice | «صوت سرى» comes from the phone's `NavVoice` (`.playback` / `.voicePrompt` / `.duckOthers`): iOS sends it to the car speakers and ducks the radio. CarPlay never speaks a second time. While the walkie-talkie owns `.playAndRecord`, guidance waits for it, so the walkie session is not broken | `Navigation/NavVoice.swift` (unchanged) |
| Safety | a friend's SOS or «غرّز» → sticky navigation alert «اتجه له» (road preview to them) + «اتصال» / «أظهره». My SOS takes two deliberate steps (alert, then «نعم، أرسل النداء» within 20 s). CarPlay has no press-and-hold, and Apple's HIG keeps destructive actions behind a confirmation | `CarPlaySOSGuard` |
| Walkie | an incoming voice note plays through the phone's audio (car speakers) and shows a 5 s banner «أبو فهد يتكلم» with «وقّف»; «اضغط وسجّل» records on the phone's mic (tap, talk, tap «أرسل»; «احذف» discards) | `CarPlayWalkieSource` |

### Walkie-talkie from the car: Apple rules

- The PushToTalk framework has no CarPlay UI. Its system transmit UI (Lock Screen / Dynamic Island)
  does not appear on CarPlay. So CarPlay cannot start a PTT *system* transmission.
- «اضغط وسجّل» records a **voice note** instead (the same `VoiceNoteCenter.talkTapped` as the
  phone). It is one tap to start and one tap to send, with no holding and no reading. Apple's
  CarPlay guidelines say navigation apps must not offer messaging features that are not about
  navigation, and messaging belongs to SiriKit messaging apps.
- **Review risk:** App Review may treat this as messaging. If they object, remove the
  «اضغط وسجّل» bar button (one line in `updateButtons`). Incoming notes keep playing over the car
  speakers either way, because that is the phone's own audio.

### DEBUG launch arguments (simulator)

`-SaryCarPlayShow dest|search|place|talk|members|trips|wayback|rally|destination|sos|pan|group`,
`-SaryCarPlayGo` (with `place`: start guidance on the first route 8 s after the preview),
`-SaryCarPlayTalk` (a friend's voice note is «playing»), and the existing `-SaryCarPlayFriendSOS`,
`-SaryCarPlayRally`, `-SaryCarPlayDestination`, `-SaryCarPlayNight 1`.
