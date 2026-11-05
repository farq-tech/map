import Foundation

/// Place search for «ابحث أو أدخل إحداثية»: Mapbox Geocoding v6 (forward), Arabic,
/// biased to the map centre, Saudi Arabia first (then worldwide if nothing matched).
/// Uses the app's existing public Mapbox token; the query never carries who you are.
enum PlaceSearch {
    struct Place: Equatable, Identifiable {
        var id: String
        var name: String
        var detail: String?
        var point: LngLat
    }

    enum SearchError: Error, Equatable {
        case noToken
        case network
        case http(Int)

        var arabic: String {
            switch self {
            case .noToken: return "البحث عن الأماكن غير مفعّل في هذه النسخة. أدخل إحداثية بدلًا منه."
            case .network: return "لا يوجد اتصال بالإنترنت. تقدر تدخل إحداثية بدون إنترنت."
            case .http: return "تعذّر البحث الآن. أعد المحاولة."
            }
        }
    }

    static let endpoint = URL(string: "https://api.mapbox.com/search/geocode/v6/forward")!

    static var token: String? {
        let t = (Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String)?.trimmingCharacters(in: .whitespaces)
        guard let t, !t.isEmpty, !t.hasPrefix("$(") else { return nil }
        return t
    }

    /// The request URL. `saudiOnly` adds `country=sa` (the first pass).
    static func request(query: String, proximity: LngLat?, saudiOnly: Bool, token: String, limit: Int = 8) -> URLRequest? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "q", value: String(q.prefix(256))),
            .init(name: "language", value: "ar"),
            .init(name: "limit", value: String(min(10, max(1, limit)))),
            .init(name: "autocomplete", value: "true"),
        ]
        if let p = proximity, PlanGeo.valid(lat: p.lat, lng: p.lng) {
            items.append(.init(name: "proximity", value: String(format: "%.4f,%.4f", p.lng, p.lat)))
        }
        if saudiOnly { items.append(.init(name: "country", value: "sa")) }
        items.append(.init(name: "access_token", value: token))
        c.queryItems = items
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// GeoJSON FeatureCollection → places (features without a usable point are skipped).
    static func parse(_ data: Data) -> [Place] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let feats = obj["features"] as? [[String: Any]] else { return [] }
        return feats.compactMap { f in
            let props = f["properties"] as? [String: Any] ?? [:]
            var lng: Double?, lat: Double?
            if let coords = props["coordinates"] as? [String: Any] {
                lng = coords["longitude"] as? Double
                lat = coords["latitude"] as? Double
            }
            if lng == nil, let g = f["geometry"] as? [String: Any], let c = g["coordinates"] as? [Double], c.count >= 2 {
                lng = c[0]; lat = c[1]
            }
            guard let lng, let lat, PlanGeo.valid(lat: lat, lng: lng) else { return nil }
            let name = (props["name_preferred"] as? String) ?? (props["name"] as? String) ?? (props["full_address"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let detail = (props["place_formatted"] as? String) ?? (props["full_address"] as? String).flatMap { $0 == name ? nil : $0 }
            let id = (f["id"] as? String) ?? (props["mapbox_id"] as? String) ?? "\(lat),\(lng)"
            return Place(id: id, name: name, detail: detail, point: LngLat(lng: lng, lat: lat))
        }
    }

    typealias Fetch = (URLRequest) async throws -> (Data, Int)

    static let liveFetch: Fetch = { req in
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Saudi Arabia first; worldwide only when that found nothing.
    static func search(_ query: String, near: LngLat?, token: String? = PlaceSearch.token, fetch: Fetch = PlaceSearch.liveFetch) async throws -> [Place] {
        guard let token else { throw SearchError.noToken }
        for saudi in [true, false] {
            guard let req = request(query: query, proximity: near, saudiOnly: saudi, token: token) else { return [] }
            let data: Data, status: Int
            do { (data, status) = try await fetch(req) } catch { throw SearchError.network }
            guard (200..<300).contains(status) else { throw SearchError.http(status) }
            let found = parse(data)
            if !found.isEmpty { return found }
        }
        return []
    }
}
