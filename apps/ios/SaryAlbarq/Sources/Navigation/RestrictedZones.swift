import Foundation

/// Provider-independent safety net for routing (issue #187).
///
/// Zones are OSM `aeroway=aerodrome` and `landuse=military` polygons for Saudi Arabia, bundled as
/// `Resources/RestrictedZones/restricted_zones.json` (built by `scripts/build_restricted_zones.py`;
/// © OpenStreetMap contributors, ODbL). A route that drives through one is rejected whichever
/// engine produced it: OSM-based engines (Valhalla) treat the untagged `highway=service` ways inside
/// an airfield as ordinary public streets.
///
/// Legitimate cases are not flagged:
///  - classified roads (`motorway…tertiary`) that run through an aerodrome polygon: «openLines»;
///  - passenger terminals and public parking (`aeroway=terminal`, `amenity=parking`): «openRings»;
///  - a zone that already contains the trip's origin (the driver must be able to leave it).
struct RestrictedZoneSet {
    struct Zone {
        enum Kind: String { case aerodrome, military }
        var id: String
        var kind: Kind
        var name: String
        var ring: [LngLat]
        /// The ring's bounding box, grown by `marginM` (so a prefilter never misses the margin).
        let box: Box

        init(id: String, kind: Kind, name: String, ring: [LngLat]) {
            self.id = id; self.kind = kind; self.name = name; self.ring = ring
            self.box = Box(ring).grown(byMeters: Self.margin(kind))
        }

        /// OSM draws an aerodrome as a strip around the runway; the fenced airfield (service roads,
        /// aprons, hangars) extends a few hundred metres beyond it. Routes are checked with this
        /// margin; a destination only against the ring itself.
        static func margin(_ kind: Kind) -> Double { kind == .aerodrome ? RestrictedZoneSet.aerodromeMarginM : 0 }
        var marginM: Double { Self.margin(kind) }

        /// «مطار الثمامة» / «منشأة عسكرية»: what to call it in an alert.
        var title: String {
            if !name.isEmpty { return name }
            return kind == .aerodrome ? "مطار" : "منشأة عسكرية"
        }
    }

    struct Box {
        var minLat: Double, minLng: Double, maxLat: Double, maxLng: Double
        init(_ pts: [LngLat]) {
            minLat = pts.map(\.lat).min() ?? 0; maxLat = pts.map(\.lat).max() ?? 0
            minLng = pts.map(\.lng).min() ?? 0; maxLng = pts.map(\.lng).max() ?? 0
        }
        func grown(byMeters m: Double) -> Box {
            var b = self
            let dLat = m / 111_320.0, dLng = m / (111_320.0 * max(0.2, cos(((minLat + maxLat) / 2) * .pi / 180)))
            b.minLat -= dLat; b.maxLat += dLat; b.minLng -= dLng; b.maxLng += dLng
            return b
        }
        func contains(_ p: LngLat) -> Bool { p.lat >= minLat && p.lat <= maxLat && p.lng >= minLng && p.lng <= maxLng }
        func intersects(_ o: Box) -> Bool { !(o.minLat > maxLat || o.maxLat < minLat || o.minLng > maxLng || o.maxLng < minLng) }
    }

    var zones: [Zone]
    private(set) var openLines: [(box: Box, pts: [LngLat])]
    private(set) var openRings: [(box: Box, pts: [LngLat])]

    /// A crossing shorter than this is a GPS-edge graze, not a drive through the facility.
    static let minCrossingM = 120.0
    /// Distance from a classified road within which a point counts as being on that public road.
    static let openRoadToleranceM = 45.0
    /// Sampling step along the route, metres.
    static let stepM = 25.0
    /// How far beyond the OSM aerodrome ring the airfield fence is assumed to run.
    static let aerodromeMarginM = 300.0

    init(zones: [Zone], openLines: [[LngLat]] = [], openRings: [[LngLat]] = []) {
        self.zones = zones
        self.openLines = openLines.map { (Box($0), $0) }
        self.openRings = openRings.map { (Box($0), $0) }
    }

    static let empty = RestrictedZoneSet(zones: [])

    // MARK: loading

    private struct FileModel: Decodable {
        struct Z: Decodable { var id: String; var kind: String; var name: String; var ring: [[Double]] }
        struct L: Decodable { var line: [[Double]] }
        struct R: Decodable { var ring: [[Double]] }
        var zones: [Z]
        var openLines: [L]?
        var openRings: [R]?
    }

    static func decode(_ data: Data) -> RestrictedZoneSet? {
        guard let m = try? JSONDecoder().decode(FileModel.self, from: data) else { return nil }
        func pts(_ a: [[Double]]) -> [LngLat] { a.compactMap { $0.count >= 2 ? LngLat(lng: $0[0], lat: $0[1]) : nil } }
        let zones = m.zones.compactMap { z -> Zone? in
            let r = pts(z.ring)
            return r.count >= 4 ? Zone(id: z.id, kind: Zone.Kind(rawValue: z.kind) ?? .military, name: z.name, ring: r) : nil
        }
        return RestrictedZoneSet(zones: zones, openLines: (m.openLines ?? []).map { pts($0.line) }, openRings: (m.openRings ?? []).map { pts($0.ring) })
    }

    /// Loaded once from the app bundle; empty (guard off) if the file is missing or unreadable.
    static let bundled: RestrictedZoneSet = {
        let bundles = [Bundle.main] + Bundle.allBundles
        for b in bundles {
            if let url = b.url(forResource: "restricted_zones", withExtension: "json", subdirectory: "RestrictedZones") ?? b.url(forResource: "restricted_zones", withExtension: "json"),
               let data = try? Data(contentsOf: url), let set = decode(data) { return set }
        }
        return .empty
    }()

    // MARK: geometry

    static func contains(_ ring: [LngLat], _ p: LngLat) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat), p.lng < (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func distanceToLineM(_ pts: [LngLat], _ p: LngLat) -> Double {
        let mLat = 111_320.0, mLng = 111_320.0 * cos(p.lat * .pi / 180)
        var best = Double.infinity
        for (a, b) in zip(pts, pts.dropFirst()) {
            let ax = (a.lng - p.lng) * mLng, ay = (a.lat - p.lat) * mLat
            let bx = (b.lng - p.lng) * mLng, by = (b.lat - p.lat) * mLat
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            best = min(best, hypot(ax + t * dx, ay + t * dy))
        }
        return best
    }

    /// True when `p` is on a public part of an aerodrome: near a classified road or in a terminal/parking.
    func isPublic(_ p: LngLat) -> Bool {
        let pad = 0.0005 // ~55 m
        for r in openRings where r.box.grown(byMeters: Self.openRoadToleranceM).contains(p) {
            // A terminal building plus its forecourt/kerb (the pick-up point is outside the footprint).
            if Self.contains(r.pts, p) || Self.distanceToLineM(r.pts, p) <= Self.openRoadToleranceM { return true }
        }
        for l in openLines {
            guard p.lat >= l.box.minLat - pad, p.lat <= l.box.maxLat + pad, p.lng >= l.box.minLng - pad, p.lng <= l.box.maxLng + pad else { continue }
            if Self.distanceToLineM(l.pts, p) <= Self.openRoadToleranceM { return true }
        }
        return false
    }

    /// The zone a point is in, unless that part is public (terminal, parking, classified road).
    func restrictedZone(containing p: LngLat) -> Zone? {
        for z in zones where z.box.contains(p) && Self.contains(z.ring, p) && !isPublic(p) { return z }
        return nil
    }

    /// Inside the ring, or within the zone's margin of it.
    static func covers(_ z: Zone, _ p: LngLat) -> Bool {
        guard z.box.contains(p) else { return false }
        if contains(z.ring, p) { return true }
        return z.marginM > 0 && distanceToLineM(z.ring, p) <= z.marginM
    }

    struct Crossing: Equatable {
        var zoneId: String
        var title: String
        /// Metres of the route driven inside the zone off the public roads.
        var meters: Double
    }

    /// Zones `route` is driven through (≥ `minCrossingM` off public roads). Zones containing
    /// `exempt` points (the trip's origin) are ignored: the driver has to be able to leave.
    ///
    /// `tailZoneId`/`tailM`: when the destination is itself inside an aerodrome, the last `tailM`
    /// metres of the route do not count for THAT aerodrome (terminal roads, car parks), while a
    /// route that crosses the airfield earlier on its way somewhere else is still rejected.
    func crossings(of route: [LngLat], exempt: [LngLat] = [], tailZoneId: String? = nil, tailM: Double = 0) -> [Crossing] {
        guard route.count >= 2, !zones.isEmpty else { return [] }
        let rbox = Box(route)
        // Metres from each vertex to the end of the route.
        var toEnd = [Double](repeating: 0, count: route.count)
        if tailZoneId != nil {
            for i in stride(from: route.count - 2, through: 0, by: -1) { toEnd[i] = toEnd[i + 1] + Vehicle.distanceMeters(route[i], route[i + 1]) }
        }
        var out: [Crossing] = []
        for z in zones where z.box.intersects(rbox) {
            if exempt.contains(where: { Self.covers(z, $0) }) { continue }
            var meters = 0.0
            let tailing = z.id == tailZoneId
            for i in 0..<(route.count - 1) {
                let a = route[i], b = route[i + 1]
                let seg = Box([a, b])
                guard seg.intersects(z.box) else { continue }
                let len = Vehicle.distanceMeters(a, b)
                let n = max(1, Int((len / Self.stepM).rounded(.up)))
                for k in 0..<n {
                    let f = (Double(k) + 0.5) / Double(n)
                    if tailing, toEnd[i] - len * f <= tailM { continue }
                    let p = LngLat(lng: a.lng + (b.lng - a.lng) * f, lat: a.lat + (b.lat - a.lat) * f)
                    if Self.covers(z, p), !isPublic(p) { meters += len / Double(n) }
                }
            }
            if meters >= Self.minCrossingM { out.append(Crossing(zoneId: z.id, title: z.title, meters: meters)) }
        }
        return out
    }

    func zone(id: String) -> Zone? { zones.first { $0.id == id } }
}

/// Rejects (and, once, re-asks around) any route that drives through a restricted zone, for every
/// provider underneath it (Mapbox, Valhalla, the desert grid).
final class RestrictedZoneGuardProvider: NavRoutingProvider {
    let base: NavRoutingProvider
    let zones: RestrictedZoneSet
    var name: String { base.name }
    /// Last stretch of a route to a destination inside an airport that is not checked against that airport.
    static let destinationTailM = 1500.0

    init(base: NavRoutingProvider, zones: RestrictedZoneSet = .bundled) {
        self.base = base
        self.zones = zones
    }

    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan {
        // A destination inside a MILITARY facility is never routed to: say so instead of drawing a path.
        // A destination inside an AERODROME (terminal, car park, cargo) is routed normally: people
        // do go to airports. Only the last `tailM` of such a route is exempt from the check.
        let target = request.target.position
        if let z = zones.restrictedZone(containing: target), z.kind == .military {
            throw NavRoutingError.restrictedDestination(z.title)
        }
        let tailZone = zones.zones.first { $0.kind == .aerodrome && RestrictedZoneSet.covers($0, target) }
        let plan = try await base.routes(request)
        let firstPass = classify(plan, request, tailZone: tailZone)
        if !firstPass.clean.isEmpty { return NavRoutePlan(routes: firstPass.clean, native: plan.native) }
        guard !plan.routes.isEmpty else { return plan }

        // Every route crosses a zone: ask the engine again with those zones excluded.
        var retry = request
        retry.avoidPolygons = firstPass.crossed.prefix(4).compactMap { zones.zone(id: $0.zoneId)?.ring }
        let blocked = firstPass.crossed.first?.title ?? "منطقة مقيّدة"
        guard !retry.avoidPolygons.isEmpty, retry.avoidPolygons != request.avoidPolygons else {
            throw NavRoutingError.restrictedRoute(blocked)
        }
        let second: NavRoutePlan
        do { second = try await base.routes(retry) } catch { throw NavRoutingError.restrictedRoute(blocked) }
        let again = classify(second, retry, tailZone: tailZone)
        guard !again.clean.isEmpty else { throw NavRoutingError.restrictedRoute(again.crossed.first?.title ?? blocked) }
        return NavRoutePlan(routes: again.clean, native: second.native)
    }

    private func classify(_ plan: NavRoutePlan, _ request: NavRouteRequest, tailZone: RestrictedZoneSet.Zone?) -> (clean: [NavRoute], crossed: [RestrictedZoneSet.Crossing]) {
        var clean: [NavRoute] = []
        var crossed: [RestrictedZoneSet.Crossing] = []
        for route in plan.routes {
            let c = zones.crossings(of: route.coordinates, exempt: [request.origin], tailZoneId: tailZone?.id, tailM: Self.destinationTailM)
            if c.isEmpty { clean.append(route) } else { crossed.append(contentsOf: c) }
        }
        var seen = Set<String>()
        crossed = crossed.filter { seen.insert($0.zoneId).inserted }
        return (clean, crossed)
    }
}
