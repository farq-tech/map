import Combine
import Foundation

/// The weather overlays of «الطبقات» (exploration): «السحاب الآن», «وين نزل مطر», «وين ربّع».
/// One at a time, over whichever base layer is chosen. Every picture comes from our API
/// (`/api/weather/...`, docs/weather-sources.md): the app holds no provider key and never
/// talks to EUMETSAT or NASA itself.
enum WeatherOverlayKind: String, CaseIterable, Identifiable, Codable {
    case none
    case clouds
    case rain
    case wind
    case green

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "بدون"
        case .clouds: return "السحاب الآن"
        case .rain: return "وين نزل مطر"
        case .wind: return "اتجاه الرياح"
        case .green: return "وين ربّع"
        }
    }

    var detail: String {
        switch self {
        case .none: return "الخريطة بلا طبقة طقس"
        case .clouds: return "صور القمر الصناعي لآخر ساعتين تتحرك، وين السحاب يمشي"
        case .rain: return "المطر اللي نزل فعلًا (تقدير الأقمار الصناعية) واتجاه حركته"
        case .wind: return "خطوط تبيّن وين تهب الريح الحين (توقّع نموذج جوي، مو قياس)"
        case .green: return "الأماكن اللي خضّرت بعد المطر (ربيع، روضات، فياض)"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "circle.slash"
        case .clouds: return "cloud.fill"
        case .rain: return "cloud.rain.fill"
        case .wind: return "wind"
        case .green: return "leaf.fill"
        }
    }

    /// The licence's credit line, shown with the layer (each source's terms, docs/weather-sources.md).
    func attribution(year: Int = Calendar(identifier: .gregorian).component(.year, from: Date())) -> String {
        switch self {
        case .none: return ""
        case .clouds: return "Contains modified EUMETSAT Meteosat data \(year)"
        case .rain: return "NASA GPM IMERG (Early) via NASA GIBS"
        case .wind: return "Data from MET Norway (ECMWF HRES), CC BY 4.0"
        case .green: return "NASA VIIRS NOAA-20 NDVI via NASA GIBS"
        }
    }
}

/// Legend rows: colour (RGB hex, as the server paints the tiles) and the Arabic label.
struct WeatherLegendItem: Equatable, Hashable {
    var hex: UInt32
    var label: String
}

enum WeatherLegend {
    /// Accumulated rain (mm): the same steps as `apps/api/lib/weather/rain.js` LEGEND.
    static let rain: [WeatherLegendItem] = [
        .init(hex: 0x8FD3FF, label: "١–٥ ملم"),
        .init(hex: 0x40A0FF, label: "٥–١٠"),
        .init(hex: 0x1E60E6, label: "١٠–٢٥"),
        .init(hex: 0x783CDC, label: "٢٥–٥٠"),
        .init(hex: 0xC828A0, label: "+٥٠"),
    ]
    /// Greening (NDVI rise over the summer): `green.js` LEGEND.
    static let green: [WeatherLegendItem] = [
        .init(hex: 0xAAE678, label: "بداية خضرة"),
        .init(hex: 0x5AC846, label: "ربيع واضح"),
        .init(hex: 0x148C28, label: "ربيع كثيف"),
    ]
    static let wind: [WeatherLegendItem] = [
        .init(hex: 0xFFFFFF, label: "خط التدفق: طوله مسافة ٦ ساعات بسرعة الريح، والسهم وجهتها"),
    ]
    static let clouds: [WeatherLegendItem] = [
        .init(hex: 0x78D6FF, label: "قمم باردة: احتمال مطر"),
        .init(hex: 0xFFFFFF, label: "سحب كثيفة"),
        .init(hex: 0xA5C8EE, label: "سحب رقيقة"),
    ]

    static func items(_ k: WeatherOverlayKind) -> [WeatherLegendItem] {
        switch k {
        case .none: return []
        case .clouds: return clouds
        case .rain: return rain
        case .wind: return wind
        case .green: return green
        }
    }
}

/// The person's choice (remembered), shared by the layers sheet and the map overlay.
@MainActor
final class WeatherLayers: ObservableObject {
    static let shared = WeatherLayers()

    static let kindKey = "sary.map.weather.v1"
    static let daysKey = "sary.map.weather.rainDays.v1"
    static let allowedDays = [1, 3, 7]

    @Published var kind: WeatherOverlayKind {
        didSet { defaults.set(kind.rawValue, forKey: Self.kindKey) }
    }
    /// «وين نزل مطر»: the last 1 / 3 / 7 days.
    @Published var rainDays: Int {
        didSet {
            if !Self.allowedDays.contains(rainDays) { rainDays = 3 }
            defaults.set(rainDays, forKey: Self.daysKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kind = defaults.string(forKey: Self.kindKey).flatMap(WeatherOverlayKind.init) ?? .none
        let d = defaults.integer(forKey: Self.daysKey)
        rainDays = Self.allowedDays.contains(d) ? d : 3
        #if DEBUG
        /* `-SaryWeather clouds|rain|wind|green [-SaryRainDays 7]` (screenshots). */
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryWeather"), i + 1 < a.count, let k = WeatherOverlayKind(rawValue: a[i + 1]) { kind = k }
        if let i = a.firstIndex(of: "-SaryRainDays"), i + 1 < a.count, let d = Int(a[i + 1]), Self.allowedDays.contains(d) { rainDays = d }
        #endif
    }

    /// «آخر ٣ أيام».
    static func daysLabel(_ d: Int) -> String {
        switch d {
        case 1: return "آخر يوم"
        case 7: return "آخر أسبوع"
        default: return "آخر \(SaryFormat.number(d)) أيام"
        }
    }
}

// MARK: - API

/// `GET /api/weather/clouds/tiles` (the fields the app uses).
struct CloudFramesResponse: Decodable, Equatable {
    struct Frame: Decodable, Equatable {
        var id: String
        var time: String
        var label_ar: String
        var tile_url: String
    }
    var ok: Bool
    var frames: [Frame]
    var minzoom: Double?
    var maxzoom: Double?
    var bounds: [Double]?
    var attribution: String?
}

enum WeatherLayerAPI {
    /// A server path template (`/api/...{z}/{x}/{y}.png`) as an absolute URL template.
    static func absolute(_ path: String, base: URL = Endpoints.apiBase) -> String {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return path.hasPrefix("http") ? path : s + (path.hasPrefix("/") ? path : "/" + path)
    }

    static func rainTiles(days: Int, base: URL = Endpoints.apiBase) -> String {
        absolute("/api/weather/rain/tile/\(days)/{z}/{x}/{y}.png", base: base)
    }

    static func greenTiles(base: URL = Endpoints.apiBase) -> String {
        absolute("/api/weather/green/tile/{z}/{x}/{y}.png", base: base)
    }

    #if DEBUG
    /// `-SaryCloudFramesStub` (UI tests): a fixed timeline of 6 frames, 10 min apart, ending now, so a test of the
    /// card's timeline (scrubber) does not depend on the live API or the network. The tile URLs point nowhere (the
    /// map just shows no cloud pictures); only the card's state is under test.
    static func stubCloudFrames(now: Date = Date(), count: Int = 6) -> CloudFramesResponse {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ids = DateFormatter(); ids.locale = Locale(identifier: "en_US_POSIX"); ids.timeZone = TimeZone(identifier: "UTC")
        ids.dateFormat = "yyyyMMdd'T'HHmm'Z'"
        let frames = (0..<count).map { i -> CloudFramesResponse.Frame in
            let t = now.addingTimeInterval(-Double(count - 1 - i) * 600)
            return .init(id: ids.string(from: t), time: iso.string(from: t), label_ar: "\(i + 1)", tile_url: "http://127.0.0.1:9/stub/\(i)/{z}/{x}/{y}.png")
        }
        return CloudFramesResponse(ok: true, frames: frames, minzoom: 0, maxzoom: 9, bounds: [25, 8, 65, 40], attribution: nil)
    }
    #endif

    static func cloudFrames(base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> CloudFramesResponse {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SaryCloudFramesStub") { return stubCloudFrames() }
        #endif
        let url = base.appendingPathComponent("api/weather/clouds/tiles")
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CloudFramesResponse.self, from: data)
    }
}
