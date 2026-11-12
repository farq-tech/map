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

    init(allowanceM: Double = 0) { self.allowanceM = allowanceM }

    /// A new route: start fresh, remembering how far the car already is from it.
    mutating func reset(allowanceM: Double = 0) {
        self = RouteAdherence(allowanceM: allowanceM)
    }

    /// The lateral tolerance for this fix.
    func toleranceM(accuracy: Double?) -> Double {
        let acc = (accuracy ?? 10).isFinite ? (accuracy ?? 10) : 10
        return min(Self.maxBaseM, max(Self.baseM, 2 * acc)) + allowanceM
    }

    /// The fix against the route. `expectedAlongM` narrows the search to the part of the route the car
    /// should be on (a route that comes back along the other carriageway must not match its later half).
    static func measure(_ fix: DeviceFix, on line: RouteLine, expectedAlongM: Double? = nil) -> Sample? {
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
        let diff = HeadingChooser.course(fix).map { RoadSnap.angleDiff($0, b.bearing) }
        return Sample(crossM: b.d, routeBearing: b.bearing, alongM: b.along, courseDiff: diff)
    }

    /// Feed one fix. Returns the new state when it just changed.
    @discardableResult
    mutating func note(_ fix: DeviceFix, on line: RouteLine, expectedAlongM: Double? = nil) -> State? {
        guard let s = Self.measure(fix, on: line, expectedAlongM: expectedAlongM) else { return nil }
        last = s
        /* A parked or crawling car (and a very poor fix) says nothing about which road it is on. */
        let speed = fix.speed ?? 0
        guard speed >= Self.minSpeedMps, (fix.accuracy ?? 10) <= 40 else { return nil }
        let tol = toleranceM(accuracy: fix.accuracy)
        let acrossOff = s.crossM > tol
        let wrongWay = speed >= Self.wrongWayMinSpeedMps && (s.courseDiff ?? 0) >= Self.wrongWayDeg && s.crossM > Self.wrongWayMinCrossM
        if acrossOff || wrongWay {
            onCount = 0
            offCount += 1
            if offSinceMs == nil { offSinceMs = fix.atMs }
            if state == .on, offCount >= Self.offFixes, fix.atMs - (offSinceMs ?? fix.atMs) >= Self.offSeconds * 1000 {
                state = .off
                return .off
            }
        } else if s.crossM <= max(12, min(tol, 2 * (fix.accuracy ?? 10))) + allowanceM, (s.courseDiff ?? 0) < Self.wrongWayDeg {
            offCount = 0
            offSinceMs = nil
            onCount += 1
            if state == .off, onCount >= Self.onFixes {
                state = .on
                return .on
            }
        }
        return nil
    }

    /// A new route from the car's own position that still starts off the road line by `crossM`
    /// (the router put it on the other carriageway): accept that offset rather than loop.
    static func allowance(forCrossM crossM: Double, accuracy: Double?) -> Double {
        let base = min(maxBaseM, max(baseM, 2 * (accuracy ?? 10)))
        return crossM > base ? min(60, crossM - base + 8) : 0
    }
}
