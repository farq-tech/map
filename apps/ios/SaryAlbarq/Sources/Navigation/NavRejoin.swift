import Foundation

/// «كيف أرجع للمسار؟»: the car is off the drawn route (a track, `NavSession` reroute). We follow the
/// tracks (الدروب): the route itself is the guidance. A short straight shortcut to the nearest point of
/// the route is drawn ONLY when (1) it is short, (2) the bundled terrain grid (`DesertGrid`: ground class
/// + DEM elevation) says it crosses nothing hard, and (3) its cost beats following the tracks.
/// Missing terrain data = no line. Pure and unit-tested; `NavRejoinTuning` holds every tunable number.
enum NavRejoinTuning {
    /// Inside this the car counts as «on the track»: no connector.
    static let hideM = 25.0
    /// A shortcut longer than this is never drawn (owner: 250 m).
    static let maxShortcutM = 250.0
    /// Terrain is sampled along the line at this spacing (the grid is ~90 m, so denser is pointless).
    static let sampleStepM = 25.0
    /// Ruggedness: elevation this far to each side of the chord, metres.
    static let sideOffsetM = 30.0
    /// A side sample differing from the chord point by more than this vetoes the line (rocks, a ridge or a gully beside it), metres.
    static let maxSideDeltaM = 10.0
    /// Slope above this on any sampled step vetoes the line (`DesertRouter.hardGrade`, 15 %).
    static let maxGrade = DesertRouter.hardGrade
    /// End-to-end elevation difference above this vetoes the line, metres.
    static let maxEndDeltaM = 25.0
    /// Any sample higher than the chord (the straight ramp between the ends) by more than this vetoes it, metres.
    static let maxAboveChordM = 25.0
    /// Ground classes a shortcut may cross: firm ground and flat sand. Crest, sabkha, wadi, rock, forbidden: never.
    static let allowedGround: Set<DesertGrid.Ground> = [.firm, .sand]

    // Cost, in seconds-equivalent. Shortcut: time at the off-track speed scaled by the router's own
    // effort (ground x slope), plus a flat penalty for leaving the tracks.
    /// Pace over firm flat ground off the track, km/h (effort 1.0); sand (1.7) is slower by the same factor.
    static let offTrackKmh = 30.0
    /// Flat penalty for leaving the tracks (risk of getting stuck, no track under the wheels), seconds.
    static let offTrackPenaltyS = 10.0
    /// Extra seconds per 1 % of average slope on the shortcut (difficulty beyond what `effort` already scales).
    static let slopePenaltyPerPercentS = 2.0
    // Following the tracks to the same point.
    /// The tracks never run straight from where the car is: the way along them is this many times the straight distance.
    static let trackDetourFactor = 3.5
    /// Time to find and reach the track network at all, seconds.
    static let trackAccessPenaltyS = 20.0
    /// Track pace, km/h (`DesertRouter.trackKmh`), at the router's track effort.
    static let trackKmh = DesertRouter.trackKmh
}

/// Where the rejoin logic reads the ground. Nil = unknown, and unknown means NO straight line.
protocol NavTerrain {
    /// Real metres (no exaggeration).
    func elevation(at p: LngLat) -> Double?
    func ground(at p: LngLat) -> DesertGrid.Ground?
    /// The data's own resolution, metres: slopes are measured over at least this distance.
    var resolutionM: Double { get }
}

/// The bundled desert grid (ground class + Copernicus DEM, offline, ~90 m).
struct GridTerrain: NavTerrain {
    let grid: DesertGrid
    /// The live map's Mapbox terrain-DEM (`mapboxMap.elevation(at:)`, exaggeration already removed);
    /// used for elevation when it answers, the grid's own DEM otherwise.
    var liveElevation: ((LngLat) -> Double?)?
    var resolutionM: Double { liveElevation == nil ? 90 : 30 }

    private func inside(_ p: LngLat) -> Bool {
        let h = grid.header
        return p.lat > h.south && p.lat < h.north && p.lng > h.west && p.lng < h.east
    }
    func elevation(at p: LngLat) -> Double? {
        guard inside(p) else { return nil }
        return liveElevation?(p) ?? Double(grid.elev[grid.index(p)])
    }
    func ground(at p: LngLat) -> DesertGrid.Ground? { inside(p) ? grid.ground(grid.index(p)) : nil }
}

enum NavRejoinLive {
    /// Set by the live map when its terrain-DEM source is on the style (`OutingMapboxView`).
    nonisolated(unsafe) static var elevation: ((LngLat) -> Double?)?
}

/// The dashed hop from the car to the route.
struct NavConnector: Equatable {
    var from: LngLat
    var to: LngLat
    var distanceM: Double
    var etaS: Double
    /// The end is the route's first coordinate (the car is behind its start), not a point along it.
    var toRouteStart: Bool
}

enum NavRejoin {
    /// Why no shortcut (tests / logs).
    enum Veto: Equatable { case onRoute, tooFar, noTerrain, ground, steep, elevation, rugged, tracksCheaper }

    struct Decision: Equatable {
        var connector: NavConnector?
        var veto: Veto?
        var shortcutCostS: Double?
        var tracksCostS: Double?
    }

    static func connector(me: LngLat?, route: [LngLat], terrain: NavTerrain?) -> NavConnector? {
        decide(me: me, route: route, terrain: terrain).connector
    }

    static func decide(me: LngLat?, route: [LngLat], terrain: NavTerrain?) -> Decision {
        guard let me, let (to, atStart, d) = nearest(me, route) else { return Decision(veto: .onRoute) }
        guard d > NavRejoinTuning.hideM else { return Decision(veto: .onRoute) }
        guard d <= NavRejoinTuning.maxShortcutM else { return Decision(veto: .tooFar) }
        guard let terrain else { return Decision(veto: .noTerrain) }
        let n = max(2, Int((d / NavRejoinTuning.sampleStepM).rounded(.up)) + 1)
        var z: [Double] = [], g: [DesertGrid.Ground] = []
        let kx = 111_320 * cos(me.lat * Double.pi / 180), ky = 110_540.0
        let ex = (to.lng - me.lng) * kx, ey = (to.lat - me.lat) * ky
        let ux = -ey / d, uy = ex / d  // unit normal, metres
        var side: [(Double, Double)] = []
        for k in 0 ..< n {
            let t = Double(k) / Double(n - 1)
            let p = LngLat(lng: me.lng + t * (to.lng - me.lng), lat: me.lat + t * (to.lat - me.lat))
            guard let e = terrain.elevation(at: p), let gr = terrain.ground(at: p) else { return Decision(veto: .noTerrain) }
            z.append(e); g.append(gr)
            func off(_ m: Double) -> LngLat { LngLat(lng: p.lng + m * ux / kx, lat: p.lat + m * uy / ky) }
            guard let l = terrain.elevation(at: off(NavRejoinTuning.sideOffsetM)), let r = terrain.elevation(at: off(-NavRejoinTuning.sideOffsetM)) else { return Decision(veto: .noTerrain) }
            side.append((l, r))
        }
        for (k, s) in side.enumerated() where abs(s.0 - z[k]) > NavRejoinTuning.maxSideDeltaM || abs(s.1 - z[k]) > NavRejoinTuning.maxSideDeltaM {
            return Decision(veto: .rugged)
        }
        let seg = d / Double(n - 1)
        // Ground first (rock / crest / sabkha / wadi / forbidden), then slope, then elevation.
        if g.contains(where: { !NavRejoinTuning.allowedGround.contains($0) }) { return Decision(veto: .ground) }
        var cost = 0.0
        var worst = 0.0
        /* Slope over about one grid cell (~90 m): cells are flat blocks, so a step between two samples inside
         * neighbouring cells would otherwise read a cell boundary as a cliff. */
        let w = max(1, Int((terrain.resolutionM / seg).rounded()))
        for k in 0 ..< n - 1 {
            let j = min(n - 1, k + w)
            let grade = (z[j] - z[k]) / (Double(j - k) * seg)
            worst = max(worst, abs(grade))
            let e = DesertRouter.effort(ground: g[k + 1], flags: 0, ridge: 255, bearing: 0, grade: grade, rain: false).0
            guard abs(grade) <= NavRejoinTuning.maxGrade, let e else { return Decision(veto: .steep) }
            cost += seg * e / (NavRejoinTuning.offTrackKmh / 3.6)
        }
        if abs(z[n - 1] - z[0]) > NavRejoinTuning.maxEndDeltaM { return Decision(veto: .elevation) }
        for k in 0 ..< n {
            let chord = z[0] + (z[n - 1] - z[0]) * Double(k) / Double(n - 1)
            if z[k] - chord > NavRejoinTuning.maxAboveChordM { return Decision(veto: .elevation) }
        }
        let avgPct = abs(z[n - 1] - z[0]) / d * 100
        let shortcut = cost + NavRejoinTuning.offTrackPenaltyS + NavRejoinTuning.slopePenaltyPerPercentS * avgPct
        let tracks = d * NavRejoinTuning.trackDetourFactor * DesertRouter.trackEffort / (NavRejoinTuning.trackKmh / 3.6)
            + NavRejoinTuning.trackAccessPenaltyS
        guard shortcut < tracks else { return Decision(veto: .tracksCheaper, shortcutCostS: shortcut, tracksCostS: tracks) }
        let c = NavConnector(from: me, to: to, distanceM: d, etaS: cost, toRouteStart: atStart)
        return Decision(connector: c, shortcutCostS: shortcut, tracksCostS: tracks)
    }

    /// The connector's map text: «٩٠ م • ٢٠ ث».
    static func label(_ c: NavConnector) -> String {
        "\(SaryFormat.distance(meters: c.distanceM)) • \(NavText.remaining(seconds: c.etaS))"
    }

    /// The grid for a connector, if one of the bundled regions holds both ends (offline, cached).
    static func bundledTerrain(_ a: LngLat, _ b: LngLat) -> NavTerrain? {
        DesertGrid.covering(a, b).flatMap { DesertGrid.bundled($0) }.map { GridTerrain(grid: $0, liveElevation: NavRejoinLive.elevation) }
    }

    /// Nearest point of the polyline to `me`, whether it is the first coordinate, and the distance in metres.
    static func nearest(_ me: LngLat, _ route: [LngLat]) -> (LngLat, Bool, Double)? {
        guard !route.isEmpty else { return nil }
        let kx = 111_320 * cos(me.lat * Double.pi / 180), ky = 110_540.0
        func xy(_ p: LngLat) -> (Double, Double) { ((p.lng - me.lng) * kx, (p.lat - me.lat) * ky) }
        var best: (d2: Double, point: LngLat, atStart: Bool)?
        if route.count == 1 {
            let (x, y) = xy(route[0])
            best = (x * x + y * y, route[0], true)
        }
        for i in 0 ..< max(route.count - 1, 0) {
            let (ax, ay) = xy(route[i]), (bx, by) = xy(route[i + 1])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
            let x = ax + t * dx, y = ay + t * dy
            let d2 = x * x + y * y
            if best == nil || d2 < best!.d2 {
                let pt = t == 0 ? route[i] : t == 1 ? route[i + 1]
                    : LngLat(lng: route[i].lng + t * (route[i + 1].lng - route[i].lng), lat: route[i].lat + t * (route[i + 1].lat - route[i].lat))
                best = (d2, pt, i == 0 && t == 0)
            }
        }
        guard let b = best else { return nil }
        return (b.point, b.atStart, b.d2.squareRoot())
    }
}
