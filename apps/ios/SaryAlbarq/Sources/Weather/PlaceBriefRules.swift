import Foundation

// «بريف المكان»: the brief for a tapped map spot. Pure rules and formatting
// (unit-tested in PlaceBriefTests); every line traces back to a number we were given.

/// Terrain at the spot, from the map's loaded Mapbox Terrain-DEM tiles only (never guessed).
struct TerrainSample: Equatable {
    var elevationM: Double?
    /// Steepest slope from four DEM samples around the spot (degrees); nil unless all five exist.
    var slopeDeg: Double?

    static let unavailable = TerrainSample(elevationM: nil, slopeDeg: nil)
}

/// The tapped spot's name and where it came from.
struct PlaceName: Equatable {
    enum Source: Equatable { case saved, map, geocoder }
    var text: String
    var source: Source
    /// From the geocoder at town / region level: shown as «قرب …».
    var approximate = false

    var display: String { approximate ? "قرب \(text)" : text }
}

/// The camping / outing line: its level and the numbers behind it.
struct PlaceAssessment: Equatable {
    enum Level: Int, Comparable {
        case unknown, good, caution, poor
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    var level: Level
    var title: String
    /// One line per rule that fired (or, when all is well, the values that were checked).
    var reasons: [String]
    /// «التقييم من توقعات قبل ٣ س» when the data is not current.
    var note: String?
}

enum PlaceBriefThresholds {
    /// The owner's rule of thumb: sustained wind above 35 km/h spoils a camp (tents, sand).
    static let windPoor = 35.0
    static let gustPoor = 55.0
    static let windCaution = 25.0
    static let gustCaution = 40.0
    /// Feels-like heat (°C).
    static let heatPoor = 40.0
    static let heatCaution = 35.0
    static let cold = 5.0
    static let uvHigh = 8.0
    /// Less daylight than this left: say so.
    static let daylightShortS: TimeInterval = 60 * 60
    /// Hours on the mini timeline.
    static let timelineHours = 12
    /// Taps closer together than this open one brief (debounce).
    static let tapDebounceS: TimeInterval = 0.6
    /// A saved place this close names the spot.
    static let savedPlaceNameM = 150.0
}

enum PlaceBriefRules {
    // MARK: feels like

    /// NWS heat index (Rothfusz regression, °C in / out) when it is hot and humid enough to matter.
    static func heatIndex(tempC t: Double, humidity rh: Double) -> Double? {
        guard t >= 26.7, rh >= 40 else { return nil }
        let f = t * 9 / 5 + 32
        var hi = -42.379 + 2.04901523 * f + 10.14333127 * rh - 0.22475541 * f * rh - 0.00683783 * f * f
            - 0.05481717 * rh * rh + 0.00122874 * f * f * rh + 0.00085282 * f * rh * rh - 0.00000199 * f * f * rh * rh
        if rh > 85, f >= 80, f <= 87 { hi += ((rh - 85) / 10) * ((87 - f) / 5) }
        return (hi - 32) * 5 / 9
    }

    /// The model's apparent temperature, else the heat index, else nil (never the air temperature dressed up).
    static func feelsLike(_ h: WeatherHour) -> Double? {
        if let a = h.apparentC { return a }
        guard let t = h.temperatureC, let rh = h.humidity else { return nil }
        return heatIndex(tempC: t, humidity: rh)
    }

    // MARK: UV

    /// WHO bands.
    static func uvBand(_ uv: Double) -> String {
        switch uv {
        case ..<3: return "منخفض"
        case ..<6: return "متوسط"
        case ..<8: return "عالٍ"
        case ..<11: return "عالٍ جدًا"
        default: return "شديد"
        }
    }

    static func uvText(_ uv: Double?) -> String {
        guard let uv else { return "غير متاح" }
        return "\(SaryFormat.number(Int(uv.rounded()))) • \(uvBand(uv))"
    }

    // MARK: sun

    struct SunDay: Equatable {
        var sunrise: Date?
        var sunset: Date?
        var isDay: Bool
    }

    /// The sunrise and sunset around `now` from the sun's position (no network). By day: this
    /// morning's sunrise and tonight's sunset; by night: the last sunset and the next sunrise.
    static func sun(now: Date, lat: Double, lng: Double) -> SunDay {
        let h = SunTimes.horizonDeg
        let isDay = SunLight.elevationDeg(now, lat: lat, lng: lng) > h
        func crossing(forward: Bool, rising: Bool) -> Date? {
            let step: TimeInterval = forward ? 300 : -300
            var t = now
            var el = SunLight.elevationDeg(t, lat: lat, lng: lng)
            for _ in 0..<(26 * 12) {
                let n = t.addingTimeInterval(step)
                let en = SunLight.elevationDeg(n, lat: lat, lng: lng)
                /* Order the pair in time so "rising" means below → above. */
                let (a, ea, b, eb) = forward ? (t, el, n, en) : (n, en, t, el)
                if rising ? (ea <= h && eb > h) : (ea > h && eb <= h) { return refine(a, b, lat: lat, lng: lng, rising: rising) }
                t = n
                el = en
            }
            return nil
        }
        if isDay { return SunDay(sunrise: crossing(forward: false, rising: true), sunset: crossing(forward: true, rising: false), isDay: true) }
        return SunDay(sunrise: crossing(forward: true, rising: true), sunset: crossing(forward: false, rising: false), isDay: false)
    }

    private static func refine(_ a0: Date, _ b0: Date, lat: Double, lng: Double, rising: Bool) -> Date {
        var a = a0, b = b0
        for _ in 0..<16 {
            let m = Date(timeIntervalSince1970: (a.timeIntervalSince1970 + b.timeIntervalSince1970) / 2)
            let above = SunLight.elevationDeg(m, lat: lat, lng: lng) > SunTimes.horizonDeg
            if above == rising { b = m } else { a = m }
        }
        return b
    }

    /// «باقي ٣ س ١٠ د من النهار» / «الشمس غربت • الشروق ٦:١٢ ص».
    static func daylightText(_ s: SunDay, now: Date, timeZone: TimeZone = .current) -> String {
        if s.isDay, let set = s.sunset {
            let left = Int(set.timeIntervalSince(now))
            return left < 60 ? "الغروب الآن" : "باقي \(SaryFormat.duration(seconds: left)) من النهار"
        }
        if let rise = s.sunrise { return "الشمس غاربة • الشروق \(WeatherFormat.clock(rise, timeZone: timeZone))" }
        return "أوقات الشمس غير متاحة"
    }

    // MARK: terrain

    /// Slope (degrees) from the centre and four samples `spacingM` east, west, north and south.
    static func slopeDeg(center: Double?, east: Double?, west: Double?, north: Double?, south: Double?, spacingM: Double) -> Double? {
        guard center != nil, let e = east, let w = west, let n = north, let s = south, spacingM > 0 else { return nil }
        let dx = (e - w) / (2 * spacingM), dy = (n - s) / (2 * spacingM)
        return atan(hypot(dx, dy)) * 180 / .pi
    }

    static func slopeLabel(_ deg: Double) -> String {
        switch deg {
        case ..<2: return "مستوٍ تقريبًا"
        case ..<6: return "ميل خفيف"
        case ..<12: return "ميل متوسط"
        default: return "منحدر شديد"
        }
    }

    static func elevationText(_ t: TerrainSample) -> String {
        guard let m = t.elevationM, m.isFinite else { return "الارتفاع غير متاح" }
        return "الارتفاع \(SaryFormat.number(Int(m.rounded()))) م"
    }

    static func slopeText(_ t: TerrainSample) -> String? {
        guard let d = t.slopeDeg, d.isFinite else { return nil }
        return "الميل نحو \(SaryFormat.number(Int(d.rounded())))° • \(slopeLabel(d))"
    }

    // MARK: header

    /// «على بعد ١٢٫٤ كم • شمال غرب منك» (straight line), «عند موقعك» when very close.
    static func distanceText(from me: LngLat?, to p: LngLat) -> String? {
        guard let me else { return nil }
        let d = PlanGeo.meters(me, p)
        if d < 30 { return "عند موقعك" }
        return "على بعد \(SaryFormat.distance(meters: d)) • \(Geo.directionLabel(PlanGeo.bearing(me, p))) منك"
    }

    // MARK: freshness / source

    /// «المصدر: Open-Meteo • ١١:٢٥ ص (قبل ٥ د)», never pretending old data is current. The clock time
    /// is when the data arrived on this phone (Build 36 item 12: «when was this updated?»).
    static func sourceLine(_ w: PlaceWeather, now: Date, failed: WeatherFetchFailure?, timeZone: TimeZone = .current) -> (text: String, stale: Bool) {
        let age = SaryFormat.elapsed(since: w.report.fetchedAt, now: now)
        let clock = WeatherFormat.clock(w.report.fetchedAt, timeZone: timeZone)
        let stale = now.timeIntervalSince(w.report.fetchedAt) > WeatherThresholds.freshS
        var parts = ["المصدر: \(w.provider.label)", "\(clock) (\(age))"]
        if stale { parts[1] = "بيانات محفوظة \(clock) (\(age)) — ليست حالية" }
        if failed == .offline { parts.append("بلا إنترنت") } else if failed == .server { parts.append("تعذّر التحديث") }
        return (parts.joined(separator: " • "), stale)
    }

    // MARK: assessment

    /// «تقييم للتخييم/الطلعة» from the numbers only; nil-safe (a missing number is said, not assumed).
    static func assessment(_ r: WeatherReport, now: Date, sun: SunDay? = nil) -> PlaceAssessment {
        guard let (h, observed) = WeatherRules.nowValue(r, now: now) else {
            return PlaceAssessment(level: .unknown, title: "لا تقييم: التوقعات المحفوظة انتهت", reasons: [])
        }
        typealias T = PlaceBriefThresholds
        var poor: [String] = [], caution: [String] = [], checked: [String] = [], missing: [String] = []
        let soon = [h] + WeatherRules.upcoming(r, now: now, count: 3)

        /* Wind: the worst of now + 3 h. */
        let wind = soon.compactMap(\.windKmh).max(), gust = soon.compactMap(\.gustKmh).max()
        /* The worst value may come later than now: say so, so the line matches the «now» facts above it. */
        let later = " خلال ٣ س"
        if let w = wind {
            let g = gust.map { " (هبّات \(WeatherFormat.speed($0)))" } ?? ""
            let windLater = w > (h.windKmh ?? -1) || (gust ?? 0) > (h.gustKmh ?? -1) ? later : ""
            if w > T.windPoor || (gust ?? 0) > T.gustPoor { poor.append("رياح قوية \(WeatherFormat.speed(w))\(g)\(windLater) — فوق \(SaryFormat.number(Int(T.windPoor))) كم/س") }
            else if w > T.windCaution || (gust ?? 0) > T.gustCaution { caution.append("رياح نشطة \(WeatherFormat.speed(w))\(g)\(windLater)") }
            else { checked.append("رياح \(WeatherFormat.speed(w))") }
        } else { missing.append("الرياح") }

        /* Heat: feels-like when we have it, else the air temperature. */
        if let t = feelsLike(h) ?? h.temperatureC {
            let word = feelsLike(h) == nil ? "الحرارة" : "يُحس كأنها"
            if t >= T.heatPoor { poor.append("حر شديد: \(word) \(WeatherFormat.temp(t)) — \(SaryFormat.number(Int(T.heatPoor)))° فأكثر") }
            else if t >= T.heatCaution { caution.append("حر: \(word) \(WeatherFormat.temp(t))") }
            else if let a = h.temperatureC, a <= T.cold { caution.append("برد: \(WeatherFormat.temp(a))") }
            else { checked.append("حرارة \(WeatherFormat.temp(h.temperatureC ?? t))") }
        } else { missing.append("الحرارة") }

        /* Dust / visibility. */
        if r.airAvailable, let worst = soon.filter({ $0.dust != nil }).max(by: { ($0.dust ?? 0) < ($1.dust ?? 0) }), let d = DustLevel.of(worst.dust) {
            let pm = worst.pm10.map { " (PM10 \(SaryFormat.number(Int($0.rounded()))))" } ?? ""
            let when = d > (DustLevel.of(h.dust) ?? .clear) ? later : ""
            if d >= .moderate { poor.append("\(d.label)\(pm)\(when)") }
            else if d == .light { caution.append("\(d.label)\(pm)\(when)") }
            else { checked.append("بلا غبار يُذكر") }
        } else { missing.append("الغبار") }
        if let v = h.visibilityM, v < WeatherThresholds.visibilityReducedM { caution.append("الرؤية \(WeatherFormat.visibility(v))") }

        /* Rain, storms and floods (this point's forecast; upstream catchments are not modelled). */
        let next12 = WeatherRules.upcoming(r, now: now, count: WeatherThresholds.rainHours)
        if next12.contains(where: { (95...99).contains($0.weatherCode ?? 0) }) {
            poor.append("عواصف رعدية متوقعة خلال ١٢ س")
        }
        if WeatherRules.floodRain(r, now: now) {
            poor.append("مطر قد يجري الأودية: \(WeatherFormat.mm(WeatherRules.rainTotal(r, now: now, hours: WeatherThresholds.floodHours))) خلال ٢٤ س — لا تخيّم في بطن وادٍ")
        } else if let first = next12.first(where: WeatherRules.rainExpected) {
            let chance = next12.compactMap(\.precipitationProbability).max().map { " • احتمال \(SaryFormat.percent(Int($0.rounded())))" } ?? ""
            caution.append("مطر متوقع \(WeatherAlerts.when(first.time, now: now))\(chance)")
        } else if next12.contains(where: { $0.precipitationProbability != nil }) {
            checked.append("لا مطر متوقع خلال ١٢ س")
        } else { missing.append("المطر") }

        /* Sun. */
        if let uv = h.uvIndex, uv >= T.uvHigh { caution.append("أشعة شمس قوية (UV \(SaryFormat.number(Int(uv.rounded())))) — ظل وماء") }
        if let s = sun, s.isDay, let set = s.sunset, set.timeIntervalSince(now) < T.daylightShortS {
            caution.append("باقي أقل من ساعة على الغروب")
        }

        let level: PlaceAssessment.Level = !poor.isEmpty ? .poor : (!caution.isEmpty ? .caution : (checked.isEmpty ? .unknown : .good))
        var reasons = poor + caution
        if level == .good { reasons = checked }
        if !missing.isEmpty { reasons.append("غير متاح: \(missing.joined(separator: "، "))") }
        let title: String
        switch level {
        case .poor: title = "غير مناسب للتخييم الآن"
        case .caution: title = "مناسب مع الحذر"
        case .good: title = "مناسب للتخييم والطلعة"
        case .unknown: title = "لا تقييم: البيانات غير كافية"
        }
        return PlaceAssessment(level: level, title: title, reasons: reasons, note: note(r, now: now, observed: observed))
    }

    /// Said only when the data is older than an hour (fresh hourly forecasts are the reading).
    private static func note(_ r: WeatherReport, now: Date, observed: Bool) -> String? {
        guard !observed, now.timeIntervalSince(r.fetchedAt) > WeatherThresholds.freshS else { return nil }
        return "التقييم من توقعات \(SaryFormat.elapsed(since: r.fetchedAt, now: now)) — ليست قراءة حالية"
    }
}

// MARK: - Presenter

/// Plain values for the brief section of the point card.
struct PlaceBriefUI: Equatable {
    enum Phase: Equatable { case loading, unavailable(String), ready }
    var phase: Phase = .loading
    /// «الآن» or «متوقع لهذه الساعة» (older data: never shown as current).
    var nowLabel = ""
    var temp = "—"
    var condition = ""
    var symbol = "cloud.fill"
    var feelsLike: String?
    var wind: WeatherWindUI?
    var humidity = "الرطوبة غير متاحة"
    var dust = "الغبار غير متاح"
    var dustLevel: DustLevel?
    var visibility = "—"
    var uv = "غير متاح"
    var rain = "المطر غير متاح"
    var hours: [WeatherHourUI] = []
    var sunrise: String?
    var sunset: String?
    var daylight = ""
    var assessment: PlaceAssessment?
    var source = ""
    /// «نقطة التوقع على بعد أقل من ١ كم من النقطة».
    var forecastPoint: String?
    var stale = false
    var offline = false
    var provider: WeatherProviderID?
}

enum PlaceBriefPresenter {
    static func build(_ w: PlaceWeather?, loading: Bool, failed: WeatherFetchFailure?, point: LngLat, now: Date, timeZone: TimeZone = .current) -> PlaceBriefUI {
        var ui = PlaceBriefUI()
        let sun = PlaceBriefRules.sun(now: now, lat: point.lat, lng: point.lng)
        ui.sunrise = sun.sunrise.map { WeatherFormat.clock($0, timeZone: timeZone) }
        ui.sunset = sun.sunset.map { WeatherFormat.clock($0, timeZone: timeZone) }
        ui.daylight = PlaceBriefRules.daylightText(sun, now: now, timeZone: timeZone)
        ui.offline = failed == .offline
        guard let w else {
            if let failed {
                ui.phase = .unavailable(failed == .offline ? "الطقس غير متاح بدون إنترنت، وما فيه قراءة محفوظة قريبة من هذه النقطة" : "تعذّر جلب الطقس لهذه النقطة. حاول بعد قليل")
            } else {
                ui.phase = loading ? .loading : .unavailable("الطقس غير متاح")
            }
            return ui
        }
        let r = w.report
        ui.provider = w.provider
        let src = PlaceBriefRules.sourceLine(w, now: now, failed: failed, timeZone: timeZone)
        ui.source = src.text
        ui.forecastPoint = WeatherProvenance.point(r, reference: WeatherReference(point: Geo.LatLng(lat: point.lat, lng: point.lng), label: "من النقطة"))
        ui.stale = src.stale
        guard let (h, observed) = WeatherRules.nowValue(r, now: now) else {
            ui.phase = .unavailable("آخر توقعات محفوظة لهذه النقطة انتهت (\(SaryFormat.elapsed(since: r.fetchedAt, now: now))). اتصل بالإنترنت لتحديثها")
            ui.stale = true
            return ui
        }
        ui.phase = .ready
        ui.nowLabel = observed ? "الآن" : "متوقع لهذه الساعة"
        ui.temp = WeatherFormat.temp(h.temperatureC)
        let c = WeatherRules.displayCondition(h)
        ui.condition = c.text
        ui.symbol = c.symbol
        ui.feelsLike = PlaceBriefRules.feelsLike(h).map { "يُحس كأنها \(WeatherFormat.temp($0))" }
        ui.wind = WeatherPresenter.wind(h)
        ui.humidity = h.humidity.map { "الرطوبة \(SaryFormat.percent(Int($0.rounded())))" } ?? "الرطوبة غير متاحة"
        if r.airAvailable, let d = DustLevel.of(h.dust) {
            ui.dustLevel = d
            ui.dust = d.label + (h.pm10.map { " • PM10 \(SaryFormat.number(Int($0.rounded()))) µg/m³" } ?? "")
        } else {
            ui.dust = w.provider == .weatherKit ? "الغبار غير متاح من Apple Weather" : "الغبار غير متاح"
        }
        ui.visibility = WeatherFormat.visibility(h.visibilityM)
        if (ui.dustLevel ?? .clear) >= .moderate, (h.visibilityM ?? .infinity) >= WeatherThresholds.visibilityReducedM { ui.visibility = "قد تقل بسبب الغبار" }
        ui.uv = PlaceBriefRules.uvText(h.uvIndex)
        ui.rain = rainText(r, now: now)
        ui.hours = WeatherRules.upcoming(r, now: now, count: PlaceBriefThresholds.timelineHours).enumerated()
            .map { i, x in WeatherPresenter.hourUI(x, label: i == 0 ? "الآن" : WeatherFormat.hour(x.time, timeZone: timeZone)) }
        ui.assessment = PlaceBriefRules.assessment(r, now: now, sun: sun)
        return ui
    }

    /// «احتمال ٣٠٪ • نحو ١٫٢ مم خلال ١٢ س» / «لا مطر متوقع خلال ١٢ س».
    static func rainText(_ r: WeatherReport, now: Date) -> String {
        guard let chance = WeatherRules.maxRainChance(r, now: now) else { return "احتمال المطر غير متاح" }
        let total = WeatherRules.rainTotal(r, now: now, hours: WeatherThresholds.rainHours)
        if chance < 10, total < 0.1 { return "لا مطر متوقع خلال ١٢ س" }
        var s = "احتمال المطر حتى \(SaryFormat.percent(Int(chance.rounded())))"
        if total >= 0.1 { s += " • نحو \(WeatherFormat.mm(total))" }
        return s + " خلال ١٢ س"
    }

    /// The driving one-liner: «٣١° • رياح ٢٢ كم/س • غبار كثيف».
    static func compactLine(_ ui: PlaceBriefUI) -> String {
        guard ui.phase == .ready else { return "" }
        var bits = [ui.temp]
        if let w = ui.wind { bits.append("رياح \(w.speed)") }
        if let d = ui.dustLevel, d >= .light { bits.append(d.label) }
        return bits.joined(separator: " • ")
    }
}
