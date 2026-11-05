import Foundation

/// Build 8 «ترتيب الشاشة» (docs/IA-REDESIGN.md): the context mode, the «+» actions,
/// and what the trip header and the map show.
extension LiveOutingController {
    /// Driving or stopped, right now. `drive`: the appearance's drive mode (`theme.drive`).
    func liveContext(drive: Bool) -> LiveContext {
        LiveContextRule.resolve(override: contextOverride, navigating: nav.isActive, moving: motion.moving,
                                driveMode: drive, sheetRaised: sheetDetent != .peek, exploring: exploreActive)
    }

    /// Tapping the trip header: the trip's details («الرحلة» at half height).
    func openTripDetails() {
        statusExpanded = false
        bellOpen = false
        selectedTab = .trip
        sheetDetent = .half
    }

    /// «طريق العودة» on the map by itself: while it runs, after arrival, or off the planned route.
    var showsBackTrackShortcut: Bool {
        if backTrack != nil { return true }
        if case .arrived = tripPanel.phase { return true }
        if let plan = planModel, plan.following, plan.plan.hasRoute,
           plan.followStatus(fix: location.lastFix, now: Date()).kind == .offRoute { return true }
        return false
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

    /// What «أدوات الطلعة» and the «الرحلة» tab's route actions offer right now.
    var actionState: LiveActionCatalog.State {
        .init(backTracking: backTrack != nil,
              following: planModel?.following == true,
              hasRoute: planModel?.plan.hasRoute ?? false,
              stuck: safety.myStuck != nil,
              ended: tripEnded,
              guideAllTarget: canGuideAll && session.view?.status == .active ? autoNavNextTarget?.name : nil,
              chat: chat.isAvailable,
              channels: session.walkie.showsChannels)
    }

    /// One row of the «+» sheet was chosen: close it, then act (most actions open their own sheet).
    func performAction(_ id: String) {
        modal = nil
        /* An entry that needs a running trip is not offered after the end (the catalog drops it). */
        if tripEnded, LiveActionCatalog.needsRunningTrip.contains(id) { return }
        let run: () -> Void = { [weak self] in self?.runAction(id) }
        switch id {
        case "backtrack", "follow", "fit", "rally", "timer", "effects", "realistic": run()
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
        case "youtube": MediaCenters.of(self).open()
        case "radio": GroupAudioCenters.of(self).open()
        case "explore": enterExplore()
        case "channels": modal = .pttChannels
        case "enjad": openEnjad(.emergency)
        case "fit": a.fitGroup()
        case "rally": selectedTab = .group; sheetDetent = .half
        case "timer": selectedTab = .trip; sheetDetent = .half
        case "convoy": modal = .convoyAlerts
        case "brief":
            if let f = location.lastFix { modal = .plan(.brief(LngLat(lng: f.lng, lat: f.lat), name: nil)) } else { toast("ننتظر أول قراءة من GPS") }
        case "savePlace":
            if let f = location.lastFix { modal = .placeEdit(SavedPlaceDraft(id: nil, point: LngLat(lng: f.lng, lat: f.lat), name: "", icon: .pin)) } else { toast("ننتظر أول قراءة من GPS") }
        case "hires":
            enterExplore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.modal = .layers }
        case "realistic": realisticRequest += 1
        case "effects": settingsAdvanced = true; selectedTab = .more; sheetDetent = .full
        default: break
        }
    }
}
