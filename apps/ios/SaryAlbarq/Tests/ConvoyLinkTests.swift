import XCTest
@testable import SaryAlbarq

/// The thin thread between the convoy's two ends: geometry, style by distance, and who may get one.
final class ConvoyLinkTests: XCTestCase {
    // MARK: geometry

    func testTheLineStartsAndEndsAtTheMarkerEdgesNotTheCentres() throws {
        let s = try XCTUnwrap(ConvoyLinkGeometry.segment(a: CGPoint(x: 100, y: 100), b: CGPoint(x: 100, y: 300), inset: 20))
        XCTAssertEqual(s.from.y, 120, accuracy: 0.001)
        XCTAssertEqual(s.to.y, 280, accuracy: 0.001)
        XCTAssertEqual(s.length, 160, accuracy: 0.001)
        XCTAssertEqual(s.mid.y, 200, accuracy: 0.001)
    }

    func testTheLineStretchesAsTheCarsMoveApart() throws {
        var last: CGFloat = 0
        for gap in stride(from: 80, through: 800, by: 120) {
            let s = try XCTUnwrap(ConvoyLinkGeometry.segment(a: .zero, b: CGPoint(x: CGFloat(gap), y: 0)))
            XCTAssertGreaterThan(s.length, last, "a longer gap on screen is a longer line")
            last = s.length
        }
    }

    func testTheLineFollowsADiagonalDirection() throws {
        let s = try XCTUnwrap(ConvoyLinkGeometry.segment(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 300, y: 400), inset: 20))
        /* 3-4-5: unit vector (0.6, 0.8); inset 20 → (12, 16) from the first car. */
        XCTAssertEqual(s.from.x, 12, accuracy: 0.001)
        XCTAssertEqual(s.from.y, 16, accuracy: 0.001)
        XCTAssertEqual(s.length, 460, accuracy: 0.001)
    }

    func testCarsTooCloseOrNonFiniteGetNoLine() {
        XCTAssertNil(ConvoyLinkGeometry.segment(a: CGPoint(x: 10, y: 10), b: CGPoint(x: 10, y: 10)))
        XCTAssertNil(ConvoyLinkGeometry.segment(a: .zero, b: CGPoint(x: 50, y: 0)), "50 pt apart leaves under 14 pt visible")
        XCTAssertNil(ConvoyLinkGeometry.segment(a: .zero, b: CGPoint(x: CGFloat.infinity, y: 0)))
        XCTAssertNil(ConvoyLinkGeometry.segment(a: .zero, b: CGPoint(x: CGFloat.nan, y: 0)))
    }

    // MARK: style

    func testTheLineIsAlwaysThin() {
        for m in [10.0, 300, 600, 1000, 2500, 6000] {
            let w = ConvoyLinkGeometry.style(meters: m, gapM: 1000).width
            XCTAssertLessThanOrEqual(w, 1.5)
            XCTAssertGreaterThanOrEqual(w, 1)
        }
    }

    func testCloseIsSolidAndQuietAndUnlabelled() {
        let s = ConvoyLinkGeometry.style(meters: 120, gapM: 1000)
        XCTAssertTrue(s.dash.isEmpty)
        XCTAssertFalse(s.showsLabel)
        XCTAssertEqual(s.tone, .calm)
        XCTAssertLessThanOrEqual(s.opacity, 0.5, "never a heavy line")
    }

    func testTheDashOpensWithTheDistanceAndTheToneTurnsPastTheGap() {
        let near = ConvoyLinkGeometry.style(meters: 700, gapM: 1000)
        let past = ConvoyLinkGeometry.style(meters: 1200, gapM: 1000)
        let far = ConvoyLinkGeometry.style(meters: 1900, gapM: 1000)
        XCTAssertEqual(near.tone, .calm)
        XCTAssertEqual(past.tone, .past)
        XCTAssertGreaterThan(far.dash[0], past.dash[0], "the dash lengthens as they separate")
        XCTAssertLessThanOrEqual(far.dash[0], 14)
    }

    func testVeryFarFadesToAWhisperNeverToZero() {
        let s = ConvoyLinkGeometry.style(meters: 9000, gapM: 1000)
        XCTAssertLessThanOrEqual(s.opacity, 0.3)
        XCTAssertGreaterThanOrEqual(s.opacity, 0.2)
    }

    func testTheLabelAppearsOnlyFrom500Metres() {
        XCTAssertFalse(ConvoyLinkGeometry.style(meters: 480, gapM: 1000).showsLabel)
        XCTAssertTrue(ConvoyLinkGeometry.style(meters: 500, gapM: 1000).showsLabel)
        XCTAssertTrue(ConvoyLinkGeometry.style(meters: 3000, gapM: 200).showsLabel)
    }

    // MARK: who gets a thread

    private func member(_ id: String, lat: Double, live: Bool = true, accuracy: Double = 8) -> MapMember {
        MapMember(id: id, position: LngLat(lng: 46.70, lat: lat), color: 0xFFFFFF, name: id, presence: live ? .live : .recent,
                  heading: nil, accuracyM: accuracy, atMs: 0, note: nil, isMe: false)
    }

    func testBothEndsLiveGiveTheTrueDistanceRoundedToTenMetres() throws {
        let convoy = ConvoyInfo(lead_user_id: "L", tail_user_id: "T", max_gap_m: 500)
        /* 0.01° of latitude ≈ 1111 m. */
        let info = try XCTUnwrap(ConvoyLink.info(convoy: convoy, members: [member("L", lat: 24.71), member("T", lat: 24.70)]))
        XCTAssertEqual(info.meters, 1110, accuracy: 15)
        XCTAssertEqual(info.meters.truncatingRemainder(dividingBy: 10), 0)
        XCTAssertEqual(info.gapM, 500)
        XCTAssertEqual(info.leadId, "L")
        XCTAssertEqual(info.tailId, "T")
    }

    func testAStaleOrApproximateEndNeverGetsAThread() {
        let convoy = ConvoyInfo(lead_user_id: "L", tail_user_id: "T", max_gap_m: 500)
        XCTAssertNil(ConvoyLink.info(convoy: convoy, members: [member("L", lat: 24.71), member("T", lat: 24.70, live: false)]))
        XCTAssertNil(ConvoyLink.info(convoy: convoy, members: [member("L", lat: 24.71), member("T", lat: 24.70, accuracy: 90)]))
    }

    func testNoConvoyOrOneEndOrTheSameCarMeansNoThread() {
        let members = [member("L", lat: 24.71), member("T", lat: 24.70)]
        XCTAssertNil(ConvoyLink.info(convoy: nil, members: members))
        XCTAssertNil(ConvoyLink.info(convoy: ConvoyInfo.off, members: members))
        XCTAssertNil(ConvoyLink.info(convoy: ConvoyInfo(lead_user_id: "L", tail_user_id: nil, max_gap_m: 500), members: members))
        XCTAssertNil(ConvoyLink.info(convoy: ConvoyInfo(lead_user_id: "L", tail_user_id: "L", max_gap_m: 500), members: members))
        XCTAssertNil(ConvoyLink.info(convoy: ConvoyInfo(lead_user_id: "L", tail_user_id: "X", max_gap_m: 500), members: members), "an end with no fix at all")
    }

    // MARK: the car → chip leader lines

    func testLeaderLineIsFineAndFaint() {
        XCTAssertLessThanOrEqual(LeaderStyle.lineWidth, 1.5)
        XCTAssertLessThanOrEqual(LeaderStyle.haloWidth, 2.5)
        XCTAssertLessThanOrEqual(LeaderStyle.lineAlpha, 0.6)
        XCTAssertLessThanOrEqual(LeaderStyle.haloAlpha, 0.4)
    }

    func testLeaderStartsAtTheCarEdgeAndStretchesWithTheDistance() throws {
        let short = try XCTUnwrap(LeaderStyle.segment(from: .zero, to: CGPoint(x: 0, y: 60)))
        let long = try XCTUnwrap(LeaderStyle.segment(from: .zero, to: CGPoint(x: 0, y: 160)))
        XCTAssertEqual(short.0.y, LeaderStyle.carInset, accuracy: 0.001, "starts at the marker edge, not its centre")
        XCTAssertEqual(short.1.y, 60, accuracy: 0.001)
        XCTAssertGreaterThan(long.1.y - long.0.y, short.1.y - short.0.y, "a farther chip means a longer line")
    }

    func testAChipRightOnTheCarGetsNoLeader() {
        XCTAssertNil(LeaderStyle.segment(from: .zero, to: CGPoint(x: 10, y: 0)))
        XCTAssertNil(LeaderStyle.segment(from: .zero, to: CGPoint(x: CGFloat.nan, y: 0)))
    }
}
