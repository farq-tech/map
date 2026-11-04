import Foundation

/// What of my trail may go on a story that leaves the outing.
///
/// Default (both switches off):
/// - a privacy zone of `zoneM` around where my trail STARTS and where it ENDS
///   (usually home, or the place we met): every part of the trail inside either
///   circle is cut, and the line stops at the circle's edge — so the end of the
///   drawn line is ~500 m from the real point in every direction, and a trail
///   that comes back near home later is cut there too;
/// - waypoints and the «أطول وقفة» marker inside a zone are not drawn;
/// - the map is framed on what is left, never on the hidden ends;
/// - companions are a count, never names.
enum StoryPrivacy {
    static let zoneM = 500.0

    /// A visible stretch of the trail; `fadeStart` / `fadeEnd` mark ends cut by a zone
    /// (drawn fading out, so nobody reads the edge of the zone as a destination).
    struct Run: Equatable {
        var points: [StoryPoint]
        var fadeStart = false
        var fadeEnd = false
    }

    struct Result: Equatable {
        var runs: [Run]
        var startZone: LngLat?
        var endZone: LngLat?
        /// Everything that is drawn (for framing the map).
        var visiblePoints: [LngLat] { runs.flatMap { $0.points.map(\.position) } }
        var isEmpty: Bool { runs.allSatisfy { $0.points.count < 2 } }
    }

    /// The trail as the story may show it.
    static func apply(_ pts: [StoryPoint], showStartEnd: Bool, zoneM: Double = zoneM) -> Result {
        guard let first = pts.first, let last = pts.last else { return Result(runs: []) }
        if showStartEnd { return Result(runs: pts.count >= 2 ? [Run(points: pts)] : []) }
        let zones = [first.position, last.position]
        func inside(_ p: LngLat) -> Bool { zones.contains { Vehicle.distanceMeters($0, p) < zoneM } }

        var runs: [Run] = []
        var cur: [StoryPoint] = []
        var curFadeStart = false
        func close(fadeEnd: Bool) {
            if cur.count >= 2 { runs.append(Run(points: cur, fadeStart: curFadeStart, fadeEnd: fadeEnd)) }
            cur = []
        }

        for i in pts.indices {
            let p = pts[i]
            let pIn = inside(p.position)
            if i == 0 {
                if !pIn { cur = [p] }
                continue
            }
            let prev = pts[i - 1]
            let prevIn = inside(prev.position)
            switch (prevIn, pIn) {
            case (false, false):
                /* Both outside, but a long straight step can still cross a zone. */
                if let (a, b) = crossing(prev, p, zones: zones, zoneM: zoneM) {
                    cur.append(a)
                    close(fadeEnd: true)
                    var q = b
                    q.gap = false
                    cur = [q]
                    curFadeStart = true
                    var r = p
                    r.gap = p.gap
                    cur.append(r)
                } else {
                    cur.append(p)
                }
            case (false, true):
                cur.append(edge(from: prev, to: p, zones: zones, zoneM: zoneM, leaving: false))
                close(fadeEnd: true)
            case (true, false):
                var e = edge(from: prev, to: p, zones: zones, zoneM: zoneM, leaving: true)
                e.gap = false
                cur = [e, p]
                curFadeStart = true
            case (true, true):
                continue
            }
        }
        close(fadeEnd: false)
        return Result(runs: runs, startZone: zones[0], endZone: zones[1])
    }

    /// Is `p` drawable (outside both zones, or zones off)?
    static func isVisible(_ p: LngLat, in r: Result, zoneM: Double = zoneM) -> Bool {
        for z in [r.startZone, r.endZone].compactMap({ $0 }) where Vehicle.distanceMeters(z, p) < zoneM { return false }
        return true
    }

    /// Who is named on the story.
    static func names(_ companions: [String], show: Bool) -> [String] { show ? companions : [] }

    // MARK: geometry

    /// The point between a→b where it crosses into (or out of) the zones, by bisection.
    private static func edge(from a: StoryPoint, to b: StoryPoint, zones: [LngLat], zoneM: Double, leaving: Bool) -> StoryPoint {
        func inside(_ p: LngLat) -> Bool { zones.contains { Vehicle.distanceMeters($0, p) < zoneM } }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let isIn = inside(lerp(a, b, mid).position)
            /* entering: lo stays outside; leaving: lo stays inside. */
            if isIn == leaving { lo = mid } else { hi = mid }
        }
        /* Always return the side that is OUTSIDE (never a point a hair inside a zone). */
        return lerp(a, b, leaving ? hi : lo)
    }

    /// For a step whose ends are both outside: where it enters and leaves a zone, if it does.
    private static func crossing(_ a: StoryPoint, _ b: StoryPoint, zones: [LngLat], zoneM: Double) -> (StoryPoint, StoryPoint)? {
        for z in zones {
            let pr = TrailGeoLite.project(z, a.position, b.position)
            guard pr.distM < zoneM, pr.u > 0, pr.u < 1 else { continue }
            let mid = lerp(a, b, pr.u)
            let enter = edge(from: a, to: mid, zones: [z], zoneM: zoneM, leaving: false)
            let leave = edge(from: mid, to: b, zones: [z], zoneM: zoneM, leaving: true)
            return (enter, leave)
        }
        return nil
    }

    static func lerp(_ a: StoryPoint, _ b: StoryPoint, _ u: Double) -> StoryPoint {
        StoryPoint(lat: a.lat + (b.lat - a.lat) * u, lng: a.lng + (b.lng - a.lng) * u, t: a.t + (b.t - a.t) * u, gap: b.gap)
    }
}

/// Flat-earth projection of a point on a segment (metres); enough for the few-km steps we cut.
enum TrailGeoLite {
    static func project(_ p: LngLat, _ a: LngLat, _ b: LngLat) -> (u: Double, distM: Double) {
        let k = Double.pi / 180, r = 6_371_000.0
        let c = cos(a.lat * k)
        let bx = (b.lng - a.lng) * k * c * r, by = (b.lat - a.lat) * k * r
        let px = (p.lng - a.lng) * k * c * r, py = (p.lat - a.lat) * k * r
        let len2 = bx * bx + by * by
        let u = len2 > 0 ? max(0, min(1, (px * bx + py * by) / len2)) : 0
        let dx = px - bx * u, dy = py - by * u
        return (u, (dx * dx + dy * dy).squareRoot())
    }
}
