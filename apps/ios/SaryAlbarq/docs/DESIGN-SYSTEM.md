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

- Name chips and note bubbles are design-system views inside Mapbox view
  annotations, so they track the cars natively; bubbles show from zoom 13.5.
- Edge arrows are SwiftUI (`SaryMapOverlayLayer`), placed from the map's
  projection (`EdgeArrows.place`), kept clear of the cluster, SOS dock, status
  capsule, alert lane, rally flag, «أنت» and visible friends.
- Chrome frames are measured (window coordinates) and passed to the map as
  insets, so keep-group framing stays clear of the capsule, alert lane,
  controls and the sheet's real top edge.
- Place labels are Arabic: the Standard Satellite style is fetched once and
  its labels pointed at `name_ar` (`ArabicBasemap`).
- Real screenshots: `docs/live-shots/`. DEBUG launch overrides:
  `-SaryScheme light|dark`, `-SaryDrive 1|0`, `-SaryNight 1|0`, `-SaryFallback 1`.
