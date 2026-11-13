import CoreLocation
import XCTest
@testable import SaryAlbarq

// «ابدأ الطلعة» ⇒ automatic turn-by-turn until arrival: target selection, stop advance,
// arrival radius, resume after a relaunch, off-road and offline fallbacks (never a made-up route).

private let olaya = LngLat(lng: 46.6744, lat: 24.7113)
private let camp = OutingDestination(name: "مخيم النفود", lat: 24.7590, lng: 46.7491)
private let fuel = OutingDestination(name: "محطة الوقود", lat: 24.7240, lng: 46.6960)
private let lookout = OutingDestination(name: "الطعس", lat: 24.7400, lng: 46.7200)

private extension DeviceFix {
    func with(atMs t: Double) -> DeviceFix { var f = self; f.atMs = t; return f }
}

private func fix(_ p: LngLat, accuracy: Double = 5) -> DeviceFix {
    DeviceFix(lat: p.lat, lng: p.lng, accuracy: accuracy, heading: nil, speed: 12, atMs: Date().timeIntervalSince1970 * 1000)
}

/// Guidance on for this phone (the leader's «للكل» accepted, or started by me).
private func on() -> TripAutoNavState {
    var s = TripAutoNavState()
    s.active = true
    return s
}

private func active(_ edit: (inout TripAutoNav.Input) -> Void = { _ in }) -> TripAutoNav.Input {
    var i = TripAutoNav.Input()
    i.state = on()
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
        XCTAssertEqual(TripAutoNav.decide(active { $0.state.active = false }), .none, "nobody started it for this phone: «ابدأ الطلعة» alone does not")
        XCTAssertEqual(TripAutoNav.decide(active { $0.state.paused = true }), .none, "«أوقف التوجيه» on this phone")
    }

    /// Build 21 regression: guidance on, my fix 5 minutes old → nothing happened, in silence.
    /// Now the wait is shown, and the first fresh fix starts it.
    @MainActor func testAnOldFixWaitsVisiblyThenStartsWithTheFreshOne() {
        let loc = LocationSharer()
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000
        loc.ingest(fix(olaya, accuracy: 35).with(atMs: nowMs - 300_000), nowMs: nowMs)
        XCTAssertNotNil(loc.lastFix, "the old fix is kept for the map")
        var i = active { $0.hasFix = NavFixWait.isFresh(loc.lastFix, now: now) }
        XCTAssertFalse(i.hasFix, "5 minutes old is not where I am")
        XCTAssertEqual(TripAutoNav.decide(i), .none)
        XCTAssertTrue(TripAutoNav.waitsForFix(i), "«ننتظر موقعك…» instead of silence")
        let wait = NavFixWait(pending: .auto, since: now)
        XCTAssertEqual(NavFixWait.text(accuracyM: 35, slow: wait.slow(now: now)), "ننتظر موقعك… • الدقة ±٣٥ م")
        XCTAssertEqual(NavFixWait.text(accuracyM: nil, slow: wait.slow(now: now.addingTimeInterval(46))), "ما قدرنا نحدد موقعك، اطلع لمكان مكشوف")
        /* A fresh fix: decided again, it starts. */
        loc.ingest(fix(olaya, accuracy: 8).with(atMs: nowMs + 1000), nowMs: nowMs + 1000)
        i.hasFix = NavFixWait.isFresh(loc.lastFix, now: now.addingTimeInterval(1))
        XCTAssertTrue(i.hasFix)
        XCTAssertFalse(TripAutoNav.waitsForFix(i))
        XCTAssertEqual(TripAutoNav.decide(i), .start(TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!))
    }

    func testNoWaitWhenNothingWouldStart() {
        XCTAssertFalse(TripAutoNav.waitsForFix(active { $0.hasFix = false; $0.state.paused = true }), "paused: nothing to wait for")
        XCTAssertFalse(TripAutoNav.waitsForFix(active { $0.hasFix = false; $0.state.active = false }))
        XCTAssertFalse(TripAutoNav.waitsForFix(active { $0.hasFix = false; $0.status = .created }))
    }

    func testWaitingAsksTheGpsAtItsBest() {
        XCTAssertEqual(LocationTuning.plan(.init(watching: true, urgent: true))?.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(LocationTuning.plan(.init(watching: true, urgent: true))?.distanceFilter, kCLDistanceFilterNone)
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
        let s = TripAutoNav.arrived(on(), at: atFuel, stops: stops)
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
        let s = TripAutoNav.arrived(on(), at: dest, stops: [])
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
        var s = on()
        s.reachedStops = [TripAutoNav.key(fuel)]
        s.save("o", defaults)
        let back = TripAutoNavState.load("o", defaults)
        /* iOS closed the app on the way: it opens again idle, the trip still active. */
        let d = TripAutoNav.decide(active { $0.stops = [fuel, lookout]; $0.state = back })
        XCTAssertEqual(d, .start(TripAutoNav.target(stop: lookout, index: 1)))
    }

    func testRelaunchAfterArrivalOrPauseDoesNotRestart() {
        var arrived = on()
        arrived.arrived = true
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = arrived }), .none)
        var paused = on()
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

/// «ابدأ التوجيه للكل» (the leader) / «لي فقط» / members only for themselves.
final class NavBroadcastTests: XCTestCase {
    private let owner = "u-owner", deputy = "u-deputy", member = "u-member", me = "u-me"
    private var cmd: String { NavBroadcast.text(targetName: "روضة الثمامة") }

    func testTheCommandIsANoteWithinTheLimit() {
        XCTAssertTrue(NavBroadcast.isBroadcast(cmd))
        XCTAssertEqual(NavBroadcast.targetName(cmd), "روضة الثمامة")
        XCTAssertFalse(NavBroadcast.isBroadcast("بوقف عند المحطة"))
        XCTAssertFalse(NavBroadcast.isBroadcast(RallyRecall.noteText))
        XCTAssertLessThanOrEqual(NavBroadcast.text(targetName: String(repeating: "ا", count: 200)).count, ServerRules.noteMax)
    }

    /// UI-AUDIT ١-هـ: «للكل؟» is asked only when somebody else is in the trip.
    func testAloneTheLeaderIsNotAskedForAll() {
        XCTAssertFalse(NavBroadcast.asksForAll(memberCount: 0), "no snapshot yet")
        XCTAssertFalse(NavBroadcast.asksForAll(memberCount: 1), "only me")
        XCTAssertTrue(NavBroadcast.asksForAll(memberCount: 2))
        XCTAssertTrue(NavBroadcast.asksForAll(memberCount: 9))
    }

    func testLeaderForAllStartsAMember() {
        var s = TripAutoNavState()
        let r = NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true)
        XCTAssertEqual(r, .start)
        XCTAssertTrue(s.active)
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = s }), .start(TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!))
        /* The same note again (every snapshot carries it): acted on once. */
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true), .none)
    }

    func testBroadcastFromANonLeaderIsIgnored() {
        var s = TripAutoNavState()
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: member, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true), .ignored)
        XCTAssertFalse(s.active)
        XCTAssertNil(s.broadcastAt)
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = s }), .none, "nothing starts")
        /* The deputy too, while the rule is «leader only». */
        XCTAssertFalse(NavBroadcast.deputyMayBroadcast)
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t2", senderId: deputy, ownerId: owner, senderIsDeputy: true, myId: me, autoAccept: true), .ignored)
        XCTAssertFalse(s.active)
    }

    func testMyOwnNoteIsNotACommandToMe() {
        var s = TripAutoNavState()
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: owner, autoAccept: true), .none)
        XCTAssertFalse(s.active, "the leader's «لي فقط» / «للكل» is set on his phone directly")
    }

    func testLeaderOnlyMeStartsNobodyElse() {
        /* «لي فقط» sends nothing: a member's phone sees no command and stays off. */
        let member = TripAutoNavState()
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = member }), .none)
        XCTAssertFalse(member.active)
    }

    func testMemberCannotStartForOthers() {
        XCTAssertFalse(NavBroadcast.mayBroadcast(senderId: member, ownerId: owner, senderIsDeputy: false))
        XCTAssertTrue(NavBroadcast.mayBroadcast(senderId: owner, ownerId: owner, senderIsDeputy: false))
    }

    func testSettingOffOffersInsteadOfStarting() {
        var s = TripAutoNavState()
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: false), .offer)
        XCTAssertTrue(s.offered)
        XCTAssertFalse(s.active, "one tap «ابدأ» first")
    }

    func testMemberLocalStopStaysLocalUntilANewCommand() {
        var s = TripAutoNavState()
        _ = NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true)
        s.paused = true // «أوقف التوجيه» on this phone
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = s }), .none)
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t1", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true), .none,
                       "the old command does not override my stop")
        XCTAssertTrue(s.paused)
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t2", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true), .start,
                       "«وجّه الكل» again is a new command")
        XCTAssertFalse(s.paused)
    }

    func testNoCommandAfterArrival() {
        var s = on()
        s.arrived = true
        s.active = false
        XCTAssertEqual(NavBroadcast.receive(&s, text: cmd, at: "t9", senderId: owner, ownerId: owner, senderIsDeputy: false, myId: me, autoAccept: true), .none)
        XCTAssertFalse(s.active)
    }

    func testOldSavedStateStillDecodes() throws {
        let old = #"{"reachedStops":["24.72400,46.69600"],"paused":false,"arrived":false}"#
        let s = try JSONDecoder().decode(TripAutoNavState.self, from: Data(old.utf8))
        XCTAssertEqual(s.reachedStops.count, 1)
        XCTAssertFalse(s.active)
    }

    func testLeaderSeesGuideAllInTheTripTab() {
        let items = LiveActionCatalog.tripRouteActions(.init(guideAllTarget: "روضة الثمامة"))
        XCTAssertEqual(items.first { $0.id == "guideAll" }?.title, "وجّه الكل إلى روضة الثمامة")
        XCTAssertNil(LiveActionCatalog.tripRouteActions(.init()).first { $0.id == "guideAll" }, "members: no way to start it for others")
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

/// An engine whose start takes a while (like the Mapbox one resolving its routes first).
@MainActor
final class SlowStartEngine: NavGuidanceEngine {
    var onEvent: (NavGuidanceEvent) -> Void = { _ in }
    private(set) var startCalled = false
    private(set) var startFinished = false
    private(set) var running = false

    func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws {
        startCalled = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        running = true
        startFinished = true
    }

    func stop() { running = false }
    func ingest(_ fix: DeviceFix) {}
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

    func testArbitraryPointStartsPersonalGuidanceImmediately() async {
        let point = NavTarget(source: .point, name: "نقطة برية", position: campPos)
        let router = ScriptedRouter([.success(NavRoutePlan(routes: [road(to: campPos)]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }

        n.startImmediately(to: point)

        XCTAssertEqual(n.phase, .planning)
        await wait("personal guidance starts") { n.phase == .guiding }
        XCTAssertFalse(n.auto, "a point selected on the map must not start group auto-guidance")
        XCTAssertEqual(n.target, point)
        XCTAssertEqual(n.active?.id, "r1")
    }

    func testArbitraryPointStillStartsWithHonestBearingWhenNoRouteExists() async {
        let point = NavTarget(source: .point, name: "نقطة برية", position: campPos)
        let router = ScriptedRouter([.failure(.noRoute)])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }

        n.startImmediately(to: point)

        await wait("direct guidance starts") { n.phase == .offRoad }
        XCTAssertFalse(n.auto)
        XCTAssertTrue(n.direct)
        XCTAssertEqual(n.fallback, .noRoad)
        XCTAssertEqual(n.offRoad?.from, olaya)
        XCTAssertEqual(n.offRoad?.to, campPos)
    }

    func testImmediatePointRetriesTheRoadRouteWhenConnectivityReturns() async {
        let point = NavTarget(source: .point, name: "نقطة برية", position: campPos)
        let router = ScriptedRouter([.failure(.offline), .success(NavRoutePlan(routes: [road(to: campPos)]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }

        n.startImmediately(to: point)
        await wait("temporary bearing guidance") { n.phase == .offRoad }
        XCTAssertEqual(n.fallback, .offline)

        let finished = await n.retryRoute()
        XCTAssertTrue(finished)
        XCTAssertEqual(n.phase, .guiding)
        XCTAssertFalse(n.auto)
        XCTAssertNil(n.fallback)
        XCTAssertEqual(router.calls, 2)
    }

    /// Build 36 field bug: the blue location arrow stayed after «أنهِ الطلعة». Ending a person's own
    /// guidance (a map point, offline → bearing) stops its GPS and its road-route retries for good.
    func testEndingPersonalGuidanceStopsItsGPSAndRetries() async {
        let point = NavTarget(source: .point, name: "نقطة برية", position: campPos)
        let router = ScriptedRouter([.failure(.offline)])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.retryInterval = 0.05
        n.myFix = { fix(olaya) }

        n.startImmediately(to: point)
        await wait("temporary bearing guidance") { n.phase == .offRoad }
        XCTAssertTrue(n.isLocating, "the bearing leg runs on its own location stream")

        n.end()
        XCTAssertFalse(n.isLocating)
        XCTAssertEqual(n.phase, .idle)
        let calls = router.calls
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(router.calls, calls, "no road-route retry after the end")
        XCTAssertEqual(n.phase, .idle)
        XCTAssertFalse(n.isLocating)
    }

    /// «إنهاء» while the engine is still starting (the Mapbox engine awaits before it starts its
    /// trip): the engine must not be left running behind the ended guidance.
    func testEndWhileTheEngineIsStartingLeavesNothingRunning() async {
        let engine = SlowStartEngine()
        let router = ScriptedRouter([.success(NavRoutePlan(routes: [road(to: campPos)]))])
        let n = NavSession(provider: router, makeEngine: { _ in engine })
        n.muted = true
        n.myFix = { fix(olaya) }

        n.startImmediately(to: NavTarget(source: .point, name: "نقطة", position: campPos))
        await wait("the engine is starting") { engine.startCalled }
        n.end()
        await wait("the engine finished starting", timeout: 3) { engine.startFinished }
        await wait("and was stopped again") { !engine.running }
        XCTAssertEqual(n.phase, .idle)
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
        XCTAssertEqual(NavOffRoad.note(fallback: n.fallback, bearing: leg?.bearing ?? 0).hasPrefix("مافي طريق مزفلت: كمّل مع السهم"), true)
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
        XCTAssertTrue(said.first?.contains("مافي طريق مزفلت يوصّلك للوجهة") == true, said.first ?? "-")
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
        XCTAssertEqual(NavOffRoad.title(direct: n.direct, fallback: n.fallback), "بلا إنترنت • اتجاه مباشر")
        XCTAssertTrue(n.activityLine?.text.hasPrefix("بلا إنترنت: اتجه مع السهم") == true)
        XCTAssertEqual(n.snapshot.offRoadInstruction?.hasPrefix("بلا إنترنت") , true, "CarPlay says it too")
        /* Still offline: a retry changes nothing. */
        let stillOff = await n.retryRoute()
        XCTAssertFalse(stillOff)
        XCTAssertEqual(n.phase, .offRoad)
        n.end()
    }

    /// Field report (build 23): STC 5G at 480 Mbps, yet the HUD said «بلا إنترنت». A router
    /// failure while online must never blame the user's connection.
    func testRouterFailureWhileOnlineIsNotCalledOffline() async {
        let router = ScriptedRouter([.failure(.failed("")), .success(NavRoutePlan(routes: [road(to: campPos, id: "back")]))])
        let n = NavSession(provider: router, makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.retryInterval = 60
        n.myFix = { fix(olaya) }
        n.autoStart(to: campTarget)
        await wait("bearing guidance") { n.phase == .offRoad }
        XCTAssertEqual(n.fallback, .routeFailed)
        XCTAssertNil(n.active, "never a made-up route")
        let title = NavOffRoad.title(direct: n.direct, fallback: n.fallback)
        XCTAssertEqual(title, "تعذّر حساب الطريق • اتجاه مباشر")
        XCTAssertFalse(title.contains("إنترنت"))
        XCTAssertFalse(NavOffRoad.note(fallback: n.fallback, bearing: 90).contains("إنترنت"))
        XCTAssertFalse(n.activityLine?.text.contains("إنترنت") ?? true)
        /* It keeps retrying, and switches to the road when the router answers. */
        let done = await n.retryRoute()
        XCTAssertTrue(done)
        XCTAssertEqual(n.phase, .guiding)
        XCTAssertNil(n.fallback)
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

    /// A long stretch without signal must not re-run the whole routing chain every 20 s.
    func testOfflineRetryBacksOffExponentiallyUpToFiveMinutes() {
        XCTAssertEqual(NavSession.retryDelay(attempt: 0, base: 20), 20)
        XCTAssertEqual(NavSession.retryDelay(attempt: 1, base: 20), 40)
        XCTAssertEqual(NavSession.retryDelay(attempt: 2, base: 20), 80)
        XCTAssertEqual(NavSession.retryDelay(attempt: 4, base: 20), 300, "capped at five minutes")
        XCTAssertEqual(NavSession.retryDelay(attempt: 1_000, base: 20), 300)
        XCTAssertEqual(NavSession.retryDelay(attempt: 3, base: 600), 600, "a longer configured interval is kept")
        XCTAssertEqual(NavSession.retryDelay(attempt: 1, base: 0.05), 0.1, accuracy: 1e-9)
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

/// «طريق الرجعة» (owner): in the desert the return follows EXACTLY the outbound trail; in the
/// city the fastest road. The outbound trail is cut at its city ↔ desert junction; the desert
/// part is retraced to the junction (`BackTrack`), then the trip's road guidance takes over.
final class ReturnTripHybridTests: XCTestCase {
    /// 41 points, 100 m apart, due north from the city (index 0) to the desert camp (index 40).
    private let home = LngLat(lng: 46.70, lat: 24.90)
    private func at(_ northM: Double, _ eastM: Double = 0) -> LngLat { TrailGeo.lngLat(eastM, northM, ref: home) }
    private var outbound: [TrailPoint] {
        (0...40).map { i in let p = at(Double(i) * 100); return TrailPoint(lat: p.lat, lng: p.lng, t: 1_800_000_000_000 + Double(i) * 10_000) }
    }
    private let noRegion: (LngLat) -> String? = { _ in nil }

    private func span(_ pts: [TrailPoint], _ r: ClosedRange<Int>) -> MatchedSpan {
        let piece = MatchedPiece(first: r.lowerBound, last: r.upperBound, coords: r.map { pts[$0].position },
                                 anchors: r.map { (t: pts[$0].t, index: $0 - r.lowerBound) }, confidence: 0.9)
        return MatchedSpan(piece: piece)
    }

    // MARK: the split

    func testSavedRoadEndCutsTheTrailAtTheNearestPoint() {
        let pts = outbound
        let s = ReturnRoute.split(pts, saved: at(2_000, 60), match: nil, region: noRegion)
        XCTAssertEqual(s, ReturnRoute.Split(junction: 20, source: .savedRoute))
        let leg = ReturnRoute.desertLeg(pts, split: s)
        XCTAssertEqual(leg.count, 21)
        XCTAssertEqual(leg.first?.position, pts[20].position)
        XCTAssertEqual(leg.last?.position, pts[40].position)
    }

    func testSavedRoadEndOffTheTrailIsNotTrusted() {
        /* The driver left the road somewhere else than the route said: the next source decides. */
        let s = ReturnRoute.split(outbound, saved: at(2_000, 1_000), match: nil, region: noRegion)
        XCTAssertEqual(s, ReturnRoute.Split(junction: 0, source: .none))
    }

    func testRoadMatcherFallbackEndsAtTheLastLongMatchedStretch() {
        let pts = outbound
        var cache = TrailMatchCache()
        cache.spans = [span(pts, 0...20), span(pts, 30...31)]
        cache.doneUpToT = pts.last!.t
        let s = ReturnRoute.split(pts, saved: nil, match: cache, region: noRegion)
        XCTAssertEqual(s, ReturnRoute.Split(junction: 20, source: .roadMatch), "a 100 m match in the desert is not the road network")
        /* The matcher never looked at the end of the trail: what it did not match says nothing. */
        cache.doneUpToT = pts[25].t
        XCTAssertEqual(ReturnRoute.split(pts, saved: nil, match: cache, region: noRegion).source, .none)
    }

    func testDesertRegionFallbackCutsWhereTheTrailEnteredIt() {
        let pts = outbound
        let edge = pts[25].lat - 1e-6
        let s = ReturnRoute.split(pts, saved: nil, match: TrailMatchCache(), region: { $0.lat > edge ? "thumamah" : nil })
        XCTAssertEqual(s, ReturnRoute.Split(junction: 25, source: .desertRegion))
        /* The whole trail inside the region: nothing tells the city from the desert. */
        XCTAssertEqual(ReturnRoute.split(pts, saved: nil, match: nil, region: { _ in "thumamah" }).source, .none)
    }

    func testNothingKnownRetracesTheWholeTrail() {
        let pts = outbound
        let s = ReturnRoute.split(pts, saved: nil, match: nil, region: noRegion)
        XCTAssertEqual(s, ReturnRoute.Split(junction: 0, source: .none))
        XCTAssertEqual(ReturnRoute.desertLeg(pts, split: s).map(\.position), pts.map(\.position))
        XCTAssertEqual(ReturnRoute.start(trail: pts, split: s, me: pts[40].position), .desertTrail(ReturnRoute.desertLeg(pts, split: s)))
        XCTAssertEqual(ReturnRoute.split([], saved: nil, match: nil, region: noRegion).junction, 0)
    }

    func testRoadEndOfARoute() {
        let a = at(0), b = at(1_000), c = at(2_000)
        let paved = NavRoute(id: "mapbox-0", coordinates: [a, b, c], distanceM: 2_000, durationS: 120, steps: [])
        XCTAssertEqual(ReturnRoute.roadEnd(of: paved), c, "all paved: its end")
        var dirt = paved
        dirt.surfaceRuns = [NavSurfaceRun(kind: .paved, coordinates: [a, b]), NavSurfaceRun(kind: .unpaved, coordinates: [b, c])]
        XCTAssertEqual(ReturnRoute.roadEnd(of: dirt), b, "where the paved road ends")
        let desert = NavRoute(id: "desert-desert-easy", coordinates: [b, c], distanceM: 1_000, durationS: 300, steps: [])
        XCTAssertNil(ReturnRoute.roadEnd(of: desert), "a pure desert-grid route has no road part")
        var hybrid = desert
        hybrid.id = "mapbox-0-desert-easy"
        hybrid.roadEnd = b
        XCTAssertEqual(ReturnRoute.roadEnd(of: hybrid), b)
    }

    func testJunctionStoreRoundTripAndAccountWipe() {
        let d = UserDefaults(suiteName: "junction-\(UUID().uuidString)")!
        XCTAssertNil(OutboundJunctionStore.load("o1", defaults: d))
        OutboundJunctionStore.save("o1", at(2_000), defaults: d)
        let p = OutboundJunctionStore.load("o1", defaults: d)
        XCTAssertLessThan(Vehicle.distanceMeters(p ?? home, at(2_000)), 0.5)
        OutboundJunctionStore.forgetAll(defaults: d)
        XCTAssertNil(OutboundJunctionStore.load("o1", defaults: d))
    }

    @MainActor
    func testAccountWipeForgetsTheJunctions() {
        XCTAssertTrue(LocalAccountData.keys.contains(OutboundJunctionStore.key))
    }

    // MARK: where the return starts

    func testFromTheDesertRetracesOnlyTheDesertPartBackToTheJunction() throws {
        let pts = outbound
        let s = ReturnRoute.Split(junction: 20, source: .savedRoute)
        guard case let .desertTrail(leg) = ReturnRoute.start(trail: pts, split: s, me: at(4_000, 20)) else { return XCTFail("desert leg expected") }
        /* `BackTrack` guides to its path's FIRST point: the junction, not the old start. */
        var bt = try XCTUnwrap(BackTrack(path: leg))
        XCTAssertEqual(bt.startPoint, pts[20].position)
        let far = bt.update(at(4_000, 20))
        XCTAssertFalse(far.arrived)
        XCTAssertEqual(far.remainingM, 2_020, accuracy: 15)
        /* Off the trail in the desert: led back to the SAME trail. */
        let off = bt.update(at(3_000, 200))
        XCTAssertTrue(off.offTrack)
        XCTAssertLessThan(Vehicle.distanceMeters(off.nearest, at(3_000)), 5)
        XCTAssertTrue(bt.update(at(2_010)).arrived)
    }

    func testCitySideJunctionOrFarFromTheTrailIsTheNormalRoad() {
        let pts = outbound
        let s = ReturnRoute.Split(junction: 20, source: .roadMatch)
        XCTAssertEqual(ReturnRoute.start(trail: pts, split: s, me: at(1_000, 30)), .road, "the city part: fastest road")
        XCTAssertEqual(ReturnRoute.start(trail: pts, split: s, me: at(2_010)), .road, "at the junction")
        XCTAssertEqual(ReturnRoute.start(trail: pts, split: s, me: at(3_500, 8_000)), .road, "nowhere near the old trail")
        XCTAssertEqual(ReturnRoute.start(trail: pts, split: ReturnRoute.Split(junction: 40, source: .roadMatch), me: at(4_000)), .road,
                       "a trail that never left the road")
    }

    // MARK: the hand-over

    func testArrivalAtTheJunctionHandsOverToTheRoadGuidance() throws {
        let pts = outbound
        let s = ReturnRoute.Split(junction: 20, source: .savedRoute)
        var guide = ReturnGuide()
        XCTAssertFalse(guide.holdsRoadGuidance)
        let start = ReturnRoute.start(trail: pts, split: s, me: at(4_000))
        guide.begin(start)
        XCTAssertEqual(guide.phase, .desert)
        XCTAssertTrue(guide.holdsRoadGuidance, "no new desert route while the trail is retraced")
        guide.begin(.road)
        XCTAssertEqual(guide.phase, .desert, "decided once")

        var bt = try XCTUnwrap(BackTrack(path: ReturnRoute.desertLeg(pts, split: s)))
        XCTAssertFalse(guide.backTrackUpdate(bt.update(at(3_000))))
        XCTAssertTrue(guide.holdsRoadGuidance)
        XCTAssertTrue(guide.backTrackUpdate(bt.update(at(2_005))), "the junction reached: hand over")
        XCTAssertEqual(guide.phase, .road)
        XCTAssertFalse(guide.holdsRoadGuidance)
        XCTAssertFalse(guide.backTrackUpdate(bt.update(at(2_005))), "once")
        /* The trip's own guidance now starts the road leg to the return trip's destination. */
        let startPoint = OutingDestination(name: "نقطة البداية", lat: home.lat, lng: home.lng)
        guard case let .start(t) = TripAutoNav.decide(active { $0.destination = startPoint }) else { return XCTFail("road guidance expected") }
        XCTAssertEqual(t.source, .destination)
        XCTAssertEqual(t.position, home)
    }

    func testStoppingTheDesertLegOrStartingInTheCityIsTheRoad() {
        var g = ReturnGuide()
        g.begin(.road)
        XCTAssertEqual(g.phase, .road)
        var d = ReturnGuide()
        d.begin(.desertTrail(outbound))
        d.cancel()
        XCTAssertEqual(d.phase, .road)
        XCTAssertFalse(d.holdsRoadGuidance)
    }
}

/// Build 36 (owner's report item 10): «أوقف التوجيه» stops guidance and nothing else — it never
/// arrives, and nothing starts again by itself afterwards.
final class TripAutoNavStopGuidanceTests: XCTestCase {
    func testStoppingTheTripsGuidancePausesIt() {
        XCTAssertTrue(TripAutoNav.stopPausesTrip(on(), navAuto: true, navPhase: .guiding))
        XCTAssertTrue(TripAutoNav.stopPausesTrip(on(), navAuto: true, navPhase: .offRoad))
        XCTAssertFalse(TripAutoNav.stopPausesTrip(on(), navAuto: true, navPhase: .arrived), "closing «وصلتوا» is not a pause")
        XCTAssertFalse(TripAutoNav.stopPausesTrip(on(), navAuto: false, navPhase: .idle))
    }

    func testStoppingMyOwnGuidanceDoesNotRestartTheTripsByItself() {
        /* «اتجه» to a station while the trip's guidance is on, then «أوقف التوجيه». */
        XCTAssertTrue(TripAutoNav.stopPausesTrip(on(), navAuto: false, navPhase: .guiding))
        var paused = on()
        paused.paused = true
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = paused }), .none, "paused: nothing starts by itself")
        /* Without the pause the trip's guidance would have come straight back — the bug. */
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = on() }), .start(TripAutoNav.nextTarget(destination: camp, stops: [], reached: [])!))
        /* No trip guidance on this phone: a person's own stop has nothing to pause. */
        XCTAssertFalse(TripAutoNav.stopPausesTrip(TripAutoNavState(), navAuto: false, navPhase: .guiding))
        var arrived = on()
        arrived.arrived = true
        XCTAssertFalse(TripAutoNav.stopPausesTrip(arrived, navAuto: false, navPhase: .guiding))
    }

    func testAPauseIsNeverAnArrival() {
        var s = on()
        s.paused = true
        XCTAssertFalse(s.arrived)
        XCTAssertEqual(TripAutoNav.decide(active { $0.state = s; $0.navPhase = .guiding; $0.navAuto = true; $0.navTarget = TripAutoNav.nextTarget(destination: camp, stops: [], reached: []) }), .none)
    }
}

/// Build 36 (owner's report item 5): the banner, the remaining distance and the time left always
/// describe the same route and the same, latest position.
@MainActor
final class NavSessionSyncTests: XCTestCase {
    private var campPos: LngLat { LngLat(lng: camp.lng, lat: camp.lat) }

    private func road(from a: LngLat, to end: LngLat, id: String, turnAt: Double = 0.5) -> NavRoute {
        let c = (0...10).map { i in LngLat(lng: a.lng + (end.lng - a.lng) * Double(i) / 10, lat: a.lat + (end.lat - a.lat) * Double(i) / 10) }
        let d = Vehicle.distanceMeters(a, end)
        let k = c[Int(turnAt * 10)]
        return NavRoute(id: id, coordinates: c, distanceM: d, durationS: d / 15, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "العليا", location: a, distanceM: d * turnAt, durationS: d * turnAt / 15),
            NavStep(maneuver: .init(kind: .turn, direction: .right), roadName: "التخصصي", location: k, distanceM: d * (1 - turnAt), durationS: d * (1 - turnAt) / 15),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: end, distanceM: 0, durationS: 0),
        ])
    }

    private func guiding(_ r: NavRoute) async -> NavSession {
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [r]))]), makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { fix(olaya) }
        n.autoStart(to: NavTarget(source: .destination, name: camp.name, position: campPos))
        let end = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.phase, .guiding)
        return n
    }

    func testAnOlderFixNeverMovesTheGuidanceBack() async {
        let r = road(from: olaya, to: campPos, id: "a")
        let n = await guiding(r)
        let t = Date().timeIntervalSince1970 * 1000 + 10_000
        let ahead = r.coordinates[4], behind = r.coordinates[2]
        n.ingest(fix(ahead).with(atMs: t))
        let p = n.progress
        XCTAssertNotNil(p)
        /* The app's own stream re-sends an older fix after our locator's newer one. */
        n.ingest(fix(behind).with(atMs: t - 1_000))
        XCTAssertEqual(n.progress, p, "the remaining distance never jumps back up")
        n.ingest(fix(ahead).with(atMs: t))
        XCTAssertEqual(n.progress, p, "the same fix twice changes nothing")
        n.ingest(fix(r.coordinates[5]).with(atMs: t + 1_000))
        XCTAssertLessThan(n.progress?.distanceRemainingM ?? .infinity, p?.distanceRemainingM ?? 0, "a newer fix steers")
        n.end()
    }

    func testNewerFixRule() {
        let a = fix(olaya).with(atMs: 1_000)
        XCTAssertTrue(NavSession.isNewer(a, than: nil))
        XCTAssertTrue(NavSession.isNewer(a.with(atMs: 1_001), than: a))
        XCTAssertFalse(NavSession.isNewer(a.with(atMs: 999), than: a))
        XCTAssertFalse(NavSession.isNewer(a, than: a))
        XCTAssertTrue(NavSession.isNewer(fix(campPos).with(atMs: 1_000), than: a), "same millisecond, another place")
    }

    func testOffRouteKeepsReroutingUntilTheNewRouteAndNeverShowsTheOldRoutesTurn() async {
        let r = road(from: olaya, to: campPos, id: "a")
        let n = await guiding(r)
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 300, distanceRemainingM: 4_000, durationRemainingS: 300)))
        n.handle(.offRoute)
        XCTAssertTrue(n.rerouting)
        /* The engine still measures against the abandoned route: its distance grows. */
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 420, distanceRemainingM: 4_120, durationRemainingS: 310)))
        XCTAssertTrue(n.rerouting, "«نعيد حساب الطريق…» stays until the new route")
        XCTAssertEqual(n.progress?.distanceToManeuverM, 300, "the old route's growing numbers are not shown")
        /* The new route starts where I am: a different turn, nothing like the old one. */
        let from = LngLat(lng: olaya.lng + 0.003, lat: olaya.lat - 0.002)
        let new = road(from: from, to: campPos, id: "b", turnAt: 0.3)
        n.handle(.rerouted(new))
        XCTAssertFalse(n.rerouting)
        XCTAssertNil(n.shownProgress, "the old route's step index is not read against the new route")
        XCTAssertEqual(n.currentStep, new.steps[1])
        XCTAssertEqual(n.maneuverDistanceM ?? 0, new.steps[0].distanceM, accuracy: 0.5, "up to the first turn, not the step after it")
        XCTAssertEqual(n.remainingMeters ?? 0, new.distanceM + (n.offRoad?.distanceM ?? 0), accuracy: 1, "the new route's distance")
        XCTAssertEqual(n.remainingSeconds ?? 0, new.durationS, accuracy: 1)
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 250, distanceRemainingM: 3_500, durationRemainingS: 260)))
        XCTAssertEqual(n.shownProgress?.distanceToManeuverM, 250)
        XCTAssertEqual(n.remainingSeconds ?? 0, 260, accuracy: 2, "the new route's time at once (no blend with the old one)")
        n.end()
    }

    func testATrafficRefreshOfTheSameRouteKeepsItsProgress() async {
        let r = road(from: olaya, to: campPos, id: "a")
        let n = await guiding(r)
        n.handle(.progress(NavProgress(stepIndex: 2, distanceToManeuverM: 800, distanceRemainingM: 800, durationRemainingS: 60)))
        var refreshed = r
        refreshed.id = "a2"
        refreshed.durationS += 30
        n.handle(.rerouted(refreshed))
        XCTAssertEqual(n.shownProgress?.stepIndex, 2, "same road, fresh traffic: still the same turn")
        XCTAssertEqual(n.currentStep, refreshed.steps[2])
        n.end()
    }

    func testBeforeTheFirstProgressTheBannerDistanceIsToTheFirstTurn() async {
        let r = road(from: olaya, to: campPos, id: "a", turnAt: 0.3)
        let n = await guiding(r)
        XCTAssertNil(n.shownProgress)
        XCTAssertEqual(n.currentStep, r.steps[1])
        XCTAssertEqual(n.maneuverDistanceM ?? 0, r.steps[0].distanceM, accuracy: 0.5)
        XCTAssertNotEqual(n.maneuverDistanceM ?? 0, r.steps[1].distanceM, accuracy: 1)
        n.end()
    }
}
