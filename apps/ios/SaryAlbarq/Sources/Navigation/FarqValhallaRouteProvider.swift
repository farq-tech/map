import Foundation
import MapboxDirections
@_spi(MapboxInternal) import MapboxNavigationCore
import MapboxNavigationNative

/// «مزوّد المسارات»: who computes routes. Default «تلقائي»: Mapbox Directions with live traffic
/// (`driving-traffic`, an exact arrival time in town) for every road it covers, and the company's Valhalla
/// for the desert and the roads Mapbox does not reach, or when Mapbox fails.
enum NavProviderChoice: String, CaseIterable, Identifiable {
    /// Mapbox with traffic first; the company's Valhalla (when its server says it is enabled) where
    /// Mapbox's route stops short of the target (desert, tracks) or Mapbox has no route.
    case auto
    case mapbox
    /// Try the company's Valhalla first (falls back to Mapbox when it cannot answer).
    case farq

    static let key = "sary.nav.provider.v1"
    var id: String { rawValue }

    static var current: NavProviderChoice {
        get { NavProviderChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var label: String {
        switch self {
        case .auto: return "تلقائي"
        case .mapbox: return "Mapbox"
        case .farq: return "فرق"
        }
    }
}

/// Why the company's router did not answer — every case falls back to Mapbox.
enum FarqRoutingError: Error, Equatable {
    /// `/api/outings/routing/*` is not deployed yet (404).
    case notDeployed
    /// `GET /routing/status` says `enabled: false`.
    case disabled
    /// The server answered `routing_unavailable` (Valhalla down / no tiles).
    case unavailable
    /// `no_route` / OSRM `NoRoute`.
    case noRoute
    case badResponse(String)
}

/// The company's Valhalla through our own server (`feat/routing-proxy`):
/// `POST /api/outings/routing/route` (Bearer identity token) answers a
/// Mapbox-Directions-compatible OSRM JSON (polyline6, banner + voice
/// instructions, `provider: "farq-valhalla"`). The response is decoded as a
/// Directions `RouteResponse`, so the Navigation SDK follows it like any route.
///
/// The Navigation SDK's way to navigate a route that came from elsewhere is
/// `NavigationRoutes(routeResponse:routeIndex:responseOrigin:)` with origin
/// `.customExternal`. In 3.27.3 that initializer is marked `@_spi(MapboxInternal)`
/// (it is the one Mapbox's own custom-route examples use); if it ever fails, the
/// route is followed by `LocalGuidanceEngine` instead — never a dead end.
///
/// Note: reroutes during such a trip are computed by the SDK's own reroute
/// controller, i.e. by Mapbox Directions (same trip, not billed separately).
final class FarqValhallaRouteProvider: NavRoutingProvider {
    let name = "فرق (Valhalla)"
    let base: URL
    let token: () -> String?
    let session: URLSession
    /// Guarded by a lock: `DesertAwareRouteProvider` sends several route requests at once.
    private let statusLock = NSLock()
    private var statusCacheValue: (enabled: Bool, at: Date)?
    private var statusCache: (enabled: Bool, at: Date)? {
        get { statusLock.lock(); defer { statusLock.unlock() }; return statusCacheValue }
        set { statusLock.lock(); statusCacheValue = newValue; statusLock.unlock() }
    }

    init(base: URL = Endpoints.apiBase, token: @escaping () -> String? = { IdentityStore.currentToken() }, session: URLSession = .shared) {
        self.base = base
        self.token = token
        self.session = session
    }

    // MARK: request

    /// The body the proxy expects (`language: ar-SA`, metric is implied by Valhalla's km units).
    static func body(_ r: NavRouteRequest) -> [String: Any] {
        let o = r.options
        return [
            "locations": [["lat": r.origin.lat, "lng": r.origin.lng], ["lat": r.target.position.lat, "lng": r.target.position.lng]],
            "costing": "auto",
            "options": ["avoid_unpaved": o.avoidUnpaved, "avoid_tolls": o.avoidTolls, "avoid_highways": false, "use_tracks": !o.avoidUnpaved],
            "alternates": 2,
            "language": "ar-SA",
        ]
    }

    private func request(_ path: String, method: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// `GET /api/outings/routing/status` → `{enabled}`, cached five minutes. 404 = not deployed.
    func enabled() async -> Bool {
        if let c = statusCache, Date().timeIntervalSince(c.at) < 300 { return c.enabled }
        var on = false
        if let (data, resp) = try? await session.data(for: request("api/outings/routing/status", method: "GET")),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            on = j["enabled"] as? Bool ?? false
        }
        statusCache = (on, Date())
        return on
    }

    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        let body = try JSONSerialization.data(withJSONObject: Self.body(r))
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: request("api/outings/routing/route", method: "POST", body: body))
        } catch let e as URLError {
            throw e.code == .notConnectedToInternet ? NavRoutingError.offline : FarqRoutingError.unavailable
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (json?["error"] as? String) ?? (json?["code"] as? String)
        if status == 404, code == nil || code == "not_found" { throw FarqRoutingError.notDeployed }
        if code == "routing_unavailable" { throw FarqRoutingError.unavailable }
        if code == "no_route" || code == "NoRoute" || code == "NoSegment" { throw FarqRoutingError.noRoute }
        guard status == 200, code == nil || code == "Ok" else { throw FarqRoutingError.badResponse(code ?? "http \(status)") }
        return try Self.plan(from: data, request: r)
    }

    // MARK: response → routes

    /// The Directions options the response is decoded against (same mapping as Mapbox, polyline6).
    static func decodeOptions(_ r: NavRouteRequest) -> NavigationRouteOptions {
        let o = MapboxNavRoutingProvider.options(r)
        o.shapeFormat = .polyline6
        o.includesSteps = true
        o.includesSpokenInstructions = true
        o.includesVisualInstructions = true
        return o
    }

    static func decode(_ data: Data, request r: NavRouteRequest) throws -> RouteResponse {
        let dec = JSONDecoder()
        dec.userInfo[.options] = decodeOptions(r)
        /* Credentials only label the response (requests never go anywhere with them). */
        dec.userInfo[.credentials] = Credentials(accessToken: MapboxNavCore.token ?? "pk.farq", host: nil)
        do {
            return try dec.decode(RouteResponse.self, from: data)
        } catch {
            throw FarqRoutingError.badResponse("decode: \(error)")
        }
    }

    static func plan(from data: Data, request r: NavRouteRequest) throws -> NavRoutePlan {
        let resp = try decode(data, request: r)
        let routes = (resp.routes ?? []).enumerated().map { i, route in MapboxNavRoutingProvider.convert(route, id: "farq-\(i)") }
        guard !routes.isEmpty else { throw FarqRoutingError.noRoute }
        return NavRoutePlan(routes: routes, native: FarqRoutesBox(resp))
    }
}

/// A Valhalla response, turned into `NavigationRoutes` for the chosen route when guidance starts.
final class FarqRoutesBox {
    let response: RouteResponse
    init(_ r: RouteResponse) { response = r }

    func navigationRoutes(routeId: String) async throws -> NavigationRoutes {
        let i = Int(routeId.replacingOccurrences(of: "farq-", with: "")) ?? 0
        return try await NavigationRoutes(routeResponse: response, routeIndex: i, responseOrigin: .customExternal)
    }
}

/// «تلقائي / Mapbox / فرق» with the automatic fallback: the company's router
/// when it can answer, Mapbox Directions whenever it cannot.
final class SwitchingRouteProvider: NavRoutingProvider {
    let farq: FarqValhallaRouteProvider
    let mapbox: NavRoutingProvider
    var choice: () -> NavProviderChoice
    /// Which one answered last (diagnostics row in the options sheet, DEBUG). Guarded by a lock:
    /// `DesertAwareRouteProvider` sends several route requests through this provider at once.
    private(set) var lastUsed: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return lastUsedValue }
        set { stateLock.lock(); lastUsedValue = newValue; stateLock.unlock() }
    }
    private(set) var lastFallbackReason: FarqRoutingError? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return lastFallbackReasonValue }
        set { stateLock.lock(); lastFallbackReasonValue = newValue; stateLock.unlock() }
    }
    private let stateLock = NSLock()
    private var lastUsedValue = "Mapbox"
    private var lastFallbackReasonValue: FarqRoutingError?

    var name: String { lastUsed }

    init(farq: FarqValhallaRouteProvider = FarqValhallaRouteProvider(), mapbox: NavRoutingProvider, choice: @escaping () -> NavProviderChoice = { NavProviderChoice.current }) {
        self.farq = farq
        self.mapbox = mapbox
        self.choice = choice
    }

    /// «تلقائي»: a Mapbox route that ends farther than this from the target has left the roads Mapbox
    /// knows (desert, tracks, new districts); Valhalla is asked then and wins if it gets closer.
    static let uncoveredGapM = 300.0

    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        let c = choice()
        if c == .mapbox { return try await viaMapbox(r, reason: nil) }
        if c == .auto { return try await automatic(r) }
        do {
            let p = try await farq.routes(r)
            lastUsed = farq.name
            lastFallbackReason = nil
            return p
        } catch let e as FarqRoutingError {
            return try await viaMapbox(r, reason: e)
        }
    }

    /// Mapbox with traffic first (live ETA in town); Valhalla only off Mapbox's roads or when Mapbox fails.
    private func automatic(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        let mb: NavRoutePlan
        do {
            mb = try await mapbox.routes(r)
        } catch {
            /* Offline: Valhalla is a server too. */
            if (error as? NavRoutingError) == .offline { throw error }
            guard await farq.enabled(), let p = try? await farq.routes(r), !p.routes.isEmpty else { throw error }
            lastUsed = farq.name
            lastFallbackReason = nil
            return p
        }
        lastUsed = mapbox.name
        lastFallbackReason = nil
        let target = r.target.position
        guard let end = mb.routes.first?.end else { return mb }
        let gap = PlanGeo.meters(end, target)
        guard gap > Self.uncoveredGapM, await farq.enabled(),
              let p = try? await farq.routes(r), let fe = p.routes.first?.end,
              PlanGeo.meters(fe, target) + Self.uncoveredGapM / 2 < gap else { return mb }
        lastUsed = farq.name
        return p
    }

    private func viaMapbox(_ r: NavRouteRequest, reason: FarqRoutingError?) async throws -> NavRoutePlan {
        lastFallbackReason = reason
        let p = try await mapbox.routes(r)
        lastUsed = mapbox.name
        return p
    }
}
