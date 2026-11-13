import XCTest
@testable import SaryAlbarq

/// «الخط بين السيارة وبداية المسار»: off the drawn route, a dashed hop shows the way back onto it.
final class NavConnectorTests: XCTestCase {
    private let originLat = 28.0, originLng = 41.0
    /// 1 m north ≈ 1/110540 deg; a route going east from (0, 0).
    private func pt(east: Double, north: Double) -> LngLat {
        LngLat(lng: originLng + east / (111_320 * cos(originLat * .pi / 180)), lat: originLat + north / 110_540)
    }
    private var route: [LngLat] { [pt(east: 0, north: 0), pt(east: 500, north: 0), pt(east: 1000, north: 0)] }

    /// A 120x120 grid (~10 km) around the origin, all firm and flat unless a test changes it.
    private func grid(_ ground: DesertGrid.Ground = .firm) -> DesertGrid {
        DesertGrid(rows: 120, cols: 120, ground: ground, south: originLat - 0.05, west: originLng - 0.05)
    }
    private func connector(_ g: DesertGrid?, east: Double, north: Double) -> NavRejoin.Decision {
        NavRejoin.decide(me: pt(east: east, north: north), route: route, terrain: g.map { GridTerrain(grid: $0) })
    }

    func testShortFlatShortcutIsShown() throws {
        /* The owner's case: ~100 m from the start of the route in open sand. */
        let d = connector(grid(.sand), east: 0, north: -100)
        let c = try XCTUnwrap(d.connector)
        XCTAssertEqual(c.distanceM, 100, accuracy: 1)
        XCTAssertTrue(c.toRouteStart)
        XCTAssertGreaterThan(c.etaS, 0)
        XCTAssertLessThan(d.shortcutCostS!, d.tracksCostS!)
        XCTAssertFalse(NavRejoin.label(c).isEmpty)
    }

    func testEndsAtTheNearestPointAlongTheRoute() throws {
        let c = try XCTUnwrap(connector(grid(), east: 750, north: -120).connector)
        XCTAssertFalse(c.toRouteStart)
        XCTAssertEqual(c.to.lng, pt(east: 750, north: 0).lng, accuracy: 1e-6)
    }

    func testHiddenWhenOnTheRoute() {
        XCTAssertEqual(connector(grid(), east: 200, north: 24).veto, .onRoute)
        XCTAssertNil(NavRejoin.connector(me: nil, route: route, terrain: GridTerrain(grid: grid())))
        XCTAssertNil(NavRejoin.connector(me: pt(east: 0, north: 0), route: [], terrain: GridTerrain(grid: grid())))
    }

    func testTooFarIsNeverDrawn() {
        XCTAssertEqual(connector(grid(), east: 300, north: -251).veto, .tooFar)
        XCTAssertNotNil(connector(grid(), east: 300, north: -240).connector)
    }

    func testMissingTerrainMeansNoLine() {
        XCTAssertEqual(connector(nil, east: 0, north: -100).veto, .noTerrain)
        /* Outside the grid's box. */
        let far = DesertGrid(rows: 10, cols: 10, ground: .firm, south: originLat + 1, west: originLng + 1)
        XCTAssertEqual(connector(far, east: 0, north: -100).veto, .noTerrain)
    }

    func testRockCrestSabkhaWadiAreVetoed() {
        for gr in [DesertGrid.Ground.rock, .crest, .sabkha, .wadi, .forbidden] {
            XCTAssertEqual(connector(grid(gr), east: 0, north: -100).veto, .ground, "\(gr)")
        }
    }

    func testSteepSlopeIsVetoed() {
        var g = grid()
        for r in 0 ..< g.rows { for c in 0 ..< g.cols { g.elev[r * g.cols + c] = Float(500 + Double(g.rows - r) * 20) } }
        /* ~20 m per ~92 m row = 22 %: steeper than the 15 % limit. */
        XCTAssertEqual(connector(g, east: 0, north: -150).veto, .steep)
    }

    func testBigElevationDifferenceIsVetoed() {
        /* A smooth 12 % ramp (under the grade limit) over 240 m is ~29 m in total: over the 25 m limit. */
        var t = GridTerrain(grid: grid())
        t.liveElevation = { p in 500 + (p.lat - self.originLat) * 110_540 * 0.12 }
        let d = NavRejoin.decide(me: pt(east: 0, north: -240), route: route, terrain: t)
        XCTAssertEqual(d.veto, .elevation)
    }

    func testABumpOverTheChordIsVetoed() {
        var g = grid()
        g.elev[g.index(pt(east: 0, north: -120))] = 540
        let v = connector(g, east: 0, north: -240).veto
        XCTAssertTrue(v == .steep || v == .elevation || v == .rugged)
    }

    func testLiveDEMWinsAndNilElevationMeansNoLine() {
        let g = grid()
        let me = pt(east: 0, north: -100)
        var flat = GridTerrain(grid: g)
        flat.liveElevation = { _ in 500 }
        XCTAssertNotNil(NavRejoin.decide(me: me, route: route, terrain: flat).connector)
        var hole = GridTerrain(grid: g)
        hole.liveElevation = { p in p.lat > self.originLat - 0.0004 ? nil : 500 }
        /* The DEM answers nil: the grid's own elevation is used (offline data), still flat: line kept. */
        XCTAssertNotNil(NavRejoin.decide(me: me, route: route, terrain: hole).connector)
        /* A terrain with no answer at all (unknown) never gives a line. */
        XCTAssertEqual(NavRejoin.decide(me: me, route: route, terrain: NoTerrain()).veto, .noTerrain)
        /* A ridge beside the chord (live DEM) is rugged ground. */
        var ridge = GridTerrain(grid: g)
        ridge.liveElevation = { p in abs(p.lng - self.originLng) > 0.00015 ? 540 : 500 }
        XCTAssertEqual(NavRejoin.decide(me: me, route: route, terrain: ridge).veto, .rugged)
    }

    func testTracksWinWhenTheShortcutIsHarderThanFollowingThem() {
        /* Deep sand and a slope make the shortcut cost more than a detour along the tracks. */
        var g = grid(.sand)
        for r in 0 ..< g.rows { for c in 0 ..< g.cols { g.elev[r * g.cols + c] = Float(500 + Double(g.rows - r) * 1.0) } }
        let d = NavRejoin.decide(me: pt(east: 0, north: -240), route: route, terrain: GridTerrain(grid: g))
        XCTAssertEqual(d.veto, .tracksCheaper)
        XCTAssertNil(d.connector)
    }

    func testDrawingChangeDetectionSeesTheConnector() {
        var a = MapNavDrawing(), b = MapNavDrawing()
        b.connector = [pt(east: 0, north: 0), pt(east: 0, north: 100)]
        XCTAssertTrue(NavSourceChanges.between(drawn: a, next: b).offRoad)
        a.connector = b.connector
        XCTAssertFalse(NavSourceChanges.between(drawn: a, next: b).offRoad)
    }
}

private struct NoTerrain: NavTerrain {
    func elevation(at p: LngLat) -> Double? { nil }
    func ground(at p: LngLat) -> DesertGrid.Ground? { nil }
    var resolutionM: Double { 90 }
}
