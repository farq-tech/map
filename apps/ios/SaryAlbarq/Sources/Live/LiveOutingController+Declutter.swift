import Foundation
import SwiftUI

/// UI-AUDIT م3 (docs/UI-AUDIT.md §٢ «شاشة الطلعة لكل حالة»): what each state of the live screen
/// shows, as pure rules (unit-tested in `LiveDeclutterTests`). One primary per state — the
/// `OutingFlow` CTA; everything else is quiet, and each action has one way in.
enum LiveScreenRules {
    /// The outing's primary button shrinks to a pill whenever the sheet is raised, and — owner's
    /// decision (2026-11-11) — whenever the car is driving, whatever the state («وين رايحين؟» too):
    /// the walkie-talkie is the one big control on the road.
    static func primaryCompact(sheetRaised: Bool, driving: Bool) -> Bool { sheetRaised || driving }

    /// The stopped quick row (four): «البر», «المحادثة» (when the server has it), «التجمع», «المزيد».
    /// «ملاحة» / «وجّه الكل» left it (the CTA is the one accent; «وجّه الكل» is offered in
    /// `NavStartChoiceSheet`), «أخفِ موقعي» moved into «المزيد», «طريق الرجعة» is the map's side button.
    static func quickRow(chat: Bool, rally: Bool = true) -> [String] {
        ["desert"] + (chat ? ["chat"] : []) + (rally ? ["rally"] : []) + ["more"]
    }

    /// What the live screen offers that only makes sense with others. A solo outing («اتجه» on my
    /// own, docs/SOLO-OUTING.md (ج)) hides all of it; a real or demo outing shows all of it.
    struct GroupUI: Equatable {
        /// «اضغط وتكلم», its channel chip and «الترددات».
        var walkieTalkie = true
        /// «رسالة صوتية»: recording and the dock over the map (a solo recording would be uploaded,
        /// refused and deleted: never offered).
        var voiceNotes = true
        /// «المحادثة» (quick row, «المزيد»).
        var chat = true
        /// «نقطة التجمع» (quick row, panel, map point card).
        var rally = true
        /// «ادعُ أصدقاءك» (sheet, «المزيد»).
        var invite = true
        /// Friends' alerts: «القافلة», «نبّهه», «رسالة فوق سيارتي», «أخفِ موقعي», «شوف الكل», «وجّه الكل».
        var friendAlerts = true
        /// «الأصدقاء»: the people list in the sheet and the «المزيد» group.
        var friends = true
        /// SOS goes to the server and the group (with the 3 s «تراجع»). False: SOS is a 911 call.
        var serverSOS = true
        /// The outing can be left («غادر الطلعة») or paused for everyone.
        var leaveAndPause = true
    }

    /// A real or demo outing: everything.
    static let group = GroupUI()

    /// A solo outing: nobody else, nothing sent — no walkie-talkie, voice notes, chat, rally,
    /// invite, friends' alerts or «الأصدقاء»; SOS is a 911 call; «أنهِ المشوار» ends it here.
    static let solo = GroupUI(walkieTalkie: false, voiceNotes: false, chat: false, rally: false, invite: false,
                              friendAlerts: false, friends: false, serverSOS: false, leaveAndPause: false)

    static func groupUI(solo isSolo: Bool) -> GroupUI { isSolo ? solo : group }

    /// The quick row: stopped and looking only — never before the start (the sheet is the people
    /// and «ادعُ أصدقاءك» then), while driving or guiding, after the end, or while my SOS is on.
    static func showsQuickRow(ended: Bool, notStarted: Bool, navigating: Bool, driving: Bool, sosFocused: Bool) -> Bool {
        !ended && !notStarted && !navigating && !driving && !sosFocused
    }

    /// Whether the quick row shows AT PEEK — what sizes the peek detent. Unlike `showsQuickRow`
    /// for the content, it never depends on where the sheet is: the raised sheet always reads
    /// «stopped» (`LiveContextRule`), so sizing the peek from the live context made raising the
    /// sheet change the detent set (88 → 172 in drive mode) and lowering it change it back, and
    /// SwiftUI re-snapped the sheet by itself each time (owner report, Build 36).
    static func peekShowsQuickRow(override o: LiveContextOverride, navigating: Bool, moving: Bool, driveMode: Bool,
                                  exploring: Bool, ended: Bool, notStarted: Bool, sosFocused: Bool) -> Bool {
        /* Exploring hides the quick row (LiveSheet: `showsQuickRow && !exploreActive`): a peek sized for
         * it was a tall empty sheet under the explore map (owner, Build 40). */
        guard !ended, !navigating, !exploring else { return false }
        let context = LiveContextRule.resolve(override: o, navigating: navigating, moving: moving, driveMode: driveMode,
                                              sheetRaised: false, exploring: exploring)
        return showsQuickRow(ended: ended, notStarted: notStarted, navigating: navigating, driving: context == .driving,
                             sosFocused: sosFocused)
    }

    /// My SOS is on: the focused mode — the SOS strip, the walkie-talkie and the map; no CTA,
    /// quick row or side buttons until «أنا بخير».
    static func sosFocused(_ mine: MySOSUI) -> Bool {
        if case .active = mine { return true }
        return false
    }

    /// «طريق الرجعة» on the map's side: when it fits the moment (arrived, off the planned route),
    /// never while it already runs — then its panel's «إنهاء» is the one way out.
    static func backTrackShortcut(running: Bool, arrived: Bool, offRoute: Bool) -> Bool {
        !running && (arrived || offRoute)
    }

    /// Guiding: two side circles at most — the camera and «على الطريق». The voice and «المسارات»
    /// are in the pulled-up guidance sheet (`NavTripOptions`).
    static let navSideIDs: [String] = ["locate", "nav.search"]

    /// «٤ مباشر · الأبعد ١٫٢ كم» over the dock only when the convoy has something to say
    /// (someone drifted off or out of the column).
    static func showsConvoyLine(_ alerts: [LiveAlertUI]) -> Bool {
        alerts.contains { a in
            switch a.kind {
            case .convoy, .drift: return true
            default: return false
            }
        }
    }

    /// The header's alert history: only with something in it (queued, past, or the list open).
    static func showsBell(bell: Int, hasHistory: Bool, open: Bool) -> Bool {
        bell > 0 || hasHistory || open
    }

    /// The history button beside an alert card: only without the header (the guidance banner is
    /// the top bar) — with the header its bell is the one way in.
    static func historyBesideCard(bannerOnly: Bool) -> Bool { bannerOnly }

    /// «روح له» while guiding elsewhere asks first, like «اتجه» («نغيّر الوجهة…؟»). Refreshing
    /// the same friend's moved position («حدّث الطريق») does not.
    static func memberGoNeedsConfirm(phase: NavPhase, currentMemberId: String?, memberId: String) -> Bool {
        /* The same phases as `LiveOutingController.directionsNeedsConfirm` (kept here: this enum is not main-actor). */
        let guiding = phase == .guiding || phase == .offRoad || phase == .planning
        return guiding && currentMemberId != memberId
    }
}

/// Build 8 «ترتيب الشاشة» (docs/IA-REDESIGN.md): the context mode, the «+» actions,
/// and what the trip header and the map show.
extension LiveOutingController {
    /// Driving or stopped, right now. `drive`: the appearance's drive mode (`theme.drive`).
    func liveContext(drive: Bool) -> LiveContext {
        LiveContextRule.resolve(override: contextOverride, navigating: nav.isActive, moving: motion.moving,
                                driveMode: drive, sheetRaised: sheetDetent != .peek, exploring: exploreActive)
    }

    /// Tapping the trip header: the trip's details (destination, progress, legs, plan).
    func openTripDetails() {
        statusExpanded = false
        bellOpen = false
        modal = .panel(.route)
    }

    /// My SOS is on: the focused mode (`LiveScreenRules.sosFocused`).
    /// Read several times per render: `mySOS` is `ui.sos.mine` without a presenter pass.
    var sosFocused: Bool { LiveScreenRules.sosFocused(mySOS) }

    /// `ui.status == .notStarted` and `ui.sos.mine`, all the focused-mode checks below read, from
    /// the same merged view the presenter's input uses, without building the input or running the
    /// presenter (`sheetShape` alone is read several times per render).
    private var focusFacts: (notStarted: Bool, mySOS: MySOSUI) {
        let v = session.meshOverlay.view
        return (LiveOutingPresenter.status(v?.status) == .notStarted,
                LiveOutingPresenter.mySOS(view: v, sending: session.sosSending, now: Date()))
    }

    /// The sheet's row of key actions shows under the summary line (stopped / looking; never
    /// before the start, while driving, guiding, after the end, or while my SOS is on).
    func showsQuickRow(drive: Bool) -> Bool {
        guard !tripEnded, !nav.isActive, liveContext(drive: drive) != .driving else { return false }
        let f = focusFacts
        /* «طريق الرجعة» running is focused like my SOS (UI-AUDIT: the panel, SOS and the walkie-talkie only). */
        return LiveScreenRules.showsQuickRow(ended: false, notStarted: f.notStarted, navigating: false,
                                             driving: false, sosFocused: LiveScreenRules.sosFocused(f.mySOS) || backTrack != nil)
    }

    /// The live sheet's detent shape (`LiveSheetShape`): the peek height from the context the screen
    /// has AT PEEK, so raising / lowering the sheet never changes its own detent set.
    func sheetShape(drive: Bool) -> LiveSheetShape {
        guard !tripEnded, !nav.isActive else {
            /* Guiding on a route with dirt or off-road: room for «زفلت … ← ترابي …» under the numbers. */
            let surfaces = !tripEnded && nav.isActive && nav.phase != .arrived && nav.surfaceAhead != nil
            return LiveSheetShape(drive: drive, trip: false, surfaces: surfaces, guide: navBarV2)
        }
        /* The idle sheet holds the search field at peek: the taller peek the quick row used. */
        if idleHome { return LiveSheetShape(drive: drive, trip: true) }
        let f = focusFacts
        let trip = LiveScreenRules.peekShowsQuickRow(override: contextOverride, navigating: false, moving: motion.moving,
                                                     driveMode: drive, exploring: exploreActive, ended: false,
                                                     notStarted: f.notStarted,
                                                     sosFocused: LiveScreenRules.sosFocused(f.mySOS) || backTrack != nil)
        return LiveSheetShape(drive: drive, trip: trip)
    }

    /// «طريق الرجعة» on the map by itself: after arrival or off the planned route — not while it
    /// runs (its panel's «إنهاء» stops it; no second stop button).
    var showsBackTrackShortcut: Bool {
        var arrived = false
        if case .arrived = tripPanel.phase { arrived = true }
        var offRoute = false
        if let plan = planModel, plan.following, plan.plan.hasRoute,
           plan.followStatus(fix: location.lastFix, now: Date()).kind == .offRoute { offRoute = true }
        return LiveScreenRules.backTrackShortcut(running: backTrack != nil, arrived: arrived, offRoute: offRoute)
    }

    /// After the end, «طريق الرجعة» stays on the map (UI-AUDIT 0.3): it runs on this phone along my
    /// trail (`BackTrack`), so it needs no network — while it runs, or while there is a trail to retrace.
    var showsBackTrackAfterEnd: Bool {
        tripEnded && (backTrack != nil || session.trail.points.count >= 2)
    }

    /// Guiding with the redesigned live screen (`NavDriveLayout`): the maneuver card on top, the one
    /// bottom bar with the friends and the walkie-talkie in its footer (DEBUG `-SaryDriveV1`: the old layout).
    var navBarV2: Bool { NavDriveLayout.v2 && nav.isActive }

    /// A solo outing («اتجه» on my own): one member, on this phone only.
    var isSolo: Bool { session.isSolo }

    /// What of the group's UI this outing shows (`LiveScreenRules.solo` in a solo outing).
    var groupUI: LiveScreenRules.GroupUI { LiveScreenRules.groupUI(solo: isSolo) }

    /// The outing has ended («انتهت الطلعة»): the screen shows the end, not live controls.
    var tripEnded: Bool { session.displayView?.status == .ended || session.closedReason == .outingEnded }

    /// Members in an alert state (SOS, «غرّز», silent): their edge arrows always show.
    var alertingMemberIds: Set<String> { alertingMemberIds(ui: ui) }

    /// The same from a `ui` already built for this render (its participants are
    /// `LiveOutingPresenter.participants(input)`), so the presenter does not run again.
    func alertingMemberIds(ui: LiveOutingUIState) -> Set<String> {
        var s = Set(ui.sos.incoming.map(\.participantId))
        for r in safety.friendsStuck { s.insert(r.userId) }
        for p in ui.participantsTab.participants where p.silentSince != nil { s.insert(p.id) }
        return s
    }

    /// «الإعدادات» as a pushed page: the full-screen cover appears without its slide-up, the page
    /// slides in itself (`SettingsPushHost`).
    func openSettings() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { settingsOpen = true }
    }

    func closeSettings() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { settingsOpen = false }
    }

    /// What «أدوات الطلعة» and the «الرحلة» tab's route actions offer right now.
    var actionState: LiveActionCatalog.State {
        .init(backTracking: backTrack != nil,
              following: planModel?.following == true,
              hasRoute: planModel?.plan.hasRoute ?? false,
              stuck: safety.myStuck != nil,
              ended: tripEnded,
              guideAllTarget: canGuideAll && guideAllHasOthers && session.view?.status == .active ? autoNavNextTarget?.name : nil,
              chat: chat.isAvailable && groupUI.chat,
              channels: session.walkie.showsChannels && groupUI.walkieTalkie,
              canHide: canHideLocation && groupUI.friendAlerts,
              hidden: isLocationHidden,
              solo: isSolo)
    }

    /// «المزيد» → an entry that only opens another sheet: swapped in directly (`sheet(item:)`
    /// dismisses the current sheet and presents the new one when the item changes) — no
    /// nil → 0.4 s → reopen flicker.
    static let swapsModalDirectly: Set<String> = ["search", "weather", "qibla", "camp", "channels", "enjad", "rally", "timer",
                                                  "route", "invite", "convoy"]

    /// One row of the «+» sheet was chosen: close it, then act (most actions open their own sheet).
    func performAction(_ id: String) {
        /* An entry that needs a running trip is not offered after the end (the catalog drops it). */
        if tripEnded, LiveActionCatalog.needsRunningTrip.contains(id) { modal = nil; return }
        /* A solo outing never runs a group action, whatever asked for it (the catalog drops them). */
        if isSolo, LiveActionCatalog.soloHidden.contains(id) { modal = nil; return }
        if Self.swapsModalDirectly.contains(id) { return runAction(id) }
        modal = nil
        let run: () -> Void = { [weak self] in self?.runAction(id) }
        switch id {
        case "backtrack", "follow", "fit", "effects", "realistic", "settings", "hide": run()
        default: DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: run)
        }
    }

    private func runAction(_ id: String) {
        let a = actions
        switch id {
        case "navigate": openNavPicker()
        case "guideAll": startGuidanceForAll()
        case "search": modal = .plan(.search)
        case "backtrack": backTrack == nil ? startBackTrack() : stopBackTrack()
        case "hide": if canHideLocation { toggleHidden() }
        case "follow":
            if let plan = planModel, plan.plan.hasRoute {
                plan.following.toggle()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.modal = .plan(.editor) }
            }
        case "note": a.openNoteComposer()
        case "chat": if chat.isAvailable { openChat() }
        case "stuck": stuckControlTapped()
        case "waypoint": features.composeAtMe(location.lastFix)
        case "copyme": modal = .plan(.me)
        case "nearest": a.openNearestStations()
        case "weather": modal = .weather
        case "qibla": modal = .qibla
        case "camp": modal = .campSuggest
        case "desertRoute":
            if let d = tripDestination { modal = .desertRoute(LngLat(lng: d.lng, lat: d.lat), d.name.isEmpty ? "الوجهة" : d.name, false, false) }
            else { toast("حدّد وجهة الطلعة، أو افتح «اقترح لي مكان كشتة» واختر «دروب البر»") }
        case "youtube": MediaCenters.of(self).open()
        case "radio": GroupAudioCenters.of(self).open()
        case "explore": enterExplore()
        case "channels": modal = .pttChannels
        case "enjad": openEnjad(.emergency)
        case "fit": a.fitGroup()
        case "rally": modal = .panel(.rally)
        case "timer": modal = .panel(.safety)
        case "route": modal = .panel(.route)
        case "invite": modal = .panel(.invite)
        case "settings": openSettings()
        case "convoy": modal = .convoyAlerts
        case "brief":
            if let f = location.lastFix { modal = .plan(.brief(LngLat(lng: f.lng, lat: f.lat), name: nil)) } else { toast("ننتظر أول قراءة للموقع") }
        case "savePlace":
            if let f = location.lastFix { modal = .placeEdit(SavedPlaceDraft(id: nil, point: LngLat(lng: f.lng, lat: f.lat), name: "", icon: .pin)) } else { toast("ننتظر أول قراءة للموقع") }
        case "hires":
            enterExplore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.modal = .layers }
        case "realistic": realisticRequest += 1
        case "effects": openSettings()
        default: break
        }
    }

    /// «غيّر الوجهة» in the guidance bar: the trip's leg → «وين رايحين؟»; my own guidance → «إلى أين؟».
    func navChangeDestination() {
        if nav.auto || legs.current != nil { flowTapped(.changeDestination) } else { openNavPicker() }
    }
}

/// Screen-size adaptation of the live screen's chrome, as pure rules (unit-tested in
/// `LiveDeclutterTests`). Everything here returns the regular design on a standard phone
/// (390–402 × 844–874 pt, default text) and only steps in when the room is short: the iPhone SE
/// (375 × 667, 20 pt status bar, no home indicator), the 375 pt wide minis, or large Dynamic Type.
enum LiveFit {
    /// Below this height the screen is «short» (iPhone SE 2/3: 667 pt): secondary pieces drop out.
    static let compactHeightBelow: CGFloat = 700

    /// A short screen. 0 (not measured yet) is never short.
    static func compactHeight(_ height: CGFloat) -> Bool { height > 0 && height < compactHeightBelow }

    /// The header's weather pill: on a narrow phone the outing's state line needs the width more
    /// (the weather stays in the sheet and in its own alerts). Large text needs a wider phone.
    /// Replaces `UIScreen.main.bounds.width < 380` with the real container width.
    static func showsHeaderWeather(width: CGFloat, largeText: Bool) -> Bool {
        guard width > 0 else { return true }
        return width >= (largeText ? 420 : 380)
    }

    /// The alerts' list under the header (the bell): 42 % of the screen, at least 220 pt — on a
    /// short screen at most 30 % (≥ 160 pt), so the list and the side buttons under it stay above
    /// the dock and the peeking sheet.
    static func alertListMaxHeight(screenHeight h: CGFloat) -> CGFloat {
        let regular = max(220, h * 0.42)
        guard compactHeight(h) else { return regular }
        return min(regular, max(160, (h * 0.30).rounded()))
    }

    /// Captions under the map's side buttons: off while guiding (as before) and on a short screen,
    /// where the two 19 pt captions are what pushes the side column into the dock.
    static func sideCaptions(guiding: Bool, screenHeight: CGFloat) -> Bool {
        !guiding && !compactHeight(screenHeight)
    }

    /// The side buttons under the open alerts' list: on a short screen they step aside while the
    /// list is open (320 × 568 Display Zoom: header + list + side column ran ~50 pt into the dock).
    static func sideWithAlertList(bellOpen: Bool, screenHeight: CGFloat) -> Bool {
        !(bellOpen && compactHeight(screenHeight))
    }

    // MARK: The dock (bottom row over the sheet)

    /// «اضغط وتكلم» pill: 200 pt big (driving), 178 pt stopped, never under 150 pt.
    static let bigPTTWidth: CGFloat = 200
    static let pillPTTWidth: CGFloat = 178
    static let minPTTWidth: CGFloat = 150
    /// `LovableSpeedBubble`.
    static let speedBubbleWidth: CGFloat = 76

    /// `NavSpeedCluster`: the speed disc, and the limit sign overlapping it by 6 pt.
    static func navSpeedClusterWidth(drive: Bool, limit: Bool) -> CGFloat {
        let d: CGFloat = drive ? 72 : 64
        return limit ? d + d * 0.72 - 6 : d
    }

    /// The compact primary pill (`OutingPrimaryCTA(compact: true)`): 16 pt icon, 6 pt gap, 2 × 16 pt
    /// padding and the 15 pt heavy title (≈ 8.5 pt a character at the default size).
    static func compactCTAWidth(title: String, textScale: CGFloat = 1) -> CGFloat {
        (16 + 6 + 32 + CGFloat(title.count) * 8.5 * textScale).rounded(.up)
    }

    /// Roughly how much the chrome's text grows at a Dynamic Type size (body 17 pt = 1), up to the
    /// dock's `xxLarge` cap.
    static func textScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1
        case .xLarge: return 1.12
        default: return 1.24
        }
    }

    struct Dock: Equatable {
        /// The talk pill's minimum width (its regular width when the row has room).
        var pttMinWidth: CGFloat
        /// The compact primary moves to its own row just above the dock (same side), so neither
        /// it nor «اضغط وتكلم» is squeezed into a truncated label.
        var ctaOwnRow: Bool
    }

    /// Fits the driving dock's row — [speed] «اضغط وتكلم» [compact primary] [guiding speed] — in
    /// `width`. The pill gives way first (down to `minPTTWidth`); if that is not enough the
    /// primary takes its own row. `speed` / `cluster` are 0 when not shown; `cta` is nil when
    /// there is no compact primary in the row.
    static func dock(width: CGFloat, ptt: CGFloat, speed: CGFloat, cta: CGFloat?, cluster: CGFloat, spacing: CGFloat = 8) -> Dock {
        guard width > 0 else { return Dock(pttMinWidth: ptt, ctaOwnRow: false) }
        let others = (speed > 0 ? speed + spacing : 0) + (cluster > 0 ? cluster + spacing : 0)
        if let cta {
            let room = width - others - cta - spacing
            if room >= min(ptt, minPTTWidth) { return Dock(pttMinWidth: min(ptt, room), ctaOwnRow: false) }
        }
        let room = width - others
        return Dock(pttMinWidth: min(ptt, max(minPTTWidth, room)), ctaOwnRow: cta != nil)
    }
}
