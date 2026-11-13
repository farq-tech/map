import Combine
import CoreLocation
import Foundation
import UIKit

/// Where a navigation is.
enum NavPhase: Equatable {
    case idle
    /// The route options sheet: routes loading / shown / failed.
    case planning
    /// Turn-by-turn on the road route.
    case guiding
    /// «آخر جزء بدون طريق»: road ended (or there is none), straight line to the target.
    case offRoad
    case arrived
}

/// Why the guidance is a straight line instead of a road route (said on screen, honestly).
enum NavFallback: Equatable {
    /// The router knows no road to the target (a desert camp off the network).
    case noRoad
    /// The phone has no internet (the request never left): bearing guidance while we retry.
    /// Never a made-up route.
    case offline
    /// The internet works but the router failed or timed out: bearing guidance while we retry.
    /// Never «بلا إنترنت» — that would blame the user's connection for our server.
    case routeFailed

    /// Bearing guidance that keeps asking for a road route.
    var retrying: Bool { self == .offline || self == .routeFailed }
}

enum NavCameraMode: Equatable {
    /// Behind my car, heading-up, tilted.
    case follow
    /// The whole remaining route.
    case overview
    /// The person moved the map: leave it alone until «تابع».
    case free
}

/// One navigation at a time, from «ابدأ الملاحة» to «إنهاء». Owns the routing
/// provider, the guidance engine and the voice; the live screen observes it.
@MainActor
final class NavSession: ObservableObject {
    @Published private(set) var phase: NavPhase = .idle
    @Published private(set) var target: NavTarget?
    @Published var options: NavRouteOptions = .load() {
        didSet { options.save() }
    }
    /// Ordered best first (`NavRouteChoice`).
    @Published private(set) var routes: [NavRoute] = []
    @Published var selectedId: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// No road route at all: only a straight line (honest «اتجاه مباشر»).
    @Published private(set) var direct = false
    /// The route being driven.
    @Published private(set) var active: NavRoute?
    @Published private(set) var progress: NavProgress?
    /// The route revision `progress` was measured on. A reroute replaces `active` at once, but the
    /// next progress (on the NEW route) comes a moment later: until then the old route's step
    /// index and distances must not be read against the new route (`shownProgress`).
    private var progressRevision = 0
    @Published private(set) var rerouting = false
    /// When the current off-route began (`rerouteHoldS`).
    private var reroutingSince: Date?
    /// Our own check of the raw GPS fix against the route (`RouteAdherence`): a parallel carriageway
    /// the SDK still counts as «on the route» (owner, build 46) must not keep a stale instruction.
    private(set) var adherence = RouteAdherence()
    private var routeLine: RouteLine?
    private var adherenceHold = false
    /// The off-road wording (build 49, `OffRoadVoice`): used when most of the route is dirt, track or open
    /// ground. Same voice, desert words; the road-trip lines are unchanged.
    private var offRoadVoice = OffRoadVoice()
    private(set) var offRoadTrip = false
    private var offRoadBegan = false
    private var forceTask: Task<Void, Never>?
    private var forcedAt: [Date] = []
    /// Our own reroutes: at most this many in `forceWindowS`, at least `forceGapS` apart.
    static let forceMax = 3
    static let forceWindowS = 300.0
    static let forceGapS = 20.0
    @Published private(set) var offRoad: NavOffRoadLeg?
    /// Live remainder in the off-road phase.
    @Published private(set) var offRoadNow: (distanceM: Double, bearing: Double)?
    @Published var camera: NavCameraMode = .follow
    @Published var muted: Bool {
        didSet { voice.muted = muted }
    }
    @Published private(set) var arrivedAt: Date?
    @Published private(set) var startedAt: Date?
    /// Started by the trip («ابدأ الطلعة», `TripAutoNav`), not by a tap: no options sheet,
    /// the best route at once, and a straight line (never a made-up road) when routing fails.
    @Published private(set) var auto = false
    @Published private(set) var fallback: NavFallback?
    /// Arrived at the target (the stop / destination logic lives with the trip).
    var onArrived: (NavTarget) -> Void = { _ in }
    /// Offline fallback: the first wait before trying a road route again. Each failed try
    /// doubles the wait (20 s, 40 s, 80 s …) up to `maxRetryInterval`, so a long stretch without
    /// signal does not re-run the whole routing chain every 20 s. `retryNow()` (network back)
    /// still tries at once.
    var retryInterval: TimeInterval = 20
    /// The longest wait between two automatic retries (never shorter than `retryInterval`).
    static let maxRetryInterval: TimeInterval = 300
    private var retryTask: Task<Void, Never>?
    private var retryable = false
    private var retriesEnabled = false
    private var retrying = false
    /// Said before the first instruction of an automatic start («نبدأ التوجيه إلى …»).
    private var autoIntro: NavLine?

    let provider: NavRoutingProvider
    let voice = NavVoice()
    private var plan = NavRoutePlan(routes: [])
    private var engine: NavGuidanceEngine?
    private let makeEngine: (NavRoutePlan) -> NavGuidanceEngine
    private let locator = NavLocator()
    private var fetchTask: Task<Void, Never>?
    private var lastOffRouteSpoken = Date.distantPast
    private let spokenSubject = PassthroughSubject<String, Never>()
    /// My latest fix (from the app's location owner).
    var myFix: () -> DeviceFix? = { nil }
    /// Say something on screen (the live screen's toast).
    var toast: (String) -> Void = { _ in }

    init(provider: NavRoutingProvider, makeEngine: ((NavRoutePlan) -> NavGuidanceEngine)? = nil) {
        self.provider = provider
        muted = UserDefaults.standard.bool(forKey: NavVoice.muteKey)
        self.makeEngine = makeEngine ?? { plan in
            plan.native is MapboxRoutesBox || plan.native is FarqRoutesBox ? MapboxGuidanceEngine() as NavGuidanceEngine : LocalGuidanceEngine()
        }
        voice.onSpoken = { [weak self] t in self?.spokenSubject.send(t) }
        locator.onFix = { [weak self] f in self?.ingest(f) }
        voice.onReevaluate = { [weak self] in self?.restateCurrent() }
        voice.atPlayback = { [weak self] l, c in self?.playback(l, choice: c) ?? .play(l) }
    }

    /// The arrival time: the engine's (Mapbox: live traffic) remaining time, smoothed (`NavETASmoother`).
    private(set) var etaSmoother = NavETASmoother()
    private var etaAnnouncer = NavETAAnnouncer()
    private var openingVoicePending = false

    /// «باقي ربع ساعة وتوصل.» at the start, every 10 min, and when the arrival moved by more than 5 —
    /// never over a maneuver (only with 20 s and 150 m of road before the next one, the speaker free).
    func announceETAIfDue(_ p: NavProgress, now: Date = Date()) {
        guard phase == .guiding, !rerouting, !openingVoicePending,
              let a = etaSmoother.arrival, etaAnnouncer.isDue(arrival: a, now: now),
              !voice.isSpeaking else { return }
        let v = max(3, guidanceSpeed(now) ?? 0)
        guard p.distanceToManeuverM > 150, p.distanceToManeuverM / v > 20 else { return }
        let s = a.timeIntervalSince(now)
        etaAnnouncer.said(arrival: a, now: now)
        voice.say(NavLine(NavETAAnnouncer.text(arrival: a, remainingS: s), clips: NavETAAnnouncer.clip(remainingS: s).map { [$0] } ?? [],
                          routeRevision: routeRevision, expiresAt: now.addingTimeInterval(15)))
    }

    /// When the last progress came, and my speed along the route from progress to progress.
    private var progressAt = Date.distantPast
    private var progressSpeed: Double?

    /// Mapbox's map-matched position while it guides (not published: progress redraws anyway).
    private(set) var matchedFix: DeviceFix?

    private func fresh(_ f: DeviceFix?, _ now: Date) -> DeviceFix? {
        guard let f, now.timeIntervalSince1970 * 1000 - f.atMs < 3000 else { return nil }
        return f
    }

    /// «أنت» on the map while guiding: Mapbox's matched position (on the road, the same point the
    /// distances are measured from, no smoothing lag) — else what the map draws otherwise.
    func mapFix(_ f: DeviceFix?, now: Date = Date()) -> DeviceFix? {
        guard phase == .guiding, !rerouting, var m = fresh(matchedFix, now) else { return f }
        m.heading = HeadingChooser.course(m) ?? f?.heading
        return m
    }

    /// My speed for prompt timing: the matched / raw fix's own (Doppler) when fresh, else along the route.
    func guidanceSpeed(_ now: Date = Date()) -> Double? {
        if let v = fresh(matchedFix, now)?.speed, v >= 0 { return v }
        if let f = myFix(), let v = f.speed, v >= 0, now.timeIntervalSince1970 * 1000 - f.atMs < 3000 { return v }
        return progressSpeed
    }

    private func noteProgress(_ p: NavProgress, now: Date = Date()) {
        if let old = progress, old.stepIndex == p.stepIndex {
            let dt = now.timeIntervalSince(progressAt)
            if dt > 0.2, dt < 5 {
                let v = max(0, (old.distanceToManeuverM - p.distanceToManeuverM) / dt)
                progressSpeed = progressSpeed.map { 0.5 * $0 + 0.5 * v } ?? v
            }
        }
        progressAt = now
    }

    /// The line as it is about to play (build 22, `NavPromptTiming`): rebuilt for the distance
    /// when it ENDS, from the engine's distance now (projected from its last progress), rounded
    /// down; the action alone when the turn is right there; held so it ends at the distance it
    /// says; dropped when the maneuver is behind me.
    func playback(_ line: NavLine, choice c: NavVoiceChoice, now: Date = Date()) -> NavVoice.Playback {
        guard phase == .guiding, let id = line.maneuverID, let r = active, let p = progress,
              let colon = id.firstIndex(of: ":"), Int(id[..<colon]) == routeRevision,
              let index = Int(id[id.index(after: colon)...]), r.steps.indices.contains(index) else { return .play(line) }
        if p.stepIndex > index { return .drop }
        guard p.stepIndex == index else { return .play(line) }
        let v = guidanceSpeed(now)
        let age = min(3, max(0, now.timeIntervalSince(progressAt)))
        let dNow = max(0, p.distanceToManeuverM - (v ?? 0) * age)
        let step = r.steps[index]
        let soft = isSoft(index)
        let stage = NavPromptBudget.stage(distanceM: dNow, speedMps: v)
        /* The per-maneuver budget, at the moment the voice commits to a line: one early + one final
         * (one short line for a soft maneuver), never the same line twice. A reroute or Mapbox's
         * traffic refresh of the same maneuver does not restart it (kept by maneuver, not route). */
        func build(_ spoken: Double?) -> NavLine? {
            guard let w = lineWords(index, distanceM: spoken ?? 0, dNow: dNow, speed: v, stage: stage, opening: line.opening) else { return nil }
            var out = line
            out.text = [line.leadText, w.text].filter { !$0.isEmpty }.joined(separator: ". ")
            out.clips = line.leadClips + w.clips
            return out
        }
        func own(_ out: NavLine) -> [String] { Array(out.clips.dropFirst(line.leadClips.count)) }
        func commit(_ out: NavLine, held: TimeInterval) -> NavVoice.Playback {
            var x = out
            /* Charge the budget once, when the voice first commits to this line (even if it is held
             * to end at a recorded distance); the re-queued held line carries `charged` and is not
             * counted again. A restated line (after a call) is outside the budget. */
            if !line.restate, !line.charged {
                let o = own(out)
                guard budget.allows(step, stage, soft: soft), !budget.repeats(step, clips: o) else { return .drop }
                budget.note(step, stage, clips: o)
                x.charged = true
            }
            x.expiresAt = now.addingTimeInterval(held + 5)
            return held > 0 ? .hold(x, held) : .play(x)
        }
        /* A soft maneuver: a short line with no distance (or nothing), said as it comes. */
        if soft {
            guard let out = build(nil) else { return .drop }
            return commit(out, held: 0)
        }
        let plan = NavPromptTiming.plan(distanceNowM: dNow, speedMps: v, latencyS: NavPromptTiming.startLatencyS(c),
                                        canHold: true, heldS: line.heldS, band: NavPromptTiming.band(c)) { s in
            guard let l = build(s) else { return 0 }
            return NavPromptTiming.duration(c, clips: l.clips, text: l.text)
        }
        guard let out = build(plan.spokenM) else { return .drop }
        /* The «now» was said: no later cue repeats it. */
        saidAtM[id] = plan.spokenM == nil ? 0 : dNow
        #if DEBUG
        NavLog.log("prompt step=%d now=%.0fm v=%.1f said=%@ ends=%.0fm hold=%.1fs", index, dNow, v ?? -1,
                   plan.spokenM.map { String(format: "%.0f", $0) } ?? "now", plan.endM, plan.holdS)
        #endif
        return commit(out, held: plan.holdS)
    }

    /// Bumped on every new route (start, reroute): lines built for an older one are dropped.
    private(set) var routeRevision = 0 {
        didSet { voice.routeRevision = routeRevision; saidAtM = [:] }
    }
    /// Per maneuver («<revision>:<step>»), how far before it the last line was said.
    private var saidAtM: [String: Double] = [:]

    /// A cue for a maneuver already announced is a duplicate (the same moment twice: a repeated
    /// event, the start line and Mapbox's first cue) unless I am clearly closer than when it was
    /// last said. Build 21: the cue was keyed by distance *band* instead — two of Mapbox's cues in
    /// one band (150 m and ~70 m are both "confirm" at 50 km/h) silenced the second, so the
    /// «now» of a turn was never said at city speed. Every closer cue is said now.
    static func isRepeat(distanceM d: Double, lastSaidM last: Double?) -> Bool {
        guard let last else { return false }
        return d > last - max(20, last * 0.25)
    }

    /// The guidance line for step `index`, `d` metres ahead — nil when that cue was already said.
    /// «صوت سرى»: no name, «ثم …» when the next maneuver follows closely and there is time.
    func guidanceLine(stepIndex index: Int, distanceM d: Double, force: Bool = false, opening: Bool = false, restate: Bool = false) -> NavLine? {
        guard let r = active, r.steps.indices.contains(index) else { return nil }
        let step = r.steps[index]
        let speed = guidanceSpeed()
        let key = "\(routeRevision):\(index)"
        if !force, Self.isRepeat(distanceM: d, lastSaidM: saidAtM[key]) {
            voice.stats.dropped(.dedupe)
            return nil
        }
        /* The per-maneuver budget (one early + one final at most, no repeats) is applied at
         * playback, where the voice commits to a line; here we only build it. */
        let stage = NavPromptBudget.stage(distanceM: d, speedMps: speed)
        guard let words = lineWords(index, distanceM: d, dNow: d, speed: speed, stage: stage, opening: opening) else { return nil }
        saidAtM[key] = d
        var line = NavLine(words.text, clips: words.clips, maneuverID: key, routeRevision: routeRevision, expiresAt: Date().addingTimeInterval(10))
        line.opening = opening
        line.restate = restate
        return line
    }

    /// Per maneuver, what was said (build 22: the owner heard one fork four times).
    private var budget = NavPromptBudget()

    /// Guidance lines go out here (tests replace it with a virtual speaker).
    lazy var sayGuidance: (NavLine) -> Void = { [weak self] in self?.voice.say($0) }

    /// A fork / lane that stays on the road it is on, or barely bends (`NavPromptBudget.isSoft`).
    /// Cached per route geometry and step: `bendDeg` scans the whole polyline, and one prompt asks
    /// several times (the line, its playback, every length `NavPromptTiming.plan` tries).
    func isSoft(_ index: Int) -> Bool {
        guard let r = active, r.steps.indices.contains(index) else { return false }
        if softCache.revision != r.geometryRevision { softCache = (r.geometryRevision, [:]) }
        if let known = softCache.byStep[index] { return known }
        let s = r.steps[index]
        let soft = NavPromptBudget.isSoft(s, previous: index > 0 ? r.steps[index - 1] : nil, bendDeg: NavPromptBudget.bendDeg(r.coordinates, at: s.location))
        softCache.byStep[index] = soft
        return soft
    }

    private var softCache: (revision: UUID?, byStep: [Int: Bool]) = (nil, [:])

    /// The words for step `index`: `distanceM` is what is said (0: the action alone), `dNow` where I am.
    /// nil: nothing to say (a soft maneuver's early cue).
    private func lineWords(_ index: Int, distanceM d: Double, dNow: Double, speed: Double?, stage: NavPromptBudget.Stage, opening: Bool) -> (text: String, clips: [String])? {
        guard let r = active, r.steps.indices.contains(index) else { return nil }
        let step = r.steps[index]
        if isSoft(index) {
            if stage == .final { return NavPromptBudget.softLine(step) }
            return opening ? ("كمّل سيده", ["mv_02"]) : nil
        }
        var clips = SaryVoiceScript.step(step, distanceM: d, auto: auto, stop: isStopTarget)
        if d > 0 {
            let next = r.steps.indices.contains(index + 1) ? r.steps[index + 1] : nil
            clips = SaryVoiceScript.withThen(clips, next: next, gapM: step.distanceM, distanceToManeuverM: dNow, speedMps: speed, stop: isStopTarget)
        }
        return (NavText.spoken(step, distanceM: d, targetName: target?.name), NavPromptBudget.tidy(clips))
    }

    /// After a call / Siri cut a line: the current maneuver, rebuilt for the distance now.
    func restateCurrent() {
        guard phase == .guiding, let p = progress,
              let line = guidanceLine(stepIndex: p.stepIndex, distanceM: p.distanceToManeuverM, force: true, restate: true) else { return }
        voice.say(line)
    }

    /// A stop on the way or the rally point (said «على يمينك», not «وجهتك …»).
    var isStopTarget: Bool { target?.source == .tripStop || target?.source == .rally }

    var isActive: Bool { phase == .guiding || phase == .offRoad || phase == .arrived }
    var selected: NavRoute? { routes.first { $0.id == selectedId } ?? routes.first }

    // MARK: planning

    func plan(to t: NavTarget) {
        guard let f = myFix() else {
            toast(NavRefusal.noFix.message)
            return
        }
        if isActive { stopEngine() }
        retryTask?.cancel()
        locator.stop()
        auto = false
        fallback = nil
        retryable = false
        target = t
        phase = .planning
        active = nil
        progress = nil
        arrivedAt = nil
        fetch(from: LngLat(lng: f.lng, lat: f.lat), heading: Policy.trustedHeading(f.heading, speed: f.speed))
    }

    /// The options changed in the sheet: ask again.
    func refetch() {
        guard phase == .planning, let f = myFix() else { return }
        fetch(from: LngLat(lng: f.lng, lat: f.lat), heading: Policy.trustedHeading(f.heading, speed: f.speed))
    }

    private func fetch(from origin: LngLat, heading: Double?) {
        guard let t = target else { return }
        fetchTask?.cancel()
        loading = true
        error = nil
        direct = false
        let req = NavRouteRequest(origin: origin, heading: heading, target: t, options: options)
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let p = try await self.provider.routes(req)
                guard !Task.isCancelled else { return }
                self.plan = p
                self.routes = NavRouteChoice.order(p.routes, options: self.options)
                self.selectedId = self.routes.first?.id
                self.offRoad = NavOffRoad.lastLeg(routeEnd: self.selected?.end, target: t.position)
                if self.routes.isEmpty { self.goDirect(origin, t) }
                #if DEBUG
                NavLog.log("routes %d via %@ first=%.0fm/%.0fs", self.routes.count, self.provider.name, self.routes.first?.distanceM ?? 0, self.routes.first?.durationS ?? 0)
                #endif
            } catch let e as NavRoutingError {
                guard !Task.isCancelled else { return }
                #if DEBUG
                NavLog.log("routing error %@", String(describing: e))
                #endif
                if e == .noRoute { self.goDirect(origin, t) } else { self.error = e.message; self.routes = [] }
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                NavLog.log("routing error %@", String(describing: error))
                #endif
                self.error = NavRoutingError.failed("").message
                self.routes = []
            }
            self.loading = false
        }
    }

    private func goDirect(_ origin: LngLat, _ t: NavTarget) {
        plan = NavRoutePlan(routes: [])
        routes = []
        selectedId = nil
        direct = true
        offRoad = NavOffRoad.direct(from: origin, to: t.position)
    }

    func select(_ id: String) {
        selectedId = id
        if let t = target { offRoad = NavOffRoad.lastLeg(routeEnd: selected?.end, target: t.position) }
    }

    func cancelPlanning() {
        fetchTask?.cancel()
        guard phase == .planning else { return }
        reset()
    }

    // MARK: automatic (the trip)

    /// Guide to `t` now, without the options sheet: the best road route, or — when there is
    /// no road (desert) or no network — the straight-line bearing guidance at once, retrying
    /// the road route in the background when it was the network.
    func autoStart(to t: NavTarget, intro: String? = nil, introClips: [String]? = nil) {
        guard let f = myFix() else { return }
        fetchTask?.cancel()
        retryTask?.cancel()
        if isActive { stopEngine() }
        locator.stop()
        reset()
        auto = true
        retriesEnabled = true
        target = t
        phase = .planning
        loading = true
        arrivedAt = nil
        startedAt = nil
        autoIntro = intro.map { NavLine($0, clips: introClips ?? SaryVoiceScript.intro(resumed: false)) }
        let origin = LngLat(lng: f.lng, lat: f.lat)
        let heading = Policy.trustedHeading(f.heading, speed: f.speed)
        #if DEBUG
        NavLog.log("auto start to %@", t.name)
        #endif
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let r = await self.requestRoutes(origin: origin, heading: heading, target: t)
            guard !Task.isCancelled, self.auto, self.phase == .planning, self.target == t else { return }
            self.loading = false
            self.applyAuto(r, origin: origin, target: t)
            self.start()
        }
    }

    /// Start personal guidance to an arbitrary map point without opening route options and
    /// without marking the outing's shared/automatic guidance as active. A usable hybrid route
    /// is preferred; if no router can produce one, start the explicitly labelled bearing fallback.
    func startImmediately(to t: NavTarget) {
        guard let f = myFix() else { return }
        fetchTask?.cancel()
        retryTask?.cancel()
        if isActive { stopEngine() }
        locator.stop()
        reset()
        retriesEnabled = true
        target = t
        phase = .planning
        loading = true
        let origin = LngLat(lng: f.lng, lat: f.lat)
        let heading = Policy.trustedHeading(f.heading, speed: f.speed)
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.requestRoutes(origin: origin, heading: heading, target: t)
            guard !Task.isCancelled, !self.auto, self.phase == .planning, self.target == t else { return }
            self.loading = false
            self.applyAuto(result, origin: origin, target: t)
            self.start()
        }
    }

    private func requestRoutes(origin: LngLat, heading: Double?, target t: NavTarget) async -> Result<NavRoutePlan, NavRoutingError> {
        do {
            return .success(try await provider.routes(NavRouteRequest(origin: origin, heading: heading, target: t, options: options)))
        } catch let e as NavRoutingError {
            return .failure(e)
        } catch {
            return .failure(.failed(""))
        }
    }

    private func applyAuto(_ r: Result<NavRoutePlan, NavRoutingError>, origin: LngLat, target t: NavTarget) {
        switch r {
        case let .success(p) where !p.routes.isEmpty:
            plan = p
            routes = NavRouteChoice.order(p.routes, options: options)
            selectedId = routes.first?.id
            direct = false
            offRoad = NavOffRoad.lastLeg(routeEnd: selected?.end, target: t.position)
            fallback = nil
            retryable = false
        case .success, .failure(.noRoute):
            goDirect(origin, t)
            fallback = .noRoad
            retryable = false
        case .failure(.notConfigured):
            goDirect(origin, t)
            fallback = .routeFailed
            retryable = false
        case .failure(.offline):
            goDirect(origin, t)
            fallback = .offline
            retryable = true
        case .failure:
            goDirect(origin, t)
            fallback = .routeFailed
            retryable = true
        }
        #if DEBUG
        NavLog.log("route result routes=%d fallback=%@", routes.count, String(describing: fallback))
        #endif
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard retryable, retriesEnabled else { return }
        let first = retryInterval
        retryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let wait = NavSession.retryDelay(attempt: attempt, base: first)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if await self.retryRoute() { return }
                attempt += 1
            }
        }
    }

    /// The wait before automatic retry number `attempt` (0-based): `base` doubled per failed
    /// try, capped at `maxRetryInterval` (or at `base` when that is already longer).
    static func retryDelay(attempt: Int, base: TimeInterval) -> TimeInterval {
        let first = max(0.01, base)
        let cap = max(first, maxRetryInterval)
        let doublings = min(max(0, attempt), 30)
        return min(cap, first * pow(2, Double(doublings)))
    }

    /// One more try at a road route while the offline bearing guidance runs (on a timer, and
    /// when the network comes back). True when there is nothing left to retry.
    @discardableResult
    func retryRoute() async -> Bool {
        guard retriesEnabled, phase == .offRoad, fallback?.retrying == true, retryable else { return true }
        guard !retrying, let t = target, let f = myFix() else { return false }
        retrying = true
        defer { retrying = false }
        let origin = LngLat(lng: f.lng, lat: f.lat)
        let r = await requestRoutes(origin: origin, heading: Policy.trustedHeading(f.heading, speed: f.speed), target: t)
        guard retriesEnabled, phase == .offRoad, fallback?.retrying == true, target == t else { return true }
        switch r {
        case let .success(p) where !p.routes.isEmpty:
            #if DEBUG
            NavLog.log("retry: road route is back")
            #endif
            locator.stop()
            applyAuto(r, origin: origin, target: t)
            autoIntro = NavLine("رجع الاتصال، نوجّهك على الطريق", clips: ["rr_05"])
            start()
            return true
        case .success, .failure(.noRoute):
            fallback = .noRoad
            retryable = false
            voice.say("مافي طريق مزفلت يوصّلك للوجهة. كمّل مع السهم", clips: ["dir_06"])
            return true
        default:
            return false
        }
    }

    /// The network is back: try the road route now instead of waiting for the timer.
    func retryNow() {
        guard retriesEnabled, phase == .offRoad, fallback?.retrying == true, retryable else { return }
        Task { await retryRoute() }
    }

    /// The trip says I arrived (dwell at the destination): end on «وصلتوا».
    func finishArrival() {
        guard phase == .guiding || phase == .offRoad else { return }
        arrive()
    }

    // MARK: guidance

    func start() {
        guard let t = target else { return }
        #if DEBUG
        NavLog.log("start provider=%@ routes=%d direct=%d", provider.name, routes.count, direct ? 1 : 0)
        #endif
        if startedAt == nil || !auto { startedAt = Date() }
        camera = .follow
        let intro = autoIntro ?? NavLine("", clips: [])
        autoIntro = nil
        if direct || selected == nil {
            phase = .offRoad
            locator.start()
            if let f = myFix() { ingest(f) }
            if let leg = offRoad {
                let way = "\(NavText.compassDefinite(leg.bearing))، \(NavText.spokenInDistance(leg.distanceM) ?? "")"
                let arrow = { (lead: String) in SaryVoiceScript.arrow(lead: lead, bearing: leg.bearing, distanceM: leg.distanceM) }
                if fallback == .offline {
                    voice.say(intro + NavLine("ما فيه إنترنت لحساب الطريق. اتجه مع السهم \(way). نعيد المحاولة لما يرجع الاتصال", clips: arrow("rr_06")))
                } else if fallback == .routeFailed {
                    voice.say(intro + NavLine("ما قدرنا نحسب الطريق الحين. اتجه مع السهم \(way). نعيد المحاولة", clips: arrow("dir_07")))
                } else if auto || fallback == .noRoad {
                    /* «ما فيه طريق مزفلت يوصّلك للوجهة» (dir_06), not bar_01: in the v4 set bar_01 says «انتهى الطريق المزفلت», wrong before any road. */
                    voice.say(intro + NavLine("مافي طريق مزفلت يوصّلك للوجهة. كمّل مع السهم \(way)", clips: arrow("dir_06")))
                } else {
                    voice.say("لا يوجد طريق معروف. اتجه \(NavText.compassDefinite(leg.bearing)) \(NavText.spokenInDistance(leg.distanceM) ?? "")", clips: arrow("dir_07"))
                }
            }
            if retriesEnabled { scheduleRetry() }
            UIApplication.shared.isIdleTimerDisabled = true
            return
        }
        guard let r = selected else { return }
        openingVoicePending = auto
        active = r
        routeRevision += 1
        setRouteLine(r)
        phase = .guiding
        offRoad = NavOffRoad.lastLeg(routeEnd: r.end, target: t.position)
        let e = makeEngine(plan)
        attach(e)
        Task { [weak self] in
            guard let self else { return }
            var started: NavGuidanceEngine = e
            do {
                try await e.start(route: r, plan: self.plan, target: t)
            } catch {
                #if DEBUG
                NavLog.log("engine start failed %@ → local", String(describing: error))
                #endif
                /* The SDK could not take this route (e.g. a custom route it cannot parse):
                 * follow it ourselves rather than give up. */
                e.stop()
                guard self.engine === e else { return }
                let local = LocalGuidanceEngine()
                self.attach(local)
                started = local
                try? await local.start(route: r, plan: self.plan, target: t)
            }
            /* «إنهاء» (or the trip's end) came while the engine was still starting: `end()` stopped it
             * before it ran, so stop it again now — never a Mapbox trip and its GPS left behind. */
            guard self.engine === started else { started.stop(); return }
            let opening = self.openingWithETA(intro)
            self.openingVoicePending = false
            if r.steps.count > 1, let line = self.guidanceLine(stepIndex: 1, distanceM: r.steps.first?.distanceM ?? 0, opening: true) {
                self.sayGuidance(opening + line)
            } else if !opening.clips.isEmpty || !opening.text.isEmpty {
                self.voice.say(opening)
            }
        }
        /* The trip's guidance keeps a location stream of its own: the voice goes on with the
         * screen locked even when this phone is not sharing (the Mapbox engine ignores the fixes). */
        if auto { locator.start() }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Put the first ETA into the route's opening prompt. The first GPS progress can arrive before
    /// the opening instruction is spoken; defer the standalone ETA so it does not interrupt or
    /// immediately repeat the same start announcement.
    private func openingWithETA(_ intro: NavLine, now: Date = Date()) -> NavLine {
        guard auto, let arrival = etaSmoother.arrival,
              let remaining = etaSmoother.remaining(now), remaining >= NavETAAnnouncer.minRemainingS else { return intro }
        etaAnnouncer.said(arrival: arrival, now: now)
        let eta = NavLine(NavETAAnnouncer.text(arrival: arrival, remainingS: remaining),
                          clips: NavETAAnnouncer.clip(remainingS: remaining).map { [$0] } ?? [],
                          routeRevision: routeRevision, expiresAt: now.addingTimeInterval(15))
        return intro + eta
    }

    private func attach(_ e: NavGuidanceEngine) {
        engine = e
        e.onEvent = { [weak self] ev in self?.handle(ev) }
        matchedFix = nil
        if let m = e as? MapboxGuidanceEngine {
            m.onMatched = { [weak self] f in self?.matchedFix = f }
        }
        if let local = e as? LocalGuidanceEngine {
            local.reroute = { [weak self] from, heading in await self?.rerouteLocally(from: from, heading: heading) }
            locator.start()
        }
    }

    private func rerouteLocally(from: LngLat, heading: Double?) async -> NavRoute? {
        guard let t = target else { return nil }
        let p = try? await provider.routes(NavRouteRequest(origin: from, heading: heading, target: t, options: options))
        guard let p, let r = NavRouteChoice.order(p.routes, options: options).first else { return nil }
        plan = p
        return r
    }

    /// Off the route, the engine keeps measuring against the OLD route (its distances grow as I
    /// drive away from it). Build 36: the first such progress cleared «نعيد حساب الطريق…» at once,
    /// so the banner flipped back to the abandoned route's turn with a growing distance while the
    /// bottom bar kept the old remaining distance. The old route's progress is held back this long
    /// (a reroute normally lands in 1–3 s; a failed one says so with `.rerouteFailed`); after it the
    /// engine is trusted again (back on the route without a new one).
    static let rerouteHoldS = 8.0

    /// Mapbox's periodic traffic refresh of the same route vs a real reroute from where I am: the
    /// same start and (nearly) the same length is the same route, its progress still applies.
    static func isRefresh(of old: NavRoute?, _ new: NavRoute) -> Bool {
        guard let old, let a = old.coordinates.first, let b = new.coordinates.first else { return false }
        return Vehicle.distanceMeters(a, b) < 10 && abs(old.distanceM - new.distanceM) <= max(50, old.distanceM * 0.02)
    }

    func handle(_ ev: NavGuidanceEvent) {
        #if DEBUG
        if case let .progress(p) = ev {
            if Int(p.distanceRemainingM) / 250 != Int(progress?.distanceRemainingM ?? -1) / 250 {
                NavLog.log("progress step=%d toManeuver=%.0f remaining=%.0f eta=%.0fs limit=%@", p.stepIndex, p.distanceToManeuverM, p.distanceRemainingM, p.durationRemainingS, p.speedLimitKmh.map(String.init) ?? "-")
            }
        } else {
            NavLog.log("event %@", String(describing: ev))
        }
        #endif
        switch ev {
        case let .progress(p):
            guard phase == .guiding else { return }
            if rerouting {
                /* The abandoned route's numbers: not shown, not timed (see `rerouteHoldS`). */
                if let s = reroutingSince, Date().timeIntervalSince(s) < Self.rerouteHoldS { return }
                rerouting = false
                reroutingSince = nil
            }
            /* The raw fix says I am on another road than the route: its numbers are stale. */
            if adherence.state == .off { return }
            noteProgress(p)
            progress = p
            progressRevision = routeRevision
            etaSmoother.update(remainingS: p.durationRemainingS, speedMps: guidanceSpeed())
            announceETAIfDue(p)
            speakOffRoadProgress(p)
        case .offRoute:
            guard phase == .guiding else { return }
            if !rerouting { reroutingSince = Date() }
            rerouting = true
            /* Once, not on every reroute while the driver is still finding the way back. */
            if Date().timeIntervalSince(lastOffRouteSpoken) > 45 {
                lastOffRouteSpoken = Date()
                if offRoadTrip {
                    speakOffRoadDeviation(from: myFix())
                } else {
                    /* «start_08», not «rr_01»: that clip says «درب يديد» (Emirati), the owner says «جديد». */
                    voice.say("طلعت عن الدرب، نضبط لك الطريق", clips: ["start_08"])
                }
            }
        case let .rerouted(r):
            guard phase == .guiding else { return }
            rerouting = false
            reroutingSince = nil
            let refresh = Self.isRefresh(of: active, r)
            active = r
            routeRevision += 1
            /* A traffic refresh of the same route says nothing new about which road I am on. */
            if !refresh { setRouteLine(r, near: myFix()) }
            if refresh {
                /* The same road with fresh traffic: the last progress still describes it. */
                progressRevision = routeRevision
            } else {
                /* A new route from here: its own time at once, not blended with the old route's. */
                etaSmoother.snapNext()
            }
            if let t = target { offRoad = NavOffRoad.lastLeg(routeEnd: r.end, target: t.position) }
            toast("مسار جديد")
            /* The new route's first maneuver at once: Mapbox's own first cue for it came just
             * BEFORE this event (still on the old route) and was lost — up to a minute of silence. */
            if r.steps.count > 1, let line = guidanceLine(stepIndex: 1, distanceM: r.steps[0].distanceM, force: true, opening: true) { sayGuidance(line) }
        case let .rerouteFailed(m):
            rerouting = false
            reroutingSince = nil
            toast(m)
        case .arrivedAtRouteEnd:
            guard phase == .guiding else { return }
            stopEngine()
            if let leg = offRoad {
                phase = .offRoad
                locator.start()
                voice.say(auto ? "انتهى الطريق المزفلت. كمّل مع السهم باتجاه \(NavText.compassDefinite(leg.bearing))، \(NavText.spokenInDistance(leg.distanceM) ?? "")"
                               : "انتهى الطريق. \(NavOffRoad.summary(leg))",
                          clips: SaryVoiceScript.arrow(lead: "dir_05", bearing: leg.bearing, distanceM: leg.distanceM))
                if let f = myFix() { ingest(f) }
            } else {
                arrive()
            }
        case let .speak(t):
            /* Our own engine names the step: build the line here (stage, «ثم», revision). */
            if let i = t.maneuverID.flatMap(Int.init) {
                if let line = guidanceLine(stepIndex: i, distanceM: progress?.distanceToManeuverM ?? 0) { sayGuidance(line) }
            } else {
                voice.say(t)
            }
        case let .cue(routerText):
            /* Mid-reroute the cue belongs to the route being fetched: `.rerouted` says it. */
            if rerouting { return }
            if let p = progress, active?.steps.indices.contains(p.stepIndex) == true {
                if let line = guidanceLine(stepIndex: p.stepIndex, distanceM: p.distanceToManeuverM) { sayGuidance(line) }
            } else if let r = active, r.steps.count > 1, let line = guidanceLine(stepIndex: 1, distanceM: r.steps[0].distanceM, force: true) {
                /* No progress yet (the first seconds, just after a reroute): the first maneuver of the route. */
                voice.say(line)
            } else if NavText.isArabic(routerText) {
                /* Router narration only as a last resort, and never in another language
                 * (Valhalla narrates in English around Arabic street names). No clips: the
                 * device voice says it (`NavVoice.speak`), never silence. */
                voice.say(routerText, clips: [])
            }
        }
    }

    private func arrive() {
        phase = .arrived
        #if DEBUG
        NavLog.log("arrived at %@", target?.name ?? "-")
        #endif
        arrivedAt = Date()
        locator.stop()
        stopEngine()
        retryTask?.cancel()
        if offRoadTrip, let s = offRoadVoice.arrival(OffRoadContext()) {
            voice.say(s.navLine())
        } else {
            voice.say(auto ? "وصلتوا \(target?.name ?? "")" : "وصلت إلى \(target?.name ?? "وجهتك")", clips: [target?.source == .rally ? "start_07" : auto ? "arr_01" : "arr_02"])
        }
        UIApplication.shared.isIdleTimerDisabled = false
        if let t = target { onArrived(t) }
    }

    /// The last fix that steered the guidance (`isNewer`).
    private var lastIngested: DeviceFix?

    /// Two location streams feed the guidance (the app's own `location.lastFix`, re-sent on every
    /// location publish, and `NavLocator`): build 36 fed both straight in, so an older fix arriving
    /// after a newer one moved the progress BACK (the turn distance jumped up and down while the
    /// remaining distance lagged). Only a fix newer than the last one steers; a repeat is ignored.
    static func isNewer(_ f: DeviceFix, than last: DeviceFix?) -> Bool {
        guard let last else { return true }
        if f.atMs != last.atMs { return f.atMs > last.atMs }
        return f.lat != last.lat || f.lng != last.lng
    }

    /// Every GPS fix (the app's own, and our locator's in the off-road phase / local engine).
    func ingest(_ f: DeviceFix) {
        if phase == .guiding || phase == .offRoad {
            guard Self.isNewer(f, than: lastIngested) else { return }
            lastIngested = f
        }
        switch phase {
        case .guiding:
            engine?.ingest(f)
            checkAdherence(f)
        case .offRoad:
            guard let leg = offRoad else { return }
            let r = NavOffRoad.remaining(leg, me: LngLat(lng: f.lng, lat: f.lat))
            offRoadNow = (r.distanceM, r.bearing)
            if r.arrived { arrive() }
        default:
            break
        }
    }

    // MARK: route adherence (parallel carriageways)

    /// The new route's line, and how far the car already is from it: a router that put it on the
    /// other carriageway keeps that offset as an allowance instead of being flagged again and again.
    private func setRouteLine(_ r: NavRoute, near fix: DeviceFix? = nil) {
        let line = RouteLine(r.coordinates)
        routeLine = line
        offRoadTrip = OffRoadVoice.isOffRoadTrip(NavSurfaceKm.of(r.surfaceRuns, routeM: r.distanceM))
        adherenceHold = false
        var allowance = 0.0
        if let f = fix, let s = RouteAdherence.measure(f, on: line) {
            allowance = RouteAdherence.allowance(forCrossM: s.crossM, accuracy: f.accuracy)
        }
        adherence.reset(allowanceM: allowance)
    }

    /// Where along the route the car should be (from the last progress on THIS route), metres.
    private func expectedAlongM(_ line: RouteLine) -> Double? {
        guard let p = progress, progressRevision == routeRevision, let r = active, r.distanceM > 0 else { return nil }
        return line.length * max(0, min(1, 1 - p.distanceRemainingM / r.distanceM))
    }

    private func checkAdherence(_ f: DeviceFix) {
        guard let line = routeLine, !(engine is LocalGuidanceEngine) else { return }
        let change = adherence.note(f, on: line, expectedAlongM: expectedAlongM(line))
        #if DEBUG
        if change != nil { NavLog.log("adherence %@ cross=%.0f", String(describing: change!), adherence.last?.crossM ?? -1) }
        #endif
        if change == .on, adherenceHold, forceTask == nil {
            /* Back on the route by itself: the engine's numbers are good again. */
            adherenceHold = false
            rerouting = false
            reroutingSince = nil
        }
        if adherence.state == .off {
            if offRoadTrip { speakOffRoadDeviation(from: f) }
            forceReroute(from: f)
        }
    }

    /// The raw fix has been on another road than the route for a while: ask for a route from where the
    /// car is, with its course (so the carriageway it drives is the one chosen) and start it.
    private func forceReroute(from f: DeviceFix) {
        guard phase == .guiding, forceTask == nil, let t = target, let e = engine else { return }
        let now = Date()
        /* The SDK's own reroute is on its way: give it its few seconds first. */
        if !adherenceHold, let s = reroutingSince, now.timeIntervalSince(s) < Self.rerouteHoldS { return }
        forcedAt = forcedAt.filter { now.timeIntervalSince($0) < Self.forceWindowS }
        if let l = forcedAt.last, now.timeIntervalSince(l) < Self.forceGapS { return }
        if forcedAt.count >= Self.forceMax {
            /* Three tries and the router still puts the route there: accept it, never loop. */
            let cross = adherence.last?.crossM ?? 0
            adherence.reset(allowanceM: min(60, cross + 8))
            adherenceHold = false
            rerouting = false
            reroutingSince = nil
            return
        }
        forcedAt.append(now)
        adherenceHold = true
        if !rerouting { reroutingSince = now }
        rerouting = true
        let origin = LngLat(lng: f.lng, lat: f.lat)
        let heading = HeadingChooser.course(f)
        forceTask = Task { [weak self] in
            guard let self else { return }
            defer { self.forceTask = nil }
            let p = try? await self.provider.routes(NavRouteRequest(origin: origin, heading: heading, target: t, options: self.options))
            guard !Task.isCancelled, self.phase == .guiding, self.engine === e else { return }
            guard let p, let r = NavRouteChoice.order(p.routes, options: self.options).first else {
                /* No new route (offline, server): say so; the next fix tries again after the gap. */
                self.rerouting = false
                self.reroutingSince = nil
                self.toast("تعذّر حساب طريق جديد")
                return
            }
            self.plan = p
            do { try await e.start(route: r, plan: p, target: t) } catch {
                guard self.engine === e else { return }
                self.rerouting = false
                self.reroutingSince = nil
                return
            }
            guard !Task.isCancelled, self.phase == .guiding, self.engine === e else { return }
            self.progress = nil
            self.handle(.rerouted(r))
        }
    }

    /// Our own location stream (`NavLocator`) is running (tests: it must stop with the guidance).
    var isLocating: Bool { locator.running }

    func end() {
        fetchTask?.cancel()
        forceTask?.cancel()
        forceTask = nil
        retryTask?.cancel()
        stopEngine()
        locator.stop()
        voice.stop()
        reset()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }

    // MARK: off-road wording (build 49)

    private func offRoadContext(_ p: NavProgress?) -> OffRoadContext {
        OffRoadContext(distanceToManeuverM: p?.distanceToManeuverM, warningActive: false, now: Date())
    }

    private func sayOffRoad(_ s: OffRoadSpeech?) {
        guard let s else { return }
        voice.say(s.navLine(routeRevision: routeRevision))
    }

    /// The trip's first line, then the milestones («باقي ٢٠ كيلو على مسارك» …) and «رجعت على مسارك».
    private func speakOffRoadProgress(_ p: NavProgress) {
        guard offRoadTrip else { return }
        let ctx = offRoadContext(p)
        if !offRoadBegan {
            offRoadBegan = true
            sayOffRoad(offRoadVoice.begin(ctx))
        }
        sayOffRoad(offRoadVoice.progress(remainingM: p.distanceRemainingM, ctx))
        if offRoadVoice.deviationOpen, adherence.state == .on { sayOffRoad(offRoadVoice.backOnRoute(ctx)) }
    }

    /// Off the route: «ابتعدت عن مسارك، ارجع [الجهة]» from the raw fix and the route line, or «بعدت كثير عن مسارك».
    private func speakOffRoadDeviation(from fix: DeviceFix?) {
        guard offRoadTrip, let f = fix, let line = routeLine,
              let n = OffRoadGeometry.nearest(on: line.coords, from: LngLat(lng: f.lng, lat: f.lat)) else { return }
        sayOffRoad(offRoadVoice.deviation(crossM: n.distanceM, bearingToRoute: n.bearing, offRoadContext(progress)))
    }

    private func reset() {
        offRoadVoice.reset()
        offRoadBegan = false
        offRoadTrip = false
        phase = .idle
        routeLine = nil
        adherence.reset()
        adherenceHold = false
        forcedAt = []
        lastIngested = nil
        reroutingSince = nil
        progressRevision = 0
        progressAt = .distantPast
        progressSpeed = nil
        etaSmoother.reset()
        etaAnnouncer.reset()
        openingVoicePending = false
        budget.reset()
        matchedFix = nil
        target = nil
        routes = []
        selectedId = nil
        active = nil
        progress = nil
        offRoad = nil
        offRoadNow = nil
        rerouting = false
        loading = false
        error = nil
        direct = false
        plan = NavRoutePlan(routes: [])
        auto = false
        fallback = nil
        retryable = false
        retriesEnabled = false
        autoIntro = nil
    }

    // MARK: what the UI shows

    /// The progress the screen reads: only one measured on the route being driven (never the
    /// previous route's, in the moment between a reroute and the new route's first progress).
    var shownProgress: NavProgress? { progressRevision == routeRevision ? progress : nil }

    var currentStep: NavStep? {
        guard let r = active, let p = shownProgress, r.steps.indices.contains(p.stepIndex) else { return active?.steps.dropFirst().first }
        return r.steps[p.stepIndex]
    }

    var nextStep: NavStep? {
        guard let r = active else { return nil }
        let i = (shownProgress?.stepIndex ?? 1) + 1
        return r.steps.indices.contains(i) ? r.steps[i] : nil
    }

    /// How far the maneuver on the banner (`currentStep`) is. Without a progress yet (the start, just
    /// after a reroute) that is the first step's length — the road up to the first maneuver — not
    /// the length of the step AFTER it (what the banner showed before build 37).
    var maneuverDistanceM: Double? {
        guard let r = active else { return nil }
        if let p = shownProgress, r.steps.indices.contains(p.stepIndex) { return p.distanceToManeuverM }
        return r.steps.first?.distanceM
    }

    var etaDate: Date? {
        guard let s = remainingSeconds else { return nil }
        return Date().addingTimeInterval(s)
    }

    var remainingSeconds: Double? {
        if let p = shownProgress { return etaSmoother.remaining() ?? p.durationRemainingS }
        return active?.durationS
    }

    var remainingMeters: Double? {
        if phase == .offRoad { return offRoadNow?.distanceM ?? offRoad?.distanceM }
        let road = shownProgress?.distanceRemainingM ?? active?.distanceM
        return road.map { $0 + (offRoad?.distanceM ?? 0) }
    }

    var spoken: AnyPublisher<String, Never> { spokenSubject.eraseToAnyPublisher() }

    #if DEBUG
    /// Screenshots: put the session in a state without driving.
    func debugSet(phase: NavPhase, target: NavTarget, routes: [NavRoute], progress: NavProgress?, offRoad: NavOffRoadLeg?, rerouting: Bool = false, direct: Bool = false) {
        self.target = target
        self.routes = routes
        selectedId = routes.first?.id
        active = phase == .planning ? nil : routes.first
        self.progress = progress
        progressRevision = routeRevision
        self.offRoad = offRoad
        offRoadNow = offRoad.map { ($0.distanceM, $0.bearing) }
        self.rerouting = rerouting
        self.direct = direct
        self.phase = phase
        if phase == .arrived { arrivedAt = Date() }
    }

    /// UI tests: arrive at the current target as if driven there (the real `arrive()` path).
    func debugArrive() {
        guard phase == .guiding || phase == .offRoad else { return }
        arrive()
    }
    #endif
}

/// Our own location stream for the off-road last leg (and the local engine):
/// the Mapbox engine is idle by then, and the leg must keep working locked.
/// Runs only between «ابدأ الملاحة» and arrival / «إنهاء»; never sent anywhere.
@MainActor
final class NavLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onFix: (DeviceFix) -> Void = { _ in }
    private(set) var running = false
    /// Stale, coarse and teleporting fixes never steer the last leg (`FixQualityGate`).
    private var gate = FixQualityGate(keepsFirstStale: false)

    override init() {
        super.init()
        manager.delegate = self
        /* Guidance: the best the chip can do (Apple: BestForNavigation while navigating), the
         * generic navigation model (no road snapping off-road), no distance filter, never paused. */
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !running else { return }
        running = true
        if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes").flatMap({ $0 as? [String] })?.contains("location") == true {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        gate.reset()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationTuning.deviceFix)
        Task { @MainActor in
            let now = Date().timeIntervalSince1970 * 1000
            for f in fixes { if case let .accept(ok) = self.gate.judge(f, nowMs: now) { self.onFix(ok) } }
        }
    }
}

/// «الملاحة» in one line for the Lock Screen / Dynamic Island (the widget cannot link `NavText`).
struct NavActivityLine: Equatable {
    var text: String
    var symbol: String
    var arrived = false
}

extension NavSession {
    var activityLine: NavActivityLine? {
        switch phase {
        case .guiding:
            if rerouting { return NavActivityLine(text: "نعيد حساب الطريق…", symbol: "arrow.triangle.2.circlepath") }
            guard let step = currentStep else { return nil }
            let d = maneuverDistanceM ?? step.distanceM
            let inD = NavText.inDistance(d).map { $0 + " " } ?? ""
            return NavActivityLine(text: inD + NavText.instruction(step, targetName: target?.name), symbol: NavGlyph.symbol(step.maneuver))
        case .offRoad:
            guard let leg = offRoad else { return nil }
            return NavActivityLine(text: NavOffRoad.line(leg, remainingM: offRoadNow?.distanceM, bearing: offRoadNow?.bearing, fallback: fallback),
                                   symbol: "location.north.fill")
        case .arrived:
            return NavActivityLine(text: "\(auto ? "وصلتوا" : "وصلت") \(target?.name ?? "")", symbol: "flag.checkered", arrived: true)
        case .idle, .planning:
            return nil
        }
    }
}
