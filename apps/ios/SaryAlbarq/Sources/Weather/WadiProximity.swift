import Foundation

/// A watercourse line read from the Mapbox Streets v8 tiles the map has loaded
/// (source-layer `waterway`).
struct WaterwayLine: Equatable {
    /// Streets v8 `class`: river, canal, stream, stream_intermittent, drain, ditch.
    var cls: String
    var name: String?
    var coords: [Geo.LatLng]
}

/// «هل الطلعة في وادٍ أو قربه؟» — an ESTIMATE from map data.
///
/// Method: the live map keeps an invisible probe layer on Mapbox Streets v8
/// `waterway` (the same vector source the map already loads for road snapping).
/// When the camera settles we read the features of the tiles that are loaded
/// (`querySourceFeatures`) and keep the watercourse classes below. The distance
/// from each member's last real fix, the rally point, the destination and the
/// planned route (sampled every 200 m) to every segment is measured on a local
/// flat projection (error < 0.1 % at outing scales).
///
/// Limits (said in the app): only watercourses someone mapped in OpenStreetMap
/// are known, and many desert wadis are not; only the tiles the map has loaded
/// are searched (roughly what is on screen); wide wadi beds mapped as areas, not
/// lines, are missed; and a flood can come from rain far upstream that the
/// local forecast does not show. So it is a hint, never an all-clear.
enum WadiProximity {
    /// Streets v8 classes that can carry a flash flood. OSM's `waterway=wadi`
    /// arrives as `stream_intermittent`; "wadi" is kept for other tilesets.
    static let classes: Set<String> = ["river", "stream", "stream_intermittent", "wadi", "drain", "canal", "ditch"]

    /// Mapbox expression for the probe layer and the query.
    static var filter: [Any] { ["match", ["get", "class"], classes.sorted(), true, false] }

    static func isWatercourse(_ cls: String) -> Bool { classes.contains(cls) }

    /// Metres from `p` to the segment a–b (local equirectangular projection around `p`).
    static func distance(_ p: Geo.LatLng, toSegment a: Geo.LatLng, _ b: Geo.LatLng) -> Double {
        let k = Double.pi / 180 * Geo.earthRadiusM
        let c = cos(p.lat * .pi / 180)
        let ax = (a.lng - p.lng) * k * c, ay = (a.lat - p.lat) * k
        let bx = (b.lng - p.lng) * k * c, by = (b.lat - p.lat) * k
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0
        t = min(1, max(0, t))
        let x = ax + t * dx, y = ay + t * dy
        return (x * x + y * y).squareRoot()
    }

    static func distance(_ p: Geo.LatLng, to line: WaterwayLine) -> Double {
        guard let first = line.coords.first else { return .infinity }
        guard line.coords.count > 1 else { return Geo.haversineMeters(p, first) }
        var best = Double.infinity
        for i in 1..<line.coords.count {
            best = min(best, distance(p, toSegment: line.coords[i - 1], line.coords[i]))
        }
        return best
    }

    /// Nearest watercourse to any of `points`; nil when none is loaded.
    static func nearest(to points: [Geo.LatLng], lines: [WaterwayLine]) -> WadiContext? {
        var best: WadiContext?
        for l in lines where isWatercourse(l.cls) {
            /* Cheap bounding-box reject: further than 3 km in latitude from every point. */
            let lats = l.coords.map(\.lat)
            guard let lo = lats.min(), let hi = lats.max() else { continue }
            for p in points where p.lat > lo - 0.03 && p.lat < hi + 0.03 {
                let d = distance(p, to: l)
                if d < (best?.distanceM ?? .infinity) { best = WadiContext(distanceM: d, name: l.name) }
            }
        }
        return best
    }

    /// The planned route as points no further apart than `step` metres.
    static func densify(_ route: [Geo.LatLng], step: Double = 200) -> [Geo.LatLng] {
        guard route.count > 1 else { return route }
        var out = [route[0]]
        for i in 1..<route.count {
            let a = route[i - 1], b = route[i]
            let n = max(1, Int((Geo.haversineMeters(a, b) / step).rounded(.up)))
            for s in 1...n {
                let t = Double(s) / Double(n)
                out.append(Geo.LatLng(lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t))
            }
        }
        return out
    }
}
