import Foundation

/// «سرعة المركبة»: my speed from CoreLocation, friends' speed from their fresh
/// positions, the optional over-speed nudge and the trip's max / average.
///
/// All of it is computed on this phone. Nothing here is ever sent: the server
/// already gets the raw `speed` of each shared fix (as before); the smoothed
/// speed, the peak and the average stay local (owner rule).
enum Speed {
    /// m/s → km/h.
    static func kmh(_ mps: Double) -> Double { mps * 3.6 }
    /// km/h → m/s.
    static func mps(_ kmh: Double) -> Double { kmh / 3.6 }

    /// Below this a car is standing (GPS jitter while parked reads 1–3 km/h).
    static let parkedKmh = 3.0
    /// My fix older than this is not a current speed: «—», never a stale number.
    static let staleMs = 5_000.0
    /// Smoothing window, seconds of fixes averaged.
    static let windowMs = 4_000.0
    /// CoreLocation's own speed error worse than this: no number (≈ 18 km/h).
    static let maxSpeedAccuracyMps = 5.0
    /// Position error worse than this: the speed is not trusted either.
    static let maxHorizontalAccuracyM = 65.0

    /// True when CoreLocation's speed for this fix can be shown.
    static func isValid(_ f: DeviceFix) -> Bool {
        guard let s = f.speed, s.isFinite, s >= 0, s <= Policy.maxPlausibleMps else { return false }
        guard let a = f.accuracy, a >= 0, a <= maxHorizontalAccuracyM else { return false }
        if let sa = f.speedAccuracy, sa > maxSpeedAccuracyMps { return false }
        return true
    }
}

/// What the speedometer shows.
enum SpeedReading: Equatable {
    /// No trustworthy current speed (no fix, invalid speed, or older than ~5 s): «—».
    case unknown
    case kmh(Double)

    var kmh: Double? { if case let .kmh(v) = self { return v } else { return nil } }
}

/// A few seconds of my own fixes averaged into one steady number.
///
/// Rules (unit-tested):
///   * the latest fix decides: if its speed is invalid the reading is «—» and the
///     window restarts (an old good value is never shown after a bad one);
///   * only fixes within `Speed.windowMs` of the latest are averaged;
///   * the reading goes «—» once the latest fix is older than `Speed.staleMs`;
///   * under `Speed.parkedKmh` it reads 0.
struct SpeedSmoother: Equatable {
    struct Sample: Equatable { var atMs: Double; var mps: Double }

    private(set) var samples: [Sample] = []
    /// Time of the newest fix seen at all (valid or not).
    private(set) var latestAtMs: Double?
    private(set) var latestValid = false

    mutating func add(_ f: DeviceFix) {
        if let t = latestAtMs, f.atMs <= t { return }
        latestAtMs = f.atMs
        guard Speed.isValid(f), let s = f.speed else {
            latestValid = false
            samples.removeAll()
            return
        }
        latestValid = true
        samples.append(Sample(atMs: f.atMs, mps: s))
        samples.removeAll { f.atMs - $0.atMs > Speed.windowMs }
    }

    mutating func reset() { self = SpeedSmoother() }

    func reading(nowMs: Double) -> SpeedReading {
        guard latestValid, let t = latestAtMs, !samples.isEmpty else { return .unknown }
        /* A future timestamp (clock change) is as untrustworthy as an old one. */
        let age = nowMs - t
        guard age <= Speed.staleMs, age >= -Speed.staleMs else { return .unknown }
        let mean = samples.map(\.mps).reduce(0, +) / Double(samples.count)
        let v = Speed.kmh(mean)
        return .kmh(v < Speed.parkedKmh ? 0 : v)
    }
}

/// The trip's top speed, robust to a single GPS spike: the highest speed that
/// three fixes in a row (each ≤ 10 s apart) all reached.
struct SpeedPeak: Codable, Equatable {
    var maxMps: Double = 0
    /// The last few valid speeds (kept only to judge the next one).
    var recent: [Double] = []
    var lastAtMs: Double?

    static let run = 3
    static let maxGapMs = 10_000.0

    mutating func add(_ f: DeviceFix) {
        if let t = lastAtMs, f.atMs <= t { return }
        defer { lastAtMs = f.atMs }
        guard Speed.isValid(f), let s = f.speed else { recent.removeAll(); return }
        if let t = lastAtMs, f.atMs - t > Self.maxGapMs { recent.removeAll() }
        recent.append(s)
        if recent.count > Self.run { recent.removeFirst(recent.count - Self.run) }
        if recent.count == Self.run, let low = recent.min() { maxMps = max(maxMps, low) }
    }
}

/// «أعلى سرعة» and «متوسط السرعة أثناء الحركة» for the trip summary and the speedometer.
struct TripSpeedSummary: Equatable {
    var maxKmh: Double?
    var avgMovingKmh: Double?

    /// Too little driving for an honest average.
    static let minMovingS = 60.0
    static let minDistanceM = 200.0

    static func make(distanceM: Double, movingS: Double, peakMps: Double?) -> TripSpeedSummary {
        let maxK = peakMps.flatMap { $0 > 0 ? Speed.kmh($0) : nil }
        var avg: Double?
        if movingS >= minMovingS, distanceM >= minDistanceM {
            avg = Speed.kmh(distanceM / movingS)
            /* The average can't beat the peak; when both exist keep them consistent. */
            if let m = maxK, let a = avg, a > m { avg = m }
        }
        return TripSpeedSummary(maxKmh: maxK, avgMovingKmh: avg)
    }

    var isEmpty: Bool { maxKmh == nil && avgMovingKmh == nil }
}

extension TripLog {
    /// My speeds for this trip (this device only, never shared).
    var speedSummary: TripSpeedSummary {
        TripSpeedSummary.make(distanceM: distanceM, movingS: movingS, peakMps: peak?.maxMps)
    }
}

/// «نبّهني إذا تجاوزت»: a gentle nudge when I stay over my limit for a few
/// seconds. Fires once, then waits until I drop clearly under the limit AND a
/// cooldown has passed — never a stream of buzzes.
struct SpeedAlertGate: Equatable {
    var thresholdKmh: Double
    /// Must fall this far under the limit to re-arm.
    static let rearmMarginKmh = 8.0
    /// Over the limit this long before the nudge.
    static let sustainMs = 3_000.0
    /// At most one nudge per this long.
    static let cooldownMs = 120_000.0

    private(set) var armed = true
    private(set) var overSinceMs: Double?
    private(set) var lastFiredMs: Double?

    init(thresholdKmh: Double) { self.thresholdKmh = thresholdKmh }

    /// Feed every reading; true means «nudge now».
    mutating func update(_ r: SpeedReading, nowMs: Double) -> Bool {
        guard let v = r.kmh else { overSinceMs = nil; return false }
        if v <= thresholdKmh - Self.rearmMarginKmh { armed = true }
        guard v > thresholdKmh else { overSinceMs = nil; return false }
        let since = overSinceMs ?? nowMs
        overSinceMs = since
        guard armed, nowMs - since >= Self.sustainMs else { return false }
        if let l = lastFiredMs, nowMs - l < Self.cooldownMs { return false }
        armed = false
        lastFiredMs = nowMs
        return true
    }
}

/// The person's choice for the over-speed nudge (this device; off by default).
enum SpeedPrefs {
    static let alertKey = "sary.speed.alert.v1"
    static let limitKey = "sary.speed.limit.v1"
    static let defaultLimitKmh = 120
    static let limits = Array(stride(from: 60, through: 180, by: 10))
    static var keys: [String] { [alertKey, limitKey] }

    static func alertOn(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: alertKey) }
    static func limitKmh(_ d: UserDefaults = .standard) -> Int {
        let v = d.integer(forKey: limitKey)
        return limits.contains(v) ? v : defaultLimitKmh
    }
}

extension SaryFormat {
    static let speedUnit = "كم/س"

    /// The number alone, whole km/h: "٨٧"; «—» when unknown.
    static func speedValue(kmh: Double?) -> String {
        guard let k = kmh, k.isFinite, k >= 0 else { return "—" }
        return number(Int(k.rounded()))
    }

    /// "٨٧ كم/س"; «—» when unknown.
    static func speed(kmh: Double?) -> String {
        guard kmh != nil, speedValue(kmh: kmh) != "—" else { return "—" }
        return "\(speedValue(kmh: kmh)) \(speedUnit)"
    }

    /// A friend's speed on their row/card: «واقف» when standing, else "٨٧ كم/س".
    static func friendSpeed(kmh: Double) -> String {
        kmh < Speed.parkedKmh ? "واقف" : speed(kmh: kmh)
    }
}
