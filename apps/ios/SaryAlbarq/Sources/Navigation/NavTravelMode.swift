import Foundation

/// «أبي يكون فيه خيارين، خيار للسيارة وخيار للمشي» (owner, Build 49): how the person travels.
///
/// The mode is chosen in the route options sheet (both designs share it), is remembered, and rides
/// in `NavRouteOptions.mode`, so every request (first route, refetch, reroute, forced reroute)
/// carries it without any extra plumbing. Everything that differs between a car and a walker is
/// decided by pure functions in this file so it is unit-tested without a phone:
///   * the request (`NavRouteSpec` in NavRouting.swift, `FarqValhallaRouteProvider.body`),
///   * the time (`WalkPace`: 4.5 km/h flat, slope-aware),
///   * off-route tolerance (`RouteAdherence.Tuning.for(_:)`),
///   * wording and prompt timing (`WalkWording`, `NavPromptTiming.plan(... mode:)`).
enum TravelMode: String, CaseIterable, Identifiable, Equatable {
    case car, walk

    var id: String { rawValue }

    static let `default` = TravelMode.car
    static let defaultsKey = "sary.nav.travelMode.v1"

    /// The two-segment control: «بالسيارة» / «مشي».
    var title: String {
        switch self {
        case .car: return "بالسيارة"
        case .walk: return "مشي"
        }
    }

    var symbol: String {
        switch self {
        case .car: return "car.fill"
        case .walk: return "figure.walk"
        }
    }

    var isWalk: Bool { self == .walk }

    /// The remembered choice (car when nothing, or something unknown, was saved).
    static func load(_ d: UserDefaults = .standard) -> TravelMode {
        d.string(forKey: defaultsKey).flatMap(TravelMode.init(rawValue:)) ?? .default
    }

    func save(_ d: UserDefaults = .standard) { d.set(rawValue, forKey: Self.defaultsKey) }

    /// The mode of the guidance running right now (`.car` when none): what the map reads to draw a
    /// walker dot instead of the car and to zoom closer. Set by `NavSession` when guidance starts / ends.
    static var active: TravelMode = .car
}

// MARK: - walking pace

/// Walking time: 4.5 km/h on the flat, slower uphill and on steep descents (Tobler's hiking function,
/// scaled so the flat speed is exactly 4.5 km/h). Used for road legs (no elevation: flat) and for the
/// desert raster (`DesertGrid.elev`: slope-aware).
enum WalkPace {
    /// 4.5 km/h in m/s.
    static let flatMps = 4.5 / 3.6
    /// Never slower than this however steep (a scramble), m/s.
    static let minMps = 0.3
    /// Tobler's function peaks at a slight downhill (about −2.9°) at 6 km/h; flat is 6·e^(−0.175) = 5.04 km/h.
    private static let toblerFlatKmh = 6 * exp(-3.5 * 0.05)

    /// Speed on a slope (rise over run, +0.1 = 10 % uphill), m/s.
    static func speed(slope: Double) -> Double {
        let s = max(-1, min(1, slope.isFinite ? slope : 0))
        let kmh = 6 * exp(-3.5 * abs(s + 0.05))
        return max(minMps, kmh / toblerFlatKmh * flatMps)
    }

    /// A flat walk of `distanceM` metres, seconds.
    static func duration(distanceM: Double) -> Double { max(0, distanceM) / flatMps }

    /// A path with an elevation lookup (`nil` anywhere: that stretch is taken as flat), seconds.
    static func duration(points: [LngLat], elevation: (LngLat) -> Double?) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let d = Vehicle.distanceMeters(a, b)
            guard d > 0 else { continue }
            var slope = 0.0
            if let za = elevation(a), let zb = elevation(b) { slope = (zb - za) / d }
            total += d / speed(slope: slope)
        }
        return total
    }

    /// The walking version of a route from a road router: the time is the walking pace over the
    /// route's length (the router's own walking estimate, 1.4 m/s, is faster than a family walks),
    /// the steps are scaled to match, and the car-only parts of a step (lanes, posted limit) are dropped.
    /// A route whose time is already slope-aware (the desert ones) keeps its time.
    static func retimed(_ route: NavRoute) -> NavRoute {
        var r = route
        if !isDesert(route) {
            let walk = duration(distanceM: route.distanceM)
            let k = route.durationS > 0 ? walk / route.durationS : 1
            r.durationS = walk
            r.steps = route.steps.map { var s = $0; s.durationS *= k; return s }
            if let legs = route.timingProfile {
                r.timingProfile = legs.map { NavRouteTimingLeg(distanceM: $0.distanceM, durationS: $0.durationS * k) }
            }
            r.congestion = nil
        }
        r.steps = r.steps.map { var s = $0; s.lanes = []; s.speedLimitKmh = nil; return s }
        return r
    }

    /// Routes built by `DesertAwareRouteProvider` (their ids carry «desert»): already timed on the raster.
    static func isDesert(_ r: NavRoute) -> Bool { r.id.contains("desert") }

    /// Time left on a route with `remainingM` metres still ahead: the route's total time, pro rata
    /// (keeps the slope-aware shape of a desert route; a flat road route is linear anyway).
    static func remaining(route: NavRoute, remainingM: Double) -> Double {
        guard route.distanceM > 0 else { return duration(distanceM: remainingM) }
        return route.durationS * max(0, min(1, remainingM / route.distanceM))
    }
}

/// Wraps the app's routing provider: walking answers get the walking pace and no car-only step data.
/// Car requests pass through untouched (same object, no copy).
final class TravelModeRouteProvider: NavRoutingProvider {
    let base: NavRoutingProvider
    var name: String { base.name }

    init(_ base: NavRoutingProvider) { self.base = base }

    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan {
        let plan = try await base.routes(request)
        guard request.options.mode.isWalk else { return plan }
        var out = plan
        out.routes = plan.routes.map(WalkPace.retimed)
        return out
    }
}

// MARK: - walking wording

/// «بعد ٣٠ متر انعطف يمينًا»: a walker hears distances in metres much more often than a driver
/// (a kilometre is twelve minutes on foot), finer, and nothing about lanes, limits or cameras.
enum WalkWording {
    /// Said in metres up to here; kilometres past it.
    static let metresUpToM = 1000.0
    /// Under this the maneuver is right here: just the action.
    static let nowM = 12.0
    /// «قريب»: the final prompt of a maneuver. A walker has seconds, not tens of metres, to react.
    static let finalM = 40.0
    static let finalS = 25.0

    /// Rounded down for the voice, in steps a person can judge by eye: 5 m under 50, 10 m under 200,
    /// 50 m under 1 km, then 0.1 km.
    static func flooredMeters(_ m: Double) -> Double {
        let m = max(0, m) + 0.5
        if m < 50 { return (m / 5).rounded(.down) * 5 }
        if m < 200 { return (m / 10).rounded(.down) * 10 }
        if m < metresUpToM { return (m / 50).rounded(.down) * 50 }
        return (m / 100).rounded(.down) * 100
    }

    /// «بعد ٣٠ متر» — nil when the maneuver is right here.
    static func spokenInDistance(_ m: Double) -> String? {
        guard m >= nowM else { return nil }
        let r = flooredMeters(m)
        if r < metresUpToM { return "بعد \(SaryFormat.number(Int(max(5, r)))) متر" }
        let km = (r / 100).rounded() / 10
        let s = km == km.rounded() ? SaryFormat.number(Int(km)) : SaryFormat.digits(String(format: "%.1f", km))
        return "بعد \(s) كيلومتر"
    }

    /// The banner's distance, same steps: «٣٠ م».
    static func banner(_ m: Double) -> String? {
        guard m >= nowM else { return nil }
        let r = flooredMeters(m)
        if r < metresUpToM { return "بعد \(SaryFormat.number(Int(max(5, r)))) م" }
        return "بعد \(SaryFormat.distance(meters: r))"
    }

    /// The verb for a walker: «انعطف يمينًا» is the same, but «استدر للخلف» and the car-only maneuvers
    /// (ramps, merges, lanes, roundabout exits by number) are said the pedestrian way.
    static func action(_ m: NavManeuver) -> String {
        switch m.kind {
        case .merge, .onRamp, .offRamp, .useLane, .fork:
            if let d = m.direction, d != .straight { return NavText.turn(d) }
            return "استمر للأمام"
        case .roundabout, .exitRoundabout:
            if let d = m.direction, d != .uTurn, d != .straight { return NavText.turn(d) }
            return "استمر للأمام"
        case .depart: return "ابدأ المشي"
        default: return NavText.action(m)
        }
    }

    /// The whole spoken line for a step `distanceM` metres ahead (0: the action alone).
    /// No road-name prompt: a footpath or a car road's name does not help someone on foot.
    static func spoken(_ step: NavStep, distanceM: Double, targetName: String? = nil) -> String {
        if step.maneuver.kind == .arrive {
            let name = targetName.map(NavText.arabicDigitsOnly) ?? "وجهتك"
            return distanceM < nowM ? "وصلت إلى \(name)" : "\(spokenInDistance(distanceM) ?? "") تصل إلى \(name)"
        }
        let a = action(step.maneuver)
        return spokenInDistance(distanceM).map { "\($0)، \(a)" } ?? a
    }

    /// «توصل الساعة ٤:٣٥ م، باقي ١٢ د مشيًا».
    static func etaText(arrival: Date, remainingS: Double) -> String {
        "توصل الساعة \(NavText.clock(arrival))، باقي \(NavText.remaining(seconds: remainingS)) مشيًا"
    }

    /// Phrases a walker would hear from the recorded «صوت سرى» if it had walking clips; until it does
    /// they are spoken by the device voice (ar-SA). For the PR description and the voice backlog.
    static let phrasesNeedingClips: [String] = [
        "بعد (٥ … ١٠٠٠) متر بخطوات ٥ و١٠ و٥٠ مع الاتجاه",
        "ابدأ المشي",
        "استمر للأمام",
        "تصل إلى وجهتك / وصلت",
        "توصل الساعة … باقي … مشيًا",
        "طلعت عن الدرب، نضبط لك المسار",
    ]
}
