import Foundation

/// «مساري» smoothing: a constant-velocity Kalman filter over the raw GPS fixes,
/// in flat metres around a local origin. Every fix contributes in proportion to
/// its own accuracy (a 40 m city fix nudges, a 5 m fix pulls), CoreLocation's
/// speed and course feed the velocity, and only physically impossible fixes are
/// thrown away — judged against the filtered speed, not a fixed 10 m / 30 m gate.
///
/// Pure value type (Codable, so the trail resumes exactly after a relaunch).
struct TrailKalman: Codable, Equatable {
    /// Fixes worse than this are never used (iOS reports ~65 m Wi-Fi, ~1–3 km cell / reduced accuracy).
    static let maxAccuracyM = 100.0
    /// Car manoeuvring: white-noise acceleration, m/s².
    static let accelSigma = 3.0
    /// Longer than this without a usable fix: start again at the next one (no blind prediction).
    static let reacquireS = 30.0
    /// Absolute ceiling for any implied speed (≈270 km/h).
    static let maxSpeedMps = 75.0
    /// Consistent rejected fixes in a row that mean the filter was wrong, not the GPS.
    static let resetAfter = 3

    /// Local origin of the metre grid.
    private(set) var refLat = 0.0
    private(set) var refLng = 0.0
    /// State: x, y (m, east/north of the origin), vx, vy (m/s).
    private(set) var s = [Double](repeating: 0, count: 4)
    /// Covariance, row-major 4×4.
    private(set) var p = [Double](repeating: 0, count: 16)
    /// Time of the state, ms since 1970 (0 = not started).
    private(set) var tMs = 0.0
    /// Fixes rejected in a row (they may yet prove the filter wrong).
    private(set) var rejected: [RawFix] = []

    enum Outcome: Equatable {
        /// The filtered position after this fix.
        case accepted(LngLat, speedMps: Double, sigmaM: Double, reset: Bool)
        case rejected
    }

    var started: Bool { tMs > 0 }
    var position: LngLat { TrailGeo.lngLat(s[0], s[1], ref: LngLat(lng: refLng, lat: refLat)) }
    var speedMps: Double { (s[2] * s[2] + s[3] * s[3]).squareRoot() }
    var sigmaM: Double { max(p[0], p[5]).squareRoot() }

    // MARK: step

    mutating func step(_ f: RawFix) -> Outcome {
        guard f.lat.isFinite, f.lng.isFinite, abs(f.lat) <= 90, abs(f.lng) <= 180 else { return .rejected }
        guard let acc = f.acc, acc >= 0, acc <= Self.maxAccuracyM else { return .rejected }
        guard !started || f.t > tMs else { return .rejected }
        if !started || (f.t - tMs) / 1000 > Self.reacquireS {
            start(at: f)
            return accepted(reset: false)
        }
        let dt = (f.t - tMs) / 1000
        if !plausible(f, dt: dt) {
            /* A jump. If the next fixes agree with it (and with each other), the filter was the one off. */
            if let last = rejected.last, !Self.consistent(last, f) { rejected = [] }
            rejected.append(f)
            if rejected.count >= Self.resetAfter {
                let latest = rejected
                start(at: latest[0])
                for q in latest.dropFirst() { predict(to: q.t); measure(q) }
                return accepted(reset: true)
            }
            return .rejected
        }
        rejected = []
        predict(to: f.t)
        measure(f)
        recentre()
        return accepted(reset: false)
    }

    /// Could the car really have got from the filtered position to this fix in `dt`?
    func plausible(_ f: RawFix, dt: Double) -> Bool {
        let here = position
        let d = TrailGeo.distance(here, LngLat(lng: f.lng, lat: f.lat))
        let measured = f.spd ?? 0
        let ceiling = min(Self.maxSpeedMps, max(25, 1.8 * max(speedMps, measured) + 15))
        /* Both ends are uncertain: the fix's own accuracy and the filter's, plus 20 m slack. */
        let slack = (f.acc ?? 0) + 2 * sigmaM + 20
        return d - slack <= ceiling * max(dt, 0.5)
    }

    private static func consistent(_ a: RawFix, _ b: RawFix) -> Bool {
        let dt = max((b.t - a.t) / 1000, 0.5)
        guard b.t > a.t else { return false }
        let d = TrailGeo.distance(LngLat(lng: a.lng, lat: a.lat), LngLat(lng: b.lng, lat: b.lat))
        return d - (a.acc ?? 0) - (b.acc ?? 0) <= maxSpeedMps * dt
    }

    private func accepted(reset: Bool) -> Outcome { .accepted(position, speedMps: speedMps, sigmaM: sigmaM, reset: reset) }

    // MARK: filter maths

    private mutating func start(at f: RawFix) {
        refLat = f.lat
        refLng = f.lng
        s = [0, 0, 0, 0]
        let a = max(f.acc ?? 10, 3) * Self.axisFactor
        p = [a * a, 0, 0, 0,
             0, a * a, 0, 0,
             0, 0, 100, 0,
             0, 0, 0, 100]
        tMs = f.t
        rejected = []
        measureVelocity(f)
    }

    /// iOS's horizontal accuracy is a radius; per axis we use a bit less.
    static let axisFactor = 0.75

    private mutating func predict(to t: Double) {
        let dt = (t - tMs) / 1000
        guard dt > 0 else { return }
        s[0] += s[2] * dt
        s[1] += s[3] * dt
        /* P = F P Fᵀ + Q, F = [[1,0,dt,0],[0,1,0,dt],[0,0,1,0],[0,0,0,1]]. */
        var f = [Double](repeating: 0, count: 16)
        for i in 0..<4 { f[i * 4 + i] = 1 }
        f[0 * 4 + 2] = dt
        f[1 * 4 + 3] = dt
        p = Self.mul(Self.mul(f, p), Self.transpose(f))
        let q = Self.accelSigma * Self.accelSigma
        let q11 = q * dt * dt * dt / 3, q12 = q * dt * dt / 2, q22 = q * dt
        p[0] += q11; p[5] += q11
        p[2] += q12; p[8] += q12
        p[7] += q12; p[13] += q12
        p[10] += q22; p[15] += q22
        tMs = t
    }

    private mutating func measure(_ f: RawFix) {
        let ref = LngLat(lng: refLng, lat: refLat)
        let z = TrailGeo.xy(LngLat(lng: f.lng, lat: f.lat), ref: ref)
        let a = max(f.acc ?? 10, 3) * Self.axisFactor
        update(0, z.x, a * a)
        update(1, z.y, a * a)
        measureVelocity(f)
    }

    /// CoreLocation's own speed and course (Doppler): far better than differencing positions.
    private mutating func measureVelocity(_ f: RawFix) {
        guard let v = f.spd, v >= 0 else { return }
        let sv = (f.spdAcc ?? 1.0) + 0.3
        if v < 0.5 {
            /* Standing: hold the dot still instead of letting the noise walk it. */
            update(2, 0, sv * sv)
            update(3, 0, sv * sv)
        } else if v >= 1.5, let c = f.crs, c >= 0 {
            let r = c * .pi / 180
            let sig = (sv * sv + (v * 0.2) * (v * 0.2)).squareRoot()
            update(2, v * sin(r), sig * sig)
            update(3, v * cos(r), sig * sig)
        }
    }

    /// Scalar Kalman update of state component `i` with measurement `z`, variance `r`.
    private mutating func update(_ i: Int, _ z: Double, _ r: Double) {
        let sVar = p[i * 4 + i] + r
        guard sVar > 0 else { return }
        var k = [Double](repeating: 0, count: 4)
        for row in 0..<4 { k[row] = p[row * 4 + i] / sVar }
        let innov = z - s[i]
        for row in 0..<4 { s[row] += k[row] * innov }
        let pi = (0..<4).map { p[i * 4 + $0] }
        for row in 0..<4 { for col in 0..<4 { p[row * 4 + col] -= k[row] * pi[col] } }
    }

    /// Keep the origin near the car (the flat-earth grid is only good for a few tens of km).
    private mutating func recentre() {
        guard abs(s[0]) > 20_000 || abs(s[1]) > 20_000 else { return }
        let here = position
        refLat = here.lat
        refLng = here.lng
        s[0] = 0
        s[1] = 0
    }

    private static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var c = [Double](repeating: 0, count: 16)
        for i in 0..<4 { for j in 0..<4 { var x = 0.0; for k in 0..<4 { x += a[i * 4 + k] * b[k * 4 + j] }; c[i * 4 + j] = x } }
        return c
    }

    private static func transpose(_ a: [Double]) -> [Double] {
        var c = [Double](repeating: 0, count: 16)
        for i in 0..<4 { for j in 0..<4 { c[j * 4 + i] = a[i * 4 + j] } }
        return c
    }
}

/// One raw GPS fix exactly as CoreLocation gave it (kept per outing so the trail can always be re-processed).
struct RawFix: Codable, Equatable {
    /// ms since 1970.
    var t: Double
    var lat: Double
    var lng: Double
    /// Horizontal accuracy, m (nil = invalid).
    var acc: Double?
    /// Speed m/s (nil = unknown).
    var spd: Double?
    /// Course, degrees from north (nil = unknown).
    var crs: Double?
    /// Speed accuracy m/s (nil = unknown).
    var spdAcc: Double?

    init(t: Double, lat: Double, lng: Double, acc: Double?, spd: Double? = nil, crs: Double? = nil, spdAcc: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lng = lng
        self.acc = acc
        self.spd = spd
        self.crs = crs
        self.spdAcc = spdAcc
    }

    init(_ f: DeviceFix) {
        self.init(t: f.atMs, lat: f.lat, lng: f.lng, acc: f.accuracy, spd: f.speed, crs: f.heading, spdAcc: f.speedAccuracy)
    }

    var position: LngLat { LngLat(lng: lng, lat: lat) }
}

extension TrailGeo {
    static func distance(_ a: LngLat, _ b: LngLat) -> Double { Vehicle.distanceMeters(a, b) }
}
