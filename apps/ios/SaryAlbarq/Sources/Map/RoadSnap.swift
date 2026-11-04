import Foundation

/// In town, a car is drawn on the street, not inside the house it is parked beside
/// (port of `apps/web/src/lib/sary/roadSnap.ts`). Only drivable roads from Mapbox
/// Streets' own road lines count, only within the fix's own uncertainty (25–60 m);
/// in open desert there is no street that close, so the car stays where GPS put it.
/// Display only: what is sent to the group is always the real fix.
enum RoadSnap {
    static let source = "sary-roads"
    static let probeLayer = "sary-roads-probe"
    static let maxSnapM = 60.0
    static let minSnapM = 25.0

    /// How far a fix may be moved to a street: 1.5 × its accuracy, between 25 and 60 m; 40 m when unknown.
    static func snapRadius(_ accuracyM: Double?) -> Double {
        guard let a = accuracyM, a.isFinite else { return 40 }
        return max(minSnapM, min(maxSnapM, a * 1.5))
    }

    static let drivable = [
        "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
        "secondary", "secondary_link", "tertiary", "tertiary_link", "street", "street_limited", "service",
    ]

    /// `["match", ["get", "class"], [...drivable], true, false]`
    static var drivableFilter: [Any] { ["match", ["get", "class"], drivable, true, false] }

    /// One road line, with a key that names the road across tiles (same id, or same class + name).
    struct RoadLine: Equatable {
        var key: String
        var coords: [[Double]]
    }

    /// The nearest point on any of `lines` within maxM metres of p, or nil.
    static func nearestOnLines(_ p: LngLat, _ lines: [[[Double]]], maxM: Double = maxSnapM) -> LngLat? {
        let kx = 111_320 * cos(p.lat * Double.pi / 180), ky = 110_540.0
        var best: LngLat?
        var bestD = maxM
        for line in lines where line.count >= 2 {
            for i in 0 ..< line.count - 1 {
                let ax = (line[i][0] - p.lng) * kx, ay = (line[i][1] - p.lat) * ky
                let bx = (line[i + 1][0] - p.lng) * kx, by = (line[i + 1][1] - p.lat) * ky
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
                let x = ax + t * dx, y = ay + t * dy
                let d = (x * x + y * y).squareRoot()
                if d < bestD {
                    bestD = d
                    best = LngLat(lng: p.lng + x / kx, lat: p.lat + y / ky)
                }
            }
        }
        return best
    }

    /// Only lines with a vertex within ~150 m of p (the web's cheap box).
    static func nearby(_ lines: [RoadLine], _ p: LngLat) -> [RoadLine] {
        let pad = 0.0015
        return lines.filter { l in l.coords.contains { $0.count >= 2 && abs($0[0] - p.lng) < pad && abs($0[1] - p.lat) < pad } }
    }

    // MARK: matching across fixes

    /// How many metres a road 90° off the car's course "costs" over one it is driving along.
    static let bearingPenaltyM = 25.0
    /// A different road must beat the current one by this much…
    static let switchMarginM = 5.0
    /// …on this many fixes in a row before the car is moved onto it.
    static let switchFixes = 2
    /// Draw the car along the road only when its course is within this of the road's direction.
    static let alignMaxDeg = 40.0

    struct Candidate: Equatable {
        var key: String
        var point: LngLat
        var distM: Double
        /// Direction of the road segment at the nearest point, 0–360 (the line's drawing order).
        var bearing: Double
    }

    /// Smallest angle between two headings, 0–180.
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    /// Smallest angle between a course and a two-way road, 0–90.
    static func axialDiff(_ course: Double, _ roadBearing: Double) -> Double {
        let d = angleDiff(course, roadBearing)
        return d > 90 ? 180 - d : d
    }

    /// The nearest point on each road (one per key) within maxM of p, nearest first.
    static func candidates(_ p: LngLat, _ lines: [RoadLine], maxM: Double = maxSnapM) -> [Candidate] {
        let kx = 111_320 * cos(p.lat * Double.pi / 180), ky = 110_540.0
        var best: [String: Candidate] = [:]
        var order: [String] = []
        for l in lines where l.coords.count >= 2 {
            let line = l.coords
            for i in 0 ..< line.count - 1 {
                let ax = (line[i][0] - p.lng) * kx, ay = (line[i][1] - p.lat) * ky
                let bx = (line[i + 1][0] - p.lng) * kx, by = (line[i + 1][1] - p.lat) * ky
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                if len2 == 0 { continue }
                let t = max(0, min(1, -(ax * dx + ay * dy) / len2))
                let x = ax + t * dx, y = ay + t * dy
                let d = (x * x + y * y).squareRoot()
                if d > maxM { continue }
                if let prev = best[l.key], prev.distM <= d { continue }
                if best[l.key] == nil { order.append(l.key) }
                best[l.key] = Candidate(key: l.key, point: LngLat(lng: p.lng + x / kx, lat: p.lat + y / ky), distM: d,
                                        bearing: (atan2(dx, dy) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360))
            }
        }
        /* Stable sort by distance (JS sort is stable; insertion order breaks ties). */
        return order.compactMap { best[$0] }.enumerated().sorted { a, b in
            a.element.distM != b.element.distM ? a.element.distM < b.element.distM : a.offset < b.offset
        }.map(\.element)
    }

    /// Distance, plus a penalty for a road that runs across the car's course rather than along it.
    static func cost(_ c: Candidate, course: Double?) -> Double {
        guard let course, course.isFinite else { return c.distM }
        return c.distM + bearingPenaltyM * axialDiff(course, c.bearing) / 90
    }

    /// The drawn heading: the road's own direction when moving along it; the course otherwise.
    /// Nil stays nil — a parked car is never given a direction it did not report.
    static func alignHeading(_ course: Double?, _ roadBearing: Double?) -> Double? {
        guard let course, course.isFinite else { return nil }
        guard let roadBearing else { return course }
        if axialDiff(course, roadBearing) > alignMaxDeg { return course }
        return angleDiff(course, roadBearing) <= 90 ? roadBearing : (roadBearing + 180).truncatingRemainder(dividingBy: 360)
    }

    struct Match: Equatable {
        /// Where to draw the car (the fix itself when no road is near).
        var point: LngLat
        var key: String?
        var heading: Double?
    }

    /// Per-car road matching: holds the car on its road until another is clearly better
    /// (by `switchMarginM`, on `switchFixes` fixes in a row) and scores roads by how well
    /// they line up with the course. Display only — never the shared fix.
    final class Matcher {
        private(set) var road: String?
        private var challenger: String?
        private var challengerCount = 0
        private var last: (p: LngLat, result: Match)?

        func reset() {
            road = nil
            challenger = nil
            challengerCount = 0
            last = nil
        }

        func match(_ p: LngLat, _ lines: [RoadLine], course: Double?, maxM: Double = RoadSnap.maxSnapM) -> Match {
            /* Re-renders call again with the same fix: that is not a second fix. */
            if let l = last, l.p == p { return l.result }
            let r = step(p, lines, course, maxM)
            last = (p, r)
            return r
        }

        private func step(_ p: LngLat, _ lines: [RoadLine], _ course: Double?, _ maxM: Double) -> Match {
            let cands = RoadSnap.candidates(p, lines, maxM: maxM)
            guard var best = cands.first else {
                reset()
                return Match(point: p, key: nil, heading: course)
            }
            var bestCost = RoadSnap.cost(best, course: course)
            for c in cands {
                let k = RoadSnap.cost(c, course: course)
                if k < bestCost {
                    best = c
                    bestCost = k
                }
            }
            let held = road.flatMap { r in cands.first { $0.key == r } }
            var chosen = best
            if let held, held.key != best.key {
                let clearlyBetter = bestCost + RoadSnap.switchMarginM < RoadSnap.cost(held, course: course)
                if clearlyBetter {
                    challengerCount = challenger == best.key ? challengerCount + 1 : 1
                    challenger = best.key
                } else {
                    challenger = nil
                    challengerCount = 0
                }
                if challengerCount < RoadSnap.switchFixes { chosen = held }
            }
            if chosen.key != road {
                road = chosen.key
                challenger = nil
                challengerCount = 0
            } else if chosen == best {
                challenger = nil
                challengerCount = 0
            }
            return Match(point: chosen.point, key: chosen.key, heading: RoadSnap.alignHeading(course, chosen.bearing))
        }
    }
}
