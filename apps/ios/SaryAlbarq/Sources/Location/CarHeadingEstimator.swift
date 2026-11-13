import Foundation

/// Which way the car REALLY goes («أنا أتجه للغرب وهو يحسبني مسكت المسار غلط», owner, build 48, desert near
/// Unaizah). One fix's `CLLocation.course` is a noisy thing at low speed, on sand and in turns (it can
/// jump ±100° between two fixes), so nothing that decides «wrong way» or draws the arrow should read it
/// alone. This estimator keeps a short history of the fixes and takes the direction from the
/// DISPLACEMENT over a real baseline (≥ `baselineM`), weighted by the fixes' accuracy; the chip's
/// course joins in only when CoreLocation itself rates it well and the car is really moving. When
/// neither is available it HOLDS the last good heading (no jumping) with a confidence that fades.
/// Pure and unit-tested (`CarHeadingEstimatorTests`).
struct CarHeadingEstimator: Equatable {
    // MARK: constants (the knobs the owner can tune)

    /// A fix with a worse horizontal accuracy (m) says nothing about direction (it may still draw the dot).
    static let maxAccuracyM = 25.0
    /// The displacement used for the heading must be at least this long (m).
    static let baselineM = 30.0
    /// A noisy fix needs a longer baseline: at least this many times its accuracy (a ±20 m fix over 30 m is ±30°).
    static let baselinePerAccuracy = 2.5
    /// …and the older end must be no older than this (s): a displacement from a minute ago is another road.
    static let maxWindowS = 40.0
    /// History kept (fixes).
    static let maxFixes = 40
    /// The chip's course joins in only from this ground speed (m/s)…
    static let courseMinMps = 3.0
    /// …and when CoreLocation rates it at least this well (degrees).
    static let courseMaxErrorDeg = 20.0
    /// A course that differs this much from the displacement is not blended (a turn, or noise).
    static let courseConflictDeg = 60.0
    /// Below this ground speed a fix says nothing new about direction (m/s).
    static let stillMps = 0.8
    /// A new estimate this far from the held heading must repeat `flipFixes` times before it is taken.
    static let flipDeg = 100.0
    static let flipFixes = 3
    /// The confidence at which the heading is «good» (used for the arrow and for the wrong-way verdict).
    static let goodConfidence = 0.6
    /// A held heading's confidence fades to zero over this long without fresh evidence (s).
    static let holdFadeS = 25.0
    /// Gap with no fix at all (s) after which the history starts afresh (the heading is kept, faded).
    static let gapS = 15.0
    /// chord / path length below this (a bend inside the baseline) cuts the confidence.
    static let minStraightness = 0.8

    enum Source: String, Equatable { case displacement, blended, course, held, none }

    /// What the estimator knows now.
    struct Estimate: Equatable {
        /// 0–360, or nil when never known.
        var heading: Double?
        /// 0–1.
        var confidence: Double
        var source: Source
        /// The length (m) of the displacement the heading rests on (0: none).
        var baselineM: Double

        static let none = Estimate(heading: nil, confidence: 0, source: .none, baselineM: 0)
        var isGood: Bool { heading != nil && confidence >= CarHeadingEstimator.goodConfidence }
        /// The heading only when it is good enough to act on.
        var goodHeading: Double? { isGood ? heading : nil }
    }

    private struct Pt: Equatable {
        var x: Double, y: Double   // metres east / north of `origin`
        var acc: Double
        var tMs: Double
    }

    private var pts: [Pt] = []
    private var origin: Geo.LatLng?
    private var lastAtMs: Double?
    private var held: Double?
    private var heldConfidence = 0.0
    private var heldAtMs: Double?
    private var pending: (deg: Double, n: Int)?
    private(set) var estimate = Estimate.none

    static func == (a: CarHeadingEstimator, b: CarHeadingEstimator) -> Bool { a.estimate == b.estimate && a.pts == b.pts }

    mutating func reset() { self = CarHeadingEstimator() }

    // MARK: feeding

    /// One fix, oldest first. Returns the new estimate (also in `estimate`).
    @discardableResult
    mutating func ingest(_ fix: DeviceFix) -> Estimate {
        guard fix.lat.isFinite, fix.lng.isFinite else { return estimate }
        if let l = lastAtMs, fix.atMs <= l { return estimate }
        if let l = lastAtMs, fix.atMs - l > Self.gapS * 1000 {
            /* A signal gap: the old trail is another stretch of road. The heading is kept, fading. */
            pts = []
            origin = nil
        }
        lastAtMs = fix.atMs

        let speed = fix.speed
        let moving = (speed ?? Self.courseMinMps) >= Self.stillMps
        let acc = fix.accuracy ?? Self.maxAccuracyM
        let usable = acc >= 0 && acc <= Self.maxAccuracyM && moving
        if usable {
            if origin == nil { origin = fix.coordinate }
            let o = origin!
            let kx = 111_320 * cos(o.lat * .pi / 180), ky = 110_540.0
            pts.append(Pt(x: (fix.lng - o.lng) * kx, y: (fix.lat - o.lat) * ky, acc: max(3, acc), tMs: fix.atMs))
            if pts.count > Self.maxFixes { pts.removeFirst(pts.count - Self.maxFixes) }
            pts.removeAll { fix.atMs - $0.tMs > Self.maxWindowS * 1000 }
        }

        var disp: (deg: Double, errDeg: Double, baseline: Double, straight: Double)?
        if usable { disp = displacement() }

        /* The chip's course: only when really moving and rated well. */
        var course: (deg: Double, errDeg: Double)?
        if let c = fix.heading, c.isFinite, c >= 0, let v = speed, v >= Self.courseMinMps,
           let e = fix.courseAccuracy, e >= 0, e <= Self.courseMaxErrorDeg, acc <= Self.maxAccuracyM {
            course = (c.truncatingRemainder(dividingBy: 360), max(e, 3))
        }

        var raw: (deg: Double, conf: Double, source: Source, baseline: Double)?
        if let d = disp {
            let dConf = Self.confidence(errDeg: d.errDeg) * min(1, max(0, (d.straight - 0.5) / (Self.minStraightness - 0.5)))
            if let c = course, RoadSnap.angleDiff(c.deg, d.deg) <= Self.courseConflictDeg {
                let wd = 1 / (d.errDeg * d.errDeg), wc = 1 / (c.errDeg * c.errDeg)
                let deg = Self.circularMean([(d.deg, wd), (c.deg, wc)])
                let errDeg = (1 / (wd + wc)).squareRoot()
                raw = (deg, max(dConf, Self.confidence(errDeg: errDeg) * min(1, dConf + 0.3)), .blended, d.baseline)
            } else {
                raw = (d.deg, dConf, .displacement, d.baseline)
            }
        } else if let c = course {
            /* No baseline yet (the first seconds): the course alone, never fully trusted. */
            raw = (c.deg, min(0.55, Self.confidence(errDeg: c.errDeg)), .course, 0)
        }

        if let r = raw, r.conf > 0.05 {
            let smoothed = smooth(toward: r.deg, confidence: r.conf)
            if let s = smoothed {
                held = s
                heldConfidence = r.conf
                heldAtMs = fix.atMs
                estimate = Estimate(heading: s, confidence: r.conf, source: r.source, baselineM: r.baseline)
                return estimate
            }
        }
        /* No new evidence (or a lone contradicting one): hold what was last good, fading. */
        guard let h = held, let at = heldAtMs else { estimate = .none; return estimate }
        let age = max(0, (fix.atMs - at) / 1000)
        let conf = heldConfidence * max(0, 1 - age / Self.holdFadeS)
        estimate = Estimate(heading: h, confidence: conf, source: .held, baselineM: 0)
        return estimate
    }

    // MARK: pieces

    /// The newest fix against the most recent one at least `baselineM` away: direction and its error.
    private func displacement() -> (deg: Double, errDeg: Double, baseline: Double, straight: Double)? {
        guard let n = pts.last, pts.count >= 2 else { return nil }
        var path = 0.0
        var j: Int?
        let need = max(Self.baselineM, Self.baselinePerAccuracy * n.acc * 2.0.squareRoot())
        var i = pts.count - 1
        while i > 0 {
            path += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            i -= 1
            if hypot(n.x - pts[i].x, n.y - pts[i].y) >= need { j = i; break }
        }
        guard let jj = j else { return nil }
        let a = pts[jj]
        /* Both ends averaged with their neighbours, weighted by 1/σ²: one stray fix at an end does not swing it. */
        let head = centroid(around: pts.count - 1), tail = centroid(around: jj)
        let dx = head.x - tail.x, dy = head.y - tail.y
        let d = hypot(dx, dy)
        guard d >= need * 0.8 else { return nil }
        let sigma = (head.sigma * head.sigma + tail.sigma * tail.sigma).squareRoot()
        let errDeg = atan2(sigma, d) * 180 / .pi
        let deg = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let chord = hypot(n.x - a.x, n.y - a.y)
        return (deg, max(errDeg, 1), d, path > 0 ? min(1, chord / path) : 1)
    }

    /// Weighted centroid of the fix at `k` and its immediate neighbours (±1), with the combined sigma.
    private func centroid(around k: Int) -> (x: Double, y: Double, sigma: Double) {
        var w = 0.0, x = 0.0, y = 0.0
        for i in max(0, k - 1) ... min(pts.count - 1, k + 1) {
            let wi = 1 / (pts[i].acc * pts[i].acc)
            w += wi; x += pts[i].x * wi; y += pts[i].y * wi
        }
        return (x / w, y / w, (1 / w).squareRoot())
    }

    /// 0–1 from an angular error: 5° → ~0.9, 15° → ~0.6, 30° → ~0.25.
    static func confidence(errDeg: Double) -> Double {
        max(0, min(1, 1 - errDeg / 40))
    }

    /// The next held heading: shortest-arc smoothing, and a big swing only after it repeated.
    private mutating func smooth(toward deg: Double, confidence: Double) -> Double? {
        guard let h = held else { pending = nil; return deg }
        let delta = Self.signedDelta(from: h, to: deg)
        if abs(delta) >= Self.flipDeg {
            if let p = pending, RoadSnap.angleDiff(p.deg, deg) <= 30 {
                pending = (deg, p.n + 1)
            } else {
                pending = (deg, 1)
            }
            guard let p = pending, p.n >= Self.flipFixes else { return nil }
            pending = nil
            return deg /* the car really turned round */
        }
        pending = nil
        let alpha = 0.35 + 0.4 * confidence
        return Self.norm(h + alpha * delta)
    }

    static func norm(_ d: Double) -> Double { ((d.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }

    /// Shortest signed arc from `a` to `b`, −180…180 (359 → 1 is +2).
    static func signedDelta(from a: Double, to b: Double) -> Double {
        let d = norm(b - a)
        return d > 180 ? d - 360 : d
    }

    /// Weighted circular mean of bearings (degrees).
    static func circularMean(_ items: [(deg: Double, w: Double)]) -> Double {
        var s = 0.0, c = 0.0
        for it in items {
            s += it.w * sin(it.deg * .pi / 180)
            c += it.w * cos(it.deg * .pi / 180)
        }
        return norm(atan2(s, c) * 180 / .pi)
    }
}
