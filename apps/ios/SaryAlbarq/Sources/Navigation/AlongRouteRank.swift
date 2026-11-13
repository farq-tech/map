import Foundation

/// «على طول المسار»: ranks places (fuel stations, water, services) by how far AHEAD they are along the
/// active route and how far they sit off it, instead of by straight-line distance from me. A station
/// 3 km behind me, or 20 km to the side, must not beat one 12 km ahead on my route.
///
/// Pure and Foundation-only (UX backlog R2, docs/UX-BACKLOG-2GIS.md): the route and the places come in
/// as plain coordinates, so it is unit-tested without a map, a session or a network. Works offline.
enum AlongRouteRank {
    struct Point: Equatable {
        var lat: Double
        var lng: Double
        init(lat: Double, lng: Double) { self.lat = lat; self.lng = lng }
    }

    struct Candidate: Equatable {
        var id: String
        var point: Point
        init(id: String, point: Point) { self.id = id; self.point = point }
    }

    struct Ranked: Equatable {
        var id: String
        /// Metres along the route from my position to the point nearest this place. Negative: behind me.
        var aheadM: Double
        /// Metres between the place and the route (the detour to reach it).
        var offRouteM: Double
        /// Lower is better: distance ahead plus a penalty for leaving the route.
        var score: Double
    }

    struct Config: Equatable {
        /// Places farther than this from the route are not «on the way».
        var maxOffRouteM: Double = 4_000
        /// A place this far behind me still counts as «at my position» (GPS noise, a station I am passing).
        var behindToleranceM: Double = 150
        /// Leaving the route costs this many times its length in ranking (a 1 km detour reads like 2 km ahead).
        var detourWeight: Double = 2
        var limit: Int = 6
        init() {}
        init(maxOffRouteM: Double, behindToleranceM: Double = 150, detourWeight: Double = 2, limit: Int = 6) {
            self.maxOffRouteM = maxOffRouteM
            self.behindToleranceM = behindToleranceM
            self.detourWeight = detourWeight
            self.limit = limit
        }
    }

    /// `route`: the active route's polyline. `myAlongM`: metres already travelled along it (route length
    /// minus the distance remaining). Empty when the route is unusable (fewer than two points).
    static func rank(route: [Point], myAlongM: Double, candidates: [Candidate], config: Config = Config()) -> [Ranked] {
        guard route.count >= 2, !candidates.isEmpty else { return [] }
        let cum = cumulative(route)
        var out: [Ranked] = []
        out.reserveCapacity(candidates.count)
        for c in candidates {
            let hit = nearest(on: route, cum: cum, to: c.point)
            let ahead = hit.alongM - myAlongM
            guard hit.offRouteM <= config.maxOffRouteM, ahead >= -config.behindToleranceM else { continue }
            let score = max(ahead, 0) + config.detourWeight * hit.offRouteM
            out.append(Ranked(id: c.id, aheadM: ahead, offRouteM: hit.offRouteM, score: score))
        }
        out.sort { a, b in a.score != b.score ? a.score < b.score : a.id < b.id }
        return Array(out.prefix(max(0, config.limit)))
    }

    /// «على مسارك» for a place that is practically on the route, «+٣٠٠ م عن مسارك» otherwise.
    static func detail(offRouteM: Double, number: (Int) -> String = { String($0) }) -> String {
        if offRouteM < 150 { return "على مسارك" }
        let rounded = Int((offRouteM / 100).rounded()) * 100
        if rounded >= 1_000 {
            let km = Double(rounded) / 1_000
            let kmText = km == km.rounded() ? number(Int(km)) : number(Int(km)) + "٫" + number(Int(((km - km.rounded(.down)) * 10).rounded()))
            return "+\(kmText) كم عن مسارك"
        }
        return "+\(number(rounded)) م عن مسارك"
    }

    /// Points on the route AHEAD of me (every `everyM`, up to `horizonM`): where to look for places beyond the
    /// first search box, because the nearest box around me only covers the first ~14 km of a long desert route.
    static func samples(route: [Point], myAlongM: Double, everyM: Double = 20_000, horizonM: Double = 80_000) -> [Point] {
        guard route.count >= 2, everyM > 0 else { return [] }
        let cum = cumulative(route)
        guard let total = cum.last, total > myAlongM else { return [] }
        var out: [Point] = []
        var target = max(0, myAlongM) + everyM
        var i = 1
        while target <= min(total, max(0, myAlongM) + horizonM) {
            while i < cum.count - 1, cum[i] < target { i += 1 }
            let span = cum[i] - cum[i - 1]
            let t = span > 0 ? min(1, max(0, (target - cum[i - 1]) / span)) : 0
            out.append(Point(lat: route[i - 1].lat + t * (route[i].lat - route[i - 1].lat),
                             lng: route[i - 1].lng + t * (route[i].lng - route[i - 1].lng)))
            target += everyM
        }
        return out
    }

    // MARK: geometry

    private static let mPerDegLat = 111_194.9   // same radius as `haversine`
    private static let mPerDegLng = 111_194.9

    static func cumulative(_ route: [Point]) -> [Double] {
        var out = [0.0]
        out.reserveCapacity(route.count)
        var acc = 0.0
        for i in 1..<route.count {
            acc += haversine(route[i - 1], route[i])
            out.append(acc)
        }
        return out
    }

    /// The nearest point on the polyline to `p`: its distance along the route and its distance from it.
    static func nearest(on route: [Point], cum: [Double], to p: Point) -> (alongM: Double, offRouteM: Double) {
        var best = (alongM: 0.0, offRouteM: Double.infinity)
        for i in 0..<(route.count - 1) {
            let a = route[i], b = route[i + 1]
            let cosLat = cos(a.lat * .pi / 180)
            let bx = (b.lng - a.lng) * cosLat * mPerDegLng, by = (b.lat - a.lat) * mPerDegLat
            let px = (p.lng - a.lng) * cosLat * mPerDegLng, py = (p.lat - a.lat) * mPerDegLat
            let len2 = bx * bx + by * by
            let t = len2 > 0 ? min(1, max(0, (px * bx + py * by) / len2)) : 0
            let dx = px - t * bx, dy = py - t * by
            let d = (dx * dx + dy * dy).squareRoot()
            if d < best.offRouteM {
                best = (cum[i] + t * (cum[i + 1] - cum[i]), d)
            }
        }
        return best
    }

    static func haversine(_ a: Point, _ b: Point) -> Double {
        let r = Double.pi / 180
        let dLat = (b.lat - a.lat) * r, dLng = (b.lng - a.lng) * r
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * r) * cos(b.lat * r) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * 6_371_000.0 * asin(min(1, h.squareRoot()))
    }
}
