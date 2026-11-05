import Foundation

/// «انسيابية الحركة»: every car is drawn at display refresh, between real fixes.
///
/// One `CarMotion` per car. A fix goes through a small constant-velocity Kalman filter
/// (position + velocity, per axis), the turn rate comes from the filtered course, and the
/// drawn pose is a trajectory evaluated at the frame's time:
///
/// * **My car** (1 Hz fixes, same clock): constant-turn-rate dead reckoning from the
///   filtered fix, at the fix's own time (so GPS latency is compensated), never more than
///   `horizonS` past it. A new fix that disagrees is blended in over `blendS` (< 300 ms).
/// * **Other members** (every few seconds, another phone's clock): played back along their
///   reported path — a C¹ Hermite curve from where the car is drawn to the new fix, lasting
///   about one update interval, then the same bounded dead reckoning. A gap over
///   `longGapS` glides in `longGapGlideS` instead of a teleport.
///
/// Stale, parked or approximate cars never move by estimate: they rest on the last fix.
/// Pure (no map, no clock of its own): every call gets the time, so it is unit-tested.
struct MotionVec: Equatable {
    var x: Double // metres east
    var y: Double // metres north

    static let zero = MotionVec(x: 0, y: 0)
    static func + (a: MotionVec, b: MotionVec) -> MotionVec { MotionVec(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: MotionVec, b: MotionVec) -> MotionVec { MotionVec(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: MotionVec, k: Double) -> MotionVec { MotionVec(x: a.x * k, y: a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
    /// Compass bearing of this vector (0 = north, 90 = east).
    var bearing: Double { (atan2(x, y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
    static func heading(_ deg: Double, _ len: Double = 1) -> MotionVec {
        let r = deg * .pi / 180
        return MotionVec(x: sin(r) * len, y: cos(r) * len)
    }
}

/// A local metric frame around a reference point (equirectangular: exact enough for a few km).
struct MotionFrame: Equatable {
    var origin: LngLat
    var kx: Double { 111_320 * cos(origin.lat * .pi / 180) }
    static let ky = 110_540.0

    func local(_ p: LngLat) -> MotionVec { MotionVec(x: (p.lng - origin.lng) * kx, y: (p.lat - origin.lat) * Self.ky) }
    func world(_ v: MotionVec) -> LngLat { LngLat(lng: origin.lng + v.x / kx, lat: origin.lat + v.y / Self.ky) }
}

/// Constant-velocity Kalman filter for one axis: state (position, velocity).
struct Kalman1D: Equatable {
    var x = 0.0, v = 0.0
    var pxx = 100.0, pxv = 0.0, pvv = 25.0

    mutating func predict(_ dt: Double, accelSd: Double) {
        guard dt > 0 else { return }
        x += v * dt
        let q = accelSd * accelSd
        let dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt
        let nxx = pxx + 2 * dt * pxv + dt2 * pvv + q * dt4 / 4
        let nxv = pxv + dt * pvv + q * dt3 / 2
        let nvv = pvv + q * dt2
        pxx = nxx; pxv = nxv; pvv = nvv
    }

    mutating func updatePosition(_ z: Double, variance r: Double) {
        let s = pxx + r
        let kx = pxx / s, kv = pxv / s
        let y = z - x
        x += kx * y
        v += kv * y
        let nxx = (1 - kx) * pxx, nxv = (1 - kx) * pxv, nvv = pvv - kv * pxv
        pxx = nxx; pxv = nxv; pvv = nvv
    }

    mutating func updateVelocity(_ z: Double, variance r: Double) {
        let s = pvv + r
        let kx = pxv / s, kv = pvv / s
        let y = z - v
        x += kx * y
        v += kv * y
        let nxx = pxx - kx * pxv, nxv = (1 - kv) * pxv, nvv = (1 - kv) * pvv
        pxx = nxx; pxv = nxv; pvv = nvv
    }
}

/// One fix as the map gives it (the drawn target: on the street in town, raw in the desert).
struct MotionFix: Equatable {
    var position: LngLat
    /// The fix's own time, ms (the sender's clock).
    var atMs: Double
    var speedMps: Double?
    /// Course or road direction, degrees; nil when parked / unknown.
    var course: Double?
    var accuracyM: Double?
    /// Policy says live (a stale car is never shown moving).
    var live: Bool
    /// Worse than 60 m: placed where measured, never animated.
    var approximate: Bool
}

/// What a frame draws for one car.
struct MotionPose: Equatable {
    var position: LngLat
    /// Displayed heading (rate-limited), nil when never known.
    var heading: Double?
    /// Displayed ground speed, m/s (0 when resting).
    var speedMps: Double
    /// The car is drawn moving (effects such as dust and headlights key off this).
    var moving: Bool
    /// The pose will still change without a new fix (keep the display link running).
    var animating: Bool
}

enum MotionTuning {
    /// Dead reckoning never runs further than this past the last fix.
    static let horizonS = 1.5
    /// Full speed for this long, then a smooth stop by `horizonS` (no visible brake).
    static let linearS = 1.2
    /// A new fix that disagrees is eased in over this (< 300 ms).
    static let blendS = 0.25
    /// Below this the car is parked: no estimate at all.
    static let restMps = 0.5
    /// Others: a gap longer than this glides in `longGapGlideS` instead of one interval.
    static let longGapS = 10.0
    static let longGapGlideS = 1.2
    /// Farther than this a slide would be fiction: placed at once.
    static let snapM = 2_000.0
    /// Heading: exponential approach with this time constant, never faster than `maxTurnDegS`.
    static let headingTauS = 0.12
    static let maxTurnDegS = 90.0
    /// Turn rate used for dead reckoning is clamped to this.
    static let maxOmegaDegS = 25.0
    /// A stale or parked car settles onto its fix in this.
    static let settleS = 0.6
    /// Process noise of the filter: off-road cars brake and swerve.
    static let accelSd = 3.0

    /// Seconds of dead reckoning actually applied after `dt` seconds: linear, then a smooth
    /// saturation reaching `horizonS` (continuous speed at `linearS`, zero speed at the end).
    static func reckonTime(_ dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        if dt <= linearS { return dt }
        let rest = horizonS - linearS
        return linearS + rest * (1 - exp(-(dt - linearS) / rest))
    }

    static func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Signed smallest rotation from a to b, -180…180.
    static func signedDiff(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func norm(_ d: Double) -> Double { (d.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
}

/// A path the car follows from some time on; evaluated at a frame time (seconds, local clock).
enum MotionPath: Equatable {
    /// Resting at a point.
    case rest(MotionVec)
    /// Constant-turn-rate: from p at t0 with speed v (m/s), heading (deg), turn rate (deg/s).
    case reckon(p: MotionVec, t0: Double, speed: Double, heading: Double, omega: Double)
    /// Hermite from (p0, v0) at t0 to (p1, v1) at t0 + T, then `reckon`/`rest` from p1.
    indirect case glide(p0: MotionVec, v0: MotionVec, p1: MotionVec, v1: MotionVec, t0: Double, T: Double, then: MotionPath)

    /// Position and velocity at time t.
    func eval(_ t: Double) -> (p: MotionVec, v: MotionVec) {
        switch self {
        case let .rest(p):
            return (p, .zero)
        case let .reckon(p, t0, speed, heading, omega):
            let dt = max(0, t - t0)
            let te = MotionTuning.reckonTime(dt)
            /* Speed falls to zero with the saturation (d te / d dt). */
            let k = dt <= MotionTuning.linearS ? 1 : exp(-(dt - MotionTuning.linearS) / (MotionTuning.horizonS - MotionTuning.linearS))
            let w = omega * .pi / 180
            let h0 = heading * .pi / 180
            let h = h0 + w * te
            let pos: MotionVec
            if abs(w) < 1e-4 {
                pos = p + MotionVec(x: sin(h0), y: cos(h0)) * (speed * te)
            } else {
                pos = p + MotionVec(x: (cos(h0) - cos(h)) * speed / w, y: (sin(h) - sin(h0)) * speed / w)
            }
            return (pos, MotionVec(x: sin(h), y: cos(h)) * (speed * k))
        case let .glide(p0, v0, p1, v1, t0, T, then):
            if t >= t0 + T { return then.eval(t) }
            let s = max(0, (t - t0) / T)
            let s2 = s * s, s3 = s2 * s
            let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s, h01 = -2 * s3 + 3 * s2, h11 = s3 - s2
            let m0 = v0 * T, m1 = v1 * T
            let p = p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
            let d00 = 6 * s2 - 6 * s, d10 = 3 * s2 - 4 * s + 1, d01 = -6 * s2 + 6 * s, d11 = 3 * s2 - 2 * s
            let v = (p0 * d00 + m0 * d10 + p1 * d01 + m1 * d11) * (1 / T)
            return (p, v)
        }
    }

    /// Will this path still move after time t?
    func moves(after t: Double) -> Bool {
        switch self {
        case .rest: return false
        case let .reckon(_, t0, speed, _, _): return speed > MotionTuning.restMps && t - t0 < MotionTuning.linearS + 6 * (MotionTuning.horizonS - MotionTuning.linearS)
        case let .glide(_, _, _, _, t0, T, then): return t < t0 + T || then.moves(after: t)
        }
    }
}

final class CarMotion {
    let isMe: Bool
    private(set) var frame: MotionFrame?
    private var kx = Kalman1D(), ky = Kalman1D()
    private(set) var lastFix: MotionFix?
    private var omega = 0.0
    private var lastCourse: (deg: Double, atS: Double)?
    /// Others: how often their fixes arrive (local clock), for the playback length.
    private(set) var intervalS = 3.0
    private var lastArrival: Double?
    private var path: MotionPath = .rest(.zero)
    /// The path being blended out, and when the blend started.
    private var old: (path: MotionPath, start: Double)?
    private var shownHeading: Double?
    private var lastPoseAt: Double?
    private var heldHeading: Double?

    init(isMe: Bool) { self.isMe = isMe }

    /// A new fix. `now` is the frame clock (seconds), `wallMs` the device's wall clock (for my
    /// own latency). Returns false when the fix was already known.
    @discardableResult
    func ingest(_ f: MotionFix, now: Double, wallMs: Double, reduceMotion: Bool) -> Bool {
        if let l = lastFix, l.atMs == f.atMs, l.position == f.position, l.live == f.live { return false }
        let first = frame == nil
        if first { frame = MotionFrame(origin: f.position) }
        guard let frame else { return false }
        let z = frame.local(f.position)
        let dtFix = lastFix.map { (f.atMs - $0.atMs) / 1000 } ?? 0
        let shown = currentPoint(now)
        let jump = lastFix.map { Vehicle.distanceMeters($0.position, f.position) } ?? 0

        /* Filter: reset on the first fix, a long gap, a backwards clock, a jump or an approximate fix. */
        if first || dtFix <= 0 || dtFix > 15 || jump > MotionTuning.snapM || f.approximate {
            kx = Kalman1D(x: z.x); ky = Kalman1D(x: z.y)
            omega = 0
            lastCourse = nil
        } else {
            kx.predict(dtFix, accelSd: MotionTuning.accelSd)
            ky.predict(dtFix, accelSd: MotionTuning.accelSd)
        }
        let acc = max(3, min(60, f.accuracyM ?? 10))
        kx.updatePosition(z.x, variance: acc * acc)
        ky.updatePosition(z.y, variance: acc * acc)
        if let s = f.speedMps, s.isFinite, s >= 0 {
            let c = f.course ?? (MotionVec(x: kx.v, y: ky.v).length > 0.5 ? MotionVec(x: kx.v, y: ky.v).bearing : nil)
            if s < MotionTuning.restMps {
                kx.updateVelocity(0, variance: 0.25); ky.updateVelocity(0, variance: 0.25)
            } else if let c {
                let v = MotionVec.heading(c, s)
                kx.updateVelocity(v.x, variance: 1); ky.updateVelocity(v.y, variance: 1)
            }
        }
        /* Turn rate from the course (or the filtered velocity), smoothed and clamped. */
        let vel = MotionVec(x: kx.v, y: ky.v)
        let course = f.course ?? (vel.length > 2 ? vel.bearing : nil)
        let fixS = f.atMs / 1000
        if let c = course, vel.length > 2, let lc = lastCourse, fixS - lc.atS > 0.2, fixS - lc.atS < 6 {
            let w = MotionTuning.signedDiff(lc.deg, c) / (fixS - lc.atS)
            let k = isMe ? 0.5 : 0.35
            omega = max(-MotionTuning.maxOmegaDegS, min(MotionTuning.maxOmegaDegS, omega + (w - omega) * k))
        } else if vel.length <= 2 {
            omega = 0
        }
        if let c = course { lastCourse = (c, fixS); heldHeading = c }

        let arrivedGap = lastArrival.map { now - $0 }
        if let g = arrivedGap, g > 0.3, g < MotionTuning.longGapS {
            intervalS += (g - intervalS) * 0.4
        }
        lastArrival = now
        lastFix = f

        let p = MotionVec(x: kx.x, y: ky.x)
        let speed = vel.length
        let parked = speed < MotionTuning.restMps || (f.speedMps.map { $0 < MotionTuning.restMps } ?? false)
        let canReckon = f.live && !f.approximate && !parked && !reduceMotion
        /* Exactly where measured: first sight, approximate, Reduce Motion, or far away. */
        if first || f.approximate || reduceMotion || Vehicle.distanceMeters(frame.world(shown), f.position) > MotionTuning.snapM {
            path = .rest(f.approximate ? z : p)
            old = nil
            if first || reduceMotion { shownHeading = course ?? shownHeading }
            return true
        }
        let heading = course ?? vel.bearing
        if isMe {
            /* At the fix's own time: the frame clock minus how old the fix is (latency). */
            let age = max(0, min(MotionTuning.horizonS, (wallMs - f.atMs) / 1000))
            if canReckon {
                let next = MotionPath.reckon(p: p, t0: now - age, speed: speed, heading: heading, omega: omega)
                /* The old estimate keeps playing while the new one is eased in. */
                let keep = evalBlended(now)
                old = (old.map { _ in .glide(p0: keep.p, v0: keep.v, p1: keep.p + keep.v * 0.25, v1: keep.v, t0: now, T: 0.25, then: .rest(keep.p + keep.v * 0.25)) } ?? path, now)
                path = next
            } else {
                let settle = glideToRest(from: now, to: p)
                old = nil
                path = settle
            }
        } else {
            let gap = arrivedGap ?? intervalS
            let T = gap > MotionTuning.longGapS ? MotionTuning.longGapGlideS : max(0.8, min(5, intervalS))
            let cur = evalBlended(now)
            let endV = canReckon ? vel : .zero
            let after: MotionPath = canReckon ? .reckon(p: p, t0: now + T, speed: speed, heading: heading, omega: omega) : .rest(p)
            /* Tangents no longer than 1.5 × the chord, so a noisy speed never makes a loop. */
            let chord = max(0.1, (p - cur.p).length)
            func clampT(_ v: MotionVec) -> MotionVec {
                let m = v.length * T
                return m > 1.5 * chord ? v * (1.5 * chord / m) : v
            }
            path = .glide(p0: cur.p, v0: clampT(cur.v), p1: p, v1: clampT(endV), t0: now, T: canReckon ? T : MotionTuning.settleS, then: after)
            old = nil
        }
        return true
    }

    /// A short settle onto a point (stale / parked): no estimate, only the last metres eased.
    private func glideToRest(from now: Double, to p: MotionVec) -> MotionPath {
        let cur = evalBlended(now)
        if (cur.p - p).length < 0.05 { return .rest(p) }
        return .glide(p0: cur.p, v0: cur.v, p1: p, v1: .zero, t0: now, T: MotionTuning.settleS, then: .rest(p))
    }

    private func evalBlended(_ t: Double) -> (p: MotionVec, v: MotionVec) {
        let n = path.eval(t)
        guard let o = old else { return n }
        let a = MotionTuning.smoothstep((t - o.start) / MotionTuning.blendS)
        if a >= 1 { return n }
        let q = o.path.eval(t)
        return (q.p * (1 - a) + n.p * a, q.v * (1 - a) + n.v * a)
    }

    private func currentPoint(_ t: Double) -> MotionVec { frame == nil ? .zero : evalBlended(t).p }

    /// The pose to draw at frame time `now` (seconds). Heading is rate-limited between calls.
    func pose(_ now: Double, reduceMotion: Bool = false) -> MotionPose? {
        guard let frame, let fix = lastFix else { return nil }
        if let o = old, now - o.start >= MotionTuning.blendS { old = nil }
        let e = evalBlended(now)
        let speed = e.v.length
        let moving = speed > MotionTuning.restMps && fix.live && !fix.approximate
        let target = moving && speed > 0.8 ? e.v.bearing : (heldHeading ?? shownHeading)
        if let target {
            if let h = shownHeading, let last = lastPoseAt, !reduceMotion {
                let dt = max(0, min(0.1, now - last))
                let d = MotionTuning.signedDiff(h, target)
                var step = d * (1 - exp(-dt / MotionTuning.headingTauS))
                let cap = MotionTuning.maxTurnDegS * dt
                step = max(-cap, min(cap, step))
                shownHeading = MotionTuning.norm(h + step)
            } else {
                shownHeading = target
            }
        }
        lastPoseAt = now
        let headingSettling = target.map { t in shownHeading.map { abs(MotionTuning.signedDiff($0, t)) > 0.3 } ?? false } ?? false
        let animating = path.moves(after: now) || old != nil || headingSettling
        return MotionPose(position: frame.world(e.p), heading: shownHeading, speedMps: moving ? speed : 0, moving: moving, animating: animating)
    }
}

/// Every car's motion, by member id.
final class MotionBook {
    private(set) var cars: [String: CarMotion] = [:]

    func motion(_ id: String, isMe: Bool) -> CarMotion {
        if let m = cars[id], m.isMe == isMe { return m }
        let m = CarMotion(isMe: isMe)
        cars[id] = m
        return m
    }

    func keep(_ ids: Set<String>) { cars = cars.filter { ids.contains($0.key) } }
}
