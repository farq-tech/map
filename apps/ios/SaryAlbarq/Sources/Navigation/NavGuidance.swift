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
    /// Say this now.
    case speak(String)
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

    /// Off the line by more than this, three fixes in a row (accuracy permitting): reroute.
    static let offRouteM = 50.0

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

    /// Where `p` is on the line: along-distance, lateral offset, segment.
    static func locate(_ p: LngLat, in c: [LngLat], cum: [Double], from: Int = 0) -> (along: Double, offset: Double, index: Int) {
        guard c.count >= 2 else { return (0, c.first.map { Vehicle.distanceMeters($0, p) } ?? 0, 0) }
        var best = (d: Double.infinity, s: 0.0, i: 0)
        /* Search ahead of where we were (and a little behind): a route can pass the same place twice. */
        let lo = max(0, from - 5), hi = c.count - 1
        for i in lo..<hi {
            let pr = TrailGeo.project(p, c[i], c[i + 1])
            if pr.distM < best.d { best = (pr.distM, cum[i] + pr.u * (cum[i + 1] - cum[i]), i) }
        }
        return (best.s, best.d, best.i)
    }

    /// Progress at along-distance `s` (pure, for tests).
    static func progress(route r: NavRoute, stepAlong: [Double], total: Double, at s: Double) -> NavProgress {
        let next = stepAlong.firstIndex(where: { $0 > s + 1 }) ?? max(0, r.steps.count - 1)
        let toManeuver = max(0, (next < stepAlong.count ? stepAlong[next] : total) - s)
        let remaining = max(0, total - s)
        let dur = total > 0 ? r.durationS * remaining / total : 0
        let limit = next > 0 && next - 1 < r.steps.count ? r.steps[next - 1].speedLimitKmh : nil
        return NavProgress(stepIndex: next, distanceToManeuverM: toManeuver, distanceRemainingM: remaining, durationRemainingS: dur, speedLimitKmh: limit)
    }

    func ingest(_ fix: DeviceFix) {
        guard let r = route, r.coordinates.count >= 2, !arrived else { return }
        let me = LngLat(lng: fix.lng, lat: fix.lat)
        let loc = Self.locate(me, in: r.coordinates, cum: cum, from: lastIndex)
        let total = cum.last ?? 0
        /* Off the route: only with a usable fix, and three in a row (one bad reading is not a detour). */
        let tolerance = Self.offRouteM + min(40, fix.accuracy ?? 10)
        if loc.offset > tolerance {
            offCount += 1
            if offCount >= 3, !rerouting { startReroute(me, heading: fix.heading) }
            return
        }
        offCount = 0
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
        let cues: [NavSpoken] = step.spoken.isEmpty
            ? [800.0, 250, 40].map { NavSpoken(distanceBeforeManeuver: $0, text: "") }
            : step.spoken
        for (k, cue) in cues.enumerated() where p.distanceToManeuverM <= cue.distanceBeforeManeuver {
            let key = "\(p.stepIndex):\(k)"
            guard !spokenKeys.contains(key) else { continue }
            /* Say only the nearest cue that is due (skip earlier ones we drove past). */
            for j in 0...k { spokenKeys.insert("\(p.stepIndex):\(j)") }
            let next = cues.indices.contains(k + 1) && p.distanceToManeuverM <= cues[k + 1].distanceBeforeManeuver
            if next { continue }
            onEvent(.speak(NavText.spoken(step, distanceM: p.distanceToManeuverM)))
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
                self.onEvent(.rerouteFailed("تعذّر حساب طريق جديد"))
            }
        }
    }
}
