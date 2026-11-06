import ActivityKit
import Combine
import Foundation

/// Runs the outing's Live Activity from the app: starts it when I start sharing
/// in an outing, keeps it current from the same data as the map (also in the
/// background while the trail is recorded), throttled, and ends it when I stop
/// sharing, leave, or the outing ends. Local updates only — remote APNs
/// updates are a follow-up.
@MainActor
final class OutingActivityCoordinator {
    typealias Activity = ActivityKit.Activity<OutingActivityAttributes>

    /// Distance back along my trail to its start («طريق العودة»), nil without a trail.
    lazy var backMeters: (OutingSession, DeviceFix) -> Double? = { [unowned self] s, f in self.backDistance(s, f) }
    /// «غرّزت» marks, once the stuck state reaches the session.
    var stuck: (OutingSession) -> [StuckMark] = { _ in [] }
    /// «سرعة المركبة»: the live screen's `SpeedModel.snapshot`, when it is open.
    var speed: (OutingSession) -> SpeedModel.Snapshot? = { _ in nil }
    /// «الرحلة»: the live screen's trip picture (progress, remaining, ETA), when it is open.
    var trip: (OutingSession) -> TripPanelUI? = { _ in nil }
    var nav: (OutingSession) -> NavActivityLine? = { _ in nil }

    private let location: LocationSharer
    private weak var session: OutingSession?
    private var bag = Set<AnyCancellable>()
    private var activity: Activity?
    private var lastState: OutingActivityState?
    private var lastPushAt: Date?
    private var flush: Timer?
    private var scheduled = false
    /// Back-track over the trail as it was at `count` points (rebuilt when the trail grows).
    private var backTrack: (id: String, count: Int, track: BackTrack)?
    /// DEBUG screenshot fixture is up: live data does not replace it.
    private var debugPinned = false

    init(location: LocationSharer) {
        self.location = location
    }

    /// Follow this session (nil: none open). An activity of another outing ends.
    func attach(_ s: OutingSession?) {
        guard s !== session else { return }
        bag.removeAll()
        session = s
        lastState = nil
        lastPushAt = nil
        guard let s else {
            end()
            return
        }
        /* Left over from a previous launch: keep this outing's one, end the rest. */
        for a in Activity.activities {
            if a.attributes.outingId == s.id, activity == nil { activity = a } else if a.id != activity?.id { endNow(a) }
        }
        if let a = activity, a.attributes.outingId != s.id { endNow(a); activity = nil }
        s.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        location.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        schedule()
    }

    /// Changes come in bursts (every published property); look once they settle.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.evaluate()
        }
    }

    /// The activity runs while I want to share in an active outing that is still open.
    nonisolated static func shouldRun(wantsToShare: Bool, status: OutingStatus?, closed: Bool) -> Bool {
        wantsToShare && !closed && (status == .active || status == .paused)
    }

    func evaluate(now: Date = Date()) {
        if debugPinned { return }
        guard let s = session else { return end() }
        guard Self.shouldRun(wantsToShare: s.wantsToShare, status: s.view?.status, closed: s.closedReason != nil) else { return end() }
        let input = LivePresenterInput(view: s.view, myFix: location.lastFix, gpsState: location.gpsState, locationAuthorized: location.canLocate,
                                       link: s.link, closed: s.closedReason, wantsToShare: s.wantsToShare, isSharingNow: s.isSharingNow,
                                       sosSending: s.sosSending, now: now)
        let back = location.lastFix.flatMap { backMeters(s, $0) }
        guard let state = OutingActivityBuilder.state(input, backMeters: back, stuck: stuck(s), speed: speed(s), trip: trip(s), nav: nav(s)) else { return }

        guard let a = activity else {
            start(s, state)
            return
        }
        guard OutingActivityThrottle.shouldPush(state, last: lastState, lastAt: lastPushAt, now: now) else {
            armFlush(now)
            return
        }
        push(a, state, now: now)
    }

    private func backDistance(_ s: OutingSession, _ f: DeviceFix) -> Double? {
        let n = s.trail.points.count
        if backTrack?.id != s.id || backTrack?.count != n {
            backTrack = BackTrack(path: s.displayTrail).map { (s.id, n, $0) }
        }
        guard var b = backTrack else { return nil }
        let st = b.track.update(LngLat(lng: f.lng, lat: f.lat))
        backTrack = b
        return st.remainingM
    }

    private func start(_ s: OutingSession, _ state: OutingActivityState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let v = s.view else { return }
        let attrs = OutingActivityAttributes(outingId: s.id, outingName: v.snapshot.outing.name)
        do {
            activity = try Activity.request(attributes: attrs, content: Self.content(state), pushType: nil)
            lastState = state
            lastPushAt = state.updatedAt
        } catch {
            /* Not allowed now (background, switched off in Settings): try again on the next change in the foreground. */
        }
    }

    private func push(_ a: Activity, _ state: OutingActivityState, now: Date) {
        flush?.invalidate()
        flush = nil
        lastState = state
        lastPushAt = now
        let content = Self.content(state)
        /* A friend's SOS lights the screen; nothing else does. */
        let alert = state.alert.flatMap { new -> AlertConfiguration? in
            guard new.kind == .sos, !new.isMe, lastStateAlertDiffers(new) else { return nil }
            return AlertConfiguration(title: "طوارئ", body: "\(new.name) يحتاج مساعدة", sound: .default)
        }
        Task { await a.update(content, alertConfiguration: alert) }
    }

    private var lastAlerted: OutingActivityState.Alert?
    private func lastStateAlertDiffers(_ a: OutingActivityState.Alert) -> Bool {
        defer { lastAlerted = a }
        return lastAlerted?.name != a.name || lastAlerted?.since != a.since
    }

    /// A held-back change still goes out once the 15 s window passes.
    private func armFlush(_ now: Date) {
        guard flush == nil, let at = lastPushAt else { return }
        let wait = max(1, OutingActivityThrottle.minInterval - now.timeIntervalSince(at) + 0.5)
        flush = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flush = nil
                self?.evaluate()
            }
        }
    }

    nonisolated static func content(_ s: OutingActivityState) -> ActivityContent<OutingActivityState> {
        ActivityContent(state: s, staleDate: s.updatedAt.addingTimeInterval(OutingActivityState.staleAfter))
    }

    /// Sharing stopped / left / ended: the activity goes away at once.
    func end() {
        flush?.invalidate()
        flush = nil
        lastState = nil
        lastPushAt = nil
        lastAlerted = nil
        backTrack = nil
        guard let a = activity else { return }
        activity = nil
        endNow(a)
    }

    private func endNow(_ a: Activity) {
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// Nothing open after launch: no activity should outlive its outing.
    func endOrphans() {
        guard session == nil else { return }
        for a in Activity.activities { endNow(a) }
    }

    #if DEBUG
    /// Screenshot fixture (`-SaryActivity <name>`): a fixed picture, never live data.
    func debugStart(_ name: String) {
        let now = Date()
        var s = OutingActivityState(liveCount: 3, memberCount: 4, farthestName: "سلطان", farthestMeters: 2400, backMeters: 6100,
                                    alert: nil, gpsOK: true, online: true, updatedAt: now)
        switch name {
        case "sos": s.alert = .init(kind: .sos, name: "نورة", isMe: false, since: now.addingTimeInterval(-90), more: 0)
        case "stuck": s.alert = .init(kind: .stuck, name: "أبو فهد", isMe: false, since: now.addingTimeInterval(-300))
        case "gps": s.gpsOK = false; s.backMeters = nil; s.farthestName = nil; s.farthestMeters = nil; s.liveCount = 2
        case "stale": s.updatedAt = now.addingTimeInterval(-7 * 60)
        case "trip": s.tripPercent = 62; s.tripRemainingM = 12_400; s.tripETA = now.addingTimeInterval(14 * 60); s.speedKmh = 64
        case "arrived": s.tripArrived = true; s.tripPercent = 100
        default: break
        }
        for a in Activity.activities { endNow(a) }
        let attrs = OutingActivityAttributes(outingId: DemoData.outingId, outingName: "طلعة الثمامة")
        debugPinned = true
        /* iOS will not start an activity whose stale date has passed; the old picture is still shown old (its own age). */
        let content = ActivityContent(state: s, staleDate: max(s.updatedAt, now).addingTimeInterval(OutingActivityState.staleAfter))
        do { activity = try Activity.request(attributes: attrs, content: content, pushType: nil) } catch { NSLog("SaryActivity: \(error)") }
    }
    #endif
}
