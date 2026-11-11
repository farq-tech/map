import Foundation

/// What a guidance engine reports while driving a route.
enum NavGuidanceEvent: Equatable {
    case progress(NavProgress)
    /// Left the route: a new one is being fetched.
    case offRoute
    /// The new main route after an off-route reroute.
    case rerouted(NavRoute)
    case rerouteFailed(String)
    /// Reached the route's last point (the target, or where the road ends).
    case arrivedAtRouteEnd
    /// Say this now (the text for «صوت الجهاز», the clips for «صوت سرى»).
    case speak(NavLine)
    /// The router says now is the time for a voice cue (its own text as a fallback):
    /// we say our own Arabic line for the current maneuver, same wording as the banner.
    case cue(String)
}

/// Follows one route and reports progress. Mapbox's engine (map matching, reroute,
/// voice timing from the Directions response) or our own `LocalGuidanceEngine`.
@MainActor
protocol NavGuidanceEngine: AnyObject {
    var onEvent: (NavGuidanceEvent) -> Void { get set }
    /// Start on `route` (one of `plan.routes`).
    func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws
    func stop()
    /// The app's own GPS fixes. The Mapbox engine has its own location and ignores them.
    func ingest(_ fix: DeviceFix)
}

/// Provider-independent guidance: projects my GPS fixes onto the route polyline.
/// Used for routes that carry no Mapbox handle (Valhalla later), the demo, and tests.
@MainActor
final class LocalGuidanceEngine: NavGuidanceEngine {
    var onEvent: (NavGuidanceEvent) -> Void = { _ in }
    /// Asked for a new route from here when I am off the route.
    var reroute: ((LngLat, Double?) async -> NavRoute?)?

    private(set) var route: NavRoute?
    private var cum: [Double] = []
    private var stepAlong: [Double] = []
    private var lastIndex = 0
    private var offCount = 0
    private var rerouting = false
    private var spokenKeys = Set<String>()
    private var arrived = false
    private var lastSpeed: Double?
    /// Failed reroutes in a row, and no new attempt before this time (`rerouteBackoffS`).
    private var failedReroutes = 0
    private var rerouteNotBefore = Date.distantPast
    /// The clock (tests move it).
    var now: () -> Date = Date.init

    /// Off the line by more than this, three fixes in a row (accuracy permitting): reroute.
    static let offRouteM = 50.0

    /// The wait after `failures` failed reroutes in a row before the next try: 5, 10, 20, 40, then
    /// 60 s. Offline in the desert a reroute never succeeds, and every attempt ran the whole routing
    /// chain (network request, three desert A* searches) again three fixes later, about every 3 s.
    static func rerouteBackoffS(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60, 5 * pow(2, Double(min(failures, 8) - 1)))
    }

    func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws {
        load(route)
    }

    func stop() {
        route = nil
        reroute = nil
    }

    func load(_ r: NavRoute) {
        route = r
        cum = Self.cumulative(r.coordinates)
        stepAlong = r.steps.map { Self.along(of: $0.location, in: r.coordinates, cum: cum) }
        lastIndex = 0
        offCount = 0
        spokenKeys = []
        arrived = false
        failedReroutes = 0
        rerouteNotBefore = .distantPast
    }

    static func cumulative(_ c: [LngLat]) -> [Double] {
        var out = [0.0]
        for i in 1..<max(1, c.count) { out.append(out[i - 1] + Vehicle.distanceMeters(c[i - 1], c[i])) }
        return out
    }

    /// Distance along the line of the vertex nearest to `p`.
    static func along(of p: LngLat, in c: [LngLat], cum: [Double]) -> Double {
        guard c.count >= 2 else { return 0 }
        var best = (d: Double.infinity, s: 0.0)
        for i in 0..<(c.count - 1) {
            let pr = TrailGeo.project(p, c[i], c[i + 1])
            if pr.distM < best.d { best = (pr.distM, cum[i] + pr.u * (cum[i + 1] - cum[i])) }
        }
        return best.s
    }

    /// How far past the last matched segment `locate` looks first (one fix a second at 140 km/h
    /// is ~40 m; this leaves room for long GPS gaps before the full scan is needed).
    static let searchAheadM = 2_000.0

    /// Where `p` is on the line: along-distance, lateral offset, segment.
    ///
    /// Per fix this used to project onto every segment from `from` to the END of the route (a long
    /// desert route is thousands of segments, every second, on the main thread). It now searches a
    /// window of `searchAheadM` ahead first and keeps that match when it is on the route
    /// (≤ `offRouteM`); otherwise (a GPS gap, a jump, really off the route) it falls back to the
    /// full forward scan, exactly as before. The only case that differs is a route that passes
    /// within `offRouteM` of the same place again more than `searchAheadM` later: the old scan
    /// could jump ahead to that later pass; the window keeps the continuous one.
    static func locate(_ p: LngLat, in c: [LngLat], cum: [Double], from: Int = 0) -> (along: Double, offset: Double, index: Int) {
        guard c.count >= 2 else { return (0, c.first.map { Vehicle.distanceMeters($0, p) } ?? 0, 0) }
        /* Search ahead of where we were (and a little behind): a route can pass the same place twice. */
        let lo = min(max(0, from - 5), c.count - 2), hi = c.count - 1
        func scan(_ range: Range<Int>) -> (d: Double, s: Double, i: Int) {
            var best = (d: Double.infinity, s: 0.0, i: 0)
            for i in range {
                let pr = TrailGeo.project(p, c[i], c[i + 1])
                if pr.distM < best.d { best = (pr.distM, cum[i] + pr.u * (cum[i + 1] - cum[i]), i) }
            }
            return best
        }
        let end = Self.windowEnd(cum: cum, from: min(max(0, from), hi), lo: lo, hi: hi)
        if end < hi {
            let near = scan(lo..<end)
            if near.d <= offRouteM { return (near.s, near.d, near.i) }
        }
        let best = scan(lo..<hi)
        return (best.s, best.d, best.i)
    }

    /// The (exclusive) last segment of the first search window: segments starting no more than
    /// `searchAheadM` along the line past vertex `from` (at least one past `lo`, at most `hi`).
    static func windowEnd(cum: [Double], from: Int, lo: Int, hi: Int) -> Int {
        guard cum.count > hi, from < cum.count else { return hi }
        let limit = cum[from] + searchAheadM
        /* First vertex index past the limit (`cum` never decreases). */
        var a = from, b = hi
        while a < b {
            let mid = (a + b) / 2
            if cum[mid] > limit { b = mid } else { a = mid + 1 }
        }
        return min(hi, max(lo + 1, a + 1))
    }

    /// Progress at along-distance `s` (pure, for tests).
    static func progress(route r: NavRoute, stepAlong: [Double], total: Double, at s: Double) -> NavProgress {
        let next = stepAlong.firstIndex(where: { $0 > s + 1 }) ?? max(0, r.steps.count - 1)
        let toManeuver = max(0, (next < stepAlong.count ? stepAlong[next] : total) - s)
        let remaining = max(0, total - s)
        let dur: Double
        if total <= 0 {
            dur = 0
        } else if let profile = r.timingProfile, !profile.isEmpty {
            dur = remainingDuration(profile: profile, traveledM: s)
        } else {
            dur = r.durationS * remaining / total
        }
        let limit = next > 0 && next - 1 < r.steps.count ? r.steps[next - 1].speedLimitKmh : nil
        return NavProgress(stepIndex: next, distanceToManeuverM: toManeuver, distanceRemainingM: remaining, durationRemainingS: dur, speedLimitKmh: limit)
    }

    /// Preserves separate road/desert speeds as the driver advances along a hybrid route.
    static func remainingDuration(profile: [NavRouteTimingLeg], traveledM: Double) -> Double {
        var traveled = max(0, traveledM)
        var remaining = 0.0
        for leg in profile where leg.distanceM > 0 && leg.durationS > 0 {
            let consumed = min(leg.distanceM, traveled)
            remaining += leg.durationS * (leg.distanceM - consumed) / leg.distanceM
            traveled = max(0, traveled - leg.distanceM)
        }
        return remaining
    }

    func ingest(_ fix: DeviceFix) {
        guard let r = route, r.coordinates.count >= 2, !arrived else { return }
        lastSpeed = fix.speed
        let me = LngLat(lng: fix.lng, lat: fix.lat)
        let loc = Self.locate(me, in: r.coordinates, cum: cum, from: lastIndex)
        let total = cum.last ?? 0
        /* Off the route: only with a usable fix, and three in a row (one bad reading is not a detour). */
        let tolerance = Self.offRouteM + min(40, fix.accuracy ?? 10)
        if loc.offset > tolerance {
            offCount += 1
            if offCount >= 3, !rerouting, now() >= rerouteNotBefore { startReroute(me, heading: fix.heading) }
            return
        }
        offCount = 0
        /* Back on the route: a later detour is a new one, not a retry of the failed one. */
        failedReroutes = 0
        rerouteNotBefore = .distantPast
        lastIndex = loc.index
        let p = Self.progress(route: r, stepAlong: stepAlong, total: total, at: loc.along)
        onEvent(.progress(p))
        speakIfDue(r, p)
        if p.distanceRemainingM < 25 {
            arrived = true
            onEvent(.arrivedAtRouteEnd)
        }
    }

    private func speakIfDue(_ r: NavRoute, _ p: NavProgress) {
        guard p.stepIndex < r.steps.count else { return }
        let step = r.steps[p.stepIndex]
        /* No router voice timing: ours from my speed (time ahead, not only distance). */
        let cues: [NavSpoken] = step.spoken.isEmpty
            ? NavCueBands.distances(speedMps: lastSpeed, unpaved: r.hasUnpaved).map { NavSpoken(distanceBeforeManeuver: $0, text: "") }
            : step.spoken
        for (k, cue) in cues.enumerated() where p.distanceToManeuverM <= cue.distanceBeforeManeuver {
            let key = "\(p.stepIndex):\(k)"
            guard !spokenKeys.contains(key) else { continue }
            /* Say only the nearest cue that is due (skip earlier ones we drove past). */
            for j in 0...k { spokenKeys.insert("\(p.stepIndex):\(j)") }
            let next = cues.indices.contains(k + 1) && p.distanceToManeuverM <= cues[k + 1].distanceBeforeManeuver
            if next { continue }
            onEvent(.speak(NavLine(NavText.spoken(step, distanceM: p.distanceToManeuverM), clips: SaryVoiceScript.step(step, distanceM: p.distanceToManeuverM),
                                   maneuverID: String(p.stepIndex))))
        }
    }

    private func startReroute(_ me: LngLat, heading: Double?) {
        guard let reroute else { return }
        rerouting = true
        onEvent(.offRoute)
        Task { [weak self] in
            let new = await reroute(me, heading)
            guard let self else { return }
            self.rerouting = false
            if let new {
                self.load(new)
                self.onEvent(.rerouted(new))
            } else {
                self.offCount = 0
                self.failedReroutes += 1
                self.rerouteNotBefore = self.now().addingTimeInterval(Self.rerouteBackoffS(failures: self.failedReroutes))
                self.onEvent(.rerouteFailed("تعذّر حساب طريق جديد"))
            }
        }
    }
}
