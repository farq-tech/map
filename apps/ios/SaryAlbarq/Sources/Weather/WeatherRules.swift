import Foundation

/// Every threshold the weather feature uses, in one place (unit-tested).
///
/// They are field rules of thumb for desert outings, NOT official warning
/// criteria; the app always points to the National Center for Meteorology
/// (NCM) for official warnings.
enum WeatherThresholds {
    // Wind, km/h at 10 m.
    /// «رياح نشطة»: shown on the card, no alert.
    static let windActive = 30.0
    /// Alert «رياح قوية»: sustained ≥ 40 km/h or gusts ≥ 60 km/h (tents, doors, sand lifting).
    static let windStrong = 40.0
    static let gustStrong = 60.0
    /// «رياح شديدة»: sustained ≥ 60 or gusts ≥ 80 km/h.
    static let windSevere = 60.0
    static let gustSevere = 80.0

    // Dust, CAMS surface dust µg/m³ (approximate visibility in brackets).
    /// «غبار خفيف» from 100 (haze, visibility still > 5 km).
    static let dustLight = 100.0
    /// «غبار متوسط» from 300 (visibility roughly 2–5 km).
    static let dustModerate = 300.0
    /// «غبار كثيف» from 1000 (visibility can fall to 1 km or less).
    static let dustHeavy = 1000.0
    /// Model visibility below this counts as "reduced".
    static let visibilityReducedM = 5_000.0

    // Rain.
    /// An hour counts as "rain expected" from this probability (%)…
    static let rainProbability = 50.0
    /// …or this much rain in the hour (mm).
    static let rainHourMm = 0.5
    /// Flood-relevant rain: total over the next 24 h…
    static let floodTotal24hMm = 5.0
    /// …or any single hour this wet (mm).
    static let floodHourMm = 2.0

    // Wadis.
    /// A wadi this close to a member, the rally point, the destination or the route counts.
    static let wadiNearM = 1_000.0
    /// Closer than this: «أنتم في مجرى وادٍ».
    static let wadiInsideM = 150.0

    // Windows.
    /// Wind / dust alerts look at now + the next 3 h.
    static let soonHours = 3
    /// Rain alerts look at the next 12 h; floods at the next 24 h.
    static let rainHours = 12
    static let floodHours = 24

    // Data age.
    /// Newer than this: the model's "current" value is shown as «الآن».
    static let freshS: TimeInterval = 60 * 60
    /// Do not refetch while the data is younger than this (Open-Meteo updates hourly).
    static let refetchS: TimeInterval = 30 * 60
    /// Alerts are raised only from data younger than this.
    static let alertMaxAgeS: TimeInterval = 3 * 3600
    /// The same alert at the same level comes back at most once in this window.
    static let alertRepeatS: TimeInterval = 3 * 3600
}

enum DustLevel: Int, Comparable, Codable {
    case clear, light, moderate, heavy

    static func < (a: DustLevel, b: DustLevel) -> Bool { a.rawValue < b.rawValue }

    static func of(_ dust: Double?) -> DustLevel? {
        guard let d = dust else { return nil }
        if d >= WeatherThresholds.dustHeavy { return .heavy }
        if d >= WeatherThresholds.dustModerate { return .moderate }
        if d >= WeatherThresholds.dustLight { return .light }
        return .clear
    }

    var label: String {
        switch self {
        case .clear: return "لا غبار يُذكر"
        case .light: return "غبار خفيف"
        case .moderate: return "غبار متوسط"
        case .heavy: return "غبار كثيف"
        }
    }
}

/// How old the data is, said honestly.
enum WeatherFreshness: Equatable {
    /// Younger than an hour: the model's current value is «الآن».
    case fresh
    /// Older: "now" is the forecast hour, from data this old.
    case stale(age: TimeInterval)
    /// The forecast no longer covers now: nothing to show as current.
    case expired

    static func of(_ r: WeatherReport, now: Date) -> WeatherFreshness {
        let age = max(0, now.timeIntervalSince(r.fetchedAt))
        guard let last = r.hours.last, now < last.time.addingTimeInterval(3600) else { return .expired }
        return age <= WeatherThresholds.freshS ? .fresh : .stale(age: age)
    }
}

enum WeatherRules {
    /// What to show as "now": the model's current value only while the data is
    /// fresh; otherwise the forecast for the hour that contains `now` (labelled as such).
    static func nowValue(_ r: WeatherReport, now: Date) -> (hour: WeatherHour, observed: Bool)? {
        switch WeatherFreshness.of(r, now: now) {
        case .expired: return nil
        case .fresh: if let c = r.current { return (c, true) }; fallthrough
        case .stale: return hour(containing: now, in: r).map { ($0, false) }
        }
    }

    static func hour(containing t: Date, in r: WeatherReport) -> WeatherHour? {
        r.hours.last { $0.time <= t && t < $0.time.addingTimeInterval(3600) }
    }

    /// Hours starting with the one that contains `now`.
    static func upcoming(_ r: WeatherReport, now: Date, count: Int) -> [WeatherHour] {
        Array(r.hours.filter { $0.time.addingTimeInterval(3600) > now }.prefix(count))
    }

    static func rainExpected(_ h: WeatherHour) -> Bool {
        (h.precipitationProbability ?? 0) >= WeatherThresholds.rainProbability || (h.precipitationMm ?? 0) >= WeatherThresholds.rainHourMm
    }

    /// Highest rain chance in the next `hours` (nil when the model gives none).
    static func maxRainChance(_ r: WeatherReport, now: Date, hours: Int = WeatherThresholds.rainHours) -> Double? {
        upcoming(r, now: now, count: hours).compactMap(\.precipitationProbability).max()
    }

    static func rainTotal(_ r: WeatherReport, now: Date, hours: Int) -> Double {
        upcoming(r, now: now, count: hours).compactMap(\.precipitationMm).reduce(0, +)
    }

    static func floodRain(_ r: WeatherReport, now: Date) -> Bool {
        let next = upcoming(r, now: now, count: WeatherThresholds.floodHours)
        return rainTotal(r, now: now, hours: WeatherThresholds.floodHours) >= WeatherThresholds.floodTotal24hMm
            || next.contains { ($0.precipitationMm ?? 0) >= WeatherThresholds.floodHourMm }
    }

    /// 0 = calm / active only, 1 = strong, 2 = severe.
    static func windLevel(_ h: WeatherHour) -> Int {
        let w = h.windKmh ?? 0, g = h.gustKmh ?? 0
        if w >= WeatherThresholds.windSevere || g >= WeatherThresholds.gustSevere { return 2 }
        if w >= WeatherThresholds.windStrong || g >= WeatherThresholds.gustStrong { return 1 }
        return 0
    }

    /// The wind blows TOWARDS this bearing (the arrow points this way, from north).
    static func windArrowDeg(from: Double) -> Double {
        ((from + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// «رياح شمالية غربية»: named after where it comes FROM.
    static func windName(from deg: Double) -> String {
        let names = ["شمالية", "شمالية شرقية", "شرقية", "جنوبية شرقية", "جنوبية", "جنوبية غربية", "غربية", "شمالية غربية"]
        let d = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }

    /// WMO weather code → Arabic + SF Symbol.
    static func condition(_ code: Int?) -> (text: String, symbol: String) {
        switch code {
        case 0?: return ("صحو", "sun.max.fill")
        case 1?: return ("صحو غالبًا", "sun.max.fill")
        case 2?: return ("غائم جزئيًا", "cloud.sun.fill")
        case 3?: return ("غائم", "cloud.fill")
        case 45?, 48?: return ("ضباب", "cloud.fog.fill")
        case 51?, 53?, 55?, 56?, 57?: return ("رذاذ", "cloud.drizzle.fill")
        case 61?, 66?: return ("مطر خفيف", "cloud.rain.fill")
        case 63?: return ("مطر", "cloud.rain.fill")
        case 65?, 67?: return ("مطر غزير", "cloud.heavyrain.fill")
        case 71?, 73?, 75?, 77?, 85?, 86?: return ("ثلج", "cloud.snow.fill")
        case 80?, 81?: return ("زخات مطر", "cloud.sun.rain.fill")
        case 82?: return ("زخات غزيرة", "cloud.heavyrain.fill")
        case 95?: return ("عواصف رعدية", "cloud.bolt.rain.fill")
        case 96?, 99?: return ("عواصف رعدية مع برد", "cloud.bolt.rain.fill")
        default: return ("—", "cloud.fill")
        }
    }

    /// The condition, but dust wins over «صحو» when there is enough of it to matter.
    static func displayCondition(_ h: WeatherHour) -> (text: String, symbol: String) {
        if let d = DustLevel.of(h.dust), d >= .moderate, !rainExpected(h) { return (d.label, "sun.dust.fill") }
        return condition(h.weatherCode)
    }
}

// MARK: - Alerts

enum WeatherAlertKind: String, Codable, CaseIterable {
    case wind, dust, rain, flood
}

/// One weather card for the alert lane.
struct WeatherAlertUI: Equatable, Identifiable {
    var kind: WeatherAlertKind
    /// Which forecast: the outing area or the destination.
    var forDestination: Bool
    /// Higher = more serious (escalation re-alerts inside the repeat window).
    var level: Int
    var title: String
    var detail: String
    var id: String { "weather\(forDestination ? "-dest" : ""):\(kind.rawValue)" }
}

/// Nearest mapped wadi to the group / route / destination, when the map has loaded some.
struct WadiContext: Equatable {
    var distanceM: Double
    var name: String?
}

enum WeatherAlerts {
    /// Everything worth an alert right now. Only from data younger than
    /// `alertMaxAgeS`; nothing at all from expired data.
    static func evaluate(_ r: WeatherReport, now: Date, wadi: WadiContext?, forDestination: Bool = false) -> [WeatherAlertUI] {
        guard now.timeIntervalSince(r.fetchedAt) <= WeatherThresholds.alertMaxAgeS, WeatherFreshness.of(r, now: now) != .expired else { return [] }
        var out: [WeatherAlertUI] = []
        let prefix = forDestination ? "في الوجهة: " : ""
        var soon = WeatherRules.upcoming(r, now: now, count: WeatherThresholds.soonHours)
        if let c = WeatherRules.nowValue(r, now: now)?.hour { soon.insert(c, at: 0) }

        /* Wind */
        if let worst = soon.max(by: { WeatherRules.windLevel($0) < WeatherRules.windLevel($1) || (WeatherRules.windLevel($0) == WeatherRules.windLevel($1) && ($0.gustKmh ?? 0) < ($1.gustKmh ?? 0)) }),
           WeatherRules.windLevel(worst) > 0 {
            let lvl = WeatherRules.windLevel(worst)
            let gust = soon.compactMap(\.gustKmh).max() ?? worst.gustKmh ?? 0
            out.append(WeatherAlertUI(kind: .wind, forDestination: forDestination, level: lvl,
                                      title: prefix + (lvl == 2 ? "رياح شديدة" : "رياح قوية"),
                                      detail: "هبّات حتى \(WeatherFormat.speed(gust)) \(when(worst.time, now: now)) • ثبّت الخيام وانتبه للأبواب"))
        }

        /* Dust reducing visibility */
        let dustNow = soon.compactMap { DustLevel.of($0.dust) }.max() ?? .clear
        let lowVis = soon.contains { ($0.visibilityM ?? .infinity) < WeatherThresholds.visibilityReducedM }
        if dustNow >= .moderate || (dustNow >= .light && lowVis) {
            let lvl = dustNow == .heavy ? 2 : 1
            out.append(WeatherAlertUI(kind: .dust, forDestination: forDestination, level: lvl,
                                      title: prefix + (dustNow == .heavy ? "غبار كثيف يحجب الرؤية" : "\(dustNow.label) يقلل الرؤية"),
                                      detail: dustNow == .heavy ? "الرؤية قد تقل إلى كيلو أو أقل • خفّف السرعة وشغّل الأنوار" : "خفّفوا السرعة وشغّلوا الأنوار وتلاحقوا"))
        }

        /* Rain, and floods near a wadi */
        let rainHours = WeatherRules.upcoming(r, now: now, count: WeatherThresholds.rainHours)
        if let first = rainHours.first(where: WeatherRules.rainExpected) {
            let chance = rainHours.compactMap(\.precipitationProbability).max()
            let total = WeatherRules.rainTotal(r, now: now, hours: WeatherThresholds.rainHours)
            var bits = [when(first.time, now: now)]
            if let chance { bits.append("احتمال \(SaryFormat.percent(Int(chance.rounded())))") }
            if total >= 0.1 { bits.append("نحو \(WeatherFormat.mm(total))") }
            out.append(WeatherAlertUI(kind: .rain, forDestination: forDestination, level: 1, title: prefix + "مطر متوقع", detail: bits.joined(separator: " • ")))
        }
        if let w = wadi, w.distanceM <= WeatherThresholds.wadiNearM, WeatherRules.floodRain(r, now: now) {
            let where_ = w.distanceM <= WeatherThresholds.wadiInsideM ? "أنتم في مجرى وادٍ أو بجانبه" : "وادٍ على بعد \(SaryFormat.distance(meters: w.distanceM))"
            out.append(WeatherAlertUI(kind: .flood, forDestination: forDestination, level: w.distanceM <= WeatherThresholds.wadiInsideM ? 2 : 1,
                                      title: prefix + "انتبهوا من السيول في الشعبان والأودية",
                                      detail: "\(where_) ومطر متوقع \(WeatherFormat.mm(WeatherRules.rainTotal(r, now: now, hours: WeatherThresholds.floodHours))) • لا تخيّموا في بطن الوادي. تقدير، تابع تحذيرات المركز الوطني للأرصاد"))
        }
        return out
    }

    /// «الآن» / «خلال ساعة» / «خلال ٣ س».
    static func when(_ t: Date, now: Date) -> String {
        let h = Int((t.timeIntervalSince(now) / 3600).rounded(.up))
        if h <= 0 { return "الآن" }
        if h == 1 { return "خلال ساعة" }
        return "خلال \(SaryFormat.number(h)) س"
    }
}

/// Rate limit for the alert lane: one alert per kind (and forecast) per
/// `alertRepeatS`, unless it got worse. Persisted per outing.
struct WeatherAlertGate: Codable, Equatable {
    struct Fired: Codable, Equatable { var level: Int; var at: Date }
    var fired: [String: Fired] = [:]

    mutating func admit(_ a: WeatherAlertUI, now: Date) -> Bool {
        if let f = fired[a.id], a.level <= f.level, now.timeIntervalSince(f.at) < WeatherThresholds.alertRepeatS { return false }
        fired[a.id] = Fired(level: a.level, at: now)
        return true
    }

    static func load(outing: String, defaults: UserDefaults = .standard) -> WeatherAlertGate {
        defaults.data(forKey: key(outing)).flatMap { try? JSONDecoder().decode(WeatherAlertGate.self, from: $0) } ?? WeatherAlertGate()
    }

    func save(outing: String, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key(outing)) }
    }

    static func key(_ outing: String) -> String { "sary.weather.gate.v1.\(outing)" }
}

// MARK: - Arrival estimate (destination)

enum ArrivalEstimate {
    /// Used when we have no recent driving speed: a cautious off-road average.
    static let defaultKmh = 50.0
    /// Below this the recent average is "parked", not a driving speed.
    static let minMovingKmh = 5.0

    struct Result: Equatable {
        var eta: Date
        var distanceM: Double
        var speedKmh: Double
        /// True when `speedKmh` is the default, not our recent speed.
        var assumedSpeed: Bool
    }

    /// Straight-line distance ÷ speed, from `departure` (now, or a time the person chose).
    static func estimate(from: Geo.LatLng, to: Geo.LatLng, recentKmh: Double?, departure: Date) -> Result {
        let d = Geo.haversineMeters(from, to)
        let moving = recentKmh.flatMap { $0 >= minMovingKmh ? $0 : nil }
        let v = moving ?? defaultKmh
        return Result(eta: departure.addingTimeInterval(d / (v / 3.6)), distanceM: d, speedKmh: v, assumedSpeed: moving == nil)
    }

    /// Average speed over recent fixes (path length ÷ time), km/h. Nil with fewer than 2 fixes or < 1 min.
    static func recentSpeedKmh(_ fixes: [DeviceFix]) -> Double? {
        guard fixes.count >= 2, let a = fixes.first, let b = fixes.last, b.atMs - a.atMs >= 60_000 else { return nil }
        var m = 0.0
        for i in 1..<fixes.count { m += Geo.haversineMeters(fixes[i - 1].coordinate, fixes[i].coordinate) }
        return m / ((b.atMs - a.atMs) / 1000) * 3.6
    }
}

// MARK: - Formatting

enum WeatherFormat {
    static func temp(_ c: Double?) -> String { c.map { "\(SaryFormat.number(Int($0.rounded())))°" } ?? "—" }
    static func speed(_ kmh: Double) -> String { "\(SaryFormat.number(Int(kmh.rounded()))) كم/س" }
    static func mm(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(SaryFormat.number(Int(r))) مم" : "\(SaryFormat.digits(String(format: "%.1f", r))) مم"
    }
    static func visibility(_ m: Double?) -> String {
        guard let m else { return "—" }
        return m >= 10_000 ? "أكثر من ١٠ كم" : SaryFormat.distance(meters: m)
    }

    /// «٣ م», «١١ ص» in the device's time zone.
    static func hour(_ d: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let h = cal.component(.hour, from: d)
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(SaryFormat.number(h12)) \(h < 12 ? "ص" : "م")"
    }

    /// «٤:٣٠ م» (`SaryFormat.timeOfDay`).
    static func clock(_ d: Date, timeZone: TimeZone = .current) -> String {
        SaryFormat.timeOfDay(d, timeZone: timeZone)
    }
}
