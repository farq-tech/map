import Foundation

/// The seam behind the desert chips on the home map («نفود»، «روضة»، «فيضة»، «مخيمات»،
/// «أمطار وربيع»): a chip asks a service, the service answers with places near you.
/// Today: the bundled gazetteer for the first four, and the server's rain/green search for the
/// last one (`GET /api/desert/categories/search`, docs/weather-sources.md § API), which answers
/// «قريبًا» until that endpoint is live.
struct DesertCategoryItem: Identifiable, Equatable {
    var id: String
    var title: String
    /// The other-language name, the kind, or the server's headline.
    var detail: String?
    var point: LngLat
    /// Distance from you (to the edge for an outline); nil when unknown.
    var meters: Double?
    var systemImage: String
    var polygon: [[LngLat]]? = nil
    /// Where «ابدأ» drives to (the nearest edge of a sand sea), else `point`.
    var approach: LngLat? = nil
}

enum DesertCategoryResult: Equatable {
    case places([DesertCategoryItem])
    /// Not available yet («قريبًا»), with a line saying what is coming.
    case comingSoon(String)
    case failed(String)
}

protocol DesertCategoryService {
    func search(_ category: HomeCategory, near: LngLat?) async -> DesertCategoryResult
}

/// What a desert chip asks for.
enum DesertCategorySource: Equatable {
    /// The bundled gazetteer, one kind.
    case gazetteer(DesertKind)
    /// The rain/green search on the server (`q`).
    case rainGreen(String)
}

/// Picks the service for a chip.
struct DesertCategoryRouter: DesertCategoryService {
    var gazetteer: DesertCategoryService = GazetteerCategoryService()
    var rainGreen: DesertCategoryService = RainGreenCategoryService()

    /// The app's router, made once (the bundled gazetteer behind it is read on first use).
    static let shared = DesertCategoryRouter()

    func search(_ category: HomeCategory, near: LngLat?) async -> DesertCategoryResult {
        switch category.desertSource {
        case .gazetteer?: return await gazetteer.search(category, near: near)
        case .rainGreen?: return await rainGreen.search(category, near: near)
        case nil: return .places([])
        }
    }
}

/// «نفود»، «روضة»، «فيضة»، «مخيمات» from «دليل البر», nearest first, offline.
struct GazetteerCategoryService: DesertCategoryService {
    /// Read on first search, not when the service is made (the bundled file is large).
    private let load: () -> DesertGazetteer
    var gazetteer: DesertGazetteer { load() }
    var limit = 25

    /// The bundled gazetteer, read lazily.
    init(limit: Int = 25) {
        load = { DesertGazetteer.bundled }
        self.limit = limit
    }

    init(gazetteer: DesertGazetteer, limit: Int = 25) {
        load = { gazetteer }
        self.limit = limit
    }

    /// Without a fix the list is ranked from the last known place, Riyadh only if there is none (the map opens there too).
    static var fallbackCenter: LngLat { MapOpening.center() }

    func search(_ category: HomeCategory, near: LngLat?) async -> DesertCategoryResult {
        guard case let .gazetteer(kind)? = category.desertSource else { return .places([]) }
        return .places(Self.items(gazetteer, kind: kind, near: near, limit: limit))
    }

    static func items(_ g: DesertGazetteer, kind: DesertKind, near: LngLat?, limit: Int) -> [DesertCategoryItem] {
        let me = near ?? fallbackCenter
        return g.nearest(kind, from: me, limit: limit).map { item($0, from: me) }
    }

    static func item(_ h: DesertHit, from me: LngLat?) -> DesertCategoryItem {
        let p = h.place
        let detail = [p.secondary, h.inside ? "أنت داخلها" : nil].compactMap { $0 }.joined(separator: " • ")
        return DesertCategoryItem(id: p.id, title: p.title, detail: detail.isEmpty ? p.kind.arabic : detail, point: p.point,
                                  meters: h.meters.isFinite ? h.meters : nil, systemImage: p.kind.systemImage, polygon: p.polygon,
                                  approach: me.map { p.approach(from: $0) })
    }
}

/// «أمطار وربيع»: named places near recent rain or new green, from our server.
/// Contract: `GET /api/desert/categories/search?q=مطر|ربيع&near=lat,lng[&radius_km][&limit]`
/// → `{ ok, results: [{ id, type, name_ar, kind, kind_ar, lat, lng, distance_km, score, headline_ar, … }] }`.
/// Until the endpoint is deployed (404 / no route) or while offline it answers «قريبًا».
struct RainGreenCategoryService: DesertCategoryService {
    static let comingSoon = "قريبًا: أماكن نزل فيها مطر أو خضّرت قريب منك."
    typealias Fetch = (URLRequest) async throws -> (Data, Int)

    var base: URL = Endpoints.apiBase
    var fetch: Fetch = { req in
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
    /// Asked every time: a 404 (not deployed yet), another status, a bad shape or no network
    /// all answer «قريبًا», so the chip lights up by itself once the server has the route.
    var enabled = !ProcessInfo.processInfo.arguments.contains("-SaryRainGreenOff")

    func search(_ category: HomeCategory, near: LngLat?) async -> DesertCategoryResult {
        guard case let .rainGreen(q)? = category.desertSource else { return .places([]) }
        guard enabled, let req = Self.request(base: base, q: q, near: near) else { return .comingSoon(Self.comingSoon) }
        do {
            let (data, status) = try await fetch(req)
            guard status == 200 else { return .comingSoon(Self.comingSoon) }
            guard let items = Self.parse(data, near: near) else { return .comingSoon(Self.comingSoon) }
            return .places(items)
        } catch {
            return .comingSoon(Self.comingSoon)
        }
    }

    static func request(base: URL, q: String, near: LngLat?, radiusKm: Int = 250, limit: Int = 20) -> URLRequest? {
        guard var c = URLComponents(url: base.appendingPathComponent("api/desert/categories/search"), resolvingAgainstBaseURL: false) else { return nil }
        var items: [URLQueryItem] = [.init(name: "q", value: q), .init(name: "radius_km", value: String(radiusKm)), .init(name: "limit", value: String(limit))]
        if let n = near, PlanGeo.valid(lat: n.lat, lng: n.lng) {
            items.append(.init(name: "near", value: String(format: "%.3f,%.3f", n.lat, n.lng)))
        }
        c.queryItems = items
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private struct Response: Decodable {
        struct R: Decodable {
            var id: String
            var name_ar: String?
            var kind: String?
            var kind_ar: String?
            var lat: Double
            var lng: Double
            var distance_km: Double?
            var headline_ar: String?
        }
        var ok: Bool?
        var results: [R]?
    }

    /// nil when the answer is not the contract's shape.
    static func parse(_ data: Data, near: LngLat?) -> [DesertCategoryItem]? {
        guard let r = try? JSONDecoder().decode(Response.self, from: data), r.ok != false, let results = r.results else { return nil }
        return results.compactMap { x in
            guard PlanGeo.valid(lat: x.lat, lng: x.lng) else { return nil }
            let p = LngLat(lng: x.lng, lat: x.lat)
            let icon = x.kind.flatMap(DesertKind.init(rawValue:))?.systemImage ?? (x.kind == "rawdah" ? DesertKind.rawda.systemImage : "cloud.rain.fill")
            return DesertCategoryItem(id: x.id, title: x.name_ar ?? x.kind_ar ?? "مكان", detail: x.headline_ar ?? x.kind_ar, point: p,
                                      meters: x.distance_km.map { $0 * 1000 } ?? near.map { PlanGeo.meters($0, p) }, systemImage: icon)
        }
    }
}
