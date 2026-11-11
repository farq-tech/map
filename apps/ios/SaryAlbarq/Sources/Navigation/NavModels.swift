import Foundation

// Turn-by-turn navigation «الملاحة»: plain data shared by the routing provider,
// the guidance engine, the UI and CarPlay. Nothing here imports Mapbox: a route
// from Mapbox today and from the company's own Valhalla later look the same.

/// Where «ابدأ الملاحة» was started from.
enum NavTargetSource: String, Equatable, CaseIterable {
    /// The plan's «الوجهة» (`OutingDestination`).
    case destination
    /// «نقطة التجمع».
    case rally
    /// A point picked on the map (long press) or found by search.
    case point
    /// «روح له»: a member's last LIVE position.
    case member
    /// The end of the plan's drawn route.
    case planRouteEnd
    /// A planned stop on the way to the destination (`TripPlan.stops`, automatic guidance).
    case tripStop
    /// «اتجه» on a silent member's card: where they were LAST SEEN (stale by definition, labelled so).
    case lastKnown
}

/// A place to drive to.
struct NavTarget: Equatable {
    var source: NavTargetSource
    var name: String
    var position: LngLat
    /// The member's id for `.member` (to tell them apart, and to say «تحرّك» later).
    var memberId: String? = nil
    /// `.lastKnown`: when that fix was taken. Shown as «آخر موقع معروف · قبل ١٤ د», never as live.
    var lastKnownAt: Date? = nil

    /// «آخر موقع معروف · قبل ١٤ د» for a last-known target, else nil.
    func staleNote(now: Date = Date()) -> String? {
        guard source == .lastKnown else { return nil }
        guard let at = lastKnownAt else { return "آخر موقع معروف" }
        return "آخر موقع معروف · \(SilenceText.ago(at, now: now))"
    }
}

/// Why a target cannot be used.
enum NavRefusal: Error, Equatable {
    /// The member's last fix is old: we never drive anyone to where somebody *was*.
    case memberStale(name: String, since: Date)
    /// The member is not sharing, or has no fix at all.
    case memberHidden(name: String)
    /// That's me.
    case isMe
    /// No GPS fix of my own yet.
    case noFix
    case missing

    var message: String {
        switch self {
        case let .memberStale(name, _): return "موقع \(name) قديم، ما نوجّهك لمكان ممكن تغيّر. اطلب منه يشارك موقعه."
        case let .memberHidden(name): return "\(name) ما يشارك موقعه الآن."
        case .isMe: return "هذا موقعك أنت."
        case .noFix: return "ننتظر موقعك لنحسب الطريق."
        case .missing: return "ما فيه نقطة محددة."
        }
    }
}

/// The route options sheet: «أسرع»، «تجنّب الطرق الترابية». (No toll roads in KSA, so `avoidTolls` stays off and is not shown.)
struct NavRouteOptions: Equatable {
    /// On: the traffic-aware fastest route. Off: the shortest of the returned routes.
    var fastest = true
    var avoidUnpaved = false
    var avoidTolls = false

    static let defaultsKey = "sary.nav.options.v1"

    static func load(_ d: UserDefaults = .standard) -> NavRouteOptions {
        guard let a = d.array(forKey: defaultsKey) as? [Bool], a.count == 3 else { return .init() }
        return .init(fastest: a[0], avoidUnpaved: a[1], avoidTolls: false)
    }

    func save(_ d: UserDefaults = .standard) { d.set([fastest, avoidUnpaved, avoidTolls], forKey: Self.defaultsKey) }
}

/// What a turn looks like (the banner arrow, the voice, CarPlay's `CPManeuver`).
enum NavManeuverKind: String, Equatable {
    case depart, turn, `continue`, newName, merge, onRamp, offRamp, fork, endOfRoad, useLane
    case roundabout, exitRoundabout, notification, arrive
}

enum NavTurnDirection: String, Equatable {
    case sharpRight, right, slightRight, straight, slightLeft, left, sharpLeft, uTurn
}

struct NavManeuver: Equatable {
    var kind: NavManeuverKind
    var direction: NavTurnDirection?
    /// Roundabout exit (1-based).
    var exit: Int? = nil
    /// The exit taken is the roundabout's last one before coming back round («خذ المخرج الأخير»).
    var lastExit = false
}

/// One lane at the next maneuver (`approachLanes` in Directions / Valhalla `lanes`).
struct NavLane: Equatable {
    /// Arrows painted on the lane.
    var directions: [NavTurnDirection]
    /// This lane leads where the route goes.
    var valid: Bool
    /// The best lane to be in (when the router says).
    var preferred: Bool = false
}

/// A spoken instruction, fired when `distanceAlongStep` remains before the maneuver.
struct NavSpoken: Equatable {
    var distanceBeforeManeuver: Double
    var text: String
}

/// One step: drive `distanceM` along the road, then do `maneuver` at its end.
///
/// Like Directions' `RouteStep`, a step's maneuver is at its START point; we keep
/// that shape (`location` = where the maneuver happens) so a provider maps 1:1.
struct NavStep: Equatable {
    var maneuver: NavManeuver
    /// The road the maneuver leads onto («طريق الملك فهد»), when named.
    var roadName: String?
    /// Exit / destination sign text when there is no road name.
    var signText: String? = nil
    /// The router's own text in Arabic (`language: ar`), kept for the step list.
    var routerText: String? = nil
    /// Where the maneuver happens.
    var location: LngLat
    /// Length of this step (from its maneuver to the next one), metres.
    var distanceM: Double
    var durationS: Double
    var lanes: [NavLane] = []
    var spoken: [NavSpoken] = []
    /// Posted maximum speed on this step, km/h, when the router knows.
    var speedLimitKmh: Int? = nil
}

/// A distance/time leg in a route whose segments have different expected speeds.
struct NavRouteTimingLeg: Equatable {
    var distanceM: Double
    var durationS: Double
}

enum NavSurfaceKind: String, Equatable {
    case paved
    case unpaved
    /// A cost-grid path through open, easy terrain (firm ground, flat sand), not a mapped road or track.
    case terrain
    /// A cost-grid path through rough ground: dune crests, rock, sabkha or a wadi bed.
    case rough
    /// Short, approximate join from an exact provider coordinate to a cost-grid cell center.
    /// Drawn dashed so it is never mistaken for a mapped road or verified trail.
    case gridSnap
}

struct NavSurfaceRun: Equatable {
    var kind: NavSurfaceKind
    var coordinates: [LngLat]
}

/// A route between me and a target, provider-agnostic.
struct NavRoute: Equatable, Identifiable {
    var id: String
    var coordinates: [LngLat]
    /// Stable for copies of this route value; a newly constructed route gets a new token. Consumers
    /// that need a cheap geometry-change signal (for example PiP snapshot equality) must not scan
    /// the entire polyline on every SwiftUI body evaluation.
    let geometryRevision = UUID()
    var distanceM: Double
    var durationS: Double
    var steps: [NavStep]
    /// Uses unpaved / toll roads (when the router says).
    var hasUnpaved = false
    var hasTolls = false
    /// A few road names the route is mostly on («عبر طريق الملك فهد»).
    var via: String? = nil
    /// Traffic on each segment (`coordinates[i]`→`coordinates[i+1]`), from Mapbox `driving-traffic`
    /// congestion annotations. Nil off the traffic profile (Valhalla, the desert): one colour.
    var congestion: [NavCongestion]? = nil
    /// Optional piecewise travel-time model; nil keeps the route-wide average.
    var timingProfile: [NavRouteTimingLeg]? = nil
    /// Segment geometry and surface source where the provider can establish it.
    var surfaceRuns: [NavSurfaceRun] = []
    /// A hybrid road + desert route: where its street part stops being paved (the city ↔
    /// desert junction; `ReturnRoute.roadEnd`). Nil elsewhere. Not part of equality.
    var roadEnd: LngLat? = nil

    var end: LngLat? { coordinates.last }
    var start: LngLat? { coordinates.first }

    static func == (a: NavRoute, b: NavRoute) -> Bool {
        a.id == b.id && a.distanceM == b.distanceM && a.durationS == b.durationS &&
        a.coordinates.count == b.coordinates.count && a.timingProfile == b.timingProfile && a.surfaceRuns == b.surfaceRuns
    }
}

/// Derived route geometry, computed once per `NavRoute.geometryRevision` instead of on every
/// progress tick / SwiftUI body evaluation. The live map cut its line, its traffic runs and its
/// surface runs with a fresh haversine pass over the whole polyline on every redraw; with a
/// cached cumulative table each cut is a binary search plus the copy of what is left.
///
/// Values are bit-identical to the old loops: the table holds exactly the running sums those
/// loops built (`acc += Vehicle.distanceMeters(a, b)`, in order).
enum NavRouteMetrics {
    struct Tables {
        /// Running metres at every route vertex.
        var cum: [Double]
        /// Per surface run, the running metres (across runs, as `NavSurface.remaining` counts them)
        /// at each of its vertices; empty for a run with fewer than two points.
        var surfaceCum: [[Double]]
    }

    private static let lock = NSLock()
    /// A few recent routes (the active one, its alternatives while planning).
    private static var cache: [(id: UUID, tables: Tables)] = []
    private static let capacity = 6

    /// Running metres at every vertex: `cum[0] = 0`, `cum[i] = cum[i-1] + d(c[i-1], c[i])`.
    static func cumulative(_ c: [LngLat]) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(max(1, c.count))
        out.append(0)
        var acc = 0.0
        if c.count > 1 {
            for i in 1..<c.count {
                acc += Vehicle.distanceMeters(c[i - 1], c[i])
                out.append(acc)
            }
        }
        return out
    }

    /// The running sums `NavSurface.remaining` builds while it walks the runs in order.
    static func surfaceCumulative(_ runs: [NavSurfaceRun]) -> [[Double]] {
        var acc = 0.0
        return runs.map { run in
            guard run.coordinates.count >= 2 else { return [] }
            var out = [Double]()
            out.reserveCapacity(run.coordinates.count)
            out.append(acc)
            for (a, b) in zip(run.coordinates, run.coordinates.dropFirst()) {
                acc += Vehicle.distanceMeters(a, b)
                out.append(acc)
            }
            return out
        }
    }

    /// The tables of `r`, cached by its geometry revision.
    static func tables(_ r: NavRoute) -> Tables {
        lock.lock()
        if let hit = cache.first(where: { $0.id == r.geometryRevision })?.tables,
           hit.cum.count == max(1, r.coordinates.count), hit.surfaceCum.count == r.surfaceRuns.count {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let t = Tables(cum: cumulative(r.coordinates), surfaceCum: surfaceCumulative(r.surfaceRuns))
        lock.lock()
        cache.removeAll { $0.id == r.geometryRevision }
        cache.append((r.geometryRevision, t))
        if cache.count > capacity { cache.removeFirst(cache.count - capacity) }
        lock.unlock()
        return t
    }

    /// The cumulative table of `r`, cached by its geometry revision.
    static func cumulative(_ r: NavRoute) -> [Double] { tables(r).cum }

    /// The first vertex index `i` in `1..<cum.count` with `cum[i] >= done` (nil: none), the same
    /// index a forward scan `if acc + seg >= done` finds, because `cum` never decreases.
    static func firstIndex(atLeast done: Double, in cum: [Double]) -> Int? {
        guard cum.count > 1 else { return nil }
        var lo = 1, hi = cum.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] >= done { hi = mid } else { lo = mid + 1 }
        }
        return lo < cum.count ? lo : nil
    }

    /// The part of the route still ahead (the line shrinks behind the car): the live map's and the
    /// standalone screen's cut, without re-measuring the travelled part on every redraw.
    static func remaining(_ r: NavRoute, progress: NavProgress?) -> [LngLat] {
        guard let p = progress, r.distanceM > 0, r.coordinates.count > 2 else { return r.coordinates }
        let done = max(0, r.distanceM - p.distanceRemainingM)
        let cum = cumulative(r)
        guard let i = firstIndex(atLeast: done, in: cum) else { return Array(r.coordinates.suffix(2)) }
        let a = r.coordinates[i - 1], b = r.coordinates[i]
        let seg = Vehicle.distanceMeters(a, b)
        let u = seg > 0 ? (done - cum[i - 1]) / seg : 0
        return [LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)] + r.coordinates[i...]
    }
}

/// What a provider returns: routes (best first) plus an opaque handle the
/// matching guidance engine understands (Mapbox: `NavigationRoutes`).
struct NavRoutePlan {
    var routes: [NavRoute]
    var native: AnyObject? = nil
}

/// Where I am on the route right now.
struct NavProgress: Equatable {
    var stepIndex: Int
    /// To the next maneuver (the end of the current step).
    var distanceToManeuverM: Double
    var distanceRemainingM: Double
    var durationRemainingS: Double
    /// Speed limit here, km/h, when known (Mapbox map matching, else the step's).
    var speedLimitKmh: Int? = nil
}

/// The straight-line remainder when the target is off the road network (desert).
struct NavOffRoadLeg: Equatable {
    /// Where the road ends (the route's last point).
    var from: LngLat
    /// The real target.
    var to: LngLat
    var distanceM: Double
    /// From `from` to `to`, degrees clockwise from north.
    var bearing: Double
}

/// Traffic on a stretch of road, as Mapbox's congestion annotation says (numeric 0–100 → the
/// SDK's default bands: <40 low, <60 moderate, <80 heavy, else severe).
enum NavCongestion: Int, Equatable {
    case unknown = 0, low, moderate, heavy, severe

    init(numeric v: Int?) {
        guard let v else { self = .unknown; return }
        switch v {
        case ..<40: self = .low
        case ..<60: self = .moderate
        case ..<80: self = .heavy
        default: self = .severe
        }
    }

    /// The map's line colour group: 0 = the normal route blue (low / unknown), then orange, red, dark red.
    var band: Int {
        switch self {
        case .unknown, .low: return 0
        case .moderate: return 1
        case .heavy: return 2
        case .severe: return 3
        }
    }
}

/// A run of the remaining route in one traffic band (what the map draws, one feature per run).
struct NavTrafficRun: Equatable {
    var band: Int
    var coordinates: [LngLat]
}

enum NavTraffic {
    /// The route from `done` metres on, cut into runs of equal band. Nil when the annotation does
    /// not fit the line (then the map draws one plain colour, never a wrong one).
    /// `cum`: the route's cumulative metres (`NavRouteMetrics`), when the caller has them: the
    /// travelled part is skipped by binary search instead of re-measured. Same result either way.
    static func runs(_ coords: [LngLat], congestion: [NavCongestion]?, from done: Double, cum: [Double]? = nil) -> [NavTrafficRun]? {
        guard let c = congestion, coords.count >= 2, c.count == coords.count - 1 else { return nil }
        guard c.contains(where: { $0.band > 0 }) else { return nil }
        var out: [NavTrafficRun] = []
        var acc = 0.0
        var start = 0
        if let cum, cum.count == coords.count {
            /* The first segment the old loop did not skip: the first i with cum[i + 1] > done. */
            var lo = 0, hi = coords.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cum[mid + 1] > done { hi = mid } else { lo = mid + 1 }
            }
            start = lo
            acc = cum[lo]
        }
        func add(_ band: Int, _ a: LngLat, _ b: LngLat) {
            if var last = out.last, last.band == band, last.coordinates.last == a {
                last.coordinates.append(b)
                out[out.count - 1] = last
            } else {
                out.append(NavTrafficRun(band: band, coordinates: [a, b]))
            }
        }
        for i in start..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let seg = Vehicle.distanceMeters(a, b)
            defer { acc += seg }
            if acc + seg <= done { continue }
            var from = a
            if acc < done, seg > 0 {
                let u = (done - acc) / seg
                from = LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
            }
            add(c[i].band, from, b)
        }
        return out.isEmpty ? nil : out
    }
}

enum NavSurface {
    /// The surface runs from `done` metres along the route on (runs follow the route in order):
    /// the travelled part is dropped and the run under the car is cut where it is, as
    /// `NavTraffic.runs` does for traffic.
    /// `cum`: `NavRouteMetrics.surfaceCumulative(runs)` (cached per route), when the caller has it:
    /// the travelled runs and segments are skipped by lookup instead of re-measured. Same result.
    static func remaining(_ runs: [NavSurfaceRun], from done: Double, cum: [[Double]]? = nil) -> [NavSurfaceRun] {
        guard done > 0 else { return runs }
        if let cum, cum.count == runs.count,
           zip(runs, cum).allSatisfy({ $0.coordinates.count < 2 ? $1.isEmpty : $1.count == $0.coordinates.count }) {
            return remaining(runs, from: done, table: cum)
        }
        var out: [NavSurfaceRun] = []
        var acc = 0.0
        for run in runs where run.coordinates.count >= 2 {
            if acc >= done { out.append(run); continue }
            var cut: [LngLat] = []
            for (a, b) in zip(run.coordinates, run.coordinates.dropFirst()) {
                let seg = Vehicle.distanceMeters(a, b)
                defer { acc += seg }
                if !cut.isEmpty { cut.append(b); continue }
                if acc + seg <= done { continue }
                var from = a
                if acc < done, seg > 0 {
                    let u = (done - acc) / seg
                    from = LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
                }
                cut = [from, b]
            }
            if cut.count >= 2 { out.append(NavSurfaceRun(kind: run.kind, coordinates: cut)) }
        }
        return out
    }

    /// `remaining` with the running sums looked up: `table[k][j]` is the `acc` the loop above holds
    /// before segment `j` of run `k` (bit-identical: the same additions in the same order).
    private static func remaining(_ runs: [NavSurfaceRun], from done: Double, table: [[Double]]) -> [NavSurfaceRun] {
        var out: [NavSurfaceRun] = []
        for (k, run) in runs.enumerated() where run.coordinates.count >= 2 {
            let c = table[k], pts = run.coordinates
            if c[0] >= done { out.append(run); continue }
            /* The first segment not wholly travelled: the first j with c[j + 1] > done. */
            var lo = 0, hi = pts.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if c[mid + 1] > done { hi = mid } else { lo = mid + 1 }
            }
            guard lo < pts.count - 1 else { continue }
            let a = pts[lo], b = pts[lo + 1]
            let seg = Vehicle.distanceMeters(a, b)
            var from = a
            if c[lo] < done, seg > 0 {
                let u = (done - c[lo]) / seg
                from = LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
            }
            out.append(NavSurfaceRun(kind: run.kind, coordinates: [from] + pts[(lo + 1)...]))
        }
        return out
    }
}
