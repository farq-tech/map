import XCTest
@testable import SaryAlbarq

// «ابدأ الطلعة» ⇒ automatic turn-by-turn until arrival: target selection, stop advance,
// arrival radius, resume after a relaunch, off-road and offline fallbacks (never a made-up route).

private let olaya = LngLat(lng: 46.6744, lat: 24.7113)
private let camp = OutingDestination(name: "مخيم النفود", lat: 24.7590, lng: 46.7491)
private let fuel = OutingDestination(name: "محطة الوقود", lat: 24.7240, lng: 46.6960)
private let lookout = OutingDestination(name: "الطعس", lat: 24.7400, lng: 46.7200)

private func fix(_ p: LngLat, accuracy: Double = 5) -> DeviceFix {
    DeviceFix(lat: p.lat, lng: p.lng, accuracy: accuracy, heading: nil, speed: 12, atMs: Date().timeIntervalSince1970 * 1000)
}

private func active(_ edit: (inout TripAutoNav.Input) -> Void = { _ in }) -> TripAutoNav.Input {
    var i = TripAutoNav.Input()
    i.status = .active
    i.destination = camp
    i.hasFix = true
    edit(&i)
    return i
}

final class TripAutoNavTargetTests: XCTestCase {
    func testNoStopsGoesToTheDestination() throws {
        let t = try XCTUnwrap(TripAutoNav.nextTarget(destination: camp, stops: [], reached: []))
        XCTAssertEqual(t.source, .destination)
        XCTAssertEqual(t.name, "مخيم النفود")
        XCTAssertEqual(t.position, LngLat(lng: camp.lng, lat: camp.lat))
    }

    func testFirstUnreachedStopThenTheDestination() throws {
        let stops = [fuel, lookout]
        XCTAssertEqual(TripAutoNav.nextTarget(destination: camp, stops: stops, reached: [])?.name, "محطة الوقود")
        XCTAssertEqual(TripAutoNav.nextTarget(destination: camp, stops: stops, reached: [])?.source, .tripStop)
        XCTAssertEqual(TripAutoNav.nextTarget(destination: camp, stops: stops, reached: [TripAutoNav.key(fuel)])?.name, "الطعس")
        /* Reached out of order (drove past the second first): the first unreached one is next. */
        XCTAssertEqual(TripAutoNav.nextTarget(destination: camp, stops: stops, reached: [TripAutoNav.key(lookout)])?.name, "محطة الوقود")
        let all = [TripAutoNav.key(fuel), TripAutoNav.key(lookout)]
        XCTAssertEqual(TripAutoNav.nextTarget(destination: camp, stops: stops, reached: all)?.source, .destination)
    }

    func testNoDestinationNoTarget() {
        XCTAssertNil(TripAutoNav.nextTarget(destination: nil, stops: [fuel], reached: []))
    }

    func testUnnamedStopGetsANumber() {
        let t = TripAutoNav.target(stop: OutingDestination(name: "", lat: 24.7, lng: 46.7), index: 1)
        XCTAssertEqual(t.name, "المحطة ٢")
    }
}

final class TripAutoNavDecisionTests: XCTestCase {
    func testStartsWhenTheTripIsActive() {
        XCTAssertEqual(TripAutoNav.decide(active()), .start(TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!))
    }

    func testNothingBeforeTheStartOrWithoutDestinationOrFix() {
        XCTAssertEqual(TripAutoNav.decide(active { $0.status = .created }), .none, "the leader has not pressed «ابدأ الطلعة»")
        XCTAssertEqual(TripAutoNav.decide(active { $0.destination = nil }), .none)
        XCTAssertEqual(TripAutoNav.decide(active { $0.hasFix = false }), .none, "waits for GPS, never routes from nowhere")
        XCTAssertEqual(TripAutoNav.decide(active { $0.enabled = false }), .none, "the setting is off on this phone")
        XCTAssertEqual(TripAutoNav.decide(active { $0.state.paused = true }), .none, "«أوقف التوجيه» on this phone")
    }

    func testAPersonsOwnNavigationIsNeverTakenOver() {
        let member = NavTarget(source: .member, name: "سلطان", position: olaya, memberId: "u2")
        XCTAssertEqual(TripAutoNav.decide(active { $0.navPhase = .guiding; $0.navAuto = false; $0.navTarget = member }), .none)
        XCTAssertEqual(TripAutoNav.decide(active { $0.navPhase = .planning; $0.navAuto = false; $0.navTarget = member }), .none)
    }

    func testRunningOnTheRightTargetIsLeftAlone() {
        let t = TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!
        XCTAssertEqual(TripAutoNav.decide(active { $0.navPhase = .guiding; $0.navAuto = true; $0.navTarget = t }), .none)
        XCTAssertEqual(TripAutoNav.decide(active { $0.navPhase = .offRoad; $0.navAuto = true; $0.navTarget = t }), .none)
        XCTAssertEqual(TripAutoNav.decide(active { $0.navPhase = .planning; $0.navAuto = true; $0.navTarget = t }), .none, "routes on the way")
    }

    func testAStopAddedUnderwayRetargets() {
        let dest = TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!
        let d = TripAutoNav.decide(active { $0.stops = [fuel]; $0.navPhase = .guiding; $0.navAuto = true; $0.navTarget = dest })
        XCTAssertEqual(d, .retarget(TripAutoNav.target(stop: fuel, index: 0)))
    }

    func testOutingEndedStopsTheTripsGuidance() {
        XCTAssertEqual(TripAutoNav.decide(active { $0.status = .ended; $0.navPhase = .guiding; $0.navAuto = true }), .stop)
        XCTAssertEqual(TripAutoNav.decide(active { $0.closed = true; $0.navPhase = .offRoad; $0.navAuto = true }), .stop)
        XCTAssertEqual(TripAutoNav.decide(active { $0.status = .ended; $0.navPhase = .guiding; $0.navAuto = false }), .none, "not ours")
    }

    func testTripArrivalFinishesOnWasaltu() {
        XCTAssertEqual(TripAutoNav.decide(active { $0.tripArrived = true; $0.navPhase = .offRoad; $0.navAuto = true }), .finish)
        XCTAssertEqual(TripAutoNav.decide(active { $0.tripArrived = true }), .none, "arrived: never starts again")
        XCTAssertEqual(TripAutoNav.decide(active { $0.state.arrived = true }), .none)
    }
}

final class TripAutoNavStopTests: XCTestCase {
    func testArrivingAtAStopAdvancesAfterTheDwell() {
        let stops = [fuel]
        let atFuel = TripAutoNav.target(stop: fuel, index: 0)
        let s = TripAutoNav.arrived(TripAutoNavState(), at: atFuel, stops: stops)
        XCTAssertEqual(s.reachedStops, [TripAutoNav.key(fuel)])
        XCTAssertFalse(s.arrived)
        func input(_ ago: Double) -> TripAutoNav.Input {
            active { $0.stops = stops; $0.state = s; $0.navPhase = .arrived; $0.navAuto = true; $0.navTarget = atFuel; $0.arrivedAgoS = ago }
        }
        XCTAssertEqual(TripAutoNav.decide(input(1)), .none, "«وصلتوا» stays a moment")
        XCTAssertEqual(TripAutoNav.decide(input(TripAutoNav.stopDwellS)), .start(TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!))
    }

    func testArrivingAtTheDestinationEndsForGood() {
        let dest = TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!
        let s = TripAutoNav.arrived(TripAutoNavState(), at: dest, stops: [])
        XCTAssertTrue(s.arrived)
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = s; $0.navPhase = .arrived; $0.navAuto = true; $0.navTarget = dest; $0.arrivedAgoS = 60 }), .none)
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = s }), .none, "after «إنهاء» on the card: nothing restarts")
    }

    func testArrivalRadiusForPassingAStop() {
        let s0 = TripAutoNavState()
        let near = LngLat(lng: fuel.lng + 0.0006, lat: fuel.lat) // ~60 m east
        let far = LngLat(lng: fuel.lng + 0.0010, lat: fuel.lat)  // ~100 m east
        XCTAssertLessThan(Vehicle.distanceMeters(near, LngLat(lng: fuel.lng, lat: fuel.lat)), TripAutoNav.stopPassM)
        XCTAssertGreaterThan(Vehicle.distanceMeters(far, LngLat(lng: fuel.lng, lat: fuel.lat)), TripAutoNav.stopPassM)
        XCTAssertEqual(TripAutoNav.passStops(s0, stops: [fuel], me: near, accuracy: 8).reachedStops, [TripAutoNav.key(fuel)])
        XCTAssertEqual(TripAutoNav.passStops(s0, stops: [fuel], me: far, accuracy: 8).reachedStops, [])
        XCTAssertEqual(TripAutoNav.passStops(s0, stops: [fuel], me: near, accuracy: 150).reachedStops, [], "a vague fix decides nothing")
        let twice = TripAutoNav.passStops(TripAutoNav.passStops(s0, stops: [fuel], me: near, accuracy: 8), stops: [fuel], me: near, accuracy: 8)
        XCTAssertEqual(twice.reachedStops.count, 1)
    }
}

final class TripAutoNavRelaunchTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "sary.tests.autonav"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testStateSurvivesARelaunchPerOuting() {
        var s = TripAutoNavState()
        s.reachedStops = [TripAutoNav.key(fuel)]
        s.save("outing-a", defaults)
        var p = TripAutoNavState()
        p.paused = true
        p.save("outing-b", defaults)
        XCTAssertEqual(TripAutoNavState.load("outing-a", defaults), s)
        XCTAssertEqual(TripAutoNavState.load("outing-b", defaults), p)
        XCTAssertEqual(TripAutoNavState.load("outing-c", defaults), TripAutoNavState())
    }

    func testRelaunchedMidTripResumesToTheNextStop() {
        var s = TripAutoNavState()
        s.reachedStops = [TripAutoNav.key(fuel)]
        s.save("o", defaults)
        let back = TripAutoNavState.load("o", defaults)
        /* iOS closed the app on the way: it opens again idle, the trip still active. */
        let d = TripAutoNav.decide(active { $0.stops = [fuel, lookout]; $0.state = back })
        XCTAssertEqual(d, .start(TripAutoNav.target(stop: lookout, index: 1)))
    }

    func testRelaunchAfterArrivalOrPauseDoesNotRestart() {
        var arrived = TripAutoNavState()
        arrived.arrived = true
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = arrived }), .none)
        var paused = TripAutoNavState()
        paused.paused = true
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = paused }), .none)
    }

    func testTheSettingIsOnByDefault() {
        XCTAssertTrue(TripAutoNavPrefs.enabled(defaults))
        TripAutoNavPrefs.set(false, defaults)
        XCTAssertFalse(TripAutoNavPrefs.enabled(defaults))
    }

    @MainActor
    func testAccountWipeForgetsIt() {
        XCTAssertTrue(LocalAccountData.keys.contains(TripAutoNavState.storeKey))
        XCTAssertTrue(LocalAccountData.keys.contains(TripAutoNavPrefs.enabledKey))
    }
}

final class TripPlanStopsTests: XCTestCase {
    func testStopsDecodeAndRoundTripOnlyWhenPresent() throws {
        let json = #"{"route":null,"notes":"","destination":{"name":"مخيم","lat":24.75,"lng":46.74},"stops":[{"name":"محطة","lat":24.72,"lng":46.69},{"name":"bad","lat":999,"lng":0}]}"#
        let p = try JSONDecoder().decode(TripPlan.self, from: Data(json.utf8))
        XCTAssertEqual(p.stops.map(\.name), ["محطة"], "an invalid point is dropped")
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any]
        XCTAssertEqual((again?["stops"] as? [Any])?.count, 1)
        let none = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TripPlan.empty)) as? [String: Any]
        XCTAssertNil(none?["stops"], "a plan without stops sends none (a server without stops sees no new field)")
        let old = try JSONDecoder().decode(TripPlan.self, from: Data(#"{"notes":"x"}"#.utf8))
        XCTAssertEqual(old.stops, [])
    }
}

// MARK: - the navigation session in automatic mode

/// A router whose answers the test scripts.
@MainActor
final class ScriptedRouter: NavRoutingProvider {
    let name = "Scripted"
    var answers: [Result<NavRoutePlan, NavRoutingError>]
    private(set) var calls = 0

    init(_ answers: [Result<NavRoutePlan, NavRoutingError>]) { self.answers = answers }

    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        calls += 1
        let a = answers.count > 1 ? answers.removeFirst() : answers[0]
        return try a.get()
    }
}

@MainActor
final class NavSessionAutoTests: XCTestCase {
    private var mutedBefore: Any?

    override func setUp() async throws {
        mutedBefore = UserDefaults.standard.object(forKey: NavVoice.muteKey)
    }

    override func tearDown() async throws {
        if let m = mutedBefore { UserDefaults.standard.set(m, forKey: NavVoice.muteKey) } else { UserDefaults.standard.removeObject(forKey: NavVoice.muteKey) }
    }

    private func road(to end: LngLat, id: String = "r1") -> NavRoute {
        let c = (0...10).map { i in LngLat(lng: olaya.lng + (end.lng - olaya.lng) * Double(i) / 10, lat: olaya.lat + (end.lat - olaya.lat) * Double(i) / 10) }
        let d = Vehicle.distanceMeters(olaya, end)
        return NavRoute(id: id, coordinates: c, distanceM: d, durationS: d / 15, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق الملك فهد", location: olaya, distanceM: d, durationS: d / 15),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: end, distanceM: 0, durationS: 0),
        ])
    }

    private func wait(_ what: String, timeout: TimeInterval = 3, _ ok: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !ok(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(ok(), what)
    }

    private var campPos: LngLat { LngLat(lng: camp.lng, lat: camp.lat) }
    private var campTarget: NavTarget { NavTarget(source: .destination, name: camp.name, position: campPos) }

    func testStartsGuidingAtOnceWithoutTheOptionsSheet() async {
        let router = ScriptedRouter([.success(NavRoutePlan(routes: [road(to: campPos)]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        var said: [String] = []
        n.voice.onSpoken = { said.append($0) }
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget, intro: TripAutoNav.intro(campTarget, resumed: false))
        XCTAssertEqual(n.phase, .planning)
        await wait("guiding") { n.phase == .guiding }
        XCTAssertTrue(n.auto)
        XCTAssertNil(n.fallback)
        XCTAssertEqual(n.active?.id, "r1")
        await wait("one clear voice line") { !said.isEmpty }
        XCTAssertEqual(said.count, 1, "one prompt, not a pile")
        XCTAssertTrue(said[0].hasPrefix("نبدأ التوجيه إلى مخيم النفود"), said[0])
        n.end()
        XCTAssertFalse(n.auto)
    }

    func testOffRoadDestinationRoadsThenBearing() async {
        /* The router snaps the desert camp to the nearest road ~4 km short of it. */
        let roadEnd = LngLat(lng: olaya.lng + (campPos.lng - olaya.lng) * 0.6, lat: olaya.lat + (campPos.lat - olaya.lat) * 0.6)
        let router = ScriptedRouter([.success(NavRoutePlan(routes: [road(to: roadEnd)]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("guiding") { n.phase == .guiding }
        let leg = n.offRoad
        XCTAssertNotNil(leg, "the straight-line last leg is known up front")
        XCTAssertEqual(leg?.from, roadEnd)
        n.handle(.arrivedAtRouteEnd)
        XCTAssertEqual(n.phase, .offRoad, "switches to bearing guidance by itself")
        XCTAssertEqual(NavOffRoad.note(fallback: n.fallback, bearing: leg?.bearing ?? 0).hasPrefix("بدون طريق معبّد: اتجه مع السهم"), true)
        var arrivedAt: NavTarget?
        n.onArrived = { arrivedAt = $0 }
        n.ingest(fix(LngLat(lng: campPos.lng + 0.0002, lat: campPos.lat)))
        XCTAssertEqual(n.phase, .arrived)
        XCTAssertEqual(arrivedAt, campTarget)
        XCTAssertEqual(n.activityLine?.text, "وصلتوا مخيم النفود")
        n.end()
    }

    func testNoRoadAtAllIsAStraightLineSaidHonestly() async {
        let router = ScriptedRouter([.failure(.noRoute)])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        var said: [String] = []
        n.voice.onSpoken = { said.append($0) }
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("off-road") { n.phase == .offRoad }
        XCTAssertEqual(n.fallback, .noRoad)
        XCTAssertTrue(n.direct)
        XCTAssertTrue(n.routes.isEmpty, "no road is drawn")
        XCTAssertNil(n.active)
        XCTAssertTrue(said.first?.contains("بدون طريق معبّد") == true, said.first ?? "-")
        n.end()
    }

    func testOfflineFallsBackAtOnceAndNeverFabricatesARoute() async {
        let router = ScriptedRouter([.failure(.offline)])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.retryInterval = 60
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("bearing guidance") { n.phase == .offRoad }
        XCTAssertEqual(n.fallback, .offline)
        XCTAssertTrue(n.routes.isEmpty)
        XCTAssertNil(n.active, "never a made-up route")
        XCTAssertEqual(n.offRoad?.to, campPos)
        XCTAssertEqual(n.offRoad?.from, olaya, "straight line from where I am")
        XCTAssertEqual(NavOffRoad.title(direct: n.direct, fallback: n.fallback), "بلا إنترنت · اتجاه مباشر")
        XCTAssertTrue(n.activityLine?.text.hasPrefix("بلا إنترنت: اتجه مع السهم") == true)
        XCTAssertEqual(n.snapshot.offRoadInstruction?.hasPrefix("بلا إنترنت") , true, "CarPlay says it too")
        /* Still offline: a retry changes nothing. */
        let stillOff = await n.retryRoute()
        XCTAssertFalse(stillOff)
        XCTAssertEqual(n.phase, .offRoad)
        n.end()
    }

    func testOfflineRetriesAndSwitchesToTheRoadWhenOnline() async {
        let router = ScriptedRouter([.failure(.offline), .failure(.offline), .success(NavRoutePlan(routes: [road(to: campPos, id: "back")]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.retryInterval = 0.05
        var said: [String] = []
        n.voice.onSpoken = { said.append($0) }
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("offline first") { n.phase == .offRoad }
        await wait("the road route once the network is back", timeout: 5) { n.phase == .guiding }
        XCTAssertEqual(n.active?.id, "back")
        XCTAssertNil(n.fallback)
        XCTAssertGreaterThanOrEqual(router.calls, 3)
        await wait("said") { said.contains { $0.hasPrefix("رجع الاتصال") } }
        n.end()
    }

    func testOfflineRetryThatFindsNoRoadStaysOnTheArrow() async {
        let router = ScriptedRouter([.failure(.offline), .failure(.noRoute)])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.retryInterval = 60
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("offline") { n.phase == .offRoad }
        let done = await n.retryRoute()
        XCTAssertTrue(done)
        XCTAssertEqual(n.phase, .offRoad)
        XCTAssertEqual(n.fallback, .noRoad)
        n.end()
    }

    func testAPersonsOwnPlanningIsNotAuto() async {
        let router = ScriptedRouter([.success(NavRoutePlan(routes: [road(to: campPos)]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("guiding") { n.phase == .guiding }
        n.plan(to: NavTarget(source: .point, name: "هنا", position: olaya))
        XCTAssertFalse(n.auto, "a tap on «ابدأ الملاحة» elsewhere is the person's navigation")
        XCTAssertEqual(n.phase, .planning)
        n.end()
    }

    func testFinishArrivalFromTheTrip() async {
        let router = ScriptedRouter([.success(NavRoutePlan(routes: [road(to: campPos)]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("guiding") { n.phase == .guiding }
        n.finishArrival()
        XCTAssertEqual(n.phase, .arrived)
        XCTAssertTrue(n.auto, "«وصلتوا» on the card")
        n.end()
    }
}

final class AutoNavActivityTests: XCTestCase {
    func testTheManoeuvreShowsOnlyWhileFresh() {
        var s = OutingActivityState(liveCount: 2, memberCount: 3, gpsOK: true, online: true, updatedAt: Date())
        s.navLine = "بعد ٥٠٠ م انعطف يمينًا"
        s.navSymbol = "arrow.turn.up.right"
        XCTAssertEqual(OutingActivityDisplay.make(s, now: Date()).navLine, "بعد ٥٠٠ م انعطف يمينًا")
        XCTAssertNil(OutingActivityDisplay.make(s, now: Date().addingTimeInterval(OutingActivityState.staleAfter + 5)).navLine, "an old picture points the wrong way")
    }

    func testANewManoeuvreIsUrgent() {
        var a = OutingActivityState(liveCount: 2, memberCount: 3, gpsOK: true, online: true, updatedAt: Date())
        a.navLine = "بعد ٥٠٠ م انعطف يمينًا"
        a.navSymbol = "arrow.turn.up.right"
        var b = a
        b.navLine = "بعد ٤٠٠ م انعطف يمينًا"
        XCTAssertFalse(OutingActivityThrottle.isUrgent(b, a), "the distance ticking is not urgent")
        b.navSymbol = "arrow.turn.up.left"
        XCTAssertTrue(OutingActivityThrottle.isUrgent(b, a))
    }
}
