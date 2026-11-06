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
}
