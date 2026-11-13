import MapboxDirections
import XCTest
@testable import SaryAlbarq

/// Build 49, «أبي يكون فيه خيارين، خيار للسيارة وخيار للمشي»: the mode, the request each provider
/// gets, the walking time, the off-route tolerance on foot, and the walking wording.
final class TravelModeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "travelmode.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func request(_ o: NavRouteOptions) -> NavRouteRequest {
        NavRouteRequest(origin: LngLat(lng: 46.68, lat: 24.70), heading: 10,
                        target: NavTarget(source: .point, name: "هنا", position: LngLat(lng: 46.695, lat: 24.71)), options: o)
    }

    // MARK: the mode and its memory

    func testCarIsTheDefaultAndTheChoiceIsRemembered() {
        let d = defaults()
        XCTAssertEqual(TravelMode.load(d), .car, "nothing saved: car")
        XCTAssertEqual(NavRouteOptions.load(d).mode, .car)
        var o = NavRouteOptions.load(d)
        o.mode = .walk
        o.save(d)
        XCTAssertEqual(TravelMode.load(d), .walk)
        XCTAssertEqual(NavRouteOptions.load(d).mode, .walk, "the next session starts on foot")
        o.mode = .car
        o.save(d)
        XCTAssertEqual(NavRouteOptions.load(d).mode, .car)
        d.set("hovercraft", forKey: TravelMode.defaultsKey)
        XCTAssertEqual(TravelMode.load(d), .car, "an unknown value is the default")
    }

    func testTheStoredFlagsKeepTheirShape() {
        let d = defaults()
        var o = NavRouteOptions(fastest: false, avoidUnpaved: true, avoidTolls: false, mode: .walk)
        o.save(d)
        XCTAssertEqual(d.array(forKey: NavRouteOptions.defaultsKey) as? [Bool], [false, true, false], "older builds read the same array")
        let back = NavRouteOptions.load(d)
        XCTAssertEqual(back.fastest, false)
        XCTAssertEqual(back.avoidUnpaved, true)
    }

    func testTheKeyIsAnAccountKey() {
        XCTAssertTrue(TravelMode.defaultsKey.hasPrefix("sary."), "wiped with the account like every other sary. key")
    }

    // MARK: mode → request

    func testSpecCarIsUnchangedAndWalkingDropsTheCarOptions() {
        let car = NavRouteSpec.from(.init(fastest: true, avoidUnpaved: true, avoidTolls: false))
        XCTAssertEqual(car.profile, .drivingTraffic)
        XCTAssertEqual(car.exclude, ["unpaved"])
        let walk = NavRouteSpec.from(.init(fastest: true, avoidUnpaved: true, avoidTolls: true, mode: .walk))
        XCTAssertEqual(walk.profile, .walking)
        XCTAssertEqual(walk.profile.rawValue, "walking")
        XCTAssertEqual(walk.exclude, [], "unpaved / toll exclusions are car-only")
        XCTAssertTrue(walk.alternatives)
        XCTAssertEqual(walk.language, "ar")
    }

    func testMapboxProfile() {
        let car = MapboxNavRoutingProvider.options(request(.init()))
        XCTAssertEqual(car.profileIdentifier, .automobileAvoidingTraffic)
        let walk = MapboxNavRoutingProvider.options(request(.init(avoidUnpaved: true, mode: .walk)))
        XCTAssertEqual(walk.profileIdentifier, .walking)
        XCTAssertEqual(walk.roadClassesToAvoid, [], "no dirt-road exclusion on foot")
        XCTAssertNotNil(walk.waypoints.first?.heading, "the course is still sent")
    }

    func testValhallaBody() throws {
        let car = FarqValhallaRouteProvider.body(request(.init(avoidUnpaved: true)))
        XCTAssertEqual(car["costing"] as? String, "auto", "the car request keeps its shape")
        let co = try XCTUnwrap(car["options"] as? [String: Any])
        XCTAssertEqual(Set(co.keys), ["avoid_unpaved", "avoid_tolls", "avoid_highways", "use_tracks"])
        let walk = FarqValhallaRouteProvider.body(request(.init(avoidUnpaved: true, mode: .walk)))
        XCTAssertEqual(walk["costing"] as? String, "pedestrian")
        let wo = try XCTUnwrap(walk["options"] as? [String: Any])
        XCTAssertEqual(Set(wo.keys), ["walking_speed", "use_hills"])
        XCTAssertEqual(try XCTUnwrap(wo["walking_speed"] as? Double), 4.5, accuracy: 0.001)
    }

    // MARK: walking time

    func testFlatSpeedIsFourPointFiveKmh() {
        XCTAssertEqual(WalkPace.flatMps * 3.6, 4.5, accuracy: 1e-9)
        XCTAssertEqual(WalkPace.duration(distanceM: 4_500), 3_600, accuracy: 1e-6)
        XCTAssertEqual(WalkPace.speed(slope: 0), WalkPace.flatMps, accuracy: 0.01)
    }

    func testSlopeSlowsTheWalker() {
        let flat = WalkPace.speed(slope: 0)
        XCTAssertLessThan(WalkPace.speed(slope: 0.10), flat * 0.75, "10 % uphill is much slower")
        XCTAssertLessThan(WalkPace.speed(slope: 0.30), WalkPace.speed(slope: 0.10))
        XCTAssertGreaterThan(WalkPace.speed(slope: -0.05), WalkPace.speed(slope: -0.35), "a gentle descent beats a steep one")
        XCTAssertLessThan(WalkPace.speed(slope: -0.35), flat, "a steep descent is slower than flat")
        XCTAssertGreaterThanOrEqual(WalkPace.speed(slope: 5), WalkPace.minMps)
        XCTAssertEqual(WalkPace.speed(slope: .nan), flat, accuracy: 0.01)
    }

    func testPathTimeFollowsTheTerrain() {
        let a = LngLat(lng: 46.0, lat: 24.0)
        let b = LngLat(lng: 46.0, lat: 24.0 + 1_000 / 110_540.0)
        let flat = WalkPace.duration(points: [a, b]) { _ in 600 }
        XCTAssertEqual(flat, 1_000 / WalkPace.flatMps, accuracy: 15)
        let up = WalkPace.duration(points: [a, b]) { $0 == a ? 600 : 700 }
        XCTAssertGreaterThan(up, flat * 1.3, "100 m of climb over 1 km")
        let unknown = WalkPace.duration(points: [a, b]) { _ in nil }
        XCTAssertEqual(unknown, flat, accuracy: 15, "no elevation: flat")
        XCTAssertEqual(WalkPace.duration(points: [a]) { _ in 0 }, 0)
    }

    private func carRoute(id: String = "mapbox-0") -> NavRoute {
        let a = LngLat(lng: 46.68, lat: 24.70), b = LngLat(lng: 46.69, lat: 24.70)
        return NavRoute(id: id, coordinates: [a, b], distanceM: 1_000, durationS: 60, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق الملك فهد", location: a, distanceM: 1_000, durationS: 60,
                    lanes: [NavLane(directions: [.straight], valid: true)], speedLimitKmh: 80),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: b, distanceM: 0, durationS: 0),
        ], timingProfile: [NavRouteTimingLeg(distanceM: 1_000, durationS: 60)])
    }

    func testARoadRouteIsRetimedToWalkingPace() {
        let r = WalkPace.retimed(carRoute())
        XCTAssertEqual(r.durationS, 1_000 / WalkPace.flatMps, accuracy: 1e-6)
        XCTAssertEqual(r.steps[0].durationS, r.durationS, accuracy: 1e-6, "the steps keep adding up")
        XCTAssertEqual(r.timingProfile?.first?.durationS ?? 0, r.durationS, accuracy: 1e-6)
        XCTAssertTrue(r.steps[0].lanes.isEmpty, "no lanes on foot")
        XCTAssertNil(r.steps[0].speedLimitKmh, "no posted limit on foot")
        XCTAssertEqual(r.distanceM, 1_000)
    }

    func testADesertRouteKeepsItsSlopeAwareTime() {
        var d = carRoute(id: "mapbox-0-desert-sand")
        d.durationS = 4_321
        XCTAssertEqual(WalkPace.retimed(d).durationS, 4_321, "already timed on the raster")
        XCTAssertTrue(WalkPace.retimed(d).steps[0].lanes.isEmpty)
    }

    func testTimeLeftIsProRata() {
        var r = carRoute()
        r.durationS = 800
        XCTAssertEqual(WalkPace.remaining(route: r, remainingM: 250), 200, accuracy: 1e-9)
        XCTAssertEqual(WalkPace.remaining(route: r, remainingM: 5_000), 800, "never more than the whole")
    }

    @MainActor
    func testTheProviderWrapperTouchesOnlyWalking() async throws {
        let stub = ScriptedRouter([.success(NavRoutePlan(routes: [carRoute()]))])
        let p = TravelModeRouteProvider(stub)
        XCTAssertEqual(p.name, "Scripted")
        let car = try await p.routes(request(.init()))
        XCTAssertEqual(car.routes[0].durationS, 60, "car: as the router said")
        XCTAssertEqual(car.routes[0].steps[0].lanes.count, 1)
        let walk = try await p.routes(request(.init(mode: .walk)))
        XCTAssertEqual(walk.routes[0].durationS, 1_000 / WalkPace.flatMps, accuracy: 1e-6)
        XCTAssertEqual(stub.calls, 2)
    }

    // MARK: off-route on foot

    private let road = RouteLine(RouteAdherenceTests.northRoad(km: 5))

    func testWalkingDoesNotApplyTheWrongWayRule() {
        var car = RouteAdherence()
        var walk = RouteAdherence(tuning: .walk)
        var carOff = false
        for i in 0 ..< 12 {
            /* Heading south on the route's line, 10 m beside it. */
            let f = RouteAdherenceTests.fix(i, offsetM: 10, heading: 180, speed: 8)
            if car.note(f, on: road) == .off { carOff = true }
            XCTAssertNil(walk.note(f, on: road))
        }
        XCTAssertTrue(carOff, "a car going against the traffic is flagged")
        XCTAssertEqual(walk.state, .on, "a walker may go either way along a path")
    }

    func testAWalkerStillAtTwoMetresPerSecondIsMeasuredButACarCrawlIsNot() {
        var car = RouteAdherence()
        var walk = RouteAdherence(tuning: .walk)
        for i in 0 ..< 14 {
            let f = RouteAdherenceTests.fix(i, offsetM: 45, speed: 1.3)
            car.note(f, on: road)
            walk.note(f, on: road)
        }
        XCTAssertEqual(car.state, .on, "under 2 m/s a car says nothing")
        XCTAssertEqual(walk.state, .off, "a walker 45 m off the path for 10+ s is lost")
    }

    func testWalkingNeedsSustainedDeviationAndAWiderLane() {
        var walk = RouteAdherence(tuning: .walk)
        /* 25 m (a wide pavement, a cut corner, GPS between buildings): still on the route. */
        for i in 0 ..< 30 { XCTAssertNil(walk.note(RouteAdherenceTests.fix(i, offsetM: 25, speed: 1.3), on: road)) }
        XCTAssertEqual(walk.state, .on)
        XCTAssertEqual(walk.toleranceM(accuracy: 6), 30)
        XCTAssertLessThan(RouteAdherence().toleranceM(accuracy: 6), walk.toleranceM(accuracy: 6))
        /* 45 m: not off after a few fixes, off only after ~10 s. */
        var lost = RouteAdherence(tuning: .walk)
        var offAt: Int?
        for i in 0 ..< 20 where offAt == nil { if lost.note(RouteAdherenceTests.fix(i, offsetM: 45, speed: 1.3), on: road) == .off { offAt = i } }
        let at = try! XCTUnwrap(offAt)
        XCTAssertGreaterThanOrEqual(at, 10, "sustained: ten seconds")
        XCTAssertLessThanOrEqual(at, 12)
        /* One noisy fix is nothing. */
        var noisy = RouteAdherence(tuning: .walk)
        for i in 0 ..< 20 { noisy.note(RouteAdherenceTests.fix(i, offsetM: i == 9 ? 80 : 3, speed: 1.3), on: road) }
        XCTAssertEqual(noisy.state, .on)
    }

    func testTheTuningSurvivesAReset() {
        var a = RouteAdherence(tuning: .walk)
        a.reset(allowanceM: 5)
        XCTAssertEqual(a.tuning, .walk)
        a.reset(allowanceM: 0, tuning: .car)
        XCTAssertEqual(a.tuning, .car)
        XCTAssertEqual(RouteAdherence.Tuning.for(.walk), .walk)
        XCTAssertEqual(RouteAdherence.Tuning.for(.car), .car)
        XCTAssertEqual(RouteAdherence.Tuning.car.minSpeedMps, RouteAdherence.minSpeedMps, "the car numbers are the old ones")
        XCTAssertEqual(RouteAdherence.Tuning.car.wrongWayMinSpeedMps, RouteAdherence.wrongWayMinSpeedMps)
    }

    // MARK: wording and timing

    private func turn(_ d: NavTurnDirection = .right, road: String? = "شارع التحلية") -> NavStep {
        NavStep(maneuver: .init(kind: .turn, direction: d), roadName: road, location: LngLat(lng: 46.7, lat: 24.7), distanceM: 100, durationS: 80)
    }

    func testMetresAreSaidOftenAndFinely() {
        XCTAssertEqual(WalkWording.spokenInDistance(30), "بعد ٣٠ متر")
        XCTAssertEqual(WalkWording.spokenInDistance(47), "بعد ٤٥ متر")
        XCTAssertEqual(WalkWording.spokenInDistance(133), "بعد ١٣٠ متر")
        XCTAssertEqual(WalkWording.spokenInDistance(730), "بعد ٧٠٠ متر", "metres until a kilometre")
        XCTAssertEqual(WalkWording.spokenInDistance(13), "بعد ١٠ متر")
        XCTAssertNil(WalkWording.spokenInDistance(8), "right here: the action alone")
        XCTAssertTrue(WalkWording.spokenInDistance(1_240)?.hasSuffix("كيلومتر") == true)
        XCTAssertEqual(WalkWording.banner(30), "بعد ٣٠ م")
        /* Floors, never rounds up. */
        for m in stride(from: 12.0, to: 999, by: 3) { XCTAssertLessThanOrEqual(WalkWording.flooredMeters(m), m) }
        /* The car's own voice says nothing under 30 m and rounds to 50 m from 100: this is finer. */
        XCTAssertNil(NavText.spokenInDistance(20))
        XCTAssertNotNil(WalkWording.spokenInDistance(20))
    }

    func testTheWalkingLineHasNoRoadNameAndNoCarWords() {
        XCTAssertEqual(WalkWording.spoken(turn(), distanceM: 30), "بعد ٣٠ متر، انعطف يمينًا")
        XCTAssertFalse(WalkWording.spoken(turn(), distanceM: 30).contains("التحلية"))
        XCTAssertTrue(NavText.spoken(turn(), distanceM: 30).contains("التحلية"), "the car line keeps its road name")
        XCTAssertEqual(WalkWording.spoken(turn(.left), distanceM: 0), "انعطف يسارًا")
        for kind in [NavManeuverKind.onRamp, .offRamp, .merge, .useLane, .fork] {
            let a = WalkWording.action(.init(kind: kind, direction: .right))
            XCTAssertFalse(a.contains("المنحدر") || a.contains("اندمج") || a.contains("مسار"), "\(kind): \(a)")
        }
        XCTAssertEqual(WalkWording.action(.init(kind: .depart, direction: nil)), "ابدأ المشي")
        let arrive = NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: LngLat(lng: 46.7, lat: 24.7), distanceM: 0, durationS: 0)
        XCTAssertEqual(WalkWording.spoken(arrive, distanceM: 5, targetName: "المخيم"), "وصلت إلى المخيم")
        XCTAssertEqual(WalkWording.spoken(arrive, distanceM: 60, targetName: "المخيم"), "بعد ٦٠ متر تصل إلى المخيم")
        XCTAssertTrue(WalkWording.etaText(arrival: Date(), remainingS: 1_800).hasSuffix("مشيًا"))
        XCTAssertFalse(WalkWording.phrasesNeedingClips.isEmpty)
    }

    func testPromptStagesAndTimingOnFoot() {
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 30, speedMps: 1.3, mode: .walk), .final)
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 150, speedMps: 1.3, mode: .walk), .early)
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 150, speedMps: 1.3), .final, "the car's rule is unchanged (≤ 200 m)")
        let band = NavPromptTiming.band(.device, mode: .walk)
        XCTAssertEqual(band(31), 30)
        XCTAssertNil(band(8))
        let near = NavPromptTiming.plan(distanceNowM: 9, speedMps: 1.3, latencyS: 0.6, canHold: false, mode: .walk, band: band) { _ in 2 }
        XCTAssertNil(near.spokenM, "9 m ahead on foot: now")
        let far = NavPromptTiming.plan(distanceNowM: 80, speedMps: 1.3, latencyS: 0.6, canHold: false, mode: .walk, band: band) { _ in 2.5 }
        let said = try! XCTUnwrap(far.spokenM)
        XCTAssertLessThanOrEqual(said, 80)
        XCTAssertGreaterThanOrEqual(said, 55, "metres, not a car's 100 m")
        /* The car plan for the same ask is the old behaviour (no `mode` argument). */
        let car = NavPromptTiming.plan(distanceNowM: 20, speedMps: 1.3, latencyS: 0.6, canHold: false,
                                       band: NavPromptTiming.band(.device)) { _ in 2 }
        XCTAssertNil(car.spokenM)
    }

    // MARK: the map

    func testWalkingFollowsCloser() {
        for kmh in [0.0, 3, 5, 8] {
            XCTAssertGreaterThan(FollowZoom.zoom(kmh: kmh, mode: .walk), FollowZoom.zoom(kmh: kmh, mode: .car), "\(kmh) km/h")
        }
        XCTAssertEqual(FollowZoom.zoom(kmh: 30, mode: .car), FollowZoom.zoom(kmh: 30), "the car curve is the old one")
        XCTAssertLessThanOrEqual(FollowZoom.zoom(kmh: 0, mode: .walk), 19)
    }

    // MARK: the session

    @MainActor
    func testTheSessionSpeaksWalkingTextWithTheDeviceVoiceAndTimesItsOwnWay() throws {
        let saved = UserDefaults.standard.string(forKey: TravelMode.defaultsKey)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: TravelMode.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: TravelMode.defaultsKey) }
            TravelMode.active = .car
        }
        let a = LngLat(lng: 46.6744, lat: 24.7113), b = LngLat(lng: 46.6744 + 600 / 101_000, lat: 24.7113)
        var route = NavRoute(id: "r", coordinates: [a, b], distanceM: 600, durationS: 600 / WalkPace.flatMps, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق العليا", location: a, distanceM: 600, durationS: 400),
            NavStep(maneuver: .init(kind: .turn, direction: .right), roadName: "شارع التحلية", location: b, distanceM: 100, durationS: 80),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: b, distanceM: 0, durationS: 0),
        ])
        route.durationS = 480
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route]))]), makeEngine: { _ in LocalGuidanceEngine() })
        XCTAssertEqual(n.travelMode, .car, "the default")
        XCTAssertEqual(n.voice.choice(), NavVoiceChoice.current(), "the car keeps the chosen voice")
        n.options.mode = .walk
        XCTAssertEqual(n.voice.choice(), .device, "walking: the device voice (no walking clips yet)")
        n.debugSet(phase: .guiding, target: NavTarget(source: .destination, name: "مخيم", position: b), routes: [route], progress: nil, offRoad: nil)
        XCTAssertEqual(TravelMode.active, .walk, "the map reads this for the walker dot and the zoom")
        n.myFix = { DeviceFix(lat: 24.7113, lng: 46.6744, accuracy: 5, heading: 90, speed: 1.3, atMs: Date().timeIntervalSince1970 * 1000) }
        let line = try XCTUnwrap(n.guidanceLine(stepIndex: 1, distanceM: 60, force: true))
        XCTAssertEqual(line.clips, [], "no car clips")
        XCTAssertEqual(line.text, "بعد ٦٠ متر، انعطف يمينًا")
        XCTAssertFalse(line.text.contains("التحلية"))
        /* The engine's progress is re-timed at walking pace over what is left, with no posted limit. */
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 60, distanceRemainingM: 300, durationRemainingS: 20, speedLimitKmh: 80)))
        XCTAssertEqual(try XCTUnwrap(n.progress).durationRemainingS, 240, accuracy: 0.01)
        XCTAssertNil(n.progress?.speedLimitKmh)
        n.debugSet(phase: .idle, target: NavTarget(source: .destination, name: "مخيم", position: b), routes: [route], progress: nil, offRoad: nil)
        XCTAssertEqual(TravelMode.active, .car)
    }

    @MainActor
    func testChangingTheModeAsksForTheRoutesAgain() async throws {
        let saved = UserDefaults.standard.string(forKey: TravelMode.defaultsKey)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: TravelMode.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: TravelMode.defaultsKey) }
        }
        let recorder = RecordingRouter()
        let n = NavSession(provider: recorder, makeEngine: { _ in LocalGuidanceEngine() })
        n.myFix = { DeviceFix(lat: 24.7113, lng: 46.6744, accuracy: 5, heading: nil, speed: 0, atMs: Date().timeIntervalSince1970 * 1000) }
        n.plan(to: NavTarget(source: .point, name: "هنا", position: LngLat(lng: 46.69, lat: 24.72)))
        try await waitFor { recorder.modes.count >= 1 }
        XCTAssertEqual(recorder.modes.first, .car, "the first request is the remembered mode: car by default")
        n.setMode(.walk)
        try await waitFor { recorder.modes.count >= 2 }
        XCTAssertEqual(recorder.modes.last, .walk, "picking «مشي» re-requests")
        XCTAssertEqual(TravelMode.load(), .walk, "and remembers it")
        n.setMode(.walk)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.modes.count, 2, "the same mode again is not a new request")
        n.setMode(.car)
        try await waitFor { recorder.modes.count >= 3 }
        XCTAssertEqual(recorder.modes.last, .car)
    }

    @MainActor
    private func waitFor(_ cond: () -> Bool) async throws {
        for _ in 0 ..< 100 where !cond() { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(cond(), "timed out")
    }
}

/// Records the mode of every request.
private final class RecordingRouter: NavRoutingProvider {
    let name = "Recording"
    private(set) var modes: [TravelMode] = []
    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        modes.append(r.options.mode)
        return NavRoutePlan(routes: [NavRoute(id: "x", coordinates: [r.origin, r.target.position], distanceM: 2_000, durationS: 150, steps: [])])
    }
}
