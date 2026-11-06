import Foundation

/// GPS quality for the desert (build 21): which fixes to believe, how to draw them, which way the
/// car points, and how hard the chip is working. All pure, all tested with simulated traces
/// (`GpsQualityTests`). Raw fixes are never altered here: `LocationSharer.lastFix` stays the
/// device's own reading (SOS, mesh, trail log); only `displayFix` is smoothed.
///
/// Three layers, in order:
///   1. `FixQualityGate` — throws away fixes that are invalid, stale, needlessly coarse or a
///      teleport. What it accepts is still raw (sent to the convoy, unchanged).
///   2. `DisplaySmoother` — the dot on my own map: an anchored average at a camp (no wandering),
///      a light constant-velocity Kalman on the move (no lag at 120 km/h: it snaps on a big miss).
///   3. `HeadingChooser` — the course only while really moving with a trustworthy courseAccuracy;
///      otherwise none (the map's compass takes over, see `FollowHeadingSource`).
enum GpsQuality {
    /// Older than this when it reaches us: not "now" any more (cached fix at start, resumed app).
    static let staleMs = 10_000.0
    /// Worse than this is thrown away when a better fix is recent…
    static let coarseM = 65.0
    /// …"better" meaning at most this, and "recent" meaning within this.
    static let goodM = 30.0
    static let betterRecentMs = 15_000.0
    /// 70 m/s ≈ 250 km/h: nobody drives the dunes this fast; a jump that implies it is a glitch.
    static let teleportMps = 70.0
    /// After this long without an accepted fix, the next one starts afresh (signal gap).
    static let gapMs = 30_000.0
}

// MARK: - 1. the gate

/// Why a fix was refused (counted for «جودة GPS»).
enum FixRejection: String, CaseIterable, Codable {
    case invalid, stale, coarse, teleport
}

struct FixQualityGate: Equatable {
    private(set) var reference: DeviceFix?
    /// The last refused teleport: if the next fix agrees with it, the jump was real.
    private(set) var suspect: DeviceFix?
    private(set) var lastGoodAtMs: Double?
    private(set) var rejected: [FixRejection: Int] = [:]
    private(set) var accepted = 0

    enum Verdict: Equatable {
        case accept(DeviceFix)
        case reject(FixRejection)
    }

    /// Invalid accuracy is counted here (CoreLocation's negative accuracy never becomes a `DeviceFix`).
    mutating func countInvalid() { rejected[.invalid, default: 0] += 1 }

    mutating func judge(_ fix: DeviceFix, nowMs: Double) -> Verdict {
        guard let acc = fix.accuracy, acc >= 0, fix.lat.isFinite, fix.lng.isFinite,
              abs(fix.lat) <= 90, abs(fix.lng) <= 180, !(fix.lat == 0 && fix.lng == 0) else { return refuse(.invalid) }
        if let r = reference, fix.atMs <= r.atMs { return refuse(.stale) }
        if nowMs - fix.atMs > GpsQuality.staleMs { return refuse(.stale) }
        if acc > GpsQuality.coarseM, let g = lastGoodAtMs, fix.atMs - g <= GpsQuality.betterRecentMs { return refuse(.coarse) }
        guard let r = reference, fix.atMs - r.atMs <= GpsQuality.gapMs else { return take(fix) }
        if Self.speed(r, fix) <= GpsQuality.teleportMps { return take(fix) }
        /* Implausible from the reference; if it agrees with the last refused one, the reference was the lie. */
        if let s = suspect, fix.atMs - s.atMs <= GpsQuality.staleMs, Self.speed(s, fix) <= GpsQuality.teleportMps { return take(fix) }
        suspect = fix
        return refuse(.teleport)
    }

    mutating func reset() {
        reference = nil
        suspect = nil
        lastGoodAtMs = nil
    }

    /// Distance over time, giving both fixes the benefit of their error (as `Policy.impliedSpeedMps`).
    static func speed(_ a: DeviceFix, _ b: DeviceFix) -> Double { Policy.impliedSpeedMps(a, b) }

    private mutating func take(_ fix: DeviceFix) -> Verdict {
        reference = fix
        suspect = nil
        if let a = fix.accuracy, a <= GpsQuality.goodM { lastGoodAtMs = fix.atMs }
        accepted += 1
        return .accept(fix)
    }

    private mutating func refuse(_ why: FixRejection) -> Verdict {
        rejected[why, default: 0] += 1
        return .reject(why)
    }
}

// MARK: - 2. the display

/// My own dot. Stopped: an accuracy-weighted anchor that only moves when a fix clearly leaves it
/// (twice in a row, or real speed). Moving: predict with the fix's own speed and course, then a
/// Kalman blend by accuracy; a miss bigger than 3σ snaps (a turn, a gap) so it never trails behind.
struct DisplaySmoother: Equatable {
    /// Below this the car is parked for the display (with hysteresis to `moveMps`).
    static let stillMps = 0.7
    static let moveMps = 1.5
    /// A parked anchor ignores fixes inside max(this, 2 × their accuracy) (a 1σ radius is crossed
    /// by every fifth fix of normal jitter).
    static let anchorMinRadiusM = 8.0
    /// The shown anchor moves only when the running average has drifted this far (no creeping).
    static let anchorDeadbandM = 2.0
    /// Process noise for the moving filter (m/s² of unmodelled acceleration).
    static let accelNoise = 2.5

    private(set) var parked = false
    private(set) var out: DeviceFix?
    private var variance = 0.0
    /// Parked anchor: weighted sums (weights 1/σ²).
    private var wSum = 0.0, latSum = 0.0, lngSum = 0.0
    private var outside = 0
    private var shownAnchor: Geo.LatLng?

    mutating func reset() { self = DisplaySmoother() }

    /// One accepted fix → what the map draws (same timestamp, accuracy, speed; smoothed position; trusted heading).
    mutating func update(_ fix: DeviceFix) -> DeviceFix {
        var f = fix
        f.heading = HeadingChooser.course(fix)
        let acc = max(3, fix.accuracy ?? 30)
        guard let prev = out, fix.atMs - prev.atMs <= GpsQuality.gapMs, fix.atMs > prev.atMs else {
            return restart(f, acc: acc)
        }
        let speed = fix.speed ?? -1
        let wasParked = parked
        if parked {
            if speed >= Self.moveMps { parked = false }
        } else if speed >= 0, speed < Self.stillMps {
            parked = true
        }
        if parked {
            if !wasParked { startAnchor(at: prev, acc: max(3, prev.accuracy ?? acc)) }
            let anchor = Geo.LatLng(lat: latSum / wSum, lng: lngSum / wSum)
            let d = Geo.haversineMeters(anchor, fix.coordinate)
            if d <= max(Self.anchorMinRadiusM, 2 * acc) {
                outside = 0
                let w = 1 / (acc * acc)
                wSum += w; latSum += fix.lat * w; lngSum += fix.lng * w
            } else {
                outside += 1
                /* Twice outside: really moved (crept to the next tent); re-anchor there. */
                if outside >= 2 { startAnchor(at: fix, acc: acc) }
            }
            let mean = Geo.LatLng(lat: latSum / wSum, lng: lngSum / wSum)
            if shownAnchor.map({ Geo.haversineMeters($0, mean) >= Self.anchorDeadbandM }) ?? true { shownAnchor = mean }
            let shown = shownAnchor ?? mean
            f.lat = shown.lat
            f.lng = shown.lng
            f.heading = nil
            out = f
            return f
        }
        /* Moving: constant-velocity prediction, Kalman blend. */
        let dt = (fix.atMs - prev.atMs) / 1000
        var pred = prev.coordinate
        if let v = fix.speed, v > 0, let c = fix.heading ?? prev.heading {
            pred = Self.move(prev.coordinate, meters: v * dt, bearingDeg: c)
        }
        let q = Self.accelNoise * dt * dt / 2 + (fix.speedAccuracy ?? 1) * dt
        let pVar = variance + q * q
        let miss = Geo.haversineMeters(pred, fix.coordinate)
        if miss > 3 * sqrt(pVar + acc * acc) { return restart(f, acc: acc) }
        let k = pVar / (pVar + acc * acc)
        f.lat = pred.lat + k * (fix.lat - pred.lat)
        f.lng = pred.lng + k * (fix.lng - pred.lng)
        variance = (1 - k) * pVar
        out = f
        return f
    }

    private mutating func restart(_ f: DeviceFix, acc: Double) -> DeviceFix {
        variance = acc * acc
        parked = (f.speed ?? 1) < Self.stillMps
        if parked { startAnchor(at: f, acc: acc) }
        var f = f
        if parked { f.heading = nil }
        out = f
        return f
    }

    private mutating func startAnchor(at f: DeviceFix, acc: Double) {
        let w = 1 / (acc * acc)
        wSum = w; latSum = f.lat * w; lngSum = f.lng * w
        outside = 0
        shownAnchor = f.coordinate
    }

    static func move(_ p: Geo.LatLng, meters: Double, bearingDeg: Double) -> Geo.LatLng {
        let r = Double.pi / 180
        let dLat = meters * cos(bearingDeg * r) / Geo.earthRadiusM
        let dLng = meters * sin(bearingDeg * r) / (Geo.earthRadiusM * cos(p.lat * r))
        return Geo.LatLng(lat: p.lat + dLat / r, lng: p.lng + dLng / r)
    }
}

// MARK: - 3. the heading

/// Which way the car points: the GPS course only when it means something.
enum HeadingChooser {
    /// Course is trusted from this speed (≈9 km/h)…
    static let courseMinMps = 2.5
    /// …and when CoreLocation rates it at least this good (degrees; unknown accuracy needs more speed).
    static let courseMaxErrorDeg = 30.0
    static let unknownAccuracyMinMps = 3.0
    /// Below `courseMinMps` the compass is used when it is this good (CLHeading.headingAccuracy).
    static let compassMaxErrorDeg = 35.0

    enum Source: String, Equatable { case course, compass, none }

    /// The course of `fix`, or nil when a parked / crawling car's course would point anywhere.
    static func course(_ fix: DeviceFix) -> Double? {
        guard let c = fix.heading, c.isFinite, c >= 0, let v = fix.speed, v >= courseMinMps else { return nil }
        if let e = fix.courseAccuracy {
            guard e >= 0, e <= courseMaxErrorDeg else { return nil }
        } else if v < unknownAccuracyMinMps {
            return nil
        }
        return c.truncatingRemainder(dividingBy: 360)
    }

    /// Course when moving, else the compass when it is good, else nothing (never a stale course).
    static func choose(_ fix: DeviceFix?, compass: Double?, compassError: Double?) -> (heading: Double?, source: Source) {
        if let f = fix, let c = course(f) { return (c, .course) }
        if let h = compass, h.isFinite, h >= 0, let e = compassError, e >= 0, e <= compassMaxErrorDeg { return (h, .compass) }
        return (nil, .none)
    }
}

// MARK: - motion

/// Parked / walking / driving / fast from speed, with hysteresis so the GPS settings do not flap.
enum MotionClass: String, Equatable, CaseIterable {
    case parked, walking, driving, fast

    /// Lower bounds (m/s) to enter each class; leaving needs 20 % less.
    static func enter(_ m: MotionClass) -> Double {
        switch m {
        case .parked: return 0
        case .walking: return 0.6
        case .driving: return 3.0 // ≈11 km/h: faster than anyone walks in sand
        case .fast: return Policy.fastMps
        }
    }

    /// The next class for `speed` (nil: unknown → keep the current one).
    static func next(_ current: MotionClass, speedMps: Double?) -> MotionClass {
        guard let s = speedMps, s >= 0, s.isFinite else { return current }
        let order = MotionClass.allCases
        var target = MotionClass.parked
        for m in order where s >= enter(m) { target = m }
        guard let ci = order.firstIndex(of: current), let ti = order.firstIndex(of: target) else { return target }
        if ti >= ci { return target }
        /* Going down: only when clearly below the current class's floor. */
        return s < enter(current) * 0.8 ? target : current
    }
}

// MARK: - diagnostics

/// «جودة GPS» (developer readout): what the chip gives and what we keep.
struct GpsQualityStats: Equatable {
    var lastAccuracyM: Double?
    var lastSpeedAccuracy: Double?
    var lastCourseAccuracy: Double?
    var lastAgeMs: Double?
    /// Fixes per second over the last ~10 s.
    var hz: Double = 0
    var source: String = "—"
    var accepted = 0
    var rejected: [FixRejection: Int] = [:]
    /// The settings in use, e.g. "nav · none · otherNav".
    var settings: String = "—"
    var motion: MotionClass = .parked
    var precise = true
    var headingSource: HeadingChooser.Source = .none

    var rejectedTotal: Int { rejected.values.reduce(0, +) }

    /// Fix rate from recent timestamps (ms): count over span.
    static func rate(_ times: [Double]) -> Double {
        guard times.count >= 2, let a = times.first, let b = times.last, b > a else { return 0 }
        return Double(times.count - 1) / ((b - a) / 1000)
    }

    /// One line per row, Latin digits (it is read by whoever fixes it).
    var lines: [String] {
        func n(_ v: Double?, _ unit: String) -> String { v.map { String(format: "%.0f", $0) + unit } ?? "—" }
        let r = FixRejection.allCases.map { "\($0.rawValue) \(rejected[$0] ?? 0)" }.joined(separator: " · ")
        return [
            "الدقة ±\(n(lastAccuracyM, " m")) · السرعة ±\(lastSpeedAccuracy.map { String(format: "%.1f m/s", $0) } ?? "—") · الاتجاه ±\(n(lastCourseAccuracy, "°"))",
            "\(String(format: "%.1f", hz)) Hz · العمر \(lastAgeMs.map { String(format: "%.1f s", $0 / 1000) } ?? "—") · \(source)\(precise ? "" : " · تقريبي")",
            "مقبول \(accepted) · مرفوض \(rejectedTotal) (\(r))",
            "\(motion.rawValue) · \(settings) · heading \(headingSource.rawValue)",
        ]
    }
}
