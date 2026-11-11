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
        case .noFix: return "ننتظر موقعك من GPS لنحسب الطريق."
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
    /// A cost-grid path through terrain, not a mapped road or track.
    case terrain
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
    static func runs(_ coords: [LngLat], congestion: [NavCongestion]?, from done: Double) -> [NavTrafficRun]? {
        guard let c = congestion, coords.count >= 2, c.count == coords.count - 1 else { return nil }
        guard c.contains(where: { $0.band > 0 }) else { return nil }
        var out: [NavTrafficRun] = []
        var acc = 0.0
        func add(_ band: Int, _ a: LngLat, _ b: LngLat) {
            if var last = out.last, last.band == band, last.coordinates.last == a {
                last.coordinates.append(b)
                out[out.count - 1] = last
            } else {
                out.append(NavTrafficRun(band: band, coordinates: [a, b]))
            }
        }
        for i in 0..<(coords.count - 1) {
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
    static func remaining(_ runs: [NavSurfaceRun], from done: Double) -> [NavSurfaceRun] {
        guard done > 0 else { return runs }
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
}
