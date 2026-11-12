import XCTest
@testable import SaryAlbarq

/// «أنا أمشي بالمسار الثاني ولا زال يعتبر أني بالمسار الآخر» (owner, build 46): a divided road with a
/// metro median — the car drives one carriageway while the route line sits on the other, 20–40 m away.
final class RouteAdherenceTests: XCTestCase {
    static let lng0 = 46.6700, lat0 = 24.7000
    static func east(_ m: Double) -> Double { m / (111_320 * cos(lat0 * .pi / 180)) }
    static func north(_ m: Double) -> Double { m / 110_540 }

    /// A straight road going north, `km` long, with a vertex every 100 m.
    static func northRoad(km: Double, offsetM: Double = 0) -> [LngLat] {
        stride(from: 0.0, through: km * 1000, by: 100).map { LngLat(lng: lng0 + east(offsetM), lat: lat0 + north($0)) }
    }

    /// A fix driving north at `v` m/s, `i` seconds in, `offsetM` east of the route.
    static func fix(_ i: Int, offsetM: Double, heading: Double = 0, speed: Double = 14, accuracy: Double = 6, along: Double? = nil) -> DeviceFix {
        DeviceFix(lat: lat0 + north(along ?? 500 + speed * Double(i)), lng: lng0 + east(offsetM), accuracy: accuracy, heading: heading,
                  speed: speed, atMs: 1_700_000_000_000 + Double(i) * 1000, speedAccuracy: 1, courseAccuracy: 5)
    }

    private let line = RouteLine(RouteAdherenceTests.northRoad(km: 5))

    func testTheSameCarriagewayNeverGoesOff() {
        var a = RouteAdherence()
        for i in 0 ..< 30 { XCTAssertNil(a.note(Self.fix(i, offsetM: i % 2 == 0 ? 4 : -6), on: line)) }
        XCTAssertEqual(a.state, .on)
    }

    func testAParallelCarriagewayThirtyMetresAwayGoesOffAfterAFewSeconds() {
        var a = RouteAdherence()
        var changedAt: Int?
        for i in 0 ..< 12 {
            if a.note(Self.fix(i, offsetM: 30), on: line) == .off { changedAt = i; break }
        }
        let i = try! XCTUnwrap(changedAt)
        XCTAssertGreaterThanOrEqual(i, RouteAdherence.offFixes - 1, "not on a single fix")
        XCTAssertLessThanOrEqual(i, 6, "but within a few seconds")
        XCTAssertEqual(a.state, .off)
        XCTAssertEqual(a.last!.crossM, 30, accuracy: 1.5)
    }

    func testOneNoisyFixIsNotAnotherRoad() {
        var a = RouteAdherence()
        for i in 0 ..< 20 { a.note(Self.fix(i, offsetM: i == 9 ? 38 : 3), on: line) }
        XCTAssertEqual(a.state, .on)
    }

    func testBackOnTheRouteGoesOnAgain() {
        var a = RouteAdherence()
        for i in 0 ..< 8 { a.note(Self.fix(i, offsetM: 30), on: line) }
        XCTAssertEqual(a.state, .off)
        var back: RouteAdherence.State?
        for i in 8 ..< 14 { if let c = a.note(Self.fix(i, offsetM: 3), on: line) { back = c } }
        XCTAssertEqual(back, .on)
    }

    func testTheOppositeCarriagewayDrivenTheOtherWayIsOffEvenWhenClose() {
        var a = RouteAdherence()
        for i in 0 ..< 10 { a.note(Self.fix(i, offsetM: 14, heading: 180), on: line) }
        XCTAssertEqual(a.state, .off, "14 m over, heading 180° against a northbound route")
    }

    func testAParkedOrCrawlingCarSaysNothing() {
        var a = RouteAdherence()
        for i in 0 ..< 20 { XCTAssertNil(a.note(Self.fix(i, offsetM: 35, speed: 0.4), on: line)) }
        XCTAssertEqual(a.state, .on)
    }

    func testAPoorFixWidensTheToleranceButNotForever() {
        let a = RouteAdherence()
        XCTAssertEqual(a.toleranceM(accuracy: 5), 20)
        XCTAssertEqual(a.toleranceM(accuracy: 15), 30)
        XCTAssertEqual(a.toleranceM(accuracy: 80), 45)
        XCTAssertEqual(RouteAdherence(allowanceM: 20).toleranceM(accuracy: 5), 40)
    }

    func testASearchWindowKeepsTheCarOnTheHalfOfTheRouteItIsOn() {
        /* North 3 km, then back south 3 km along the carriageway 30 m east. */
        let out = Self.northRoad(km: 3), back = Self.northRoad(km: 3, offsetM: 30).reversed()
        let l = RouteLine(out + back)
        let f = Self.fix(0, offsetM: 30, heading: 180, along: 1000)
        XCTAssertLessThan(RouteAdherence.measure(f, on: l)!.crossM, 2, "unwindowed: the return half matches")
        XCTAssertGreaterThan(RouteAdherence.measure(f, on: l, expectedAlongM: 500)!.crossM, 25, "windowed: still on the outbound half")
    }

    func testAllowanceForARouterThatInsistsOnTheOtherCarriageway() {
        XCTAssertEqual(RouteAdherence.allowance(forCrossM: 8, accuracy: 6), 0)
        XCTAssertEqual(RouteAdherence.allowance(forCrossM: 35, accuracy: 6), 23, accuracy: 0.01)
        var a = RouteAdherence(allowanceM: RouteAdherence.allowance(forCrossM: 35, accuracy: 6))
        for i in 0 ..< 20 { a.note(Self.fix(i, offsetM: 35), on: line) }
        XCTAssertEqual(a.state, .on, "no off-route loop on the road the router chose")
    }
}

/// The real `NavSession`: the SDK keeps matching the car to the route (it sends progress with the old
/// instruction) while the raw fixes are on the parallel carriageway.
@MainActor
final class ParallelCarriagewaySessionTests: XCTestCase {
    final class Engine: NavGuidanceEngine {
        var onEvent: (NavGuidanceEvent) -> Void = { _ in }
        private(set) var starts: [String] = []
        func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws { starts.append(route.id) }
        func stop() {}
        func ingest(_ fix: DeviceFix) {}
    }

    final class Recording: NavRoutingProvider {
        let name = "Recording"
        var plans: [NavRoutePlan]
        private(set) var requests: [NavRouteRequest] = []
        init(_ plans: [NavRoutePlan]) { self.plans = plans }
        func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
            requests.append(r)
            return plans.count > 1 ? plans.removeFirst() : plans[0]
        }
    }

    private func route(id: String, offsetM: Double, fromM: Double = 0) -> NavRoute {
        let c = stride(from: fromM, through: 5000, by: 100).map {
            LngLat(lng: RouteAdherenceTests.lng0 + RouteAdherenceTests.east(offsetM), lat: RouteAdherenceTests.lat0 + RouteAdherenceTests.north($0))
        }
        let steps = [NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق الأمير محمد بن سلمان", location: c[0], distanceM: 4200, durationS: 200),
                     NavStep(maneuver: .init(kind: .fork, direction: .slightLeft), roadName: "طريق الثمامة", location: c[c.count - 2], distanceM: 800, durationS: 60),
                     NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: c.last!, distanceM: 0, durationS: 0)]
        return NavRoute(id: id, coordinates: c, distanceM: 5000 - fromM, durationS: 300, steps: steps)
    }

    func testAParallelCarriagewayGetsANewRouteFromWhereTheCarIsWithItsHeadingAndTheStaleInstructionIsHeldBack() async throws {
        let old = route(id: "old", offsetM: 0)
        let new = route(id: "new", offsetM: 30, fromM: 500)
        let router = Recording([NavRoutePlan(routes: [old]), NavRoutePlan(routes: [new])])
        let engine = Engine()
        let n = NavSession(provider: router, makeEngine: { _ in engine })
        n.myFix = { RouteAdherenceTests.fix(0, offsetM: 30) }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: old.end!))
        let up = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < up { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.phase, .guiding)
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 4200, distanceRemainingM: 4500, durationRemainingS: 270, speedLimitKmh: nil)))
        XCTAssertEqual(n.progress?.distanceToManeuverM, 4200)

        /* Eight seconds on the parallel carriageway (30 m east), course north. */
        for i in 0 ..< 8 { n.ingest(RouteAdherenceTests.fix(i, offsetM: 30)) }
        XCTAssertEqual(n.adherence.state, .off)
        XCTAssertTrue(n.rerouting, "the banner says «نعيد حساب الطريق» instead of keeping the old instruction")
        /* The SDK still talks about the old route: held back, not shown. */
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 230, distanceRemainingM: 400, durationRemainingS: 20, speedLimitKmh: nil)))
        XCTAssertEqual(n.progress?.distanceToManeuverM, 4200)

        let done = Date().addingTimeInterval(3)
        while n.active?.id != "new", Date() < done { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.active?.id, "new")
        XCTAssertEqual(router.requests.count, 2)
        let req = router.requests[1]
        XCTAssertEqual(req.origin.lng, RouteAdherenceTests.lng0 + RouteAdherenceTests.east(30), accuracy: 1e-6, "from the raw fix, not the matched one")
        XCTAssertEqual(try XCTUnwrap(req.heading), 0, accuracy: 1, "with the car's course")
        XCTAssertEqual(engine.starts, ["old", "new"])
        XCTAssertFalse(n.rerouting)
        XCTAssertEqual(n.adherence.state, .on)
        /* The new route is on the carriageway the car drives: the SDK's numbers are shown again. */
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 3500, distanceRemainingM: 4000, durationRemainingS: 240, speedLimitKmh: nil)))
        XCTAssertEqual(n.progress?.distanceToManeuverM, 3500)
        n.end()
    }

    func testADrivenCarriagewayThatTheRouteIsOnNeverTriggersAReroute() async throws {
        let old = route(id: "old", offsetM: 0)
        let router = Recording([NavRoutePlan(routes: [old])])
        let n = NavSession(provider: router, makeEngine: { _ in Engine() })
        n.myFix = { RouteAdherenceTests.fix(0, offsetM: 2) }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: old.end!))
        let up = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < up { try await Task.sleep(nanoseconds: 20_000_000) }
        for i in 0 ..< 20 { n.ingest(RouteAdherenceTests.fix(i, offsetM: i % 2 == 0 ? 3 : -4)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(router.requests.count, 1)
        XCTAssertEqual(n.adherence.state, .on)
        XCTAssertFalse(n.rerouting)
        n.end()
    }

    func testARouterThatInsistsOnTheOtherCarriagewayIsAcceptedNotLooped() async throws {
        let old = route(id: "old", offsetM: 0)
        let same = route(id: "same", offsetM: 0, fromM: 500)
        let router = Recording([NavRoutePlan(routes: [old]), NavRoutePlan(routes: [same])])
        let n = NavSession(provider: router, makeEngine: { _ in Engine() })
        n.myFix = { RouteAdherenceTests.fix(0, offsetM: 30) }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: old.end!))
        let up = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < up { try await Task.sleep(nanoseconds: 20_000_000) }
        for i in 0 ..< 8 { n.ingest(RouteAdherenceTests.fix(i, offsetM: 30)) }
        let done = Date().addingTimeInterval(3)
        while n.active?.id != "same", Date() < done { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.active?.id, "same")
        for i in 8 ..< 40 { n.ingest(RouteAdherenceTests.fix(i, offsetM: 30)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(router.requests.count, 2, "one extra request, no loop")
        XCTAssertEqual(n.adherence.state, .on)
        n.end()
    }
}
