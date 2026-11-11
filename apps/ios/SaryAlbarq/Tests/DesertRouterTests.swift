import UIKit
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

    func testDiagonalCannotCutBetweenForbiddenCells() {
        var g = DesertGrid(rows: 3, cols: 3)
        set(&g, rows: 0..<1, cols: 1..<2, .forbidden)
        set(&g, rows: 1..<2, cols: 0..<1, .forbidden)
        XCTAssertNil(DesertRouter.route(g, from: 4, to: 0, mode: .short, rain: false))
    }

    func testForbiddenDestinationIsRejectedButBlockedStreetSnapCanExit() {
        var g = DesertGrid(rows: 4, cols: 4)
        set(&g, rows: 1..<2, cols: 1..<2, .forbidden)
        let escape = try! XCTUnwrap(DesertRouter.route(g, from: 5, to: 15, mode: .short, rain: false),
                                    "a street-router snap may land in a coarse blocked cell; allow exiting it")
        XCTAssertFalse(escape.dropFirst().contains { g.ground($0) == .forbidden },
                       "only the initial snapped cell may be exited; the route must not re-enter blocked cells")
        XCTAssertNil(DesertRouter.route(g, from: 0, to: 5, mode: .short, rain: false))
        XCTAssertNil(DesertRouter.route(g, from: -1, to: 15, mode: .short, rain: false))
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

    func testGroundEffortSwitchMatchesTheTable() {
        for g in [DesertGrid.Ground.firm, .sand, .crest, .sabkha, .wadi, .forbidden, .rock] {
            XCTAssertEqual(DesertRouter.groundEffortValue(g), DesertRouter.groundEffort[g] ?? 1, "\(g)")
        }
    }

    /// Perf pass: the A* keeps the orthogonal results for the diagonal corner test and reads the
    /// ground effort without a dictionary. Every path must be exactly the old router's.
    func testOptimisedAStarFindsExactlyTheOldPaths() {
        var g = DesertGrid(rows: 48, cols: 52, ground: .sand)
        /* Deterministic mixed terrain: every ground, tracks, roads, big wadis, ridges, slopes. */
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
        let grounds: [DesertGrid.Ground] = [.firm, .sand, .sand, .crest, .sabkha, .wadi, .rock, .forbidden, .firm, .sand]
        for i in 0..<(g.rows * g.cols) {
            let v = next()
            var cell = grounds[Int(v % UInt64(grounds.count))].rawValue
            if v % 17 == 0 { cell = DesertGrid.Ground.sand.rawValue | DesertGrid.track }
            if v % 41 == 0 { cell = DesertGrid.Ground.firm.rawValue | DesertGrid.road }
            if v % 23 == 0 { cell = DesertGrid.Ground.wadi.rawValue | DesertGrid.bigWadi }
            g.cell[i] = cell
            g.ridge[i] = v % 3 == 0 ? 255 : UInt8((v >> 8) % 180)
            g.elev[i] = 500 + Float((v >> 16) % 40)
        }
        let pairs = [(2 * 52 + 3, 45 * 52 + 48), (40 * 52 + 1, 3 * 52 + 50), (24 * 52 + 0, 24 * 52 + 51), (0, 47 * 52 + 51)]
        var found = 0
        for (a, b) in pairs {
            for mode in DesertRouter.Mode.allCases {
                for rain in [false, true] {
                    let new = DesertRouter.route(g, from: a, to: b, mode: mode, rain: rain)
                    let old = Self.referenceRoute(g, from: a, to: b, mode: mode, rain: rain)
                    XCTAssertEqual(new, old, "\(a)→\(b) \(mode) rain=\(rain)")
                    if new != nil { found += 1 }
                }
            }
        }
        XCTAssertGreaterThan(found, 0, "the terrain must leave some routes to compare")
    }

    /// The A* exactly as it was before the perf pass (dictionary corner lookups, recomputed moves).
    private static func referenceRoute(_ g: DesertGrid, from a: Int, to b: Int, mode: DesertRouter.Mode, rain: Bool) -> [Int]? {
        let n = g.rows * g.cols
        guard a >= 0, a < n, b >= 0, b < n else { return nil }
        func isBlocked(_ i: Int) -> Bool {
            let flags = g.cell[i] & 0xF0
            return g.ground(i) == .forbidden || (rain && flags & DesertGrid.bigWadi != 0 && flags & DesertGrid.road == 0)
        }
        let startsInBlockedCell = isBlocked(a)
        guard !isBlocked(b) else { return nil }
        var best = [Double](repeating: .infinity, count: n)
        var prev = [Int32](repeating: -1, count: n)
        let floor: Double
        switch mode {
        case .short: floor = 1
        case .balanced: floor = min(DesertRouter.trackEffort, DesertRouter.roadEffort).squareRoot()
        case .easy: floor = min(DesertRouter.trackEffort, DesertRouter.roadEffort)
        }
        let br = b / g.cols, bc = b % g.cols
        func h(_ i: Int) -> Double { floor * hypot(Double(i / g.cols - br) * g.dy, Double(i % g.cols - bc) * g.dx) }
        var heap = MinHeap()
        best[a] = 0
        heap.push(h(a), a)
        let nb: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]
        let geo = nb.map { (dr, dc) -> (Int, Int, Double, Double) in
            let d = hypot(Double(dr) * g.dy, Double(dc) * g.dx)
            let bearing = (atan2(Double(dc) * g.dx, Double(-dr) * g.dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            return (dr, dc, d, bearing)
        }
        let geoByDelta = Dictionary(uniqueKeysWithValues: geo.map { ($0.0 * 3 + $0.1, ($0.2, $0.3)) })
        func canMove(from i: Int, to j: Int, distance: Double, bearing: Double) -> Double? {
            let grade = Double(g.elev[j] - g.elev[i]) / distance
            return DesertRouter.effort(ground: g.ground(j), flags: g.cell[j] & 0xF0, ridge: g.ridge[j], bearing: bearing, grade: grade, rain: rain).0
        }
        while let top = heap.pop() {
            let (f, i) = top
            if i == b {
                var path = [b], k = b
                while prev[k] >= 0 { k = Int(prev[k]); path.append(k) }
                return path.reversed()
            }
            let gi = best[i]
            if f - h(i) > gi + 1e-6 { continue }
            let r = i / g.cols, c = i % g.cols
            for (dr, dc, d, bearing) in geo {
                let rr = r + dr, cc = c + dc
                guard rr >= 0, rr < g.rows, cc >= 0, cc < g.cols else { continue }
                let j = rr * g.cols + cc
                if dr != 0 && dc != 0 && !(i == a && startsInBlockedCell) {
                    guard let (hd, hb) = geoByDelta[dc], let (vd, vb) = geoByDelta[dr * 3] else { continue }
                    let hp = canMove(from: i, to: r * g.cols + cc, distance: hd, bearing: hb) != nil
                    let vp = canMove(from: i, to: rr * g.cols + c, distance: vd, bearing: vb) != nil
                    guard hp || vp else { continue }
                }
                guard let e = canMove(from: i, to: j, distance: d, bearing: bearing) else { continue }
                let ng = gi + DesertRouter.stepCost(mode, effort: e, dist: d)
                if ng < best[j] {
                    best[j] = ng
                    prev[j] = Int32(i)
                    heap.push(ng + h(j), j)
                }
            }
        }
        return nil
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
        let requestedAccessPoints = await base.requestedAccessPoints
        XCTAssertGreaterThanOrEqual(requestedAccessPoints, 1)
        /* «طريق الرجعة» keeps where the street part ended (the city ↔ desert junction). */
        XCTAssertEqual(route.roadEnd, route.coordinates[1])
        XCTAssertEqual(ReturnRoute.roadEnd(of: route), route.coordinates[1])
    }

    func testDesertAwareProviderKeepsHybridRouteWhenStreetRouterSnapsNearEntry() async throws {
        var grid = DesertGrid(rows: 60, cols: 60)
        set(&grid, rows: 18..<42, cols: 30..<31, .firm, flags: DesertGrid.track)
        let target = grid.point(42 * grid.cols + 30)
        let origin = LngLat(lng: 45.9, lat: 24.7)
        let base = TestDesertRoadProvider { request in
            guard request.target.name == "مدخل درب البر" else { throw NavRoutingError.noRoute }
            let access = request.target.position
            let streetEnd = LngLat(lng: access.lng + 0.002, lat: access.lat)
            return NavRoutePlan(routes: [NavRoute(id: "street-snapped", coordinates: [origin, streetEnd],
                                                   distanceM: Vehicle.distanceMeters(origin, streetEnd),
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
        XCTAssertTrue(route.surfaceRuns.contains { $0.kind == .unpaved || $0.kind == .terrain || $0.kind == .rough })
        let snap = try XCTUnwrap(route.surfaceRuns.first { $0.kind == .gridSnap },
                                 "the unsourced road-to-grid connector must be identified as an approximate snap")
        let pavedEnd = try XCTUnwrap(route.surfaceRuns.last(where: { $0.kind == .paved })?.coordinates.last,
                                     "the road-to-grid connector must start at the end of the actual street prefix")
        XCTAssertEqual(snap.coordinates.first, pavedEnd)
        XCTAssertLessThanOrEqual(Vehicle.distanceMeters(try XCTUnwrap(snap.coordinates.first),
                                                        try XCTUnwrap(snap.coordinates.last)),
                                  max(60, hypot(grid.dx, grid.dy) * 0.75))
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

    func testMappedAccessRequestsRunTogetherAndKeepPreferenceOrder() async throws {
        // Two parallel tracks: both connect, so the result must come from the nearest access
        // (first in preference order), whichever street answer arrives first.
        var grid = DesertGrid(rows: 60, cols: 60)
        set(&grid, rows: 18..<42, cols: 30..<31, .firm, flags: DesertGrid.track)
        set(&grid, rows: 18..<42, cols: 40..<41, .firm, flags: DesertGrid.track)
        let target = grid.point(42 * grid.cols + 30)
        let origin = LngLat(lng: 45.9, lat: 24.7)
        let preferred = try XCTUnwrap(grid.accessPoints(near: target).first)
        let base = ConcurrencyProbeProvider { request in
            guard request.target.name == "مدخل درب البر" else { throw NavRoutingError.noRoute }
            let end = request.target.position
            return NavRoutePlan(routes: [NavRoute(id: "street", coordinates: [origin, end],
                                                   distanceM: Vehicle.distanceMeters(origin, end),
                                                   durationS: 600, steps: [])])
        }
        let provider = DesertAwareRouteProvider(base: base, gridForRegion: { _ in grid },
                                                regionForPoint: { _ in "test" }, rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "destination", position: target),
                                      options: NavRouteOptions())

        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertTrue(route.via?.contains("درب بري محسوب") == true)
        // The street leg is [origin, access] and the origin is outside the raster, so the second
        // coordinate is the access the hybrid route was built from.
        XCTAssertEqual(route.coordinates.dropFirst().first, preferred, "the nearest connecting access wins")
        let peakConcurrent = await base.peakConcurrent
        XCTAssertGreaterThan(peakConcurrent, 1, "the street requests overlap instead of running one by one")
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
        let requestedAccessPoints = await base.requestedAccessPoints
        XCTAssertGreaterThanOrEqual(requestedAccessPoints, 1)
        XCTAssertLessThanOrEqual(Vehicle.distanceMeters(route.end!, target), 130)
        XCTAssertGreaterThan(route.distanceM, Vehicle.distanceMeters(origin, target))
        XCTAssertEqual(route.steps.first?.roadName, "طريق المدينة",
                       "hybrid guidance must preserve real street instructions before the desert leg")
        XCTAssertEqual(route.steps.last?.maneuver.kind, .arrive,
                       "the hybrid route must end with its desert destination arrival")

        // The access requests run in parallel, so "the last one asked" is not the one used. The
        // street leg is [origin, entry] with the origin outside the raster: the second coordinate
        // is the access the hybrid route was built from.
        let joined = try XCTUnwrap(route.coordinates.dropFirst().first)
        let requestedAccess = await base.requestedAccess
        let usedAccess = try XCTUnwrap(requestedAccess.first { $0 == joined })
        let options = DesertRouter.options(grid, from: usedAccess, to: target, rain: false)
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

    @MainActor func testSecondReportedThumamahPinGetsCityToDesertHybridRoute() async throws {
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Resources/CampSites/routes-thumamah.bin").standardizedFileURL
        let grid = try XCTUnwrap(DesertGrid.load(try Data(contentsOf: resource)))
        let origin = LngLat(lng: 46.6744, lat: 24.7113)
        let target = LngLat(lng: 46.62866, lat: 25.15844)
        let base = TestDesertRoadProvider { request in
            guard request.target.name == "مدخل درب البر" else { throw NavRoutingError.noRoute }
            let access = request.target.position
            let distance = Vehicle.distanceMeters(origin, access)
            return NavRoutePlan(routes: [NavRoute(id: "recorded-street-approach", coordinates: [origin, access],
                                                   distanceM: distance, durationS: 1_200, steps: [], via: "street network")])
        }
        let provider = DesertAwareRouteProvider(base: base, gridForRegion: { _ in grid },
                                                regionForPoint: { DesertAwareRouteProvider.regionName(containing: $0) },
                                                rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "نقطة الثمامة الثانية", position: target),
                                      options: NavRouteOptions())

        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first, "the second reported pin must continue from a routed street into the grid")
        XCTAssertEqual(route.start, origin)
        XCTAssertGreaterThan(route.distanceM, Vehicle.distanceMeters(origin, target))
        XCTAssertLessThanOrEqual(Vehicle.distanceMeters(route.end!, target), max(130, hypot(grid.dx, grid.dy) * 1.5))
        XCTAssertTrue(route.surfaceRuns.contains { $0.kind == .paved }, "preserve the city-road approach")
        XCTAssertTrue(route.surfaceRuns.contains { $0.kind == .terrain || $0.kind == .rough || $0.kind == .unpaved }, "continue over a classified desert surface")
        XCTAssertGreaterThanOrEqual(route.timingProfile?.count ?? 0, 2, "keep separate road and off-road ETA legs")
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

/// National tiles: names, corridor boxes, stitching, the tile store and the provider wiring
/// (mirrors scripts/camp-sites/tests/test_tiles.py for the tile math).
final class DesertTilesTests: XCTestCase {
    private let cell = 1.0 / 1200  // one 3″ lattice step

    // MARK: tile math

    func testTileNamesAreTheSouthWestCorner() {
        XCTAssertEqual(DesertTiles.TileID("t25_46"), DesertTiles.TileID(lat: 25, lng: 46))
        XCTAssertEqual(DesertTiles.TileID(lat: 16, lng: 42).name, "t16_42")
        for bad in ["thumamah", "t25", "t25_46_1", "t_46", "t25_", "t+5_46", "t25_46.bin", "T25_46", "t2500_46"] {
            XCTAssertNil(DesertTiles.TileID(bad), bad)
        }
        XCTAssertEqual(DesertTiles.tile(containing: LngLat(lng: 46.7, lat: 25.3)).name, "t25_46")
        XCTAssertEqual(DesertTiles.tile(containing: LngLat(lng: 46.0, lat: 25.0)).name, "t25_46")
        XCTAssertEqual(DesertTiles.tile(containing: LngLat(lng: 45.999, lat: 24.999)).name, "t24_45")
        XCTAssertEqual(DesertTiles.TileID(lat: 25, lng: 46).bbox, DesertGrid.BBox(s: 25, w: 46, n: 26, e: 47))
    }

    func testTilesCoveringABox() {
        XCTAssertEqual(DesertTiles.tiles(covering: DesertGrid.BBox(s: 25.2, w: 46.3, n: 25.8, e: 46.9)).map(\.name), ["t25_46"])
        // An edge on a whole degree does not pull in the neighbour.
        XCTAssertEqual(DesertTiles.tiles(covering: DesertGrid.BBox(s: 25, w: 46, n: 26, e: 47)).map(\.name), ["t25_46"])
        XCTAssertEqual(Set(DesertTiles.tiles(covering: DesertGrid.BBox(s: 24.5, w: 45.5, n: 25.5, e: 46.5)).map(\.name)),
                       ["t24_45", "t24_46", "t25_45", "t25_46"])
        XCTAssertTrue(DesertTiles.tiles(covering: DesertGrid.BBox(s: 25, w: 46, n: 25, e: 47)).isEmpty)
    }

    func testCorridorBoxes() throws {
        let target = LngLat(lng: 46.5, lat: 25.5)
        let alone = try XCTUnwrap(DesertTiles.corridor(from: nil, to: target))
        XCTAssertEqual(alone.n - alone.s, 2 * DesertTiles.aroundTargetDeg, accuracy: 1e-9)
        XCTAssertTrue(alone.contains(target))

        let near = LngLat(lng: 46.9, lat: 25.1)
        let withNear = try XCTUnwrap(DesertTiles.corridor(from: near, to: target))
        XCTAssertTrue(withNear.contains(near) && withNear.contains(target))

        // A far road end: cut to the maximum on its side, the target keeps its margin.
        let far = LngLat(lng: 44.0, lat: 23.0)
        let cut = try XCTUnwrap(DesertTiles.corridor(from: far, to: target))
        XCTAssertEqual(cut.n - cut.s, DesertTiles.maxSpanDeg, accuracy: 1e-9)
        XCTAssertEqual(cut.e - cut.w, DesertTiles.maxSpanDeg, accuracy: 1e-9)
        XCTAssertEqual(cut.n, target.lat + DesertTiles.aroundTargetDeg, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(DesertTiles.tiles(covering: cut).count, 9)

        XCTAssertNil(DesertTiles.corridor(from: nil, to: LngLat(lng: 30, lat: 30)), "outside the Kingdom")
        XCTAssertNotNil(DesertTiles.corridor(spanning: LngLat(lng: 46.0, lat: 25.0), LngLat(lng: 46.8, lat: 25.6)))
        XCTAssertNil(DesertTiles.corridor(spanning: LngLat(lng: 46.0, lat: 25.0), LngLat(lng: 47.5, lat: 25.6)), "too far apart")
    }

    // MARK: stitching

    func testStitchPlacesNeighboursOnTheLatticeAndFillsGapsWithForbidden() throws {
        var a = DesertGrid(rows: 4, cols: 4, ground: .firm, south: 25, west: 46)
        a.elev = (0..<16).map { Float($0) }
        let b = DesertGrid(rows: 4, cols: 4, ground: .sand, south: 25, west: 46 + 4 * cell)
        // One extra column east that nobody covers.
        let box = DesertGrid.BBox(s: 25, w: 46, n: 25 + 4 * cell, e: 46 + 9 * cell)
        let g = try XCTUnwrap(DesertGrid.stitch([a, b], bbox: box))
        XCTAssertEqual(g.rows, 4)
        XCTAssertEqual(g.cols, 9)
        XCTAssertEqual(g.header.south, 25, accuracy: 1e-9)
        XCTAssertEqual(g.header.east, 46 + 9 * cell, accuracy: 1e-9)
        for r in 0..<4 {
            for c in 0..<9 {
                let expected: DesertGrid.Ground = c < 4 ? .firm : c < 8 ? .sand : .forbidden
                XCTAssertEqual(g.ground(r * 9 + c), expected, "r\(r) c\(c)")
            }
            for c in 0..<4 { XCTAssertEqual(g.elev[r * 9 + c], Float(r * 4 + c)) }
        }
        // Same lattice point, same place: a cell centre maps back to its source cell.
        XCTAssertEqual(g.point(2 * 9 + 5).lat, b.point(2 * 4 + 1).lat, accuracy: 1e-9)
        XCTAssertEqual(g.point(2 * 9 + 5).lng, b.point(2 * 4 + 1).lng, accuracy: 1e-9)
    }

    func testStitchCropsAndTheFirstSourceWins() throws {
        let big = DesertGrid(rows: 10, cols: 10, ground: .firm, south: 25, west: 46)
        let crest = DesertGrid(rows: 2, cols: 2, ground: .crest, south: 25 + 4 * cell, west: 46 + 4 * cell)
        // A box inside `big`, not on cell edges: snapped outward to whole cells.
        let box = DesertGrid.BBox(s: 25 + 3.5 * cell, w: 46 + 3.5 * cell, n: 25 + 6.5 * cell, e: 46 + 6.5 * cell)
        let crestFirst = try XCTUnwrap(DesertGrid.stitch([crest, big], bbox: box))
        XCTAssertEqual(crestFirst.rows, 4)
        XCTAssertEqual(crestFirst.cols, 4)
        XCTAssertEqual(crestFirst.cell.filter { $0 == DesertGrid.Ground.crest.rawValue }.count, 4)
        let bigFirst = try XCTUnwrap(DesertGrid.stitch([big, crest], bbox: box))
        XCTAssertFalse(bigFirst.cell.contains(DesertGrid.Ground.crest.rawValue))
    }

    func testStitchRefusesOffLatticeTooBigOrEmpty() {
        let off = DesertGrid(rows: 4, cols: 4, south: 25 + cell / 3, west: 46)
        let box = DesertGrid.BBox(s: 25, w: 46, n: 25 + 4 * cell, e: 46 + 4 * cell)
        XCTAssertNil(DesertGrid.stitch([off], bbox: box), "a source off the lattice is skipped; nothing left")
        XCTAssertNil(DesertGrid.stitch([DesertGrid(rows: 4, cols: 4, south: 25, west: 46)], bbox: box, maxCells: 15))
        XCTAssertNil(DesertGrid.stitch([], bbox: box))
    }

    func testStitchedGridRoutesAcrossTheSeam() throws {
        var left = DesertGrid(rows: 20, cols: 20, ground: .sand, south: 25, west: 46)
        var right = DesertGrid(rows: 20, cols: 20, ground: .sand, south: 25, west: 46 + 20 * cell)
        for c in 0..<20 { left.cell[10 * 20 + c] = DesertGrid.Ground.firm.rawValue | DesertGrid.track }
        for c in 0..<20 { right.cell[10 * 20 + c] = DesertGrid.Ground.firm.rawValue | DesertGrid.track }
        let g = try XCTUnwrap(DesertGrid.stitch([left, right], bbox: DesertGrid.BBox(s: 25, w: 46, n: 25 + 20 * cell, e: 46 + 40 * cell)))
        let opts = DesertRouter.options(g, from: left.point(10 * 20 + 1), to: right.point(10 * 20 + 18), rain: false)
        let easy = try XCTUnwrap(opts.first { $0.mode == .easy })
        XCTAssertGreaterThan(easy.trackPercent, 90, "the track continues across the tile edge")
    }

    // MARK: tile store

    /// A real-format tile file (zlib SARYRT1, as routes.py writes it), every cell `ground`.
    private static func tileData(_ id: DesertTiles.TileID, ground: DesertGrid.Ground) -> Data {
        let n = 1200
        let header = "{\"region\":\"\(id.name)\",\"rows\":\(n),\"cols\":\(n),\"south\":\(id.lat),\"west\":\(id.lng)," +
            "\"north\":\(id.lat + 1),\"east\":\(id.lng + 1),\"arcsec\":3,\"z0\":500,\"version\":1}"
        let h = Data(header.utf8)
        var raw = Data("SARYRT1\0".utf8)
        let len = UInt32(h.count)
        raw.append(contentsOf: [UInt8(len & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len >> 16 & 0xFF), UInt8(len >> 24)])
        raw.append(h)
        var cells = [UInt8](repeating: 0, count: n * n * 4)
        for i in stride(from: 0, to: cells.count, by: 4) {
            cells[i] = ground.rawValue
            cells[i + 1] = 255
        }
        raw.append(contentsOf: cells)
        // NSData's .zlib is raw DEFLATE; DesertGrid.load skips a 2-byte header and a 4-byte trailer.
        let deflated = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? Data()
        return Data([0x78, 0xDA]) + deflated + Data([0, 0, 0, 0])
    }

    private static let west = tileData(DesertTiles.TileID(lat: 25, lng: 46), ground: .firm)
    private static let east = tileData(DesertTiles.TileID(lat: 25, lng: 47), ground: .sand)

    private static func manifest(_ tiles: [(String, Data)], sha: (Data) -> String = DesertTileStore.sha256Hex) -> Data {
        let entries = tiles.map { "{\"id\":\"\($0.0)\",\"bytes\":\($0.1.count),\"sha256\":\"\(sha($0.1))\",\"bbox\":[0,0,0,0]}" }
        return Data("{\"format\":\"SARYRT1\",\"version\":\"test\",\"arcsec\":3,\"tiles\":[\(entries.joined(separator: ","))]}".utf8)
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("desert-tiles-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private let base = URL(string: "https://tiles.example/desert/")!
    /// Across the seam between t25_46 and t25_47.
    private let seamBox = DesertGrid.BBox(s: 25.3, w: 46.8, n: 25.5, e: 47.2)

    func testStoreDownloadsVerifiesCachesAndStitches() async throws {
        let server = FakeTileServer(files: ["manifest.json": Self.manifest([("t25_46", Self.west), ("t25_47", Self.east)]),
                                            "tiles/t25_46.bin": Self.west, "tiles/t25_47.bin": Self.east])
        let dir = tempDir()
        let store = DesertTileStore(baseURL: base, cacheDir: dir, fetch: server.fetch, seeds: { _ in [] })
        let first = await store.corridor(seamBox)
        let g = try XCTUnwrap(first)
        XCTAssertEqual(g.rows, 240)
        XCTAssertEqual(g.cols, 480)
        XCTAssertEqual(g.ground(g.index(LngLat(lng: 46.9, lat: 25.4))), .firm)
        XCTAssertEqual(g.ground(g.index(LngLat(lng: 47.1, lat: 25.4))), .sand)
        XCTAssertEqual(server.paths.sorted(), ["manifest.json", "tiles/t25_46.bin", "tiles/t25_47.bin"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("routes-t25_46.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))

        // Again: memory, no request.
        let second = await store.corridor(seamBox)
        XCTAssertNotNil(second)
        XCTAssertEqual(server.paths.count, 3)

        // A new store (next launch) with no network: the disk cache and saved manifest are enough.
        let offline = FakeTileServer(files: [:], offline: true)
        let later = DesertTileStore(baseURL: base, cacheDir: dir, fetch: offline.fetch, seeds: { _ in [] })
        let third = await later.corridor(seamBox)
        let again = try XCTUnwrap(third)
        XCTAssertEqual(again.cell, g.cell)

        // A memory warning drops the decoded tiles.
        XCTAssertFalse(store.memoryTileNames.isEmpty)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertTrue(store.memoryTileNames.isEmpty)
    }

    func testStoreRefusesATileWhoseChecksumDiffers() async {
        let server = FakeTileServer(files: ["manifest.json": Self.manifest([("t25_46", Self.west), ("t25_47", Self.east)], sha: { _ in String(repeating: "0", count: 64) }),
                                            "tiles/t25_46.bin": Self.west, "tiles/t25_47.bin": Self.east])
        let dir = tempDir()
        let store = DesertTileStore(baseURL: base, cacheDir: dir, fetch: server.fetch, seeds: { _ in [] })
        let g = await store.corridor(seamBox)
        XCTAssertNil(g, "an unverified tile is never routed on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("routes-t25_46.bin").path))
    }

    func testTileOutsideTheNationalSetIsForbiddenGround() async throws {
        let server = FakeTileServer(files: ["manifest.json": Self.manifest([("t25_46", Self.west)]), "tiles/t25_46.bin": Self.west])
        let store = DesertTileStore(baseURL: base, cacheDir: tempDir(), fetch: server.fetch, seeds: { _ in [] })
        let fetched = await store.corridor(seamBox)
        let g = try XCTUnwrap(fetched)
        XCTAssertEqual(g.ground(g.index(LngLat(lng: 46.9, lat: 25.4))), .firm)
        XCTAssertEqual(g.ground(g.index(LngLat(lng: 47.1, lat: 25.4))), .forbidden)
        XCTAssertFalse(server.paths.contains("tiles/t25_47.bin"))
    }

    func testStoreWithoutServerOrCacheGivesNothing() async {
        let store = DesertTileStore(baseURL: nil, cacheDir: tempDir(), fetch: FakeTileServer(files: [:]).fetch, seeds: { _ in [] })
        let g = await store.corridor(seamBox)
        XCTAssertNil(g)
        let tooBig = await store.corridor(DesertGrid.BBox(s: 24, w: 45, n: 26, e: 47))
        XCTAssertNil(tooBig)
    }

    func testPilotSeedCoversWithoutAnyDownload() async throws {
        let pilot = DesertGrid(rows: 120, cols: 120, ground: .sand, south: 25.1, west: 46.1)
        let server = FakeTileServer(files: [:])
        let store = DesertTileStore(baseURL: base, cacheDir: tempDir(), fetch: server.fetch, seeds: { _ in [pilot] })
        let box = DesertGrid.BBox(s: 25.12, w: 46.12, n: 25.18, e: 46.18)
        let fetched = await store.corridor(box)
        let g = try XCTUnwrap(fetched)
        XCTAssertTrue(server.paths.isEmpty)
        XCTAssertTrue(g.cell.allSatisfy { $0 == DesertGrid.Ground.sand.rawValue })
    }

    func testConfiguredBaseURLSitsNextToTheTileJSON() {
        // Derivation only (Info.plist may or may not carry FarqTilesURL in the test host).
        let u = URL(string: "https://tiles.example.sa/farq.json")!.deletingLastPathComponent()
            .appendingPathComponent("desert", isDirectory: true).appendingPathComponent("manifest.json")
        XCTAssertEqual(u.absoluteString, "https://tiles.example.sa/desert/manifest.json")
    }

    // MARK: provider

    func testProviderUsesTileCorridorOutsideThePilots() async throws {
        var grid = DesertGrid(rows: 60, cols: 60)
        for r in 18..<42 { grid.cell[r * 60 + 30] = DesertGrid.Ground.firm.rawValue | DesertGrid.track }
        let target = grid.point(42 * grid.cols + 30)
        let origin = LngLat(lng: 45.9, lat: 24.7)
        let base = TestDesertRoadProvider { request in
            if request.target.name != "مدخل درب البر" { throw NavRoutingError.noRoute }
            let end = request.target.position
            return NavRoutePlan(routes: [NavRoute(id: "street", coordinates: [origin, end],
                                                   distanceM: Vehicle.distanceMeters(origin, end), durationS: 600, steps: [])])
        }
        let asked = BoxLog()
        let provider = DesertAwareRouteProvider(base: base, regionForPoint: { _ in nil },
                                                corridorGrid: { box in asked.add(box); return grid },
                                                rainMayBePresent: { false })
        let request = NavRouteRequest(origin: origin, heading: nil,
                                      target: NavTarget(source: .point, name: "destination", position: target),
                                      options: NavRouteOptions())
        let plan = try await provider.routes(request)
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertTrue(route.via?.contains("درب بري محسوب") == true)
        XCTAssertTrue(asked.boxes.contains { $0.contains(target) }, "the tile store was asked for a box around the pin")
        XCTAssertTrue(asked.boxes.allSatisfy { $0.n - $0.s <= DesertTiles.maxSpanDeg + 1e-9 && $0.e - $0.w <= DesertTiles.maxSpanDeg + 1e-9 })
    }

    func testProviderKeepsTheRoadRouteWhenTilesAreMissing() async throws {
        let target = LngLat(lng: 46.5, lat: 25.5)
        let roadEnd = LngLat(lng: 46.48, lat: 25.48)  // ~3 km short: an off-road last leg
        let origin = LngLat(lng: 46.6, lat: 24.7)
        let base = TestDesertRoadProvider { _ in
            NavRoutePlan(routes: [NavRoute(id: "street", coordinates: [origin, roadEnd], distanceM: 90_000, durationS: 3_600, steps: [])])
        }
        let asked = BoxLog()
        let provider = DesertAwareRouteProvider(base: base, regionForPoint: { _ in nil },
                                                corridorGrid: { box in asked.add(box); return nil },
                                                rainMayBePresent: { false })
        let plan = try await provider.routes(NavRouteRequest(origin: origin, heading: nil,
                                                             target: NavTarget(source: .point, name: "d", position: target),
                                                             options: NavRouteOptions()))
        XCTAssertEqual(plan.routes.map(\.id), ["street"], "offline / missing tiles: the road route and its final bearing stay")
        XCTAssertEqual(asked.boxes.count, 1)
        XCTAssertTrue(asked.boxes[0].contains(roadEnd) && asked.boxes[0].contains(target))
    }

    func testCityRouteThatReachesThePinNeverAsksForTiles() async throws {
        let target = LngLat(lng: 46.68, lat: 24.71)
        let origin = LngLat(lng: 46.6, lat: 24.7)
        let base = TestDesertRoadProvider { _ in
            NavRoutePlan(routes: [NavRoute(id: "city", coordinates: [origin, target], distanceM: 9_000, durationS: 900, steps: [])])
        }
        let asked = BoxLog()
        let provider = DesertAwareRouteProvider(base: base, regionForPoint: { _ in nil },
                                                corridorGrid: { box in asked.add(box); return nil }, rainMayBePresent: { false })
        let plan = try await provider.routes(NavRouteRequest(origin: origin, heading: nil,
                                                             target: NavTarget(source: .point, name: "مطعم", position: target),
                                                             options: NavRouteOptions()))
        XCTAssertEqual(plan.routes.map(\.id), ["city"])
        XCTAssertTrue(asked.boxes.isEmpty)
    }
}

/// Serves fixed files by path under the test base URL; records what was asked.
private final class FakeTileServer: @unchecked Sendable {
    private let files: [String: Data]
    private let offline: Bool
    private let lock = NSLock()
    private var asked: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return asked }

    init(files: [String: Data], offline: Bool = false) {
        self.files = files
        self.offline = offline
    }

    var fetch: DesertTileStore.Fetch {
        { [self] url in
            if offline { throw URLError(.notConnectedToInternet) }
            let path = url.absoluteString.replacingOccurrences(of: "https://tiles.example/desert/", with: "")
            lock.lock(); asked.append(path); lock.unlock()
            guard let d = files[path] else { return (Data("{}".utf8), 404) }
            return (d, 200)
        }
    }
}

private final class BoxLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [DesertGrid.BBox] = []
    var boxes: [DesertGrid.BBox] { lock.lock(); defer { lock.unlock() }; return all }
    func add(_ b: DesertGrid.BBox) { lock.lock(); all.append(b); lock.unlock() }
}


/// The access-point street requests run concurrently, so the bookkeeping is actor-isolated.
private actor RequestedAccessBook {
    private(set) var points: [LngLat] = []

    func append(_ point: LngLat) { points.append(point) }
    func count() -> Int { points.count }
    func all() -> [LngLat] { points }
}

private final class TestDesertRoadProvider: NavRoutingProvider {
    var name = "test streets"
    private let accessBook = RequestedAccessBook()
    var requestedAccessPoints: Int { get async { await accessBook.count() } }
    /// Every access point the street router was asked for, in arrival order.
    var requestedAccess: [LngLat] { get async { await accessBook.all() } }
    let handler: (NavRouteRequest) async throws -> NavRoutePlan

    init(handler: @escaping (NavRouteRequest) async throws -> NavRoutePlan) { self.handler = handler }

    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan {
        if request.target.name == "مدخل درب البر" {
            await accessBook.append(request.target.position)
        }
        return try await handler(request)
    }
}

/// Counts concurrent calls to show the access requests overlap (each answer waits a little).
private actor ConcurrencyProbe {
    private var inFlight = 0
    private(set) var peak = 0

    func enter() {
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func leave() { inFlight -= 1 }
}

private final class ConcurrencyProbeProvider: NavRoutingProvider {
    var name = "probe streets"
    private let probe = ConcurrencyProbe()
    var peakConcurrent: Int { get async { await probe.peak } }
    let handler: (NavRouteRequest) throws -> NavRoutePlan

    init(handler: @escaping (NavRouteRequest) throws -> NavRoutePlan) { self.handler = handler }

    func routes(_ request: NavRouteRequest) async throws -> NavRoutePlan {
        await probe.enter()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await probe.leave()
        return try handler(request)
    }
}

/// Route surfaces read as three materials: asphalt, dirt track, open terrain and rough ground.
final class NavSurfaceStyleTests: XCTestCase {
    func testRoughGroundIsCrestRockSabkhaWadi() {
        for g in [DesertGrid.Ground.crest, .rock, .sabkha, .wadi] { XCTAssertTrue(DesertAwareRouteProvider.isRough(g), "\(g)") }
        for g in [DesertGrid.Ground.firm, .sand, .forbidden] { XCTAssertFalse(DesertAwareRouteProvider.isRough(g), "\(g)") }
    }

    func testLegendSumsEachSurfaceAndSkipsTheApproximateJoin() {
        let a = LngLat(lng: 46.60, lat: 25.10), b = LngLat(lng: 46.61, lat: 25.10)
        let c = LngLat(lng: 46.62, lat: 25.10), d = LngLat(lng: 46.63, lat: 25.10)
        let runs = [NavSurfaceRun(kind: .paved, coordinates: [a, b]),
                    NavSurfaceRun(kind: .gridSnap, coordinates: [b, c]),
                    NavSurfaceRun(kind: .rough, coordinates: [c, d]),
                    NavSurfaceRun(kind: .paved, coordinates: [d, LngLat(lng: 46.64, lat: 25.10)])]
        let rows = NavSurfaceLegend.rows(runs)
        XCTAssertEqual(rows.map(\.kind), [.paved, .rough])
        XCTAssertEqual(rows[0].meters, 2 * Vehicle.distanceMeters(a, b), accuracy: 5)
        XCTAssertTrue(NavSurfaceLegend.shows(runs))
        XCTAssertFalse(NavSurfaceLegend.shows([NavSurfaceRun(kind: .paved, coordinates: [a, b])]), "all asphalt: no legend")
        XCTAssertEqual(NavSurfaceLegend.label(.unpaved), "ترابي")
        XCTAssertEqual(NavSurfaceLegend.label(.rough), "وعر")
    }

    func testEachSurfaceHasItsOwnMapLayers() {
        for id in ["sary-nav-dirt", "sary-nav-dirt-ruts", "sary-nav-terrain", "sary-nav-rough", "sary-nav-rough-ticks"] {
            XCTAssertTrue(NavMapDrawer.layerIds.contains(id), id)
        }
        XCTAssertEqual(NavMapDrawer.SurfaceStyle.dirt, "#D6A15A")
        XCTAssertNotEqual(NavMapDrawer.SurfaceStyle.dirt, NavMapDrawer.SurfaceStyle.terrain)
        XCTAssertNotEqual(NavMapDrawer.SurfaceStyle.terrain, NavMapDrawer.SurfaceStyle.rough)
    }
}
