import Foundation
import SwiftUI

/// UI-AUDIT م3 (docs/UI-AUDIT.md §٢ «شاشة الطلعة لكل حالة»): what each state of the live screen
/// shows, as pure rules (unit-tested in `LiveDeclutterTests`). One primary per state — the
/// `OutingFlow` CTA; everything else is quiet, and each action has one way in.
enum LiveScreenRules {
    /// The stopped quick row (four): «البر», «المحادثة» (when the server has it), «التجمع», «المزيد».
    /// «ملاحة» / «وجّه الكل» left it (the CTA is the one accent; «وجّه الكل» is offered in
    /// `NavStartChoiceSheet`), «أخفِ موقعي» moved into «المزيد», «طريق الرجعة» is the map's side button.
    static func quickRow(chat: Bool) -> [String] {
        ["desert"] + (chat ? ["chat"] : []) + ["rally", "more"]
    }

    /// The quick row: stopped and looking only — never before the start (the sheet is the people
    /// and «ادعُ ربعك» then), while driving or guiding, after the end, or while my SOS is on.
    static func showsQuickRow(ended: Bool, notStarted: Bool, navigating: Bool, driving: Bool, sosFocused: Bool) -> Bool {
        !ended && !notStarted && !navigating && !driving && !sosFocused
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
    var sosFocused: Bool { LiveScreenRules.sosFocused(ui.sos.mine) }

    /// The sheet's row of key actions shows under the summary line (stopped / looking; never
    /// before the start, while driving, guiding, after the end, or while my SOS is on).
    func showsQuickRow(drive: Bool) -> Bool {
        /* Cheap checks first: `ui` runs the whole presenter. */
        guard !tripEnded, !nav.isActive, liveContext(drive: drive) != .driving else { return false }
        let ui = self.ui
        return LiveScreenRules.showsQuickRow(ended: false, notStarted: ui.status == .notStarted, navigating: false,
                                             driving: false, sosFocused: LiveScreenRules.sosFocused(ui.sos.mine))
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

    /// The outing has ended («انتهت الطلعة»): the screen shows the end, not live controls.
    var tripEnded: Bool { session.displayView?.status == .ended || session.closedReason == .outingEnded }

    /// Members in an alert state (SOS, «غرّز», silent): their edge arrows always show.
    var alertingMemberIds: Set<String> {
        var s = Set(ui.sos.incoming.map(\.participantId))
        for r in safety.friendsStuck { s.insert(r.userId) }
        for p in LiveOutingPresenter.participants(input) where p.silentSince != nil { s.insert(p.id) }
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
              chat: chat.isAvailable,
              channels: session.walkie.showsChannels,
              canHide: canHideLocation,
              hidden: isLocationHidden)
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
            if let f = location.lastFix { modal = .plan(.brief(LngLat(lng: f.lng, lat: f.lat), name: nil)) } else { toast("ننتظر أول قراءة من GPS") }
        case "savePlace":
            if let f = location.lastFix { modal = .placeEdit(SavedPlaceDraft(id: nil, point: LngLat(lng: f.lng, lat: f.lat), name: "", icon: .pin)) } else { toast("ننتظر أول قراءة من GPS") }
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
