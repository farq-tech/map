import XCTest
@testable import SaryAlbarq

/// «أنا أتجه للغرب وهو يمشيني ويحسبني إني مسكت المسار غلط» (owner, build 48, desert near Unaizah).
/// The heading comes from the displacement over the last fixes, never from one fix's noisy course.
final class CarHeadingEstimatorTests: XCTestCase {
    static let lat0 = 26.0, lng0 = 44.0
    static func fix(x: Double, y: Double, t: Int, speed: Double = 12, acc: Double = 8, course: Double? = nil, courseAcc: Double? = 8) -> DeviceFix {
        DeviceFix(lat: lat0 + y / 110_540, lng: lng0 + x / (111_320 * cos(lat0 * .pi / 180)), accuracy: acc, heading: course, speed: speed,
                  atMs: 1_700_000_000_000 + Double(t) * 1000, speedAccuracy: 1, courseAccuracy: courseAcc)
    }

    /// Deterministic noise.
    struct Rng { var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 33) % 10_000) / 10_000 }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    func testWestwardDriveWithJumpingCourseIsWest() {
        var e = CarHeadingEstimator()
        var r = Rng(s: 7)
        for t in 0 ..< 40 {
            /* course jumps ±120° around west, "accuracy" claimed good only sometimes */
            let c = (270 + r.range(-120, 120) + 360).truncatingRemainder(dividingBy: 360)
            e.ingest(Self.fix(x: -9 * Double(t) + r.range(-6, 6), y: r.range(-6, 6), t: t, speed: 9, acc: r.range(8, 22), course: c, courseAcc: r.next() < 0.5 ? 45 : 12))
            if t >= 14 {
                let h = try! XCTUnwrap(e.estimate.heading)
                XCTAssertLessThan(RoadSnap.angleDiff(h, 270), 25, "t=\(t) heading \(h)")
            }
        }
        XCTAssertTrue(e.estimate.isGood)
    }

    func testNorthWrapNeverSwingsTheOtherWay() {
        var e = CarHeadingEstimator()
        var r = Rng(s: 3)
        for t in 0 ..< 30 {
            /* going due north with ±6 m sideways noise: raw bearings flip between 355° and 5° */
            e.ingest(Self.fix(x: r.range(-6, 6), y: 12 * Double(t), t: t, speed: 12, acc: 8))
            if t >= 5, let h = e.estimate.heading { XCTAssertLessThan(RoadSnap.angleDiff(h, 0), 15, "t=\(t) \(h)") }
        }
        XCTAssertEqual(CarHeadingEstimator.signedDelta(from: 359, to: 1), 2, accuracy: 1e-9)
        XCTAssertEqual(CarHeadingEstimator.signedDelta(from: 1, to: 359), -2, accuracy: 1e-9)
        XCTAssertEqual(CarHeadingEstimator.circularMean([(359, 1), (1, 1)]), 0, accuracy: 1e-6)
    }

    func testStoppedHoldsTheLastHeadingAndFadesTheConfidence() {
        var e = CarHeadingEstimator()
        for t in 0 ..< 15 { e.ingest(Self.fix(x: 12 * Double(t), y: 0, t: t)) }
        let moving = e.estimate
        XCTAssertEqual(moving.heading!, 90, accuracy: 5)
        for t in 15 ..< 25 { e.ingest(Self.fix(x: 168 + Double(t % 3), y: Double(t % 2), t: t, speed: 0.2, course: 200 + Double(t * 7), courseAcc: 60)) }
        XCTAssertEqual(e.estimate.heading!, moving.heading!, accuracy: 0.001, "no jumping while stopped")
        XCTAssertEqual(e.estimate.source, .held)
        XCTAssertLessThan(e.estimate.confidence, moving.confidence)
    }

    func testPoorFixesAreIgnoredForHeading() {
        var e = CarHeadingEstimator()
        for t in 0 ..< 12 { e.ingest(Self.fix(x: 0, y: 12 * Double(t), t: t)) }
        let before = e.estimate.heading!
        for t in 12 ..< 16 { e.ingest(Self.fix(x: 150, y: 12 * Double(t), t: t, acc: 60)) }
        XCTAssertEqual(e.estimate.heading!, before, accuracy: 3, "a 150 m sideways swing at 60 m accuracy is not a direction")
    }

    func testARealUTurnIsTakenAfterAFewFixesButNotOnOne() {
        var e = CarHeadingEstimator()
        for t in 0 ..< 12 { e.ingest(Self.fix(x: 12 * Double(t), y: 0, t: t)) }
        XCTAssertEqual(e.estimate.heading!, 90, accuracy: 5)
        var turnedAt: Int?
        for k in 1 ... 14 {
            e.ingest(Self.fix(x: 132 - 12 * Double(k), y: 0, t: 11 + k))
            if turnedAt == nil, RoadSnap.angleDiff(e.estimate.heading!, 270) < 30 { turnedAt = k }
        }
        XCTAssertNotNil(turnedAt)
        XCTAssertGreaterThan(turnedAt!, 2, "not on the first contradicting fix")
        XCTAssertLessThanOrEqual(turnedAt!, 11)
    }

    func testCourseJoinsOnlyWhenRatedWellAndFast() {
        var e = CarHeadingEstimator()
        /* Course-only start (no baseline yet): used, but never fully trusted. */
        let est = e.ingest(Self.fix(x: 0, y: 0, t: 0, speed: 10, course: 90, courseAcc: 5))
        XCTAssertEqual(est.source, .course)
        XCTAssertLessThan(est.confidence, CarHeadingEstimator.goodConfidence + 0.0001)
        var slow = CarHeadingEstimator()
        XCTAssertNil(slow.ingest(Self.fix(x: 0, y: 0, t: 0, speed: 2, course: 90, courseAcc: 5)).heading, "below 3 m/s the course is not used")
        var vague = CarHeadingEstimator()
        XCTAssertNil(vague.ingest(Self.fix(x: 0, y: 0, t: 0, speed: 10, course: 90, courseAcc: 50)).heading)
    }

    func testRouteLookaheadIsACircularMeanNotOneSegment() {
        /* West 200 m, then a 20 m kink to the north, then west again. */
        let o = (lng: Self.lng0, lat: Self.lat0)
        func p(_ x: Double, _ y: Double) -> LngLat { LngLat(lng: o.lng + x / (111_320 * cos(o.lat * .pi / 180)), lat: o.lat + y / 110_540) }
        let line = RouteLine([p(0, 0), p(-200, 0), p(-200, 20), p(-400, 20)])
        XCTAssertEqual(line.bearing(alongM: 100, behindM: 10, aheadM: 80)!, 270, accuracy: 1)
        /* The kink segment alone is 0°; the 90 m window around it is dominated by the west legs. */
        let b = line.bearing(alongM: 190, behindM: 10, aheadM: 80)!
        XCTAssertLessThan(RoadSnap.angleDiff(b, 270), 25)
    }
}

/// Replays of whole drives through `RouteAdherence`.
final class HeadingReplayTests: XCTestCase {
    typealias T = CarHeadingEstimatorTests

    /// A westward route 6 km long, 100 m vertices, with a gentle ±15 m wobble (a desert track).
    static func westRoute() -> RouteLine {
        let pts = stride(from: 0.0, through: 6000, by: 100).map { d -> LngLat in
            let y = 15 * sin(d / 700)
            return LngLat(lng: T.lng0 - d / (111_320 * cos(T.lat0 * .pi / 180)), lat: T.lat0 + y / 110_540)
        }
        return RouteLine(pts)
    }

    func testDesertDriveWestWithNoisyCourseNeverGoesOffNorWrongWay() {
        let line = Self.westRoute()
        var a = RouteAdherence()
        var r = T.Rng(s: 42)
        var t = 0
        var along = 200.0
        var changes: [RouteAdherence.State] = []
        while along < 5000 {
            let v = r.range(3.5, 11)      // sand: slow and fast
            along += v
            let y = 15 * sin(along / 700)
            var x = -along, yy = y + r.range(-7, 7)
            var acc = r.range(10, 35)
            /* every ~17th fix is an outlier: 40–60 m off, poor accuracy */
            if t % 17 == 9 { yy += r.range(40, 60) * (r.next() < 0.5 ? -1 : 1); acc = r.range(28, 40) }
            if t % 23 == 5 { x += r.range(-25, 25) }
            /* course: at low speed it jumps ±120° around west; sometimes even straight east */
            var c = (270 + r.range(-120, 120) + 360).truncatingRemainder(dividingBy: 360)
            if t % 11 == 4 { c = 90 }
            let f = T.fix(x: x, y: yy, t: t, speed: v, acc: acc, course: c, courseAcc: r.next() < 0.4 ? 10 : 35)
            if let ch = a.note(f, on: line, expectedAlongM: along) { changes.append(ch) }
            XCTAssertEqual(a.state, .on, "t=\(t) \(a.decisions.last?.line ?? "")")
            t += 1
        }
        XCTAssertTrue(changes.isEmpty)
        XCTAssertGreaterThan(t, 400)
    }

    func testTrueWrongWayIsDetectedAfterAFewSeconds() {
        /* Northbound route; the car goes SOUTH on the opposite carriageway 14 m east, 150 m of it. */
        let line = RouteLine(RouteAdherenceTests.northRoad(km: 5))
        var a = RouteAdherence()
        var off: Int?
        var r = T.Rng(s: 5)
        for i in 0 ..< 14 {
            let f = RouteAdherenceTests.fix(i, offsetM: 14 + r.range(-3, 3), heading: 180 + r.range(-40, 40), speed: 14,
                                            accuracy: r.range(6, 15), along: 2500 - 14 * Double(i))
            if a.note(f, on: line) == .off, off == nil { off = i }
        }
        let i = try! XCTUnwrap(off, "\(a.decisions.map(\.line))")
        XCTAssertLessThanOrEqual(i, 10, "within ~10 s (140 m) of starting the wrong way")
        XCTAssertGreaterThanOrEqual(i, 4, "never on a single fix")
    }

    func testALoneOppositeCourseOnTheRightRoadIsNothing() {
        let line = RouteLine(RouteAdherenceTests.northRoad(km: 5))
        var a = RouteAdherence()
        for i in 0 ..< 20 {
            /* really driving north, 6 m off the line; every other fix claims it points south */
            let f = RouteAdherenceTests.fix(i, offsetM: 10, heading: i % 2 == 0 ? 180 : 0)
            a.note(f, on: line)
            XCTAssertEqual(a.state, .on, "i=\(i)")
        }
    }

    func testArrivingBesideTheRouteEndIsNotLeavingTheRoute() {
        /* The destination flag sits 30 m from the track: the route ends there, the car drives past at 4.5 m/s. */
        let line = RouteLine(RouteAdherenceTests.northRoad(km: 1))
        var a = RouteAdherence()
        for i in 0 ..< 40 { a.note(RouteAdherenceTests.fix(i, offsetM: 30, speed: 4.5, accuracy: 10, along: 850 + 4.5 * Double(i)), on: line) }
        XCTAssertEqual(a.state, .on, "\(a.decisions.suffix(5).map(\.line))")
    }

    func testDecisionLogIsABoundedRingWithoutCoordinates() {
        let line = RouteLine(RouteAdherenceTests.northRoad(km: 5))
        var a = RouteAdherence()
        for i in 0 ..< 300 { a.note(RouteAdherenceTests.fix(i, offsetM: 2, along: 100 + Double(i)), on: line) }
        XCTAssertEqual(a.decisions.count, RouteAdherence.decisionLogSize)
        let l = a.decisions.last!.line
        XCTAssertTrue(l.hasPrefix("adh on"))
        XCTAssertFalse(l.contains("24.7"))
    }
}
