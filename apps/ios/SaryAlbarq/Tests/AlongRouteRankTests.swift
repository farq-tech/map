import XCTest
@testable import SaryAlbarq

/// «على طول المسار» (UX backlog R2): places are ranked by how far AHEAD they are on the route and how far off it
/// they sit, not by straight-line distance from me.
final class AlongRouteRankTests: XCTestCase {
    static let lat0 = 24.7000, lng0 = 46.6700
    static func north(_ m: Double) -> Double { m / 111_194.9 }
    static func east(_ m: Double) -> Double { m / (111_194.9 * cos(lat0 * .pi / 180)) }
    typealias P = AlongRouteRank.Point

    /// A straight road going north, 40 km, a vertex every 500 m.
    static let road: [P] = stride(from: 0.0, through: 40_000, by: 500).map { P(lat: lat0 + north($0), lng: lng0) }
    static func place(_ id: String, alongM: Double, eastM: Double = 0) -> AlongRouteRank.Candidate {
        .init(id: id, point: P(lat: lat0 + north(alongM), lng: lng0 + east(eastM)))
    }

    func testAheadBeatsBehindEvenWhenBehindIsCloserAsTheCrowFlies() {
        let r = AlongRouteRank.rank(route: Self.road, myAlongM: 10_000,
                                    candidates: [Self.place("behind", alongM: 7_000), Self.place("ahead", alongM: 22_000)])
        XCTAssertEqual(r.map(\.id), ["ahead"], "3 km behind me is not on the way")
        XCTAssertEqual(r[0].aheadM, 12_000, accuracy: 30)
    }

    func testAPlaceIAmPassingStillCounts() {
        let r = AlongRouteRank.rank(route: Self.road, myAlongM: 10_000, candidates: [Self.place("here", alongM: 9_900)])
        XCTAssertEqual(r.map(\.id), ["here"])
        XCTAssertEqual(r[0].aheadM, -100, accuracy: 30)
    }

    func testASmallDetourBeatsAFarPlaceOnTheRoute() {
        let r = AlongRouteRank.rank(route: Self.road, myAlongM: 0,
                                    candidates: [Self.place("onRoadFar", alongM: 30_000),
                                                 Self.place("sideNear", alongM: 8_000, eastM: 900)])
        XCTAssertEqual(r.first?.id, "sideNear")
        XCTAssertEqual(r.first?.offRouteM ?? 0, 900, accuracy: 20)
    }

    func testTooFarOffTheRouteIsDropped() {
        let r = AlongRouteRank.rank(route: Self.road, myAlongM: 0, candidates: [Self.place("far", alongM: 5_000, eastM: 9_000)])
        XCTAssertTrue(r.isEmpty)
    }

    func testOrderIsByScoreThenId() {
        let r = AlongRouteRank.rank(route: Self.road, myAlongM: 0,
                                    candidates: [Self.place("b", alongM: 5_000), Self.place("a", alongM: 5_000), Self.place("c", alongM: 2_000)])
        XCTAssertEqual(r.map(\.id), ["c", "a", "b"])
    }

    func testLimitAndEmptyInputs() {
        let many = (1...20).map { Self.place("p\($0)", alongM: Double($0) * 1_000) }
        XCTAssertEqual(AlongRouteRank.rank(route: Self.road, myAlongM: 0, candidates: many).count, 6)
        XCTAssertTrue(AlongRouteRank.rank(route: [], myAlongM: 0, candidates: many).isEmpty)
        XCTAssertTrue(AlongRouteRank.rank(route: [P(lat: 1, lng: 1)], myAlongM: 0, candidates: many).isEmpty)
        XCTAssertTrue(AlongRouteRank.rank(route: Self.road, myAlongM: 0, candidates: []).isEmpty)
    }

    func testDetailWording() {
        XCTAssertEqual(AlongRouteRank.detail(offRouteM: 40), "على مسارك")
        XCTAssertEqual(AlongRouteRank.detail(offRouteM: 320), "+300 م عن مسارك")
        XCTAssertEqual(AlongRouteRank.detail(offRouteM: 1_480), "+1٫5 كم عن مسارك")
    }

    func testSamplesAheadEveryTwentyKilometresUpToTheHorizon() {
        let long: [P] = stride(from: 0.0, through: 100_000, by: 500).map { P(lat: Self.lat0 + Self.north($0), lng: Self.lng0) }
        let s = AlongRouteRank.samples(route: long, myAlongM: 10_000)
        XCTAssertEqual(s.count, 4, "30, 50, 70 and 90 km")
        XCTAssertEqual(s[0].lat, Self.lat0 + Self.north(30_000), accuracy: 0.0005)
        XCTAssertEqual(s[3].lat, Self.lat0 + Self.north(90_000), accuracy: 0.0005)
        XCTAssertEqual(AlongRouteRank.samples(route: long, myAlongM: 99_000).count, 0, "less than one step left")
        XCTAssertTrue(AlongRouteRank.samples(route: [], myAlongM: 0).isEmpty)
    }
}
