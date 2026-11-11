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

    /// Driving (speed and course known): a city-canyon fix 30–80 m off still belongs on the street.
    static let drivingMps = 3.0
    static let maxDrivingSnapM = 100.0

    /// The search radius for this fix: `snapRadius`, widened up to 100 m when the car is clearly driving.
    static func searchRadius(accuracy: Double?, speed: Double?, course: Double?) -> Double {
        let base = snapRadius(accuracy)
        guard let v = speed, v >= drivingMps, course != nil else { return base }
        return min(maxDrivingSnapM, max(base, (accuracy ?? 40) * 1.5 + 10))
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

    /// The key of a road feature without an id: its class and first non-empty name (a road cut
    /// at a tile edge comes back as two features, and both get the same key).
    static func nameKey(cls: String, name: String, nameAr: String, ref: String) -> String {
        let n = [name, nameAr, ref].first { !$0.isEmpty } ?? ""
        return "\(cls):\(n)"
    }

    /// What a fresh road query means for the road set in use.
    struct RoadSetUpdate: Equatable {
        /// The lines differ: store the new set.
        var replace: Bool
        /// The set visibly changed (count or first line): re-match unmatched cars and re-sync.
        var changed: Bool

        static func between(old: [RoadLine], new: [RoadLine]) -> RoadSetUpdate {
            RoadSetUpdate(replace: new != old, changed: new.count != old.count || new.first?.coords != old.first?.coords)
        }
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

    /// Only lines with a segment passing within ~170 m of p. (Build 4 looked at vertices only: a long
    /// straight Riyadh street whose vertices are far apart was dropped, and the car stayed on the roofs.)
    static func nearby(_ lines: [RoadLine], _ p: LngLat, padM: Double = 170) -> [RoadLine] {
        let padLat = padM / 110_540, padLng = padM / (111_320 * cos(p.lat * Double.pi / 180))
        return lines.filter { l in
            let c = l.coords
            guard c.count >= 2 else { return false }
            for i in 0 ..< c.count - 1 where c[i].count >= 2 && c[i + 1].count >= 2 {
                if p.lng >= min(c[i][0], c[i + 1][0]) - padLng, p.lng <= max(c[i][0], c[i + 1][0]) + padLng,
                   p.lat >= min(c[i][1], c[i + 1][1]) - padLat, p.lat <= max(c[i][1], c[i + 1][1]) + padLat { return true }
            }
            return false
        }
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

        /// Clearly off-road (good fixes far from any street): never pulled onto one by a noisy fix.
        private(set) var offRoad = false
        /// The current fix's accuracy (nil from the legacy entry point).
        private var accuracyNow: Double?
        private var offRoadCount = 0
        private var stillSince: Double?

        /// Fixes this good that are this far from every street, in a row, mean off-road.
        static let offRoadGoodAccM = 20.0
        static let offRoadFixes = 3
        /// Parked this long: only a street right beside the car counts.
        static let parkedS = 30.0

        /// The full decision for one fix: radius from accuracy and motion, off-road and parked rules,
        /// then the same-road matcher. `p` is the best position we have (Kalman for «أنت»).
        func match(_ p: LngLat, _ lines: [RoadLine], course: Double?, speed: Double?, accuracy: Double?, atMs: Double) -> Match {
            if let l = last, l.p == p { return l.result }
            accuracyNow = accuracy
            if let v = speed, v < 0.5 { stillSince = stillSince ?? atMs } else if speed != nil { stillSince = nil }
            let parked = stillSince.map { atMs - $0 >= Self.parkedS * 1000 } ?? false
            let radius = parked ? RoadSnap.minSnapM : RoadSnap.searchRadius(accuracy: accuracy, speed: speed, course: course)
            if let a = accuracy, a <= Self.offRoadGoodAccM {
                let nearest = RoadSnap.candidates(p, lines, maxM: RoadSnap.maxDrivingSnapM).first?.distM ?? .infinity
                if nearest > max(35, 2 * a) {
                    offRoadCount += 1
                    if offRoadCount >= Self.offRoadFixes { offRoad = true }
                } else if nearest <= max(15, a) {
                    offRoadCount = 0
                    offRoad = false
                }
            }
            let r: Match
            if offRoad {
                road = nil
                challenger = nil
                challengerCount = 0
                r = Match(point: p, key: nil, heading: course)
            } else {
                r = step(p, lines, course, radius)
            }
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
                /* A poor fix must be much clearer, for longer, before the car changes street. */
                let margin = max(RoadSnap.switchMarginM, 0.6 * (accuracyNow ?? 0))
                let clearlyBetter = bestCost + margin < RoadSnap.cost(held, course: course)
                if clearlyBetter {
                    challengerCount = challenger == best.key ? challengerCount + 1 : 1
                    challenger = best.key
                } else {
                    challenger = nil
                    challengerCount = 0
                }
                if challengerCount < ((accuracyNow ?? 0) > 25 ? 4 : RoadSnap.switchFixes) { chosen = held }
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

/// Latest-wins for asynchronous results: each request takes a new generation, and a result
/// is applied only while its generation is still the current one (a slower, older answer
/// never overwrites a newer one).
struct QueryGeneration {
    private(set) var current = 0

    mutating func next() -> Int {
        current &+= 1
        return current
    }

    func isCurrent(_ generation: Int) -> Bool { generation == current }
}

extension WadiProximity {
    /// The class a queried waterway feature is kept under (Streets v8 `class`, else its `type`),
    /// or nil when it is no watercourse (a wadi by `type` counts whatever its class).
    static func watercourseClass(cls: String?, type: String?) -> String? {
        let c = cls ?? type ?? ""
        guard isWatercourse(c) || type == "wadi" else { return nil }
        return c
    }
}
