import Foundation

/// «كاميرا رصد» (ساهر) as the app sees it: exactly the public shape the API
/// returns from `GET /api/cameras` (lib/cameras.js `publicCamera`). No reporter
/// identity ever reaches the client.
struct SpeedCamera: Decodable, Equatable, Identifiable {
    var id: String
    var lat: Double
    var lon: Double
    /// Degrees clockwise from north the camera watches, when the source knows it.
    /// Absent → the camera alerts in both directions.
    var bearing: Double?
    var kind: CameraKind
    /// Posted limit, km/h, when known. We only ever *say* it when we trust it.
    var speed_limit: Int?
    var source: CameraSource
    /// 0…1. Low-confidence points still draw, fainter; the alert waits for higher.
    var confidence: Double

    var position: LngLat { LngLat(lng: lon, lat: lat) }
}

enum CameraKind: String, Decodable, Equatable {
    case fixed, mobile, red_light, avg_speed

    /// SF Symbol for the map pin and the alert. A plain camera glyph — never a
    /// real program's logo or colours.
    var symbol: String {
        switch self {
        case .fixed: return "camera.fill"
        case .mobile: return "camera.on.rectangle.fill"
        case .red_light: return "light.beacon.max.fill"
        case .avg_speed: return "gauge.with.dots.needle.67percent"
        }
    }

    /// Short Arabic name for the pin label and the report sheet.
    var arabic: String {
        switch self {
        case .fixed: return "كاميرا ثابتة"
        case .mobile: return "كاميرا متنقلة"
        case .red_light: return "كاميرا إشارة"
        case .avg_speed: return "رصد متوسط السرعة"
        }
    }

    /// Tolerant decoding: an unknown kind from a newer server reads as `.fixed`
    /// rather than dropping the whole point.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CameraKind(rawValue: raw) ?? .fixed
    }
}

enum CameraSource: String, Decodable, Equatable {
    case osm, official, user, other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CameraSource(rawValue: raw) ?? .other
    }
}
