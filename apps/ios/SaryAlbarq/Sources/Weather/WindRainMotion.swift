import Foundation
import MapboxMaps

/// «اتجاه الرياح» and «المطر وين كان يمشي؟» (phase 3). Both come from our API only:
///  - wind: a model forecast for the current hour (ECMWF HRES via MET Norway) on a ~150 km grid;
///  - rain motion: the direction observed rain was moving between two NASA IMERG frames an hour apart,
///    4–7 hours ago.
/// Neither is live and neither predicts rain. Every sentence says how old the data is, motion carries a
/// margin, and a weak match hides the row (docs/weather-wind-rain-motion.md).
struct WindReading: Decodable, Equatable {
    var ok: Bool
    var speed_kmh: Double
    var from_deg: Double
    var toward_deg: Double
    var from_ar: String?
    var calm: Bool?
    var model_age_min: Int?
}

struct RainMotion: Decodable, Equatable {
    struct Motion: Decodable, Equatable {
        var bearing_deg: Double
        var speed_kmh: Double
        var margin_deg: Int
        var margin_kmh: Int
    }

    var ok: Bool
    /// `moving` / `stationary` / `no_rain` / `uncertain`.
    var state: String
    var confidence: Double
    var min_confidence: Double?
    var motion: Motion?
    var rain_at_point: Bool?
    var image_age_min: Int?
}

/// `GET /api/weather/wind/streamlines`: GeoJSON lines + the model's age.
struct WindLines: Decodable {
    var ok: Bool
    var model_age_min: Int?
    var features: [Feature]
}

enum WindRainPresenter {
    static let minConfidence = 0.45

    /// «خفيفة / معتدلة / قوية…» by km/h (the dust threshold in the desert is ~30–40 km/h).
    static func strength(_ kmh: Double) -> String {
        switch kmh {
        case ..<12: return "خفيفة"
        case ..<30: return "معتدلة"
        case ..<50: return "قوية، قد تثير الغبار"
        default: return "شديدة، تثير الغبار وتخفّض الرؤية"
        }
    }

    static func wind(_ w: WindReading, subject: CloudOutlookSubject = .me) -> CloudOutlookPresenter.Display? {
        guard w.ok else { return nil }
        let age = w.model_age_min.map { "نموذج محدَّث قبل \(CloudOutlookPresenter.ageText($0))" } ?? "نموذج جوي"
        let foot = "\(age) • توقّع للساعة الحالية، مو قياس ولا بث حي • شبكة ~١٥٠ كم"
        let at = subject == .me ? "عندك" : "عند وجهتك"
        if w.calm == true || w.speed_kmh < 2 {
            return .init(arrowDegrees: nil, headline: "الجو شبه هادئ \(at)", detail: "الريح أقل من ٢ كم/س بحسب النموذج", footnote: foot)
        }
        let from = w.from_ar.map { "الريح \($0)" } ?? "الريح"
        let kmh = SaryFormat.number(Int(w.speed_kmh.rounded()))
        return .init(arrowDegrees: w.toward_deg,
                     headline: "\(from) \(at) بسرعة ~\(kmh) كم/س",
                     detail: "\(strength(w.speed_kmh)) • تهب \(CloudOutlookPresenter.directionText(w.toward_deg))",
                     footnote: foot)
    }

    static func rain(_ r: RainMotion, subject: CloudOutlookSubject = .me) -> CloudOutlookPresenter.Display? {
        guard r.ok, r.confidence >= max(minConfidence, r.min_confidence ?? 0) else { return nil }
        let age = r.image_age_min.map { "بحسب صور مطر قبل \(CloudOutlookPresenter.ageText($0))" } ?? "بحسب آخر صور المطر"
        let foot = "\(age) • متأخرة، والحركة جزء منها تقدير نموذج ناسا • مو توقع مطر"
        switch r.state {
        case "moving":
            guard let m = r.motion else { return nil }
            let kmh = SaryFormat.number(Int(m.speed_kmh.rounded()))
            return .init(arrowDegrees: m.bearing_deg,
                         headline: "المطر كان يتجه \(CloudOutlookPresenter.directionText(m.bearing_deg)) بسرعة ~\(kmh) كم/س",
                         detail: "±\(SaryFormat.number(m.margin_deg))° و±\(SaryFormat.number(m.margin_kmh)) كم/س • وقت آخر صورة",
                         footnote: foot)
        case "stationary":
            return .init(arrowDegrees: nil, headline: "المطر كان شبه ثابت", detail: "وقت آخر صورة، حول \(subject == .me ? "موقعك" : "وجهتك")", footnote: foot)
        default:
            return nil
        }
    }
}

extension WeatherLayerAPI {
    private static func get<T: Decodable>(_ path: String, _ type: T.Type, query: [URLQueryItem] = [], timeout: TimeInterval,
                                          base: URL, session: URLSession) async throws -> T {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func point(_ lat: Double, _ lng: Double) -> [URLQueryItem] {
        [.init(name: "lat", value: String(format: "%.3f", lat)), .init(name: "lng", value: String(format: "%.3f", lng))]
    }

    static func windAt(lat: Double, lng: Double, base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> WindReading {
        /* First request after a server start reads the whole grid from MET (~20 s). */
        try await get("api/weather/wind", WindReading.self, query: point(lat, lng), timeout: 90, base: base, session: session)
    }

    static func windLines(base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> WindLines {
        try await get("api/weather/wind/streamlines", WindLines.self, timeout: 90, base: base, session: session)
    }

    static func rainMotion(lat: Double, lng: Double, base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> RainMotion {
        try await get("api/weather/rain/motion", RainMotion.self, query: point(lat, lng), timeout: 90, base: base, session: session)
    }
}
