import Foundation

/// Plain values for the weather card / sheet. Built by `WeatherPresenter` (tested).
struct WeatherWindUI: Equatable {
    var speed: String
    var gust: String?
    /// Arrow rotation, degrees clockwise from north: where the wind blows TO.
    var arrowDeg: Double?
    /// «رياح شمالية غربية».
    var name: String?
    var level: Int
}

struct WeatherHourUI: Equatable, Identifiable {
    var id: Double
    var label: String
    var temp: String
    var symbol: String
    var rainChance: String?
    var arrowDeg: Double?
    var wind: String
}

struct WeatherArrivalUI: Equatable {
    /// «الوصول المتوقع ٤:٣٠ م».
    var etaText: String
    /// «٣٢ كم بخط مستقيم · بسرعتكم الأخيرة ٦٠ كم/س» or «… بافتراض ٥٠ كم/س».
    var basis: String
    /// The forecast hour at arrival, nil when arrival is beyond the forecast.
    var hour: WeatherHourUI?
    var condition: String?
}

struct WeatherCardUI: Equatable {
    enum Phase: Equatable { case loading, unavailable(String), ready }
    var title: String
    var phase: Phase
    /// «الآن» (fresh model value) or «متوقع لهذه الساعة» (from older data).
    var nowLabel: String = ""
    var temp: String = "—"
    var condition: String = ""
    var symbol: String = "cloud.fill"
    var wind: WeatherWindUI?
    var dust: DustLevel?
    var dustText: String = ""
    var visibility: String = "—"
    var rainText: String = ""
    var hours: [WeatherHourUI] = []
    /// «آخر تحديث قبل ٢٠ د».
    var updated: String = ""
    /// Data is older than an hour: shown in amber, never as current.
    var stale = false
    /// The last refresh failed.
    var offline = false
    var arrival: WeatherArrivalUI?
}

enum WeatherPresenter {
    static func card(title: String, report r: WeatherReport?, refreshing: Bool, failed: Bool, now: Date, hours count: Int = 8) -> WeatherCardUI {
        guard let r else {
            if failed { return WeatherCardUI(title: title, phase: .unavailable("تعذّر جلب الطقس، وما فيه بيانات محفوظة لهذه المنطقة"), offline: true) }
            return WeatherCardUI(title: title, phase: .loading)
        }
        let fresh = WeatherFreshness.of(r, now: now)
        var ui = WeatherCardUI(title: title, phase: .ready)
        ui.offline = failed
        ui.updated = SaryFormat.lastUpdate(since: r.fetchedAt, now: now)
        guard let (h, observed) = WeatherRules.nowValue(r, now: now) else {
            ui.phase = .unavailable("آخر توقعات محفوظة انتهت (\(SaryFormat.elapsed(since: r.fetchedAt, now: now))). اتصل بالإنترنت لتحديثها")
            ui.stale = true
            return ui
        }
        if case .stale = fresh { ui.stale = true }
        ui.nowLabel = observed ? "الآن" : "متوقع لهذه الساعة"
        ui.temp = WeatherFormat.temp(h.temperatureC)
        let c = WeatherRules.displayCondition(h)
        ui.condition = c.text
        ui.symbol = c.symbol
        ui.wind = wind(h)
        if r.airAvailable, let d = DustLevel.of(h.dust) {
            ui.dust = d
            ui.dustText = d.label
        } else {
            ui.dustText = "الغبار غير متاح"
        }
        ui.visibility = WeatherFormat.visibility(h.visibilityM)
        /* Forecast models do not lower visibility for dust: never print «أكثر من ١٠ كم» next to «غبار كثيف». */
        if (ui.dust ?? .clear) >= .moderate, (h.visibilityM ?? .infinity) >= WeatherThresholds.visibilityReducedM {
            ui.visibility = "قد تقل بسبب الغبار"
        }
        if let chance = WeatherRules.maxRainChance(r, now: now) {
            ui.rainText = chance < 10 ? "لا مطر متوقع خلال ١٢ س" : "احتمال المطر حتى \(SaryFormat.percent(Int(chance.rounded()))) خلال ١٢ س"
        } else {
            ui.rainText = "احتمال المطر غير متاح"
        }
        ui.hours = WeatherRules.upcoming(r, now: now, count: count).enumerated().map { i, x in hourUI(x, label: i == 0 ? "هذه الساعة" : WeatherFormat.hour(x.time)) }
        return ui
    }

    static func wind(_ h: WeatherHour) -> WeatherWindUI {
        WeatherWindUI(speed: h.windKmh.map(WeatherFormat.speed) ?? "—",
                      gust: h.gustKmh.map { "هبّات \(WeatherFormat.speed($0))" },
                      arrowDeg: h.windFromDeg.map(WeatherRules.windArrowDeg(from:)),
                      name: h.windFromDeg.map { "رياح \(WeatherRules.windName(from: $0))" },
                      level: WeatherRules.windLevel(h))
    }

    static func hourUI(_ x: WeatherHour, label: String) -> WeatherHourUI {
        WeatherHourUI(id: x.time.timeIntervalSince1970, label: label, temp: WeatherFormat.temp(x.temperatureC),
                      symbol: WeatherRules.displayCondition(x).symbol,
                      rainChance: x.precipitationProbability.flatMap { $0 >= 10 ? SaryFormat.percent(Int($0.rounded())) : nil },
                      arrowDeg: x.windFromDeg.map(WeatherRules.windArrowDeg(from:)),
                      wind: x.windKmh.map { SaryFormat.number(Int($0.rounded())) } ?? "—")
    }

    /// The forecast at the estimated arrival time.
    static func arrival(_ est: ArrivalEstimate.Result, report r: WeatherReport?, now: Date) -> WeatherArrivalUI {
        let speed = est.assumedSpeed ? "بافتراض \(WeatherFormat.speed(est.speedKmh))" : "بسرعتكم الأخيرة \(WeatherFormat.speed(est.speedKmh))"
        let basis = "\(SaryFormat.distance(meters: est.distanceM)) بخط مستقيم · \(speed)"
        let etaText = est.eta.timeIntervalSince(now) < 5 * 60 ? "الوصول خلال دقائق" : "الوصول المتوقع \(WeatherFormat.clock(est.eta))"
        guard let r, let h = WeatherRules.hour(containing: est.eta, in: r) else {
            return WeatherArrivalUI(etaText: etaText, basis: basis, hour: nil, condition: r == nil ? nil : "وقت الوصول بعد نهاية التوقعات المتاحة")
        }
        let c = WeatherRules.displayCondition(h)
        var bits = [c.text]
        if let w = h.windKmh { bits.append("رياح \(WeatherFormat.speed(w))") }
        if let p = h.precipitationProbability, p >= 10 { bits.append("مطر \(SaryFormat.percent(Int(p.rounded())))") }
        if let d = DustLevel.of(h.dust), d >= .light { bits.append(d.label) }
        return WeatherArrivalUI(etaText: etaText, basis: basis, hour: hourUI(h, label: WeatherFormat.hour(h.time)), condition: bits.joined(separator: " · "))
    }
}
