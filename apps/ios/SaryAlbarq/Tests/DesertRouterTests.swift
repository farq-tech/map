import XCTest
@testable import SaryAlbarq

/// «مخطط دروب البر»: the cost rules and A* (mirrors scripts/camp-sites/tests/test_routes.py).
final class DesertRouterTests: XCTestCase {
    private func set(_ g: inout DesertGrid, rows: Range<Int>, cols: Range<Int>, _ ground: DesertGrid.Ground, flags: UInt8 = 0) {
        for r in rows { for c in cols { g.cell[r * g.cols + c] = ground.rawValue | flags } }
    }

    private func cells(_ g: DesertGrid, _ path: [Int]) -> [DesertGrid.Ground] { path.map(g.ground) }

    func testEasyGoesAroundSabkhaShortCutsThroughAndFlagsIt() {
        var g = DesertGrid(rows: 30, cols: 30)
        set(&g, rows: 5..<25, cols: 12..<18, .sabkha)
        let a = 15 * 30 + 2, b = 15 * 30 + 27
        let easy = DesertRouter.route(g, from: a, to: b, mode: .easy, rain: false)!
        XCTAssertFalse(cells(g, easy).contains(.sabkha))
        let short = DesertRouter.route(g, from: a, to: b, mode: .short, rain: false)!
        XCTAssertTrue(cells(g, short).contains(.sabkha))
        let s = DesertRouter.summarize(g, short, mode: .short, rain: false)
        XCTAssertTrue(s.hard.contains { $0.reason == .sabkha })
        XCTAssertEqual(s.tip, DesertHard.sabkha.tip)
    }

    func testPrefersATrack() {
        var g = DesertGrid(rows: 30, cols: 30, ground: .sand)
        set(&g, rows: 2..<3, cols: 0..<30, .sand, flags: DesertGrid.track)
        set(&g, rows: 2..<16, cols: 1..<2, .sand, flags: DesertGrid.track)
        set(&g, rows: 2..<16, cols: 28..<29, .sand, flags: DesertGrid.track)
        let a = 15 * 30 + 1, b = 15 * 30 + 28
        let easy = DesertRouter.summarize(g, DesertRouter.route(g, from: a, to: b, mode: .easy, rain: false)!, mode: .easy, rain: false)
        XCTAssertGreaterThan(easy.trackPercent, 80)
        let short = DesertRouter.summarize(g, DesertRouter.route(g, from: a, to: b, mode: .short, rain: false)!, mode: .short, rain: false)
        XCTAssertLessThan(short.distanceM, easy.distanceM)
        XCTAssertLessThan(easy.minutes, short.minutes, "the track is quicker")
    }

    func testNeverAlongABigWadiWhenRainIsForecast() {
        var g = DesertGrid(rows: 30, cols: 30)
        set(&g, rows: 0..<30, cols: 10..<20, .wadi, flags: DesertGrid.bigWadi)
        let a = 2 * 30 + 15, b = 27 * 30 + 15
        let dry = DesertRouter.route(g, from: a, to: b, mode: .short, rain: false)
        XCTAssertNotNil(dry, "dry: along the bed")
        let wet = DesertRouter.route(g, from: a, to: b, mode: .short, rain: true)
        XCTAssertTrue(wet == nil || !wet!.dropFirst().contains { g.cell[$0] & DesertGrid.bigWadi != 0 })
        /* With a ford at the top, the wet route goes around and never enters the bed. */
        set(&g, rows: 0..<3, cols: 0..<30, .firm)
        let around = DesertRouter.route(g, from: 25 * 30 + 2, to: 25 * 30 + 27, mode: .easy, rain: true)!
        XCTAssertFalse(around.contains { g.cell[$0] & DesertGrid.bigWadi != 0 })
    }

    func testAgainstTheGrainCostsMore() {
        let along = DesertRouter.effort(ground: .sand, flags: 0, ridge: 90, bearing: 90, grade: 0, rain: false)
        let across = DesertRouter.effort(ground: .sand, flags: 0, ridge: 90, bearing: 0, grade: 0, rain: false)
        XCTAssertGreaterThan(across.0!, along.0! * 2)
        XCTAssertEqual(across.1, .against)
        XCTAssertEqual(DesertHard.against.text, "طعس عكس العرق")
    }

    func testSteepDescentRefusedAndFlagged() {
        XCTAssertNil(DesertRouter.effort(ground: .firm, flags: 0, ridge: 255, bearing: 0, grade: -0.4, rain: false).0)
        let r = DesertRouter.effort(ground: .firm, flags: 0, ridge: 255, bearing: 0, grade: -0.2, rain: false)
        XCTAssertNotNil(r.0)
        XCTAssertEqual(r.1, .down)
        XCTAssertEqual(DesertHard.down.text, "نزلة قوية")
    }

    func testForbiddenNeverCrossed() {
        var g = DesertGrid(rows: 20, cols: 20)
        set(&g, rows: 0..<20, cols: 10..<11, .forbidden)
        XCTAssertNil(DesertRouter.route(g, from: 5 * 20 + 2, to: 5 * 20 + 17, mode: .short, rain: false))
    }

    func testBundledGridsLoadAndRouteInTheNafud() throws {
        for r in CampSiteCatalog.regions {
            let g = try XCTUnwrap(DesertGrid.bundled(r), r)
            XCTAssertEqual(g.cell.count, g.rows * g.cols)
        }
        /* The illustration's example (docs: ~/code/map-wt/camp-shots/routes-nafud.png). */
        let g = try XCTUnwrap(DesertGrid.bundled("nafud"))
        let opts = DesertRouter.options(g, from: LngLat(lng: 41.61792, lat: 28.45125), to: LngLat(lng: 41.55861, lat: 28.54917), rain: false)
        XCTAssertEqual(Set(opts.map(\.mode)), Set(DesertRouter.Mode.allCases))
        let easy = try XCTUnwrap(opts.first { $0.mode == .easy }), short = try XCTUnwrap(opts.first { $0.mode == .short })
        XCTAssertGreaterThan(easy.trackPercent, short.trackPercent)
        XCTAssertLessThan(short.distanceM, easy.distanceM)
        XCTAssertGreaterThan(short.hard.count, easy.hard.count)
        XCTAssertEqual(DesertGrid.covering(LngLat(lng: 41.6, lat: 28.4), LngLat(lng: 41.5, lat: 28.5)), "nafud")
        XCTAssertNil(DesertGrid.covering(LngLat(lng: 46.67, lat: 24.71), LngLat(lng: 41.5, lat: 28.5)))
    }

    func testHeap() {
        var h = MinHeap()
        for v in [5, 1, 4, 2, 3] { h.push(Double(v), v) }
        var out: [Int] = []
        while let top = h.pop() { out.append(top.1) }
        XCTAssertEqual(out, [1, 2, 3, 4, 5])
    }

    func testDesertAwareProviderConnectsCityRoadToMappedTrackAndGridRoute() async throws {
        var grid = DesertGrid(rows: 60, cols: 60)
        set(&grid, rows: 18..<42, cols: 30..<31, .firm, flags: DesertGrid.track)
        let target = grid.point(42 * grid.cols + 30)
        let origin = LngLat(lng: 45.9, lat: 24.7) // City side, outside the pilot raster.
        let base = TestDesertRoadProvider { request in
            if request.target.name != "مدخل درب البر" { throw NavRoutingError.noRoute }
            let roadEnd = request.target.position
            return NavRoutePlan(routes: [NavRoute(id: "street", coordinates: [origin, roadEnd],
                                                   distanceM: Vehicle.distanceMeters(origin, roadEnd),
                                                   durationS: 600, steps: [], via: "street network")])
        }
        let provider = DesertAwareRouteProvider(base: base, gridForRegion: { _ in grid },
                                                regionForPoint: { _ in "test" }, rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "destination", position: target),
                                      options: NavRouteOptions())

        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertEqual(route.start, origin)
        XCTAssertTrue(route.hasUnpaved)
        XCTAssertTrue(route.via?.contains("درب بري محسوب") == true)
        XCTAssertGreaterThanOrEqual(route.coordinates.count, 3)
        XCTAssertLessThanOrEqual(Vehicle.distanceMeters(route.end!, target), 130)
        XCTAssertGreaterThanOrEqual(base.requestedAccessPoints, 1)
    }

    func testDesertAwareProviderKeepsHybridRouteWhenStreetRouterSnapsNearEntry() async throws {
        var grid = DesertGrid(rows: 60, cols: 60)
        set(&grid, rows: 18..<42, cols: 30..<31, .firm, flags: DesertGrid.track)
        let target = grid.point(42 * grid.cols + 30)
        let origin = LngLat(lng: 45.9, lat: 24.7)
        let base = TestDesertRoadProvider { request in
            guard request.target.name == "مدخل درب البر" else { throw NavRoutingError.noRoute }
            let access = request.target.position
            let snappedEnd = LngLat(lng: access.lng + 0.002, lat: access.lat)
            return NavRoutePlan(routes: [NavRoute(id: "street-snapped", coordinates: [origin, snappedEnd],
                                                   distanceM: Vehicle.distanceMeters(origin, snappedEnd),
                                                   durationS: 600, steps: [])])
        }
        let provider = DesertAwareRouteProvider(base: base, gridForRegion: { _ in grid },
                                                regionForPoint: { _ in "test" }, rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "نقطة برية", position: target),
                                      options: NavRouteOptions())

        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertTrue(route.via?.contains("درب بري محسوب") == true,
                      "a nearby router snap must not degrade to a street-only route")
        XCTAssertTrue(route.surfaceRuns.contains { $0.kind == .paved })
        XCTAssertTrue(route.surfaceRuns.contains { $0.kind == .unpaved || $0.kind == .terrain })
    }

    func testDesertAwareProviderPreservesStreetRouteIfGridCannotComplete() async throws {
        var grid = DesertGrid(rows: 30, cols: 30)
        set(&grid, rows: 10..<20, cols: 4..<5, .sand, flags: DesertGrid.track)
        set(&grid, rows: 0..<30, cols: 15..<16, .forbidden)
        let target = grid.point(15 * grid.cols + 20)
        let origin = LngLat(lng: 46.0, lat: 24.8)
        let base = TestDesertRoadProvider { request in
            if request.target.name != "مدخل درب البر" { throw NavRoutingError.noRoute }
            return NavRoutePlan(routes: [NavRoute(id: "street", coordinates: [origin, request.target.position],
                                                   distanceM: 5_000, durationS: 600, steps: [])])
        }
        let provider = DesertAwareRouteProvider(base: base, gridForRegion: { _ in grid },
                                                regionForPoint: { _ in "test" }, rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "destination", position: target),
                                      options: NavRouteOptions())

        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertEqual(route.id, "street")
        XCTAssertEqual(route.start, origin)
        let end = try XCTUnwrap(route.end)
        XCTAssertNotEqual(grid.cell[grid.index(end)] & (DesertGrid.track | DesertGrid.road), 0)
    }

    func testDesertRouterDoesNotClampOutsidePointsToRasterEdge() {
        let grid = DesertGrid(rows: 10, cols: 10)
        let outside = LngLat(lng: 47, lat: 26)
        XCTAssertTrue(DesertRouter.options(grid, from: outside, to: grid.point(55), rain: false).isEmpty)
    }

    @MainActor func testProvidedThumamahPinGetsStreetPrefixAndRasterRoute() async throws {
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Resources/CampSites/routes-thumamah.bin").standardizedFileURL
        let grid = try XCTUnwrap(DesertGrid.load(try Data(contentsOf: resource)))
        let target = LngLat(lng: 46.53676, lat: 25.26679)
        let origin = LngLat(lng: 46.50, lat: 24.90)
        let base = TestDesertRoadProvider { request in
            if request.target.name != "مدخل درب البر" { throw NavRoutingError.noRoute }
            let entry = request.target.position
            let streetDistance = Vehicle.distanceMeters(origin, entry)
            return NavRoutePlan(routes: [NavRoute(id: "street", coordinates: [origin, entry],
                                                   distanceM: streetDistance,
                                                   durationS: 1_200,
                                                   steps: [
                                                    NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق المدينة",
                                                            location: origin, distanceM: streetDistance, durationS: 1_200),
                                                    NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: "مدخل البر",
                                                            location: entry, distanceM: 0, durationS: 0)
                                                   ], via: "street network")])
        }
        let provider = DesertAwareRouteProvider(base: base, gridForRegion: { _ in grid },
                                                regionForPoint: { DesertAwareRouteProvider.regionName(containing: $0) },
                                                rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "نقطة على الخريطة", position: target),
                                      options: NavRouteOptions())

        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertEqual(route.start, origin)
        XCTAssertTrue(route.hasUnpaved)
        XCTAssertTrue(route.via?.contains("درب بري محسوب") == true)
        XCTAssertGreaterThanOrEqual(base.requestedAccessPoints, 1)
        XCTAssertLessThanOrEqual(Vehicle.distanceMeters(route.end!, target), 130)
        XCTAssertGreaterThan(route.distanceM, Vehicle.distanceMeters(origin, target))
        XCTAssertEqual(route.steps.first?.roadName, "طريق المدينة",
                       "hybrid guidance must preserve real street instructions before the desert leg")
        XCTAssertEqual(route.steps.last?.maneuver.kind, .arrive,
                       "the hybrid route must end with its desert destination arrival")

        let options = DesertRouter.options(grid, from: try XCTUnwrap(base.lastAccessPoint), to: target, rain: false)
        let desertOption = try XCTUnwrap(options.first { route.id.hasSuffix($0.mode.rawValue) })
        XCTAssertEqual(route.durationS, 1_200 + desertOption.minutes * 60, accuracy: 1,
                       "hybrid ETA must add the street provider ETA to the modeled desert ETA")
        let timing = try XCTUnwrap(route.timingProfile)
        XCTAssertEqual(timing.first?.durationS ?? 0, 1_200, accuracy: 1,
                       "the approach uses the street provider's real ETA, not distance / 8 m/s")
        let halfwayThroughStreets = timing[0].distanceM / 2
        let progress = LocalGuidanceEngine.progress(route: route, stepAlong: [], total: route.distanceM, at: halfwayThroughStreets)
        XCTAssertEqual(progress.durationRemainingS, 600 + desertOption.minutes * 60, accuracy: 1,
                       "remaining ETA keeps the full desert time while half the street leg remains")
    }

    @MainActor func testUserReportedThumamahPointCanBeReachedFromBundledMappedAccess() throws {
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Resources/CampSites/routes-thumamah.bin").standardizedFileURL
        let grid = try XCTUnwrap(DesertGrid.load(try Data(contentsOf: resource)))
        let target = LngLat(lng: 46.62866, lat: 25.15844)
        let access = try XCTUnwrap(grid.accessPoints(near: target).first)

        let options = DesertRouter.options(grid, from: access, to: target, rain: false)

        XCTAssertFalse(options.isEmpty, "the measured grid contains a costed route from a mapped road to this pin")
    }

    @MainActor func testRecordedMapboxSnapEndpointsConnectToBothReportedThumamahPins() throws {
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Resources/CampSites/routes-thumamah.bin").standardizedFileURL
        let grid = try XCTUnwrap(DesertGrid.load(try Data(contentsOf: resource)))
        // Recorded endpoints from a Mapbox Directions request on 2026-11-10. This test
        // deliberately validates only the bundled grid continuation; it makes no live
        // Mapbox request and does not prove a live end-to-end route.
        let cases: [(name: String, roadEnd: LngLat, target: LngLat)] = [
            ("25.26679,46.53676",
             LngLat(lng: 46.55734, lat: 25.27551),
             LngLat(lng: 46.53676, lat: 25.26679)),
            ("25.15844,46.62866",
             LngLat(lng: 46.636295, lat: 25.165019),
             LngLat(lng: 46.62866, lat: 25.15844))
        ]

        for item in cases {
            let options = DesertRouter.options(grid, from: item.roadEnd, to: item.target, rain: false)
            let route = try XCTUnwrap(options.first, "the bundled desert grid must connect the recorded snapped road endpoint to \(item.name)")
            XCTAssertGreaterThan(route.distanceM, 0)
            XCTAssertGreaterThanOrEqual(route.points.count, 2)
            XCTAssertLessThanOrEqual(Vehicle.distanceMeters(route.points.last!, item.target), max(130, hypot(grid.dx, grid.dy) * 1.5))
        }
    }
}

private final class TestDesertRoadProvider: NavRoutingProvider {
    var name = "test streets"
    var requestedAccessPoints = 0
    var lastAccessPoint: LngLat?
    let handler: (NavRouteRequest) async throws -> NavRoutePlan

    init(handler: @escaping (NavRouteRequest) async throws -> NavRoutePlan) { self.handler = handler }

    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan {
        if request.target.name == "مدخل درب البر" {
            requestedAccessPoints += 1
            lastAccessPoint = request.target.position
        }
        return try await handler(request)
    }
}
