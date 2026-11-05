import Foundation

// «باقي ساعة على المغرب وطريق العودة ٤٥ دقيقة»: on this phone only. Local sunset
// from the sun-position code the map already uses (`SunLight`), and the drive
// back along my own trail (distance along the trail ÷ my recent moving speed).
// Nothing here touches the network.

enum SunTimes {
    /// Apparent sunset: the sun's centre 0.833° under the horizon (refraction + radius).
    static let horizonDeg = -0.833

    /// The sunset nearest ahead of `from - lookBack`: one that happened in the last
    /// `lookBack` (still useful right after it), else the next one within a day.
    /// nil when the sun does not set (polar day/night) in that window.
    static func sunset(near from: Date, lat: Double, lng: Double, lookBack: TimeInterval = 2 * 3600) -> Date? {
        let start = from.addingTimeInterval(-lookBack)
        let step: TimeInterval = 300
        var t = start
        var el = SunLight.elevationDeg(t, lat: lat, lng: lng)
        let end = from.addingTimeInterval(26 * 3600)
        while t < end {
            let n = t.addingTimeInterval(step)
            let en = SunLight.elevationDeg(n, lat: lat, lng: lng)
            if el > horizonDeg && en <= horizonDeg { return refine(t, n, lat: lat, lng: lng) }
            t = n
            el = en
        }
        return nil
    }

    /// Bisection to well under a second.
    private static func refine(_ a0: Date, _ b0: Date, lat: Double, lng: Double) -> Date {
        var a = a0, b = b0
        for _ in 0..<20 {
            let m = Date(timeIntervalSince1970: (a.timeIntervalSince1970 + b.timeIntervalSince1970) / 2)
            if SunLight.elevationDeg(m, lat: lat, lng: lng) > horizonDeg { a = m } else { b = m }
        }
        return b
    }
}

/// My recent moving speed, from the GPS's own speed readings (no positions kept).
struct MovingSpeed: Equatable {
    /// Under this a car is not driving (idling, parked, walking around the camp).
    static let movingMps = 2.0
    /// Only the last stretch of driving counts.
    static let windowS: TimeInterval = 20 * 60
    /// Readings past this are GPS noise for a car on sand.
    static let maxMps = 45.0
    /// Enough driving seen to trust the average.
    static let minSamples = 6

    private(set) var samples: [(t: Double, v: Double)] = []

    static func == (a: Self, b: Self) -> Bool { a.samples.map(\.t) == b.samples.map(\.t) && a.samples.map(\.v) == b.samples.map(\.v) }

    mutating func add(speed: Double?, accuracy: Double?, atMs: Double) {
        guard let v = speed, v.isFinite, v >= Self.movingMps, v <= Self.maxMps else { return }
        if let a = accuracy, a > 50 { return }
        let t = atMs / 1000
        if let last = samples.last, t <= last.t { return }
        samples.append((t, v))
        prune(nowS: t)
    }

    mutating func prune(nowS: Double) {
        samples.removeAll { nowS - $0.t > Self.windowS }
    }

    /// Mean moving speed over the window, m/s; nil until enough driving was seen.
    func average(nowMs: Double) -> Double? {
        let now = nowMs / 1000
        let recent = samples.filter { now - $0.t <= Self.windowS }
        guard recent.count >= Self.minSamples else { return nil }
        return recent.map(\.v).reduce(0, +) / Double(recent.count)
    }
}

enum WayBack {
    /// Off-road reality: never assume faster than 80 km/h nor slower than 10 km/h.
    static let minMps = 10 / 3.6
    static let maxMps = 80 / 3.6
    /// No driving seen yet: a careful desert pace (30 km/h).
    static let fallbackMps = 30 / 3.6
    /// A trail shorter than this is not a drive back.
    static let minDistanceM = 500.0

    static func speed(average: Double?) -> Double {
        min(maxMps, max(minMps, average ?? fallbackMps))
    }

    /// Seconds to drive `remainingM` back along the trail; nil when there is no real way back to speak of.
    static func seconds(remainingM: Double?, averageMps: Double?) -> TimeInterval? {
        guard let d = remainingM, d.isFinite, d >= minDistanceM else { return nil }
        return d / speed(average: averageMps)
    }
}

/// When to say it, and only once per step.
enum SunsetWarning {
    /// Steps of "time left to sunset", minutes. A warning fires at most once per step.
    static let steps = [120, 90, 60, 45, 30, 15, 0]
    /// Warn when the way back takes at least (time to sunset − this).
    static let marginS: TimeInterval = 30 * 60
    /// After sunset, keep saying it for this long (twilight), once.
    static let afterSunsetS: TimeInterval = 45 * 60

    struct Warning: Equatable {
        var step: Int
        var title: String
        var detail: String
    }

    /// The step the clock is in: the smallest step at or above the minutes left (0 once the sun is down).
    static func step(minutesToSunset m: Double) -> Int? {
        if m <= 0 { return 0 }
        return steps.reversed().first { Double($0) >= m }
    }

    /// The warning to show now, or nil (not needed, or this step already warned).
    static func evaluate(now: Date, sunset: Date?, wayBackS: TimeInterval?, warned: Set<Int>) -> Warning? {
        guard let sunset, let way = wayBackS else { return nil }
        let toSunset = sunset.timeIntervalSince(now)
        guard toSunset > -afterSunsetS else { return nil }
        guard way >= toSunset - marginS else { return nil }
        guard let s = step(minutesToSunset: toSunset / 60), !warned.contains(s) else { return nil }
        let wayMin = roundUp5(way / 60)
        let wayText = "طريق الرجعة \(SafetyFormat.span(minutes: wayMin)) تقريبًا"
        let title: String
        if toSunset <= 0 {
            title = "غابت الشمس و\(wayText)"
        } else {
            let left = max(5, Int((toSunset / 60 / 5).rounded()) * 5)
            title = "باقي \(SafetyFormat.span(minutes: left)) على المغرب و\(wayText)"
        }
        let detail = toSunset <= 0 ? "ارجعوا على مساركم بهدوء، والأنوار شغالة." : "المغرب \(SafetyFormat.clock(sunset)). فكّروا ترجعون قبل الظلام."
        return Warning(step: s, title: title, detail: detail)
    }

    static func roundUp5(_ minutes: Double) -> Int { max(5, Int((minutes / 5).rounded(.up)) * 5) }
}
