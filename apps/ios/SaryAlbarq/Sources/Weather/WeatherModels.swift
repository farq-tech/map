import Foundation

/// The point we ask Open-Meteo about.
///
/// Privacy: the outing area is ROUNDED to 0.1° (≈ 11 km) before it leaves the
/// phone, so the request never carries anyone's real position. A destination or
/// a searched point is a place the person chose on purpose, so it is sent as
/// chosen (4 decimals, ≈ 11 m) — never a member's live position.
struct WeatherArea: Hashable, Codable {
    enum Precision: String, Codable {
        /// The outing area: 0.1° grid.
        case area
        /// A chosen point (destination, «الطقس هنا»): 4 decimals.
        case point
        /// «بريف المكان» (a tapped map spot): the ≈ 1 km cell (0.01°), so nearby taps share one request.
        case cell
    }

    let lat: Double
    let lng: Double
    let precision: Precision

    /// The outing's area around real positions: snapped to the 0.1° grid.
    init(around lat: Double, lng: Double) {
        self.lat = (lat * 10).rounded() / 10
        self.lng = (lng * 10).rounded() / 10
        precision = .area
    }

    /// A place the person chose (destination / searched point).
    init(point lat: Double, lng: Double) {
        self.lat = (lat * 10_000).rounded() / 10_000
        self.lng = (lng * 10_000).rounded() / 10_000
        precision = .point
    }

    /// A tapped spot for the place brief: snapped to the 0.01° (≈ 1 km) grid.
    init(cell lat: Double, lng: Double) {
        self.lat = (lat * 100).rounded() / 100
        self.lng = (lng * 100).rounded() / 100
        precision = .cell
    }

    private var format: String {
        switch precision {
        case .area: return "%.1f"
        case .point: return "%.4f"
        case .cell: return "%.2f"
        }
    }

    /// Exactly what goes into the URL.
    var latText: String { String(format: format, lat) }
    var lngText: String { String(format: format, lng) }
    var key: String { "\(precision.rawValue)_\(latText)_\(lngText)" }
    var coordinate: Geo.LatLng { Geo.LatLng(lat: lat, lng: lng) }
}

/// One hour (or "now") of weather for the area. Every field may be missing:
/// Open-Meteo returns null when a model has no value.
struct WeatherHour: Equatable, Codable {
    var time: Date
    var temperatureC: Double?
    var precipitationMm: Double?
    /// 0…100. Not available for `current`.
    var precipitationProbability: Double?
    var weatherCode: Int?
    var windKmh: Double?
    var gustKmh: Double?
    /// Meteorological: the direction the wind blows FROM, degrees from north.
    var windFromDeg: Double?
    var visibilityM: Double?
    /// Surface dust, µg/m³ (CAMS, via the air-quality API).
    var dust: Double?
    /// PM10, µg/m³.
    var pm10: Double?
    /// «يُحس كأنها»: the model's apparent temperature (heat / wind chill), °C.
    var apparentC: Double? = nil
    /// Relative humidity at 2 m, 0…100.
    var humidity: Double? = nil
    /// UV index (hourly only).
    var uvIndex: Double? = nil
}

/// Everything one refresh brought back.
struct WeatherReport: Equatable, Codable {
    var area: WeatherArea
    /// Device time the data arrived. Shown honestly as «آخر تحديث قبل …».
    var fetchedAt: Date
    /// The model's value for the current 15 minutes (a model value, not a station reading).
    var current: WeatherHour?
    /// Hourly, sorted, up to 48 h.
    var hours: [WeatherHour]
    /// False when the air-quality call failed (dust unknown, never "no dust").
    var airAvailable: Bool
    /// Where the forecast is really for: Open-Meteo answers with the model grid cell it used
    /// (top-level `latitude` / `longitude`), which can be a few km from what we asked. Nil when the
    /// provider does not say (Apple Weather, older cached reports).
    var modelLat: Double? = nil
    var modelLng: Double? = nil

    /// The forecast's own point: the model's grid cell when known, else the point we asked for.
    var forecastPoint: Geo.LatLng {
        if let modelLat, let modelLng, PlanGeo.valid(lat: modelLat, lng: modelLng) { return Geo.LatLng(lat: modelLat, lng: modelLng) }
        return area.coordinate
    }
}

// MARK: - Open-Meteo wire format

enum OpenMeteo {
    static let forecastHost = "https://api.open-meteo.com/v1/forecast"
    static let airHost = "https://air-quality-api.open-meteo.com/v1/air-quality"
    /// Attribution required by Open-Meteo's terms (CC BY 4.0).
    static let attribution = "بيانات الطقس: Open-Meteo"
    static let siteURL = URL(string: "https://open-meteo.com/")!

    static let hourlyFields = "temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,visibility,apparent_temperature,relative_humidity_2m,uv_index"
    static let currentFields = "temperature_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,visibility,apparent_temperature,relative_humidity_2m"

    /// Only the (rounded or chosen) coordinate and the fields; nothing about the person.
    static func forecastURL(_ a: WeatherArea) -> URL {
        var c = URLComponents(string: forecastHost)!
        c.queryItems = [
            .init(name: "latitude", value: a.latText), .init(name: "longitude", value: a.lngText),
            .init(name: "current", value: currentFields), .init(name: "hourly", value: hourlyFields),
            .init(name: "forecast_hours", value: "48"), .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        return c.url!
    }

    static func airURL(_ a: WeatherArea) -> URL {
        var c = URLComponents(string: airHost)!
        c.queryItems = [
            .init(name: "latitude", value: a.latText), .init(name: "longitude", value: a.lngText),
            .init(name: "current", value: "dust,pm10"), .init(name: "hourly", value: "dust,pm10"),
            .init(name: "forecast_hours", value: "48"), .init(name: "timeformat", value: "unixtime"),
        ]
        return c.url!
    }

    struct Forecast: Decodable {
        struct Current: Decodable {
            var time: Double
            var temperature_2m: Double?
            var precipitation: Double?
            var weather_code: Int?
            var wind_speed_10m: Double?
            var wind_direction_10m: Double?
            var wind_gusts_10m: Double?
            var visibility: Double?
            var apparent_temperature: Double?
            var relative_humidity_2m: Double?
        }
        struct Hourly: Decodable {
            var time: [Double]
            var temperature_2m: [Double?]?
            var precipitation_probability: [Double?]?
            var precipitation: [Double?]?
            var weather_code: [Int?]?
            var wind_speed_10m: [Double?]?
            var wind_direction_10m: [Double?]?
            var wind_gusts_10m: [Double?]?
            var visibility: [Double?]?
            var apparent_temperature: [Double?]?
            var relative_humidity_2m: [Double?]?
            var uv_index: [Double?]?
        }
        var current: Current?
        var hourly: Hourly?
        /// The model grid cell Open-Meteo used for this answer.
        var latitude: Double?
        var longitude: Double?
    }

    struct Air: Decodable {
        struct Current: Decodable { var time: Double; var dust: Double?; var pm10: Double? }
        struct Hourly: Decodable { var time: [Double]; var dust: [Double?]?; var pm10: [Double?]? }
        var current: Current?
        var hourly: Hourly?
    }

    enum ParseError: Error { case noHours }

    /// Both responses into one report. `air` may be nil (that call failed).
    static func parse(forecast: Data, air: Data?, area: WeatherArea, fetchedAt: Date) throws -> WeatherReport {
        let f = try JSONDecoder().decode(Forecast.self, from: forecast)
        let a = air.flatMap { try? JSONDecoder().decode(Air.self, from: $0) }
        guard let h = f.hourly, !h.time.isEmpty else { throw ParseError.noHours }
        func at<T>(_ arr: [T?]?, _ i: Int) -> T? { guard let arr, i < arr.count else { return nil }; return arr[i] }
        var dustAt: [Double: (Double?, Double?)] = [:]
        if let ah = a?.hourly {
            for (i, t) in ah.time.enumerated() { dustAt[t] = (at(ah.dust, i), at(ah.pm10, i)) }
        }
        var hours: [WeatherHour] = []
        for (i, t) in h.time.enumerated() {
            let d = dustAt[t]
            hours.append(WeatherHour(
                time: Date(timeIntervalSince1970: t), temperatureC: at(h.temperature_2m, i), precipitationMm: at(h.precipitation, i),
                precipitationProbability: at(h.precipitation_probability, i), weatherCode: at(h.weather_code, i),
                windKmh: at(h.wind_speed_10m, i), gustKmh: at(h.wind_gusts_10m, i), windFromDeg: at(h.wind_direction_10m, i),
                visibilityM: at(h.visibility, i), dust: d?.0 ?? nil, pm10: d?.1 ?? nil,
                apparentC: at(h.apparent_temperature, i), humidity: at(h.relative_humidity_2m, i), uvIndex: at(h.uv_index, i)))
        }
        hours.sort { $0.time < $1.time }
        var current: WeatherHour?
        if let c = f.current {
            /* Dust for "now": the air API's current value, else the hour that contains now. */
            let hourStart = (c.time / 3600).rounded(.down) * 3600
            let hourDust = dustAt[hourStart]
            let uvNow = hours.first { $0.time.timeIntervalSince1970 == hourStart }?.uvIndex
            current = WeatherHour(
                time: Date(timeIntervalSince1970: c.time), temperatureC: c.temperature_2m, precipitationMm: c.precipitation,
                precipitationProbability: nil, weatherCode: c.weather_code, windKmh: c.wind_speed_10m, gustKmh: c.wind_gusts_10m,
                windFromDeg: c.wind_direction_10m, visibilityM: c.visibility,
                dust: a?.current?.dust ?? hourDust?.0 ?? nil, pm10: a?.current?.pm10 ?? hourDust?.1 ?? nil,
                apparentC: c.apparent_temperature, humidity: c.relative_humidity_2m, uvIndex: uvNow)
        }
        return WeatherReport(area: area, fetchedAt: fetchedAt, current: current, hours: hours, airAvailable: a?.hourly != nil,
                             modelLat: f.latitude, modelLng: f.longitude)
    }
}
