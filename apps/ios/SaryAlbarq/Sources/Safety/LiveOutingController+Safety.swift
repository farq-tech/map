import Combine
import Foundation

/// The live controller's side of the safety pack: hooks the `SafetyController`
/// into the session, the GPS and the alert lane. Kept here so the shared
/// controller only gains a property and one call.
extension LiveOutingController {
    static func makeSafety(for session: OutingSession) -> SafetyController {
        SafetyController(outingId: session.id, myId: session.myUserId, backend: session.safetyBackend, seedsDemo: session.isDemo)
    }

    func attachSafety(timers: Bool = true) {
        let s = safety
        s.view = { [weak self] in self?.session.view }
        s.myFix = { [weak self] in self?.location.lastFix }
        s.mapBearing = { [weak self] in self?.overlay.projection.bearing ?? 0 }
        s.isSharingNow = { [weak self] in self?.session.isSharingNow ?? false }
        /* «طريق العودة»: from where I am, back along my own trail to its start (on this phone only). */
        s.wayBackDistanceM = { [weak self] in
            guard let self, let f = self.location.lastFix, var bt = BackTrack(path: self.session.displayTrail) else { return nil }
            let st = bt.update(LngLat(lng: f.lng, lat: f.lat))
            return st.arrived ? nil : st.remainingM
        }
        s.upsertAlert = { [weak self] a, ttl in self?.upsertAlert(a, ttl: ttl) }
        s.removeAlert = { [weak self] id in self?.dismissAlert(id) }
        s.toast = { [weak self] t in self?.toast(t) }
        /* The sunset warning is a safety line: said too, in the guidance voice (mute respected). */
        s.speak = { [weak self] l in self?.nav.voice.say(l) }
        s.openEnjad = { [weak self] k in self?.openEnjad(k) }
        s.bind(events: session.safetyEvents.eraseToAnyPublisher(),
               viewChanged: session.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
               locationChanged: location.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
               timers: timers)
        /* The Live Activity ranks «غرّزت» (OutingActivityCoordinator.stuck reads the session). */
        s.$stuck.sink { [weak self] st in
            guard let session = self?.session else { return }
            let marks = st.values.map { StuckMark(userId: $0.userId, at: $0.at) }.sorted { $0.at > $1.at }
            guard marks != session.stuckMarks else { return }
            session.stuckMarks = marks
            DispatchQueue.main.async { session.objectWillChange.send() }
        }.store(in: &s.retained)
        /* Redraw the screen (chips, strips) when the safety state changes. */
        s.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &s.retained)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SarySafety"), i + 1 < args.count {
            let state = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { s.seedDemo(state) }
        }
        if let i = args.firstIndex(of: "-SarySafetySheet"), i + 1 < args.count {
            let detent: SheetDetentUI = args[i + 1] == "full" ? .full : .half
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.sheetDetent = detent }
        }
        #endif
    }

    /// Add a card, or update it where it is (a stuck friend's distance changes as we drive).
    func upsertAlert(_ a: LiveAlertUI, ttl: TimeInterval) {
        if let i = alerts.firstIndex(where: { $0.id == a.id }) {
            if alerts[i] != a { alerts[i] = a }
        } else {
            pushAlert(a, ttl: ttl)
        }
    }

    /// A safety card tapped: a stuck friend is shown on the map; my overdue card opens the sheet.
    func safetyAlertTapped(_ id: String) -> Bool {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.first == "safety", parts.count >= 2 else { return false }
        switch parts[1] {
        case "stuck" where parts.count > 2: show(member: parts[2])
        case "overdue" where parts.count > 2 && parts[2] != "me": show(member: parts[2])
        default:
            modal = .panel(.safety)
        }
        return true
    }
}

extension LiveOutingController {
    /// «غرّزت» in the control cluster: ask (confirm), or — already stuck — open my stuck card.
    func stuckControlTapped() {
        if safety.myStuck != nil {
            modal = .panel(.safety)
        } else {
            safety.askStuck()
        }
    }
}
