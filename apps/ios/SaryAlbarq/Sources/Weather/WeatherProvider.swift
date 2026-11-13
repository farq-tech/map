import CoreLocation
import Foundation

// «بريف المكان»: where the weather for a tapped spot comes from, behind one protocol so
// the source can change without touching the card.
//
// LICENSING: Open-Meteo's free API (api.open-meteo.com) is for NON-COMMERCIAL use only
// (CC BY 4.0 data, attribution required). A commercial app needs either an Open-Meteo
// API plan (customer-api.open-meteo.com + apikey) or Apple WeatherKit. Both slot in here:
// `OpenMeteoProvider(host:)` takes the paid host, `WeatherKitProvider` is ready behind
// `WeatherProviders.weatherKitEnabled` (needs the WeatherKit entitlement in the
// provisioning profile and the Apple Weather attribution, which the card already shows).

/// Which service answered (shown on the card's source line, kept with the cache).
enum WeatherProviderID: String, Codable, Equatable {
    case openMeteo, weatherKit

    /// «المصدر: …».
    var label: String {
        switch self {
        case .openMeteo: return "Open-Meteo"
        case .weatherKit: return "Apple Weather"
        }
    }

    /// The attribution link each service's terms require next to its data.
    var attributionURL: URL {
        switch self {
        case .openMeteo: return OpenMeteo.siteURL
        case .weatherKit: return URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
        }
    }
}

/// One answer for one area, with who gave it.
struct PlaceWeather: Codable, Equatable {
    var report: WeatherReport
    var provider: WeatherProviderID
}

/// A weather source. `fetch` asks the network every time; caching is the caller's job.
protocol WeatherProvider: Sendable {
    var id: WeatherProviderID { get }
    func fetch(_ area: WeatherArea, now: Date) async throws -> WeatherReport
}

/// Why a fetch failed, as far as the card cares.
enum WeatherFetchFailure: Equatable {
    /// No connection (the desert): «غير متاح بدون إنترنت».
    case offline
    /// Anything else (server, decoding, auth).
    case server

    static func of(_ e: Error) -> WeatherFetchFailure {
        if let u = e as? URLError, [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .timedOut].contains(u.code) {
            return .offline
        }
        return .server
    }
}

/// Open-Meteo forecast + air quality (dust, PM10). Free host by default (non-commercial);
/// pass a customer host + key for the paid plan.
struct OpenMeteoProvider: WeatherProvider {
    var transport: WeatherTransport = CoalescingWeatherTransport()
    /// Paid plan: e.g. "customer-api.open-meteo.com" with `apiKey`.
    var apiKey: String? = nil
    var id: WeatherProviderID { .openMeteo }

    func fetch(_ a: WeatherArea, now: Date) async throws -> WeatherReport {
        async let f = transport.data(from: Self.keyed(OpenMeteo.forecastURL(a), apiKey))
        /* Dust is a bonus: its failure leaves dust «غير متاح», never «لا غبار». */
        async let air: Data? = try? transport.data(from: Self.keyed(OpenMeteo.airURL(a), apiKey))
        let (fd, ad) = try await (f, air)
        return try OpenMeteo.parse(forecast: fd, air: ad, area: a, fetchedAt: now)
    }

    static func keyed(_ url: URL, _ key: String?) -> URL {
        guard let key, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.host = c.host.map { "customer-" + $0 }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "apikey", value: key)]
        return c.url ?? url
    }
}

/// The first provider that answers wins (WeatherKit, then Open-Meteo).
struct FallbackWeatherProvider: Sendable {
    var providers: [any WeatherProvider]

    func fetch(_ a: WeatherArea, now: Date) async throws -> PlaceWeather {
        var last: Error = URLError(.unknown)
        for p in providers {
            do { return PlaceWeather(report: try await p.fetch(a, now: now), provider: p.id) } catch { last = error }
        }
        throw last
    }
}

enum WeatherProviders {
    /// WeatherKit as the primary source. OFF until the App ID's WeatherKit capability is in
    /// the provisioning profile (com.apple.developer.weatherkit entitlement); without it every
    /// WeatherKit call fails with an auth error and we would only add latency before Open-Meteo.
    static let weatherKitEnabled = false

    /// The chain the place brief uses.
    static var placeBrief: FallbackWeatherProvider {
        var list: [any WeatherProvider] = []
        #if canImport(WeatherKit)
        if weatherKitEnabled { list.append(WeatherKitProvider()) }
        #endif
        list.append(OpenMeteoProvider())
        return FallbackWeatherProvider(providers: list)
    }
}

#if canImport(WeatherKit)
import WeatherKit

/// Apple WeatherKit (500k calls / month included with the developer membership). No dust or
/// PM10: with it the card says «الغبار غير متاح» instead of guessing.
struct WeatherKitProvider: WeatherProvider {
    var id: WeatherProviderID { .weatherKit }

    func fetch(_ a: WeatherArea, now: Date) async throws -> WeatherReport {
        let loc = CLLocation(latitude: a.lat, longitude: a.lng)
        let end = now.addingTimeInterval(48 * 3600)
        let (cur, hourly) = try await WeatherKit.WeatherService.shared.weather(for: loc, including: .current, .hourly(startDate: now.addingTimeInterval(-3600), endDate: end))
        let hours = hourly.forecast.map { h in
            WeatherHour(time: h.date, temperatureC: h.temperature.converted(to: .celsius).value,
                        precipitationMm: h.precipitationAmount.converted(to: .millimeters).value,
                        precipitationProbability: h.precipitationChance * 100, weatherCode: Self.wmo(h.condition),
                        windKmh: h.wind.speed.converted(to: .kilometersPerHour).value,
                        gustKmh: h.wind.gust?.converted(to: .kilometersPerHour).value,
                        windFromDeg: h.wind.direction.converted(to: .degrees).value,
                        visibilityM: h.visibility.converted(to: .meters).value, dust: nil, pm10: nil,
                        apparentC: h.apparentTemperature.converted(to: .celsius).value, humidity: h.humidity * 100, uvIndex: Double(h.uvIndex.value))
        }
        let c = WeatherHour(time: cur.date, temperatureC: cur.temperature.converted(to: .celsius).value, precipitationMm: nil,
                            precipitationProbability: nil, weatherCode: Self.wmo(cur.condition),
                            windKmh: cur.wind.speed.converted(to: .kilometersPerHour).value,
                            gustKmh: cur.wind.gust?.converted(to: .kilometersPerHour).value,
                            windFromDeg: cur.wind.direction.converted(to: .degrees).value,
                            visibilityM: cur.visibility.converted(to: .meters).value, dust: nil, pm10: nil,
                            apparentC: cur.apparentTemperature.converted(to: .celsius).value, humidity: cur.humidity * 100, uvIndex: Double(cur.uvIndex.value))
        guard !hours.isEmpty else { throw OpenMeteo.ParseError.noHours }
        return WeatherReport(area: a, fetchedAt: now, current: c, hours: hours.sorted { $0.time < $1.time }, airAvailable: false)
    }

    /// Apple's condition → the WMO code our rules already understand (nil when there is no match).
    static func wmo(_ c: WeatherCondition) -> Int? {
        switch c {
        case .clear, .hot: return 0
        case .mostlyClear: return 1
        case .partlyCloudy: return 2
        case .mostlyCloudy, .cloudy: return 3
        case .foggy, .haze, .smoky: return 45
        case .drizzle, .freezingDrizzle: return 53
        case .sunShowers, .sunFlurries: return 80
        case .rain, .freezingRain: return 63
        case .heavyRain: return 65
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms: return 95
        case .hail: return 96
        case .snow, .heavySnow, .flurries, .sleet, .wintryMix, .blizzard, .blowingSnow: return 73
        default: return nil
        }
    }
}
#endif
