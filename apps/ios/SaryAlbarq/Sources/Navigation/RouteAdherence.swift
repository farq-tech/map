import Foundation

/// «أنا أمشي بالمسار الثاني ولا زال يعتبر أني بالمسار الآخر» (owner, build 46): on a divided road
/// (a metro / rail median, a service road) the Navigation SDK kept the car "on the route" while the
/// car drove the PARALLEL carriageway 20–40 m away, so the instruction stayed stale
/// («انعطف قليلًا لليسار …») and no real reroute came. This is our own, independent check of the raw
/// GPS fix against the route polyline: how far across, and whether the course agrees. Pure and
/// unit-tested; `NavSession` uses it to hold the stale numbers back and to ask for a route that
/// starts on the road the car is really on (with its heading, so the right carriageway is chosen).
struct RouteLine: Equatable {
    let coords: [LngLat]
    /// Cumulative length at each vertex, metres.
    let cum: [Double]

    init(_ coords: [LngLat]) {
        self.coords = coords
        var c = [0.0]
        c.reserveCapacity(coords.count)
        for i in 1 ..< max(coords.count, 1) {
            c.append(c[i - 1] + Geo.haversineMeters(Geo.LatLng(lat: coords[i - 1].lat, lng: coords[i - 1].lng),
                                                    Geo.LatLng(lat: coords[i].lat, lng: coords[i].lng)))
        }
        cum = coords.isEmpty ? [] : c
    }

    var length: Double { cum.last ?? 0 }

    /// The route's direction over a WINDOW (circular mean of its segments, weighted by length) from
    /// `behindM` before `alongM` to `aheadM` after it: on a winding desert track or a polyline with a
    /// kink one segment's bearing is nothing like the way the car is meant to go.
    func bearing(alongM: Double, behindM: Double = 10, aheadM: Double = 80) -> Double? {
        guard coords.count >= 2 else { return nil }
        let lo = max(0, alongM - behindM), hi = min(length, alongM + aheadM)
        var parts: [(deg: Double, w: Double)] = []
        for i in 0 ..< coords.count - 1 {
            if cum[i + 1] <= lo { continue }
            if cum[i] >= hi { break }
            let w = min(cum[i + 1], hi) - max(cum[i], lo)
            if w <= 0 { continue }
            let kx = 111_320 * cos(coords[i].lat * Double.pi / 180)
            let dx = (coords[i + 1].lng - coords[i].lng) * kx, dy = (coords[i + 1].lat - coords[i].lat) * 110_540
            if dx == 0, dy == 0 { continue }
            parts.append(((atan2(dx, dy) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360), w))
        }
        return parts.isEmpty ? nil : CarHeadingEstimator.circularMean(parts)
    }
}

struct RouteAdherence {
    /// Where one fix sits against the route.
    struct Sample: Equatable {
        /// Distance from the fix to the nearest point of the route (inside the search window), metres.
        var crossM: Double
        /// The route's direction at that point, 0–360.
        var routeBearing: Double
        /// Distance along the route of that point, metres.
        var alongM: Double
        /// Angle between the car's course and the route's direction (0–180); nil when no trusted course.
        var courseDiff: Double?
    }

    enum State: Equatable { case on, off }

    /// Lateral distance that still counts as «on the route» (GPS noise on a good fix is ≤ ~10 m).
    static let baseM = 20.0
    /// …widened by the fix's own uncertainty, but never by more than this.
    static let maxBaseM = 45.0
    /// Fixes (and seconds) in a row before «off»: one noisy fix is not a different road.
    static let offFixes = 4
    static let offSeconds = 4.0
    /// Fixes in a row back near the route before «on» again.
    static let onFixes = 3
    /// Moving at least this fast (m/s) for a fix to count either way.
    static let minSpeedMps = 2.0
    /// Driving the other way along a road next to the route (opposite carriageway).
    static let wrongWayDeg = 100.0
    static let wrongWayMinCrossM = 8.0
    static let wrongWayMinSpeedMps = 5.0
    /// …but only on SUSTAINED evidence (build 49): the heading estimate must be good and opposite the
    /// route's direction over the lookahead window for this much travel (m) or this long (s). A lone
    /// fix — whatever its course says — is never a wrong way.
    static let wrongWayMinTravelM = 70.0
    static let wrongWayMinSeconds = 6.0
    /// The route's direction is taken over this stretch around the matched point (m).
    static let lookBehindM = 10.0
    static let lookAheadM = 80.0
    /// The window searched around the expected position, metres behind / ahead of it.
    static let windowBackM = 400.0
    static let windowAheadM = 1500.0

    private(set) var state: State = .on
    /// Extra lateral distance accepted for this route: a router that insists on the other
    /// carriageway (the only legal one) must not be flagged off-route over and over.
    private(set) var allowanceM = 0.0
    /// The last sample (for logs and tests).
    private(set) var last: Sample?
    private var offCount = 0
    private var onCount = 0
    private var offSinceMs: Double?
    /// The car's real heading (displacement over the last fixes, course only when CoreLocation trusts it).
    private(set) var heading = CarHeadingEstimator()
    /// Opposite-the-route evidence so far: the first fix of the run, and the ground covered since.
    private var wrongRunStartMs: Double?
    private var wrongRunTravelM = 0.0
    private var wrongRunLast: DeviceFix?

    init(allowanceM: Double = 0) { self.allowanceM = allowanceM }

    /// A new route: start fresh, remembering how far the car already is from it.
    mutating func reset(allowanceM: Double = 0) {
        let h = heading
        self = RouteAdherence(allowanceM: allowanceM)
        /* The car did not change direction because the route did: keep what is known of it. */
        heading = h
    }

    /// The lateral tolerance for this fix.
    func toleranceM(accuracy: Double?) -> Double {
        let acc = (accuracy ?? 10).isFinite ? (accuracy ?? 10) : 10
        return min(Self.maxBaseM, max(Self.baseM, 2 * acc)) + allowanceM
    }

    /// The fix against the route. `expectedAlongM` narrows the search to the part of the route the car
    /// should be on (a route that comes back along the other carriageway must not match its later half).
    /// `heading`: the car's estimated heading (`CarHeadingEstimator`); nil falls back to the single fix's
    /// trusted course. It is compared with the route over the lookahead window, not one segment.
    static func measure(_ fix: DeviceFix, on line: RouteLine, expectedAlongM: Double? = nil, heading: Double? = nil) -> Sample? {
        guard line.coords.count >= 2 else { return nil }
        let kx = 111_320 * cos(fix.lat * Double.pi / 180), ky = 110_540.0
        func xy(_ p: LngLat) -> (Double, Double) { ((p.lng - fix.lng) * kx, (p.lat - fix.lat) * ky) }
        let lo = expectedAlongM.map { $0 - windowBackM }, hi = expectedAlongM.map { $0 + windowAheadM }
        var best: (d: Double, bearing: Double, along: Double)?
        for i in 0 ..< line.coords.count - 1 {
            if let lo, line.cum[i + 1] < lo { continue }
            if let hi, line.cum[i] > hi { break }
            let (ax, ay) = xy(line.coords[i]), (bx, by) = xy(line.coords[i + 1])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            if len2 == 0 { continue }
            let t = max(0, min(1, -(ax * dx + ay * dy) / len2))
            let x = ax + t * dx, y = ay + t * dy
            let d = (x * x + y * y).squareRoot()
            if best == nil || d < best!.d {
                let bearing = (atan2(dx, dy) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360)
                best = (d, bearing, line.cum[i] + t * (line.cum[i + 1] - line.cum[i]))
            }
        }
        guard let b = best else { return nil }
        let ahead = line.bearing(alongM: b.along, behindM: lookBehindM, aheadM: lookAheadM) ?? b.bearing
        let diff = (heading ?? HeadingChooser.course(fix)).map { RoadSnap.angleDiff($0, ahead) }
        return Sample(crossM: b.d, routeBearing: b.bearing, alongM: b.along, courseDiff: diff)
    }

    /// One decision, for diagnosing a real drive («يحسبني مسكت المسار غلط»). No coordinates, no names.
    struct Decision: Equatable {
        var atMs: Double
        var state: State
        var crossM: Double
        var toleranceM: Double
        var accuracy: Double?
        var speed: Double?
        var courseDiff: Double?
        var headingConfidence: Double
        var alongM: Double
        var reason: String
        var line: String {
            func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
            return "adh \(state == .on ? "on" : "off") \(reason) cross=\(f(crossM))/\(f(toleranceM)) acc=\(f(accuracy)) v=\(String(format: "%.1f", speed ?? -1)) diff=\(f(courseDiff)) conf=\(String(format: "%.2f", headingConfidence)) along=\(f(alongM))"
        }
    }

    /// The last decisions (ring buffer, newest last). Pure data: tiny, so it is kept in every build; it is
    /// printed to `NavLog` in DEBUG builds only.
    static let decisionLogSize = 200
    private(set) var decisions: [Decision] = []

    private mutating func record(_ fix: DeviceFix, _ s: Sample, tol: Double, speed: Double, conf: Double, _ reason: String) {
        decisions.append(Decision(atMs: fix.atMs, state: state, crossM: s.crossM, toleranceM: tol, accuracy: fix.accuracy, speed: speed,
                                  courseDiff: s.courseDiff, headingConfidence: conf, alongM: s.alongM, reason: reason))
        if decisions.count > Self.decisionLogSize { decisions.removeFirst(decisions.count - Self.decisionLogSize) }
        #if DEBUG
        if reason != "ok" { NavLog.log("%@", decisions[decisions.count - 1].line) }
        #endif
    }

    /// Within this distance of the route's end the car is arriving, not leaving the route: the destination
    /// is often 20–40 m from the track that really reaches it, and the nearest route point stops moving
    /// while the car drives past.
    static let endGuardM = 60.0

    /// Feed one fix. Returns the new state when it just changed.
    @discardableResult
    mutating func note(_ fix: DeviceFix, on line: RouteLine, expectedAlongM: Double? = nil) -> State? {
        /* The heading is the displacement over the last fixes, not this fix's own (noisy) course. */
        let est = heading.ingest(fix)
        let goodHeading = est.goodHeading
        guard var s = Self.measure(fix, on: line, expectedAlongM: expectedAlongM, heading: goodHeading) else { return nil }
        if goodHeading == nil { s.courseDiff = nil }
        last = s
        let speed = fix.speed ?? 0
        let tol = toleranceM(accuracy: fix.accuracy)
        /* A parked or crawling car (and a very poor fix) says nothing about which road it is on. */
        guard speed >= Self.minSpeedMps else { record(fix, s, tol: tol, speed: speed, conf: est.confidence, "skip-slow"); return nil }
        guard (fix.accuracy ?? 10) <= 40 else { record(fix, s, tol: tol, speed: speed, conf: est.confidence, "skip-accuracy"); return nil }
        let nearEnd = s.alongM >= line.length - Self.endGuardM
        let acrossOff = s.crossM > tol && !nearEnd
        let wrongWay = noteWrongWay(fix, sample: s, speed: speed)
        if wrongWay, state == .on {
            /* Sustained evidence already: no further fixes to wait for. */
            onCount = 0
            state = .off
            record(fix, s, tol: tol, speed: speed, conf: est.confidence, "OFF-wrong-way")
            return .off
        }
        if acrossOff {
            onCount = 0
            offCount += 1
            if offSinceMs == nil { offSinceMs = fix.atMs }
            if state == .on, offCount >= Self.offFixes, fix.atMs - (offSinceMs ?? fix.atMs) >= Self.offSeconds * 1000 {
                state = .off
                record(fix, s, tol: tol, speed: speed, conf: est.confidence, "OFF-across")
                return .off
            }
            record(fix, s, tol: tol, speed: speed, conf: est.confidence, "across \(offCount)")
        } else if s.crossM <= max(12, min(tol, 2 * (fix.accuracy ?? 10))) + allowanceM || nearEnd, (s.courseDiff ?? 0) < Self.wrongWayDeg {
            offCount = 0
            offSinceMs = nil
            onCount += 1
            if state == .off, onCount >= Self.onFixes {
                state = .on
                record(fix, s, tol: tol, speed: speed, conf: est.confidence, "ON-back")
                return .on
            }
            record(fix, s, tol: tol, speed: speed, conf: est.confidence, nearEnd && s.crossM > tol ? "near-end" : "ok")
        } else if state == .on, !wrongWay {
            /* «Fixes in a row»: a fix in between that is not off breaks the run (isolated outliers add up to nothing). */
            offCount = 0
            offSinceMs = nil
            record(fix, s, tol: tol, speed: speed, conf: est.confidence, "between")
        } else {
            record(fix, s, tol: tol, speed: speed, conf: est.confidence, "hold")
        }
        return nil
    }

    /// Opposite the route's direction (over the lookahead window) with a good heading: the run grows by
    /// the ground covered; one fix that disagrees (or no good heading) ends it. True once it has lasted
    /// `wrongWayMinTravelM` or `wrongWayMinSeconds`.
    private mutating func noteWrongWay(_ fix: DeviceFix, sample s: Sample, speed: Double) -> Bool {
        let opposite = (s.courseDiff ?? 0) >= Self.wrongWayDeg && speed >= Self.wrongWayMinSpeedMps && s.crossM > Self.wrongWayMinCrossM
        guard opposite else {
            wrongRunStartMs = nil
            wrongRunTravelM = 0
            wrongRunLast = nil
            return false
        }
        if let start = wrongRunStartMs, let prev = wrongRunLast {
            wrongRunTravelM += Geo.haversineMeters(prev.coordinate, fix.coordinate)
            wrongRunLast = fix
            return wrongRunTravelM >= Self.wrongWayMinTravelM || fix.atMs - start >= Self.wrongWayMinSeconds * 1000
        }
        wrongRunStartMs = fix.atMs
        wrongRunTravelM = 0
        wrongRunLast = fix
        return false
    }

    /// A new route from the car's own position that still starts off the road line by `crossM`
    /// (the router put it on the other carriageway): accept that offset rather than loop.
    static func allowance(forCrossM crossM: Double, accuracy: Double?) -> Double {
        let base = min(maxBaseM, max(baseM, 2 * (accuracy ?? 10)))
        return crossM > base ? min(60, crossM - base + 8) : 0
    }
}
