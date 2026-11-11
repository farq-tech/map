import Foundation

/// The one seam between the app and whoever computes routes.
///
/// Today: `MapboxNavRoutingProvider` (Mapbox Directions through the Navigation SDK).
/// Later: a `ValhallaRoutingProvider` against the company's own server, mapping the
/// same `NavRouteSpec` to Valhalla costing options. If that server answers in the
/// OSRM/Mapbox route-response format (`format=osrm` with banner + voice
/// instructions), the Mapbox guidance engine can still follow it
/// (`NavigationRoutes(routeResponse:routeIndex:responseOrigin:)`); otherwise
/// `LocalGuidanceEngine` follows any `NavRoute` on its own.
protocol NavRoutingProvider: AnyObject {
    /// Shown in diagnostics («Mapbox», «Valhalla»).
    var name: String { get }
    /// Routes from `origin` to `target`, best first. Throws `NavRoutingError`.
    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan
}

struct NavRouteRequest: Equatable {
    var origin: LngLat
    /// My course, so the first instruction does not start with a U-turn behind me.
    var heading: Double?
    var target: NavTarget
    var options: NavRouteOptions
}

enum NavRoutingError: Error, Equatable {
    /// No road route at all (the target is far from any road, or across a border).
    case noRoute
    case offline
    /// No Mapbox token in the build.
    case notConfigured
    case failed(String)

    var message: String {
        switch self {
        case .noRoute: return "ما لقينا طريقًا إلى هنا."
        case .offline: return "ما فيه إنترنت لحساب الطريق. جرّب بعد شوي."
        case .notConfigured: return "الملاحة غير مفعّلة في هذه النسخة."
        case let .failed(m): return m.isEmpty ? "تعذّر حساب الطريق، حاول مرة ثانية." : m
        }
    }
}

/// Joins the road router to the bundled offline desert cost grid when the destination is in a
/// supported pilot region. If the grid cannot complete the desert leg, keep the best real road
/// approach and let NavSession show a clearly labelled final bearing from that road endpoint.
/// A failed grid lookup must never discard a valid city route and replace it with a bearing from
/// the user's origin.
final class DesertAwareRouteProvider: NavRoutingProvider {
    let base: NavRoutingProvider
    let gridForRegion: (String) -> DesertGrid?
    let regionForPoint: (LngLat) -> String?
    /// Everywhere else in the Kingdom: one grid stitched from the national tiles for a corridor box
    /// (`DesertTileStore`). nil disables it (pilot regions only). Returns nil when the tiles are
    /// missing / offline / the box is too big; the road route + final bearing are kept then.
    let corridorGrid: ((DesertGrid.BBox) async -> DesertGrid?)?
    let rainMayBePresent: () -> Bool

    var name: String { base.name + " + دروب البر" }

    init(base: NavRoutingProvider,
         gridForRegion: @escaping (String) -> DesertGrid? = DesertGrid.bundled,
         regionForPoint: @escaping (LngLat) -> String? = { DesertAwareRouteProvider.regionName(containing: $0) },
         corridorGrid: ((DesertGrid.BBox) async -> DesertGrid?)? = { await DesertTileStore.shared.corridor($0) },
         rainMayBePresent: @escaping () -> Bool = { true }) {
        self.base = base
        self.gridForRegion = gridForRegion
        self.regionForPoint = regionForPoint
        self.corridorGrid = corridorGrid
        self.rainMayBePresent = rainMayBePresent
    }

    /// A grid to route on and a key for the per-grid caches: a bundled pilot region, or a corridor
    /// stitched from national tiles.
    private struct DesertArea {
        var key: String
        var grid: DesertGrid
    }

    /// The grid for a destination: its pilot region when it has one (bundled, offline), else a
    /// corridor from `hint` (the road route's end) to the target from the national tiles.
    private func desertArea(for target: LngLat, near hint: LngLat?, tiles: Bool = true) async -> DesertArea? {
        if let region = regionForPoint(target), let grid = gridForRegion(region) {
            return DesertArea(key: region, grid: grid)
        }
        guard tiles, let corridorGrid, let box = DesertTiles.corridor(from: hint, to: target) else { return nil }
        return await corridorArea(corridorGrid, box)
    }

    /// One grid holding both points: a shared pilot region, or a corridor when they are close enough.
    private func sharedArea(_ a: LngLat, _ b: LngLat) async -> DesertArea? {
        if let region = sharedRegion(a, b) {
            return gridForRegion(region).map { DesertArea(key: region, grid: $0) }
        }
        guard regionForPoint(b) == nil, let corridorGrid, let box = DesertTiles.corridor(spanning: a, b) else { return nil }
        return await corridorArea(corridorGrid, box)
    }

    private func corridorArea(_ load: (DesertGrid.BBox) async -> DesertGrid?, _ box: DesertGrid.BBox) async -> DesertArea? {
        guard let grid = await load(box) else { return nil }
        let h = grid.header
        return DesertArea(key: "tiles|\(h.south)|\(h.west)|\(h.north)|\(h.east)", grid: grid)
    }

    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan {
        let roadPlan: NavRoutePlan
        do {
            roadPlan = try await base.routes(request)
        } catch let error as NavRoutingError {
            let shared = await sharedArea(request.origin, request.target.position)
            if let complete = gridRoutes(from: request.origin, to: request.target.position, area: shared) {
                return NavRoutePlan(routes: complete)
            }
            if error == .noRoute, let area = await desertArea(for: request.target.position, near: nil),
               let access = await routesViaMappedAccess(request, region: area.key, grid: area.grid) {
                if !access.connected.isEmpty { return NavRoutePlan(routes: access.connected) }
                if let best = access.roadApproaches.first { return NavRoutePlan(routes: [best.route], native: best.native) }
            }
            throw error
        }

        if roadPlan.routes.contains(where: { route in
            guard let via = route.via else { return false }
            return via.contains("Wikiloc") || via.contains("الخرائط البرية")
        }) { return roadPlan }

        let target = request.target.position
        // Outside the pilots, only when the road route stops short of the pin (an off-road last
        // leg): a city route that reaches its destination never loads tiles or gains a desert leg.
        let roadEnd = roadPlan.routes.first?.end
        let offRoadLeft = roadPlan.routes.isEmpty || NavOffRoad.lastLeg(routeEnd: roadEnd, target: target) != nil
        if let area = await desertArea(for: target, near: roadEnd, tiles: offRoadLeft) {
            let region = area.key, grid = area.grid
            let combined = roadPlan.routes.first.flatMap { hybridRoutes(road: $0, target: target, region: region, grid: grid) } ?? []
            if !combined.isEmpty { return NavRoutePlan(routes: combined) }
            if let access = await routesViaMappedAccess(request, region: region, grid: grid) {
                if !access.connected.isEmpty { return NavRoutePlan(routes: access.connected) }
                if let best = access.roadApproaches.first { return NavRoutePlan(routes: [best.route], native: best.native) }
            }
            // Map routing can still provide a legitimate city/street segment even when the
            // desert grid has a gap. Keep it. NavSession derives the final arrow from route.end,
            // so the driver follows streets first instead of receiving a 50 km origin-to-pin arrow.
            if !roadPlan.routes.isEmpty || area.key.hasPrefix("tiles|") { return roadPlan }
            throw NavRoutingError.noRoute
        }

        // Outside the three pilot rasters, a road engine's route is still useful as the
        // city/road prefix. Its end is the only defensible place to start the approximate final
        // bearing; do not throw away that route because the pin is farther than the snap radius.
        return roadPlan
    }

    /// Connect a distant road origin to a supported desert route through an actual mapped OSM
    /// road/track inside the grid. Both legs come from data: the road router supplies the prefix,
    /// and the bundled terrain/OSM grid supplies the desert path. No straight-line connector is
    /// invented when either side cannot be joined.
    private struct MappedAccessResult {
        var connected: [NavRoute] = []
        var roadApproaches: [RoadApproach] = []
    }

    private struct RoadApproach {
        var route: NavRoute
        var native: AnyObject?
    }

    private func routesViaMappedAccess(_ request: NavRouteRequest, region: String, grid: DesertGrid) async -> MappedAccessResult? {
        let accesses = accessPoints(grid, region: region, near: request.target.position)
        guard !accesses.isEmpty else { return nil }
        // The street requests are independent network calls: send them together instead of one
        // after another (up to 4 round trips per route and reroute). The answers are then
        // evaluated in the original preference order, and the raster legs (3 A* each) only until
        // the first access that connects, exactly as the sequential loop did.
        let roads = await streetRoutes(request, to: accesses)
        var result = MappedAccessResult()
        for (access, fetched) in zip(accesses, roads) {
            guard let road = fetched, !road.routes.isEmpty else { continue }
            var combined: [NavRoute] = []
            for route in road.routes {
                guard let end = route.end else { continue }
                let gap = Vehicle.distanceMeters(end, access)
                /* Cell centers and Directions' snapped road endpoint may differ by roughly a
                 * raster cell. Previously a valid street route that snapped 120–200 m away
                 * from the marked access was discarded, even though the cost grid could
                 * connect from the actual route endpoint to the destination. */
                if gap <= max(180, hypot(grid.dx, grid.dy) * 2) {
                    combined.append(contentsOf: hybridRoutes(road: route, target: request.target.position, region: region, grid: grid) ?? [])
                }
                // Even if the router cannot reach the requested mapped cell precisely, its
                // street route may still be the best real approach. Preserve it for an honest
                // final bearing from that street endpoint.
                result.roadApproaches.append(contentsOf: [RoadApproach(route: route, native: road.native)])
            }
            if !combined.isEmpty {
                result.connected.append(contentsOf: combined)
                return result
            }
            // A mapped access point may be beyond the router's snap radius or the raster may
            // contain an impassable gap. NavOffRoad labels only the remainder from the route end.
        }
        guard !result.connected.isEmpty || !result.roadApproaches.isEmpty else { return nil }
        result.roadApproaches.sort {
            Vehicle.distanceMeters($0.route.end ?? request.origin, request.target.position)
                < Vehicle.distanceMeters($1.route.end ?? request.origin, request.target.position)
        }
        return result
    }


    /// One street route request per access point, all in flight at once. Answers come back in
    /// the accesses' order; a failed request is nil (as `try?` was in the sequential loop).
    private func streetRoutes(_ request: NavRouteRequest, to accesses: [LngLat]) async -> [NavRoutePlan?] {
        let base = UncheckedSendable(self.base)
        return await withTaskGroup(of: UncheckedSendable<(Int, NavRoutePlan?)>.self) { group in
            for (i, access) in accesses.enumerated() {
                var accessRequest = request
                accessRequest.target = NavTarget(source: .point, name: "مدخل درب البر", position: access)
                let job = UncheckedSendable(accessRequest)
                group.addTask {
                    let plan = try? await base.value.routes(job.value)
                    return UncheckedSendable((i, plan))
                }
            }
            var out = [NavRoutePlan?](repeating: nil, count: accesses.count)
            for await answer in group { out[answer.value.0] = answer.value.1 }
            return out
        }
    }

    /// `DesertGrid.accessPoints` scans every cell of the raster. A reroute asks again for the
    /// same destination, so keep the last few answers on this provider (whose `gridForRegion`
    /// gives the same grid for a region).
    private let accessLock = NSLock()
    private var accessCache: [String: [LngLat]] = [:]

    private func accessPoints(_ grid: DesertGrid, region: String, near target: LngLat) -> [LngLat] {
        let key = "\(region)|\(grid.rows)x\(grid.cols)|\(target.lat)|\(target.lng)"
        accessLock.lock()
        let cached = accessCache[key]
        accessLock.unlock()
        if let cached { return cached }
        let points = grid.accessPoints(near: target)
        accessLock.lock()
        if accessCache.count >= 16 { accessCache.removeAll() }
        accessCache[key] = points
        accessLock.unlock()
        return points
    }

    static func regionName(containing point: LngLat) -> String? {
        DesertGrid.bboxes.first { $0.value.contains(point) }?.key
    }

    private static func contains(_ grid: DesertGrid, _ point: LngLat) -> Bool {
        point.lat >= grid.header.south && point.lat <= grid.header.north &&
        point.lng >= grid.header.west && point.lng <= grid.header.east
    }

    private func sharedRegion(_ a: LngLat, _ b: LngLat) -> String? {
        guard let ra = regionForPoint(a), ra == regionForPoint(b) else { return nil }
        return ra
    }

    private func gridRoutes(from a: LngLat, to b: LngLat, area: DesertArea?) -> [NavRoute]? {
        guard let grid = area?.grid else { return nil }
        guard Self.contains(grid, a), Self.contains(grid, b) else { return nil }
        let options = DesertRouter.options(grid, from: a, to: b, rain: rainMayBePresent())
        guard !options.isEmpty else { return nil }
        return options.map { makeRoute($0, prefix: [], start: a, target: b, idPrefix: "desert", road: nil, grid: grid) }
    }

    private func hybridRoutes(road: NavRoute, target: LngLat, region: String, grid: DesertGrid) -> [NavRoute]? {
        guard let joinIndex = road.coordinates.indices.reversed().first(where: { Self.contains(grid, road.coordinates[$0]) }) else { return nil }
        let prefix = Array(road.coordinates[...joinIndex])
        guard let join = prefix.last else { return nil }
        let options = DesertRouter.options(grid, from: join, to: target, rain: rainMayBePresent())
        guard !options.isEmpty else { return nil }
        // The grid has finite resolution. If the road endpoint is too far from the first
        // supported cell, keep the road route and let the UI show a bearing from that endpoint.
        guard let first = options.first?.points.first,
              Vehicle.distanceMeters(join, first) <= max(60, hypot(grid.dx, grid.dy) * 0.75) else { return nil }
        return options.map { makeRoute($0, prefix: prefix, start: road.start ?? join, target: target, idPrefix: road.id, road: road, grid: grid) }
    }

    private func makeRoute(_ option: DesertRouter.Option, prefix: [LngLat], start: LngLat, target: LngLat, idPrefix: String,
                           road: NavRoute?, grid: DesertGrid) -> NavRoute {
        var coordinates = prefix
        let routePoints = option.points
        if coordinates.isEmpty { coordinates.append(start) }
        let gridJoin = coordinates.last
        if let first = routePoints.first {
            if let last = coordinates.last, Vehicle.distanceMeters(last, first) <= 5 {
                // Keep the raster path after its shared join point. Skipping the whole raster
                // polyline here silently replaced the off-road leg with a straight line to target.
                coordinates.append(contentsOf: routePoints.dropFirst())
            } else {
                coordinates.append(contentsOf: routePoints)
            }
        }
        // End at the last evidence-backed raster cell. NavOffRoad exposes the remaining
        // unsourced gap as a bearing instead of drawing it as a calculated trail.
        guard coordinates.count >= 2 else { return NavRoute(id: "\(idPrefix)-\(option.mode.rawValue)", coordinates: coordinates, distanceM: 0, durationS: 0, steps: []) }

        let cumulative = cumulativeMeters(coordinates)
        let total = cumulative.last ?? 0
        let desertRouteSteps = desertSteps(coordinates, cumulative: cumulative, targetName: "نهاية الدرب المحسوب")
        let steps: [NavStep]
        if let road {
            // Hybrid routes are guided locally (the road router's native route ends at the
            // access point). Preserve its actual street maneuvers, then continue with the
            // raster-derived desert turns and arrival. Dropping these steps made the route
            // line correct while city guidance silently became a generic bearing.
            let streetSteps = road.steps.filter { $0.maneuver.kind != .arrive }
            let desertContinuation = desertRouteSteps.filter {
                $0.maneuver.kind != .depart && $0.maneuver.kind != .arrive
            }
            let arrival = desertRouteSteps.last(where: { $0.maneuver.kind == .arrive })
            steps = streetSteps + desertContinuation + (arrival.map { [$0] } ?? [])
        } else {
            steps = desertRouteSteps
        }
        let prefixDistance = prefix.count >= 2 ? roadDistance(prefix) : 0
        let streetDuration = road.map { Self.durationAlongRoad($0, distanceM: prefixDistance) } ?? 0
        let desertDuration = option.minutes * 60
        let duration = max(60, streetDuration + desertDuration)
        var timingProfile: [NavRouteTimingLeg] = []
        if prefixDistance > 0, streetDuration > 0 {
            timingProfile.append(NavRouteTimingLeg(distanceM: min(total, prefixDistance), durationS: streetDuration))
        }
        let desertDistance = max(0, total - timingProfile.reduce(0) { $0 + $1.distanceM })
        if desertDistance > 0, desertDuration > 0 {
            timingProfile.append(NavRouteTimingLeg(distanceM: desertDistance, durationS: desertDuration))
        }
        if let last = timingProfile.indices.last {
            let profileDuration = timingProfile.reduce(0) { $0 + $1.durationS }
            timingProfile[last].durationS += max(0, duration - profileDuration)
        }
        let streetSurfaces: [NavSurfaceRun]
        if let road, prefixDistance > 0 {
            if road.surfaceRuns.isEmpty {
                streetSurfaces = [NavSurfaceRun(kind: road.hasUnpaved ? .unpaved : .paved, coordinates: prefix)]
            } else {
                streetSurfaces = Self.clip(road.surfaceRuns, to: prefixDistance)
            }
        } else {
            streetSurfaces = []
        }
        // A* starts/ends at raster-cell centers, while city routing and user pins use exact
        // coordinates. Preserve the short join geometrically, but tag it explicitly as an
        // approximate grid snap so the renderer cannot color it as paved or as a verified trail.
        let gridSnap: [NavSurfaceRun]
        if let gridJoin, let first = routePoints.first,
           Vehicle.distanceMeters(gridJoin, first) > 5 {
            gridSnap = [NavSurfaceRun(kind: .gridSnap, coordinates: [gridJoin, first])]
        } else {
            gridSnap = []
        }
        let desertSurfaces = Self.surfaceRuns(routePoints, grid: grid)
        return NavRoute(id: "\(idPrefix)-desert-\(option.mode.rawValue)", coordinates: coordinates,
                        distanceM: total, durationS: duration, steps: steps,
                        hasUnpaved: true, via: "درب بري محسوب (تضاريس وطرق OSM)", timingProfile: timingProfile,
                        surfaceRuns: streetSurfaces + gridSnap + desertSurfaces,
                        roadEnd: prefix.count >= 2 ? ReturnRoute.pavedEnd(streetSurfaces, fallback: prefix.last) : nil)
    }

    private static func surfaceRuns(_ points: [LngLat], grid: DesertGrid) -> [NavSurfaceRun] {
        guard points.count >= 2 else { return [] }
        var runs: [NavSurfaceRun] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let mid = LngLat(lng: (a.lng + b.lng) / 2, lat: (a.lat + b.lat) / 2)
            let flags = grid.cell[grid.index(mid)] & 0xF0
            let kind: NavSurfaceKind = flags & DesertGrid.road != 0 ? .paved
                : flags & DesertGrid.track != 0 ? .unpaved : .terrain
            if runs.last?.kind == kind {
                runs[runs.count - 1].coordinates.append(b)
            } else {
                runs.append(NavSurfaceRun(kind: kind, coordinates: [a, b]))
            }
        }
        return runs
    }

    private static func clip(_ runs: [NavSurfaceRun], to distance: Double) -> [NavSurfaceRun] {
        guard distance > 0 else { return [] }
        var remaining = distance
        var out: [NavSurfaceRun] = []
        for run in runs where run.coordinates.count >= 2 && remaining > 0 {
            var coordinates = [run.coordinates[0]]
            for (a, b) in zip(run.coordinates, run.coordinates.dropFirst()) {
                let segment = Vehicle.distanceMeters(a, b)
                guard segment > 0 else { continue }
                if segment <= remaining {
                    coordinates.append(b)
                    remaining -= segment
                } else {
                    let f = remaining / segment
                    coordinates.append(LngLat(lng: a.lng + (b.lng - a.lng) * f,
                                              lat: a.lat + (b.lat - a.lat) * f))
                    remaining = 0
                    break
                }
            }
            if coordinates.count >= 2 { out.append(NavSurfaceRun(kind: run.kind, coordinates: coordinates)) }
        }
        return out
    }

    /// Estimates the traversed street prefix from the street router's actual ETA. Use its
    /// maneuver legs when available (including traffic weighting); fall back to proportional
    /// distance only for providers that do not return step timings.
    private static func durationAlongRoad(_ route: NavRoute, distanceM: Double) -> Double {
        guard route.distanceM > 0, route.durationS > 0 else { return 0 }
        let fraction = min(1, max(0, distanceM / route.distanceM))
        let steps = route.steps.filter { $0.distanceM > 0 && $0.durationS > 0 }
        let stepDistance = steps.reduce(0) { $0 + $1.distanceM }
        let stepDuration = steps.reduce(0) { $0 + $1.durationS }
        guard stepDistance > 0, stepDuration > 0 else { return route.durationS * fraction }

        var distanceLeft = stepDistance * fraction
        var estimate = 0.0
        for step in steps where distanceLeft > 0 {
            let used = min(step.distanceM, distanceLeft)
            estimate += step.durationS * used / step.distanceM
            distanceLeft -= used
        }
        return estimate * (route.durationS / stepDuration)
    }

    private func roadDistance(_ points: [LngLat]) -> Double { cumulativeMeters(points).last ?? 0 }

    private func cumulativeMeters(_ points: [LngLat]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var distances = [0.0]
        distances.reserveCapacity(points.count)
        for pair in zip(points, points.dropFirst()) {
            distances.append(distances.last! + Vehicle.distanceMeters(pair.0, pair.1))
        }
        return distances
    }

    private func desertSteps(_ points: [LngLat], cumulative: [Double], targetName: String) -> [NavStep] {
        guard points.count >= 2 else { return [] }
        var steps = [NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "الدرب المحسوب", location: points[0], distanceM: 0, durationS: 0)]
        var lastCue = 0
        var lastBearing = bearing(points[0], points[1])
        for i in 1..<(points.count - 1) {
            let nextBearing = bearing(points[i], points[i + 1])
            let delta = signedAngle(nextBearing - lastBearing)
            let sinceCue = cumulative[i] - cumulative[lastCue]
            if abs(delta) >= 38, sinceCue >= 250 {
                let direction: NavTurnDirection = delta > 0 ? .right : .left
                steps.append(NavStep(maneuver: .init(kind: .turn, direction: direction), roadName: "الدرب المحسوب",
                                     location: points[i], distanceM: sinceCue, durationS: sinceCue / 8.0))
                lastCue = i
            }
            lastBearing = nextBearing
        }
        let remaining = max(0, (cumulative.last ?? 0) - cumulative[lastCue])
        steps.append(NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: targetName,
                             location: points.last!, distanceM: 0, durationS: 0))
        if steps.count > 1 { steps[steps.count - 1].distanceM = remaining }
        return steps
    }

    private func bearing(_ a: LngLat, _ b: LngLat) -> Double {
        Vehicle.bearing(a, b)
    }

    private func signedAngle(_ d: Double) -> Double {
        var a = d.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }
}



/// Carries a value the compiler cannot prove `Sendable` (a provider, a plan with its native
/// SDK object) into or out of a child task. Each value goes to exactly one task.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Provider-neutral request parameters, from the options sheet.
/// Mapbox: `profile`, `exclude`, `language`, `voice_units`; Valhalla: costing + `exclude_unpaved` / `use_tolls`.
struct NavRouteSpec: Equatable {
    enum Profile: String { case drivingTraffic = "driving-traffic", driving }
    var profile: Profile
    /// Road classes to exclude: "toll", "unpaved".
    var exclude: [String]
    var alternatives: Bool
    var language: String
    var metric: Bool

    static func from(_ o: NavRouteOptions) -> NavRouteSpec {
        var ex: [String] = []
        if o.avoidTolls { ex.append("toll") }
        if o.avoidUnpaved { ex.append("unpaved") }
        /* «أسرع» uses live traffic; off we still ask for alternatives and keep the shortest. */
        return NavRouteSpec(profile: o.fastest ? .drivingTraffic : .driving, exclude: ex, alternatives: true, language: "ar", metric: true)
    }
}

enum NavRouteChoice {
    /// Best first: «أسرع» by time, otherwise by distance. Ties keep the router's order.
    static func order(_ routes: [NavRoute], options: NavRouteOptions) -> [NavRoute] {
        let indexed = routes.enumerated().map { ($0.offset, $0.element) }
        let key: (NavRoute) -> Double = options.fastest ? { $0.durationS } : { $0.distanceM }
        return indexed.sorted { a, b in
            let ka = key(a.1), kb = key(b.1)
            return ka == kb ? a.0 < b.0 : ka < kb
        }.map(\.1)
    }

    /// «أبطأ ٤ د» / «أقصر ٢٫١ كم» against the best route (words, not +/− signs: those flip in RTL).
    static func delta(_ r: NavRoute, best: NavRoute) -> String {
        let dm = Int(((r.durationS - best.durationS) / 60).rounded())
        if dm != 0 { return (dm > 0 ? "أبطأ " : "أسرع ") + SaryFormat.number(abs(dm)) + " د" }
        let dd = r.distanceM - best.distanceM
        if abs(dd) < 50 { return "نفس الوقت" }
        return (dd > 0 ? "أطول " : "أقصر ") + SaryFormat.distance(meters: abs(dd))
    }
}
