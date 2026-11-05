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
}

/// A place to drive to.
struct NavTarget: Equatable {
    var source: NavTargetSource
    var name: String
    var position: LngLat
    /// The member's id for `.member` (to tell them apart, and to say «تحرّك» later).
    var memberId: String? = nil
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

/// A route between me and a target, provider-agnostic.
struct NavRoute: Equatable, Identifiable {
    var id: String
    var coordinates: [LngLat]
    var distanceM: Double
    var durationS: Double
    var steps: [NavStep]
    /// Uses unpaved / toll roads (when the router says).
    var hasUnpaved = false
    var hasTolls = false
    /// A few road names the route is mostly on («عبر طريق الملك فهد»).
    var via: String? = nil

    var end: LngLat? { coordinates.last }
    var start: LngLat? { coordinates.first }

    static func == (a: NavRoute, b: NavRoute) -> Bool {
        a.id == b.id && a.distanceM == b.distanceM && a.durationS == b.durationS && a.coordinates.count == b.coordinates.count
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
