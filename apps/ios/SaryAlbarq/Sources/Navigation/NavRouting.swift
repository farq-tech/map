import Foundation

/// The one seam between the app and whoever computes routes.
///
/// Today: `MapboxNavRoutingProvider` (Mapbox Directions through the Navigation SDK).
/// Later: a `ValhallaRoutingProvider` against the company's own server, mapping the
/// same `NavRouteSpec` to Valhalla costing options. If that server answers in the
/// OSRM/Mapbox route-response format (`format=osrm` with banner + voice
/// instructions), the Mapbox guidance engine can still follow it
/// (`NavigationRoutes(routeResponse:routeIndex:responseOrigin:)`); otherwise
/// `LocalGuidanceEngine` follows any `NavRoute` on its own.
protocol NavRoutingProvider: AnyObject {
    /// Shown in diagnostics («Mapbox», «Valhalla»).
    var name: String { get }
    /// Routes from `origin` to `target`, best first. Throws `NavRoutingError`.
    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan
}

struct NavRouteRequest: Equatable {
    var origin: LngLat
    /// My course, so the first instruction does not start with a U-turn behind me.
    var heading: Double?
    var target: NavTarget
    var options: NavRouteOptions
}

enum NavRoutingError: Error, Equatable {
    /// No road route at all (the target is far from any road, or across a border).
    case noRoute
    case offline
    /// No Mapbox token in the build.
    case notConfigured
    case failed(String)

    var message: String {
        switch self {
        case .noRoute: return "ما لقينا طريقًا إلى هنا."
        case .offline: return "ما فيه إنترنت لحساب الطريق. جرّب بعد شوي."
        case .notConfigured: return "الملاحة غير مفعّلة في هذه النسخة."
        case let .failed(m): return m.isEmpty ? "تعذّر حساب الطريق، حاول مرة ثانية." : m
        }
    }
}

/// Provider-neutral request parameters, from the options sheet.
/// Mapbox: `profile`, `exclude`, `language`, `voice_units`; Valhalla: costing + `exclude_unpaved` / `use_tolls`.
struct NavRouteSpec: Equatable {
    enum Profile: String { case drivingTraffic = "driving-traffic", driving }
    var profile: Profile
    /// Road classes to exclude: "toll", "unpaved".
    var exclude: [String]
    var alternatives: Bool
    var language: String
    var metric: Bool

    static func from(_ o: NavRouteOptions) -> NavRouteSpec {
        var ex: [String] = []
        if o.avoidTolls { ex.append("toll") }
        if o.avoidUnpaved { ex.append("unpaved") }
        /* «أسرع» uses live traffic; off we still ask for alternatives and keep the shortest. */
        return NavRouteSpec(profile: o.fastest ? .drivingTraffic : .driving, exclude: ex, alternatives: true, language: "ar", metric: true)
    }
}

enum NavRouteChoice {
    /// Best first: «أسرع» by time, otherwise by distance. Ties keep the router's order.
    static func order(_ routes: [NavRoute], options: NavRouteOptions) -> [NavRoute] {
        let indexed = routes.enumerated().map { ($0.offset, $0.element) }
        let key: (NavRoute) -> Double = options.fastest ? { $0.durationS } : { $0.distanceM }
        return indexed.sorted { a, b in
            let ka = key(a.1), kb = key(b.1)
            return ka == kb ? a.0 < b.0 : ka < kb
        }.map(\.1)
    }

    /// «أبطأ ٤ د» / «أقصر ٢٫١ كم» against the best route (words, not +/− signs: those flip in RTL).
    static func delta(_ r: NavRoute, best: NavRoute) -> String {
        let dm = Int(((r.durationS - best.durationS) / 60).rounded())
        if dm != 0 { return (dm > 0 ? "أبطأ " : "أسرع ") + SaryFormat.number(abs(dm)) + " د" }
        let dd = r.distanceM - best.distanceM
        if abs(dd) < 50 { return "نفس الوقت" }
        return (dd > 0 ? "أطول " : "أقصر ") + SaryFormat.distance(meters: abs(dd))
    }
}
