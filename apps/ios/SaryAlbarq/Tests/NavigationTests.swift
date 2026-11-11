import MapboxDirections
@_spi(MapboxInternal) import MapboxNavigationCore
import CoreMedia
import UIKit
import XCTest
@testable import SaryAlbarq

// «الملاحة»: option mapping, destination sources, off-road last leg, Arabic
// instructions, and the routing-provider seam (Mapbox / the company's Valhalla).

private let riyadh = LngLat(lng: 46.6753, lat: 24.7136)

private func req(_ o: NavRouteOptions = .init(), to t: LngLat = LngLat(lng: 46.695, lat: 24.71)) -> NavRouteRequest {
    NavRouteRequest(origin: LngLat(lng: 46.68, lat: 24.70), heading: 10, target: NavTarget(source: .point, name: "هنا", position: t), options: o)
}

final class NavOptionMappingTests: XCTestCase {
    func testSpecFromOptions() {
        let d = NavRouteSpec.from(.init())
        XCTAssertEqual(d.profile, .drivingTraffic)
        XCTAssertEqual(d.exclude, [])
        XCTAssertEqual(d.language, "ar")
        XCTAssertTrue(d.metric)
        XCTAssertTrue(d.alternatives)
        let all = NavRouteSpec.from(.init(fastest: false, avoidUnpaved: true, avoidTolls: true))
        XCTAssertEqual(all.profile, .driving)
        XCTAssertEqual(Set(all.exclude), ["toll", "unpaved"])
    }

    @MainActor
    func testMapboxRequestCarriesArabicMetricAndExclusions() {
        let o = MapboxNavRoutingProvider.options(req(.init(fastest: true, avoidUnpaved: true, avoidTolls: true)))
        let q = Dictionary(o.urlQueryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(q["language"], "ar")
        XCTAssertEqual(q["voice_units"], "metric")
        XCTAssertEqual(q["alternatives"], "true")
        XCTAssertEqual(q["steps"], "true")
        XCTAssertEqual(q["voice_instructions"], "true")
        XCTAssertEqual(q["banner_instructions"], "true")
        XCTAssertEqual(Set((q["exclude"] ?? "").split(separator: ",").map(String.init)), ["toll", "unpaved"])
        XCTAssertEqual(o.profileIdentifier, .automobileAvoidingTraffic)
        XCTAssertEqual(o.waypoints.count, 2)
        XCTAssertEqual(o.waypoints[0].heading, 10)
        let plain = MapboxNavRoutingProvider.options(req(.init(fastest: false)))
        XCTAssertEqual(plain.profileIdentifier, .automobile)
        XCTAssertNil(plain.urlQueryItems.first { $0.name == "exclude" }?.value.flatMap { $0.isEmpty ? nil : $0 })
    }

    func testFarqBodyMapsTheSameOptions() throws {
        let b = FarqValhallaRouteProvider.body(req(.init(fastest: true, avoidUnpaved: true, avoidTolls: false)))
        XCTAssertEqual(b["costing"] as? String, "auto")
        XCTAssertEqual(b["language"] as? String, "ar-SA")
        XCTAssertEqual(b["alternates"] as? Int, 2)
        let opts = try XCTUnwrap(b["options"] as? [String: Any])
        XCTAssertEqual(opts["avoid_unpaved"] as? Bool, true)
        XCTAssertEqual(opts["avoid_tolls"] as? Bool, false)
        XCTAssertEqual(opts["use_tracks"] as? Bool, false)
        let locs = try XCTUnwrap(b["locations"] as? [[String: Double]])
        XCTAssertEqual(locs.count, 2)
        XCTAssertEqual(locs[1]["lat"], 24.71)
    }

    func testOptionsPersist() {
        let d = UserDefaults(suiteName: "nav-tests")!
        d.removePersistentDomain(forName: "nav-tests")
        XCTAssertEqual(NavRouteOptions.load(d), NavRouteOptions())
        NavRouteOptions(fastest: false, avoidUnpaved: true, avoidTolls: true).save(d)
        /* No toll roads in KSA (#76): a saved «تجنّب الرسوم» from an older build is dropped on load. */
        XCTAssertEqual(NavRouteOptions.load(d), NavRouteOptions(fastest: false, avoidUnpaved: true, avoidTolls: false))
    }

    func testChoiceOrdersByTimeOrDistance() {
        let a = NavRoute(id: "a", coordinates: [], distanceM: 9000, durationS: 600, steps: [])
        let b = NavRoute(id: "b", coordinates: [], distanceM: 7000, durationS: 840, steps: [])
        XCTAssertEqual(NavRouteChoice.order([b, a], options: .init(fastest: true)).map(\.id), ["a", "b"])
        XCTAssertEqual(NavRouteChoice.order([a, b], options: .init(fastest: false)).map(\.id), ["b", "a"])
        XCTAssertEqual(NavRouteChoice.delta(b, best: a), "أبطأ ٤ د")
    }
}

final class NavPiPSnapshotTests: XCTestCase {
    func testSameEndpointsAndPointCountButChangedRouteGeometryInvalidatesSnapshot() {
        let routeA = NavRoute(id: "same-route-id", coordinates: [
            LngLat(lng: 46.0, lat: 24.0),
            LngLat(lng: 46.1, lat: 24.1),
            LngLat(lng: 46.2, lat: 24.2),
        ], distanceM: 1_000, durationS: 200, steps: [])
        let routeB = NavRoute(id: "same-route-id", coordinates: [
            LngLat(lng: 46.0, lat: 24.0),
            LngLat(lng: 46.1, lat: 24.15),
            LngLat(lng: 46.2, lat: 24.2),
        ], distanceM: 1_000, durationS: 200, steps: [])

        func snapshot(_ route: NavRoute) -> NavPiPSnapshot {
            NavPiPSnapshot(target: "الوجهة", road: "الطريق", instruction: "تابع", symbol: "arrow.up",
                           distanceToTurn: "١ كم", distanceRemaining: "١ كم", timeRemaining: "دقيقتان",
                           route: route.coordinates, routeRevision: route.geometryRevision, progress: 0)
        }

        XCTAssertEqual(routeA.coordinates.count, routeB.coordinates.count)
        XCTAssertEqual(routeA.coordinates.first, routeB.coordinates.first)
        XCTAssertEqual(routeA.coordinates.last, routeB.coordinates.last)
        XCTAssertNotEqual(snapshot(routeA), snapshot(routeB), "PiP must refresh for a route change even when endpoints and count match")
        XCTAssertEqual(snapshot(routeA), snapshot(routeA), "progress-only updates retain the route revision")
    }
}

final class NavPiPFrameTimingTests: XCTestCase {
    func testFirstHostClockFrameIsAccepted() {
        let now = CMTime(seconds: 100, preferredTimescale: 600)
        XCTAssertEqual(NavPiPFrameTiming.next(current: now, after: .invalid), now)
    }

    func testFramesAreRateLimitedAndMonotonic() {
        let previous = CMTime(seconds: 100, preferredTimescale: 600)
        XCTAssertNil(NavPiPFrameTiming.next(current: CMTime(seconds: 100.5, preferredTimescale: 600), after: previous))
        XCTAssertNil(NavPiPFrameTiming.next(current: CMTime(seconds: 99, preferredTimescale: 600), after: previous))
        XCTAssertEqual(NavPiPFrameTiming.next(current: CMTime(seconds: 101, preferredTimescale: 600), after: previous),
                       CMTime(seconds: 101, preferredTimescale: 600))
    }

    func testInvalidCurrentFrameTimeIsRejected() {
        XCTAssertNil(NavPiPFrameTiming.next(current: .invalid, after: .invalid))
    }
}

final class NavTargetSourceTests: XCTestCase {
    func testDestinationRallyPointPlanEnd() throws {
        let d = try NavTargets.destination(OutingDestination(name: "روضة الثمامة", lat: 25.0, lng: 46.7)).get()
        XCTAssertEqual(d.source, .destination)
        XCTAssertEqual(d.name, "روضة الثمامة")
        XCTAssertEqual(d.position, LngLat(lng: 46.7, lat: 25.0))
        XCTAssertEqual(NavTargets.destination(nil), .failure(.missing))
        XCTAssertEqual(try NavTargets.rally(MapRallyPoint(position: riyadh, label: "")).get().name, "نقطة التجمع")
        XCTAssertEqual(try NavTargets.point(riyadh).get().name, "النقطة المحددة")
        XCTAssertEqual(try NavTargets.point(riyadh, name: "مطعم").get().name, "مطعم")
        XCTAssertEqual(NavTargets.planRouteEnd([riyadh]), .failure(.missing))
        XCTAssertEqual(try NavTargets.planRouteEnd([riyadh, LngLat(lng: 46.8, lat: 24.9)]).get().position, LngLat(lng: 46.8, lat: 24.9))
    }

    func testMemberLiveIsAccepted() throws {
        let t = try NavTargets.member(id: "u2", name: "فهد", isMe: false, position: riyadh, presence: .live).get()
        XCTAssertEqual(t.source, .member)
        XCTAssertEqual(t.memberId, "u2")
        XCTAssertEqual(t.position, riyadh)
    }

    func testMemberStaleIsRefusedNeverEstimated() {
        let since = Date(timeIntervalSinceNow: -300)
        let r = NavTargets.member(id: "u3", name: "سعد", isMe: false, position: riyadh, presence: .stale(since: since))
        XCTAssertEqual(r, .failure(.memberStale(name: "سعد", since: since)))
        if case let .failure(e) = r { XCTAssertTrue(e.message.contains("قديم")) }
        XCTAssertEqual(NavTargets.member(id: "u4", name: "نورة", isMe: false, position: riyadh, presence: .paused), .failure(.memberHidden(name: "نورة")))
        XCTAssertEqual(NavTargets.member(id: "u5", name: "أنا", isMe: true, position: riyadh, presence: .live), .failure(.isMe))
        XCTAssertEqual(NavTargets.member(id: "u6", name: "علي", isMe: false, position: nil, presence: .live), .failure(.memberHidden(name: "علي")))
    }

    func testMemberMovedSuggestsRefreshOnlyPastThreshold() {
        let t = NavTarget(source: .member, name: "فهد", position: riyadh, memberId: "u2")
        XCTAssertNil(NavTargets.memberMoved(t, now: LngLat(lng: riyadh.lng + 0.001, lat: riyadh.lat)))
        XCTAssertNotNil(NavTargets.memberMoved(t, now: LngLat(lng: riyadh.lng + 0.01, lat: riyadh.lat)))
        XCTAssertNil(NavTargets.memberMoved(NavTarget(source: .rally, name: "", position: riyadh), now: LngLat(lng: 47, lat: 25)))
    }
}

final class NavOffRoadTests: XCTestCase {
    /// A point `m` metres from `p` on `bearing`.
    private func offset(_ p: LngLat, _ m: Double, bearing: Double) -> LngLat {
        let r = Double.pi / 180, R = 6_371_000.0
        let lat1 = p.lat * r, lng1 = p.lng * r, d = m / R, b = bearing * r
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lng2 = lng1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return LngLat(lng: lng2 / r, lat: lat2 / r)
    }

    func testNoLegWhenTheRoadReachesTheTarget() {
        XCTAssertNil(NavOffRoad.lastLeg(routeEnd: riyadh, target: offset(riyadh, 60, bearing: 10)))
        XCTAssertNil(NavOffRoad.lastLeg(routeEnd: nil, target: riyadh))
    }

    func testDesertTargetGivesStraightLineDistanceAndBearing() throws {
        let target = offset(riyadh, 3200, bearing: 225)
        let leg = try XCTUnwrap(NavOffRoad.lastLeg(routeEnd: riyadh, target: target))
        XCTAssertEqual(leg.distanceM, 3200, accuracy: 2)
        XCTAssertEqual(leg.bearing, 225, accuracy: 0.5)
        XCTAssertEqual(leg.from, riyadh)
        XCTAssertEqual(NavOffRoad.summary(leg), "آخر جزء بدون طريق: ٣٫٢ كم باتجاه الجنوب الغربي")
    }

    func testRemainingAndArrival() throws {
        let target = offset(riyadh, 3200, bearing: 90)
        let leg = try XCTUnwrap(NavOffRoad.lastLeg(routeEnd: riyadh, target: target))
        let half = NavOffRoad.remaining(leg, me: offset(riyadh, 1600, bearing: 90))
        XCTAssertEqual(half.distanceM, 1600, accuracy: 2)
        XCTAssertEqual(half.bearing, 90, accuracy: 0.5)
        XCTAssertFalse(half.arrived)
        XCTAssertTrue(NavOffRoad.remaining(leg, me: offset(target, 20, bearing: 0)).arrived)
        let direct = NavOffRoad.direct(from: riyadh, to: target)
        XCTAssertEqual(direct.distanceM, 3200, accuracy: 2)
    }

    func testArrowIsRelativeAndWraps() {
        XCTAssertEqual(NavOffRoad.arrowDegrees(bearing: 10, reference: 350), 20, accuracy: 1e-9)
        XCTAssertEqual(NavOffRoad.arrowDegrees(bearing: 350, reference: 10), -20, accuracy: 1e-9)
        XCTAssertEqual(NavOffRoad.arrowDegrees(bearing: 225, reference: 45), 180, accuracy: 1e-9)
    }
}

final class NavTextTests: XCTestCase {
    private func step(_ k: NavManeuverKind, _ d: NavTurnDirection? = nil, road: String? = nil, exit: Int? = nil) -> NavStep {
        NavStep(maneuver: NavManeuver(kind: k, direction: d, exit: exit), roadName: road, location: riyadh, distanceM: 100, durationS: 10)
    }

    func testBannerWithArabicDigits() {
        XCTAssertEqual(NavText.banner(step(.turn, .right, road: "طريق الملك فهد"), distanceM: 500), "بعد ٥٠٠ م انعطف يمينًا إلى طريق الملك فهد")
        XCTAssertEqual(NavText.banner(step(.turn, .left, road: "طريق العروبة"), distanceM: 1230), "بعد ١٫٢ كم انعطف يسارًا إلى طريق العروبة")
        XCTAssertEqual(NavText.banner(step(.turn, .right), distanceM: 12), "انعطف يمينًا")
        XCTAssertEqual(NavText.banner(step(.roundabout, exit: 2), distanceM: 260), "بعد ٢٥٠ م في الدوّار خذ المخرج الثاني")
        XCTAssertEqual(NavText.banner(step(.continue, road: "طريق 40"), distanceM: 3000), "بعد ٣ كم استمر على طريق ٤٠")
        XCTAssertEqual(NavText.banner(step(.arrive), distanceM: 5, targetName: "روضة خريم"), "وصلت إلى روضة خريم")
        XCTAssertEqual(NavText.banner(step(.fork, .slightRight, road: "الدائري الشرقي"), distanceM: 700), "بعد ٧٠٠ م التزم باليمين عند التفرّع إلى الدائري الشرقي")
    }

    func testRoundingAndUnits() {
        XCTAssertEqual(NavText.distance(47), "٥٠ م")
        XCTAssertEqual(NavText.distance(523), "٥٠٠ م")
        XCTAssertEqual(NavText.distance(980), "١ كم")
        XCTAssertEqual(NavText.distance(18_340), "١٨٫٣ كم")
        XCTAssertNil(NavText.inDistance(20))
        XCTAssertEqual(NavText.spokenInDistance(400), "بعد ٤٠٠ متر")
        XCTAssertEqual(NavText.spokenInDistance(2500), "بعد ٢٫٥ كيلومتر")
        XCTAssertFalse(NavText.banner(step(.turn, .right, road: "Exit 9"), distanceM: 800).contains { $0.isASCII && $0.isNumber })
    }

    func testClockAndRemaining() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 4; c.hour = 16; c.minute = 35
        c.timeZone = TimeZone(identifier: "Asia/Riyadh")
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(NavText.clock(d), "٤:٣٥ م")
        c.hour = 0; c.minute = 5
        XCTAssertEqual(NavText.clock(Calendar(identifier: .gregorian).date(from: c)!), "١٢:٠٥ ص")
        XCTAssertEqual(NavText.remaining(seconds: 30), "أقل من دقيقة")
        XCTAssertEqual(NavText.remaining(seconds: 23 * 60), "٢٣ د")
        XCTAssertEqual(NavText.remaining(seconds: 65 * 60), "١ س ٥ د")
        XCTAssertEqual(NavText.compassDefinite(225), "الجنوب الغربي")
    }

    func testGlyphsExist() {
        let kinds: [NavManeuverKind] = [.depart, .turn, .continue, .merge, .onRamp, .offRamp, .fork, .endOfRoad, .roundabout, .exitRoundabout, .arrive]
        let dirs: [NavTurnDirection?] = [nil, .sharpRight, .right, .slightRight, .straight, .slightLeft, .left, .sharpLeft, .uTurn]
        for k in kinds { for d in dirs {
            let name = NavGlyph.symbol(NavManeuver(kind: k, direction: d))
            XCTAssertNotNil(UIImage(systemName: name), name)
        } }
    }
}

// MARK: the routing-provider seam

/// Answers requests from a table (path → status, body); records what was asked.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (code, body) = Self.routes[request.url?.path ?? ""] ?? (404, Data("{\"error\":\"not_found\"}".utf8))
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Stands in for Mapbox Directions.
final class FakeMapbox: NavRoutingProvider {
    let name = "Mapbox"
    var calls = 0
    /// Throw this instead of answering.
    var fail: NavRoutingError?
    /// Where the route ends (default: at the target, i.e. Mapbox covers it).
    var end: LngLat?
    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        calls += 1
        if let fail { throw fail }
        return NavRoutePlan(routes: [NavRoute(id: "mapbox-0", coordinates: [r.origin, end ?? r.target.position], distanceM: 1000, durationS: 100, steps: [])])
    }
}

final class NavRoutingProviderTests: XCTestCase {
    private var fixture: Data!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "farq-route", withExtension: "json"))
        fixture = try Data(contentsOf: url)
        StubURLProtocol.routes = [:]
        StubURLProtocol.seen = []
    }

    private func farq() -> FarqValhallaRouteProvider {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return FarqValhallaRouteProvider(base: URL(string: "https://api.test")!, token: { "tok123" }, session: URLSession(configuration: cfg))
    }

    func testFixtureDecodesIntoArabicStepsLanesAndVoice() async throws {
        StubURLProtocol.routes["/api/outings/routing/route"] = (200, fixture)
        let p = try await farq().routes(req())
        XCTAssertEqual(p.routes.count, 2, "main + alternative")
        let r = p.routes[0]
        XCTAssertEqual(r.id, "farq-0")
        XCTAssertEqual(r.distanceM, 2627, accuracy: 2)
        XCTAssertEqual(r.coordinates.count, 21)
        XCTAssertEqual(r.coordinates.first!.lat, 24.70, accuracy: 1e-6, "polyline6")
        XCTAssertEqual(r.steps.map(\.maneuver.kind), [.depart, .turn, .arrive])
        XCTAssertEqual(r.steps[1].maneuver.direction, .right)
        XCTAssertEqual(r.steps[1].roadName, "طريق العروبة")
        XCTAssertEqual(r.steps[1].lanes.map(\.valid), [false, false, true])
        /* The voice line about the turn is spoken along step 0 and belongs to the turn. */
        XCTAssertEqual(r.steps[1].spoken.last?.text, "بعد 400 متر، انعطف يمينًا إلى طريق العروبة")
        XCTAssertEqual(NavText.banner(r.steps[1], distanceM: 400), "بعد ٤٠٠ م انعطف يمينًا إلى طريق العروبة")
        XCTAssertTrue(p.native is FarqRoutesBox)
        let sent = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
    }

    @MainActor
    func testTheNavigationSDKAcceptsTheValhallaRoute() async throws {
        StubURLProtocol.routes["/api/outings/routing/route"] = (200, fixture)
        let p = try await farq().routes(req())
        let box = try XCTUnwrap(p.native as? FarqRoutesBox)
        let nr = try await box.navigationRoutes(routeId: "farq-1")
        XCTAssertEqual(nr.mainRoute.route.distance, p.routes[1].distanceM, accuracy: 1)
        XCTAssertEqual(nr.mainRoute.route.legs.first?.steps.count, 3)
    }

    func testFallsBackToMapboxWhenNotDeployed() async throws {
        let mb = FakeMapbox()
        let sw = SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .farq })
        let p = try await sw.routes(req())
        XCTAssertEqual(p.routes.first?.id, "mapbox-0")
        XCTAssertEqual(sw.lastFallbackReason, .notDeployed)
        XCTAssertEqual(mb.calls, 1)
    }

    func testFallsBackOnRoutingUnavailableAndNoRoute() async throws {
        for code in ["routing_unavailable", "no_route"] {
            StubURLProtocol.routes["/api/outings/routing/route"] = (code == "no_route" ? 422 : 503, Data("{\"error\":\"\(code)\"}".utf8))
            let mb = FakeMapbox()
            let sw = SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .farq })
            let p = try await sw.routes(req())
            XCTAssertEqual(p.routes.first?.id, "mapbox-0", code)
            XCTAssertEqual(sw.lastFallbackReason, code == "no_route" ? .noRoute : .unavailable)
        }
    }

    /// «تلقائي»: Mapbox with traffic wherever it reaches the target (live ETA in town), even with Valhalla on.
    func testAutoKeepsMapboxWithTrafficOnRoadsItCovers() async throws {
        StubURLProtocol.routes["/api/outings/routing/route"] = (200, fixture)
        StubURLProtocol.routes["/api/outings/routing/status"] = (200, Data("{\"enabled\":true}".utf8))
        let mb = FakeMapbox()
        let sw = SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .auto })
        let p = try await sw.routes(req())
        XCTAssertEqual(p.routes.first?.id, "mapbox-0")
        XCTAssertEqual(sw.name, "Mapbox")
        XCTAssertFalse(StubURLProtocol.seen.contains { $0.url?.path == "/api/outings/routing/route" }, "Valhalla not asked in town")
        XCTAssertEqual(NavRouteSpec.from(req().options).profile, .drivingTraffic, "default options: driving-traffic")
    }

    /// «تلقائي»: Mapbox stops 2 km short (desert / a road it does not know) → Valhalla, which reaches it.
    func testAutoUsesValhallaWhereMapboxStopsShort() async throws {
        StubURLProtocol.routes["/api/outings/routing/route"] = (200, fixture)
        StubURLProtocol.routes["/api/outings/routing/status"] = (200, Data("{\"enabled\":true}".utf8))
        let mb = FakeMapbox()
        mb.end = LngLat(lng: 46.695, lat: 24.69)
        let p = try await SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .auto }).routes(req())
        XCTAssertEqual(p.routes.first?.id, "farq-0")
    }

    /// «تلقائي»: Mapbox has no route → Valhalla; Valhalla disabled → Mapbox's own error; offline → no second server.
    func testAutoFallsToValhallaOnlyWhenEnabledAndMapboxFails() async throws {
        StubURLProtocol.routes["/api/outings/routing/route"] = (200, fixture)
        StubURLProtocol.routes["/api/outings/routing/status"] = (200, Data("{\"enabled\":true}".utf8))
        let mb = FakeMapbox()
        mb.fail = .noRoute
        let p = try await SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .auto }).routes(req())
        XCTAssertEqual(p.routes.first?.id, "farq-0")

        mb.fail = .offline
        StubURLProtocol.seen = []
        do { _ = try await SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .auto }).routes(req()); XCTFail("offline") }
        catch { XCTAssertEqual(error as? NavRoutingError, .offline) }
        XCTAssertTrue(StubURLProtocol.seen.isEmpty)

        StubURLProtocol.routes["/api/outings/routing/status"] = (200, Data("{\"enabled\":false}".utf8))
        mb.fail = .noRoute
        mb.end = LngLat(lng: 46.695, lat: 24.69)
        do { _ = try await SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .auto }).routes(req()); XCTFail("disabled") }
        catch { XCTAssertEqual(error as? NavRoutingError, .noRoute) }
        mb.fail = nil
        let short = try await SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .auto }).routes(req())
        XCTAssertEqual(short.routes.first?.id, "mapbox-0", "disabled → Mapbox even when it stops short")
    }

    func testMapboxChoiceNeverCallsTheCompanyServer() async throws {
        let mb = FakeMapbox()
        _ = try await SwitchingRouteProvider(farq: farq(), mapbox: mb, choice: { .mapbox }).routes(req())
        XCTAssertTrue(StubURLProtocol.seen.isEmpty)
        XCTAssertEqual(mb.calls, 1)
    }

    /// «صوت سرى» is built from our NavStep, not from the router's text: a Valhalla route must give every
    /// maneuver its clips (and a spoken cue) just as a Mapbox one does, or the default «تلقائي» goes quiet.
    func testValhallaManeuversMapToSaryVoiceClips() async throws {
        StubURLProtocol.routes["/api/outings/routing/route"] = (200, fixture)
        let p = try await farq().routes(req())
        for r in p.routes {
            for (i, s) in r.steps.enumerated() where s.maneuver.kind != .depart {
                let near = SaryVoiceScript.step(s, distanceM: 300)
                XCTAssertFalse(near.isEmpty, "\(r.id) step \(i) \(s.maneuver.kind)")
                XCTAssertNotEqual(near.last, "mv_02", "\(r.id) step \(i): an action, not «كمّل سيده»")
                XCTAssertFalse(s.spoken.isEmpty, "\(r.id) step \(i): the router announces it")
            }
        }
    }

    func testDefaultChoiceIsAuto() {
        UserDefaults.standard.removeObject(forKey: NavProviderChoice.key)
        XCTAssertEqual(NavProviderChoice.current, .auto, "Mapbox with traffic in town, Farq's Valhalla off Mapbox's roads")
    }
}

/// Our own guidance along a route (the engine any provider can use).
@MainActor
final class LocalGuidanceTests: XCTestCase {
    private func route() -> NavRoute {
        let a = LngLat(lng: 46.68, lat: 24.70), k = LngLat(lng: 46.68, lat: 24.71), b = LngLat(lng: 46.695, lat: 24.71)
        let c = (0...10).map { LngLat(lng: 46.68, lat: 24.70 + 0.001 * Double($0)) } + (1...10).map { LngLat(lng: 46.68 + 0.0015 * Double($0), lat: 24.71) }
        let d1 = Vehicle.distanceMeters(a, k), d2 = Vehicle.distanceMeters(k, b)
        return NavRoute(id: "r", coordinates: c, distanceM: d1 + d2, durationS: 300, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "أ", location: a, distanceM: d1, durationS: 150),
            NavStep(maneuver: .init(kind: .turn, direction: .right), roadName: "ب", location: k, distanceM: d2, durationS: 150),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: b, distanceM: 0, durationS: 0),
        ])
    }

    private func fix(_ lat: Double, _ lng: Double) -> DeviceFix { DeviceFix(lat: lat, lng: lng, accuracy: 5, heading: nil, speed: 10, atMs: 0) }

    func testProgressSpeaksAndArrives() async throws {
        let e = LocalGuidanceEngine()
        var events: [NavGuidanceEvent] = []
        e.onEvent = { events.append($0) }
        let r = route()
        try await e.start(route: r, plan: .init(routes: [r]), target: NavTarget(source: .point, name: "هنا", position: r.end!))
        /* 10 m/s in town: the first cue at ~300 m (`NavCueBands`), not 800 m ahead. */
        e.ingest(fix(24.705, 46.68))
        guard case let .progress(p) = events.first else { return XCTFail("progress") }
        XCTAssertEqual(p.stepIndex, 1)
        XCTAssertEqual(p.distanceToManeuverM, 556, accuracy: 15)
        XCTAssertFalse(events.contains { if case .speak = $0 { return true } else { return false } }, "556 m at city speed: too early to speak")
        e.ingest(fix(24.7075, 46.68))
        XCTAssertTrue(events.contains { if case let .speak(t) = $0 { return t.text.contains("انعطف يمينًا") && t.clips.last == "turns_01" } else { return false } })
        e.ingest(fix(24.71, 46.6949))
        XCTAssertTrue(events.contains(.arrivedAtRouteEnd))
    }

    func testOffRouteThreeFixesInARowReroutes() async throws {
        let e = LocalGuidanceEngine()
        var events: [NavGuidanceEvent] = []
        e.onEvent = { events.append($0) }
        let r = route()
        let exp = expectation(description: "reroute asked")
        e.reroute = { _, _ in exp.fulfill(); return r }
        try await e.start(route: r, plan: .init(routes: [r]), target: NavTarget(source: .point, name: "هنا", position: r.end!))
        e.ingest(fix(24.705, 46.685)) // ~500 m off
        e.ingest(fix(24.705, 46.6851))
        XCTAssertFalse(events.contains(.offRoute), "two bad fixes are not a detour")
        e.ingest(fix(24.705, 46.6852))
        XCTAssertTrue(events.contains(.offRoute))
        await fulfillment(of: [exp], timeout: 2)
    }
}

/// Every «اتجه» (silent member, fuel station, waypoint) is OUR guidance: a nav target for
/// `directions(_:)`, never another app. Google Maps / Waze only where the person picks them by name.
@MainActor final class InAppDirectionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSilentMemberLastKnownIsAnInAppTargetLabelledOld() throws {
        let t = try NavTargets.lastKnown(name: "Alwald", lat: 24.71, lng: 46.67, at: t0.addingTimeInterval(-14 * 60)).get()
        XCTAssertEqual(t.source, .lastKnown)
        XCTAssertEqual(t.name, "آخر موقع Alwald")
        XCTAssertEqual(t.position, LngLat(lng: 46.67, lat: 24.71))
        XCTAssertNil(t.memberId, "not a live member: no «تحرّك» follow-up")
        XCTAssertEqual(t.staleNote(now: t0), "آخر موقع معروف · قبل ١٤ د", "never presented as live")
        XCTAssertEqual(NavTargets.lastKnown(name: "Alwald", lat: nil, lng: 46.6, at: t0), .failure(.missing))
        /* «روح له» still refuses the same stale member: the last-known path is the silent card's only. */
        XCTAssertEqual(NavTargets.member(id: "u", name: "Alwald", isMe: false, position: riyadh, presence: .stale(since: t0)),
                       .failure(.memberStale(name: "Alwald", since: t0)))
        XCTAssertNil(try NavTargets.point(riyadh).get().staleNote(), "only last-known targets carry the label")
    }

    func testStationAndWaypointAreInAppTargets() throws {
        let s = try NavTargets.station(name: "ساسكو", lat: 24.7, lng: 46.6).get()
        XCTAssertEqual(s.source, .point)
        XCTAssertEqual(s.name, "ساسكو")
        XCTAssertEqual(s.position, LngLat(lng: 46.6, lat: 24.7))
        XCTAssertEqual(try NavTargets.station(name: nil, lat: 24.7, lng: 46.6).get().name, "محطة بنزين")
        let w = try NavTargets.waypoint(title: "مخيّم", lat: 24.8, lng: 46.5).get()
        XCTAssertEqual(w.name, "مخيّم")
        XCTAssertEqual(w.position, LngLat(lng: 46.5, lat: 24.8))
        XCTAssertEqual(try NavTargets.waypoint(title: "", lat: 24.8, lng: 46.5).get().name, "النقطة")
    }

    func testConfirmOnlyWhileGuidanceIsOn() {
        XCTAssertTrue(LiveOutingController.directionsNeedsConfirm(.guiding))
        XCTAssertTrue(LiveOutingController.directionsNeedsConfirm(.offRoad))
        XCTAssertTrue(LiveOutingController.directionsNeedsConfirm(.planning))
        XCTAssertFalse(LiveOutingController.directionsNeedsConfirm(.idle))
        XCTAssertFalse(LiveOutingController.directionsNeedsConfirm(.arrived))
        XCTAssertEqual(LiveOutingController.retargetHint(wasAuto: false), "ترجع للوجهة من أدوات ← الطريق")
        let t = NavTarget(source: .lastKnown, name: "آخر موقع Alwald", position: riyadh)
        XCTAssertEqual(LiveConfirm.retarget(t).retargetTarget, t)
        XCTAssertNil(LiveConfirm.leave.retargetTarget)
        XCTAssertNotEqual(LiveConfirm.retarget(t).id, LiveConfirm.leave.id)
    }

    /// The call sites themselves (read from the repo when reachable): no «اتجه» opens Apple Maps.
    func testNoDirectionsButtonOpensAnotherApp() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        func read(_ p: String) throws -> String {
            guard let s = try? String(contentsOf: src.appendingPathComponent(p), encoding: .utf8) else { throw XCTSkip("sources not reachable") }
            return s
        }
        let silence = try read("Live/LiveSilence.swift")
        XCTAssertFalse(silence.contains("ExternalNav.open("), "silent card «اتجه»")
        XCTAssertTrue(silence.contains("directions(.success(t))"))
        let live = try read("Live/LiveOutingController.swift")
        XCTAssertFalse(live.contains("ExternalNav.open("), "fuel station «اتجه»")
        XCTAssertFalse(live.contains("enum Directions"), "the Apple Maps helper is gone")
        XCTAssertTrue(live.contains("directions(NavTargets.station("))
        let features = try read("Views/FeatureViews.swift")
        let opens = features.components(separatedBy: "\n").enumerated().filter { $0.element.contains("ExternalNav.open(") }
        XCTAssertEqual(opens.count, 1, "only the trip summary's explicit «افتح في Google Maps» / «افتح في Waze»")
        let lines = features.components(separatedBy: "\n")
        for (i, _) in opens {
            XCTAssertTrue(lines[i...min(i + 2, lines.count - 1)].joined().contains("app.openTitle"), "labelled as another app, not «اتجه»")
        }
        XCTAssertEqual(features.components(separatedBy: "controller.directions(NavTargets.waypoint(").count - 1, 2, "waypoint card + past waypoints")
        let nav = try read("Navigation/LiveOutingController+Nav.swift")
        XCTAssertEqual(nav.components(separatedBy: "ExternalNav.open(").count - 1, 1, "only the named apps in the route options")
        let livePlan = try read("Plan/LivePlan.swift")
        XCTAssertTrue(livePlan.contains("controller.directions(NavTargets.destination(d))"), "the destination's «اتجه» is our own guidance")
        let planRow = try read("Plan/PlanSections.swift")
        XCTAssertFalse(planRow.contains("title: \"اتجه\""), "before the start there is no in-app map: no «اتجه» that leaves the app")
    }

    /// Owner (build 21): «خرائط ابل لا تعمل بالسعودية اصلا». Nothing in Sources opens Apple Maps;
    /// CarPlay keeps MKMapItem only to describe its CPTrip (it never calls `openInMaps`).
    func testNoAppleMapsAnywhereInSources() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        guard let e = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil) else { throw XCTSkip("sources not reachable") }
        var scanned = 0
        for case let u as URL in e where u.pathExtension == "swift" {
            guard let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
            scanned += 1
            let name = u.lastPathComponent
            XCTAssertFalse(s.contains("maps.apple.com"), name)
            XCTAssertFalse(s.contains("openInMaps"), name)
            XCTAssertFalse(s.contains("خرائط Apple"), name)
            XCTAssertFalse(s.contains("Apple Maps\""), name)
            let code = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if code.contains("MKMapItem(") { XCTAssertTrue(u.path.contains("/CarPlay/"), "MKMapItem only for CarPlay's CPTrip: \(name)") }
        }
        if scanned == 0 { throw XCTSkip("sources not reachable") }
    }
}

final class ExternalNavTests: XCTestCase {
    let lat = 24.7113, lng = 46.6744

    func testGoogleApp() {
        XCTAssertEqual(ExternalNav.appURL(.google, lat: lat, lng: lng).absoluteString, "comgooglemaps://?daddr=24.71130,46.67440&directionsmode=driving")
        XCTAssertEqual(ExternalNav.url(.google, lat: lat, lng: lng, canOpen: { $0.scheme == "comgooglemaps" }).scheme, "comgooglemaps")
    }

    func testGoogleWeb() {
        let web = "https://www.google.com/maps/dir/?api=1&destination=24.71130,46.67440&travelmode=driving"
        XCTAssertEqual(ExternalNav.webURL(.google, lat: lat, lng: lng).absoluteString, web)
        XCTAssertEqual(ExternalNav.url(.google, lat: lat, lng: lng, canOpen: { _ in false }).absoluteString, web, "not installed: the universal link")
    }

    func testWazeApp() {
        XCTAssertEqual(ExternalNav.appURL(.waze, lat: lat, lng: lng).absoluteString, "waze://?ll=24.71130,46.67440&navigate=yes")
        XCTAssertEqual(ExternalNav.url(.waze, lat: lat, lng: lng, canOpen: { $0.scheme == "waze" }).scheme, "waze")
    }

    func testWazeWeb() {
        let web = "https://waze.com/ul?ll=24.71130,46.67440&navigate=yes"
        XCTAssertEqual(ExternalNav.webURL(.waze, lat: lat, lng: lng).absoluteString, web)
        XCTAssertEqual(ExternalNav.url(.waze, lat: lat, lng: lng, canOpen: { $0.scheme == "comgooglemaps" }).absoluteString, web, "only Google installed")
    }

    func testOnlyGoogleAndWazeWesternDigits() {
        XCTAssertEqual(ExternalNav.App.allCases, [.google, .waze])
        XCTAssertEqual(ExternalNav.App.google.openTitle, "افتح في Google Maps")
        XCTAssertEqual(ExternalNav.App.waze.openTitle, "افتح في Waze")
        for a in ExternalNav.App.allCases {
            for u in [ExternalNav.appURL(a, lat: lat, lng: lng), ExternalNav.webURL(a, lat: lat, lng: lng)] {
                XCTAssertFalse(u.absoluteString.contains("apple"))
                XCTAssertNil(u.absoluteString.rangeOfCharacter(from: CharacterSet(charactersIn: "٠١٢٣٤٥٦٧٨٩")))
            }
        }
    }

    func testQueriesSchemesListed() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/App/Info.plist")
        guard let d = try? Data(contentsOf: plist),
              let o = try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { throw XCTSkip("plist not reachable") }
        let schemes = o["LSApplicationQueriesSchemes"] as? [String] ?? []
        XCTAssertTrue(schemes.contains("comgooglemaps"))
        XCTAssertTrue(schemes.contains("waze"))
    }

    /// «خيارات المسار»: the routes are framed in the map left between the header and the sheet —
    /// never a padding taller than the map (Mapbox refused it and the map stayed where it was).
    func testRouteOptionsCameraAlwaysLeavesRoomForTheRoutes() {
        let size = CGSize(width: 402, height: 874)
        /* The build 21 case: header 160 pt, options sheet 520 pt tall. */
        let p = NavMapDrawer.fitPadding(size: size, chrome: UIEdgeInsets(top: 160, left: 0, bottom: 520, right: 0), bottomShare: 0.55)
        XCTAssertLessThanOrEqual(p.top + p.bottom, size.height * (1 - NavMapDrawer.minVisibleShare) + 0.5)
        XCTAssertGreaterThan(size.height - p.top - p.bottom, 170, "a strip of map is left for the routes")
        XCTAssertGreaterThan(p.bottom, 450, "still clears most of the sheet")
        /* Plenty of room: the plain margins. */
        let q = NavMapDrawer.fitPadding(size: size, chrome: UIEdgeInsets(top: 50, left: 0, bottom: 100, right: 0), bottomShare: 0.3)
        XCTAssertEqual(q.top, 120)
        XCTAssertEqual(q.bottom, 874 * 0.3 + 24, accuracy: 0.5)
        XCTAssertEqual(q.left, 50)
    }
}

/// The guidance HUD v2 rules and the traffic colours on the route.
final class NavHUDTests: XCTestCase {
    private func step(_ kind: NavManeuverKind, road: String? = nil, sign: String? = nil, dist: Double = 1000) -> NavStep {
        NavStep(maneuver: .init(kind: kind, direction: .left), roadName: road, signText: sign, location: riyadh, distanceM: dist, durationS: 60)
    }

    func testThenOnlyWhenTheNextTurnIsClose() {
        let next = step(.turn, road: "طريق العليا")
        XCTAssertTrue(NavHUD.showsThen(step(.turn, dist: 250), next: next))
        XCTAssertFalse(NavHUD.showsThen(step(.turn, dist: 400), next: next))
        XCTAssertFalse(NavHUD.showsThen(step(.turn, dist: 3300), next: next))
        XCTAssertFalse(NavHUD.showsThen(step(.turn, dist: 100), next: nil))
        XCTAssertFalse(NavHUD.showsThen(step(.arrive, dist: 0), next: next))
    }

    func testDistanceSplitsNumberAndUnit() {
        let km = NavHUD.distanceParts(3300)
        XCTAssertEqual(km.value, "٣٫٣")
        XCTAssertEqual(km.unit, "كم")
        let m = NavHUD.distanceParts(480)
        XCTAssertEqual(m.value, "٤٨٠")
        XCTAssertEqual(m.unit, "م")
    }

    func testTitleIsTheRoadElseTheAction() {
        XCTAssertEqual(NavHUD.title(step(.turn, road: "طريق الملك فهد"), targetName: nil), "طريق الملك فهد")
        XCTAssertEqual(NavHUD.title(step(.offRamp, sign: "مخرج 5"), targetName: nil), NavText.arabicDigitsOnly("مخرج 5"))
        XCTAssertEqual(NavHUD.title(step(.turn), targetName: nil), NavText.action(.init(kind: .turn, direction: .left)))
        XCTAssertEqual(NavHUD.title(step(.arrive), targetName: "حطين"), "حطين")
        XCTAssertEqual(NavHUD.title(step(.arrive), targetName: nil), "وجهتك")
    }

    func testOverLimit() {
        XCTAssertTrue(NavHUD.overLimit(kmh: 90, limit: 80))
        XCTAssertTrue(NavHUD.overLimit(kmh: 80.6, limit: 80))
        XCTAssertFalse(NavHUD.overLimit(kmh: 80.4, limit: 80))
        XCTAssertFalse(NavHUD.overLimit(kmh: 120, limit: nil))
        XCTAssertFalse(NavHUD.overLimit(kmh: nil, limit: 80))
    }

    func testTripLineAndShare() {
        let eta = Date(timeIntervalSince1970: 1_762_466_160) // 00:56 Riyadh
        XCTAssertEqual(NavHUD.tripLine(meters: 19_000, eta: eta), "١٩ كم · ١٢:٥٦ ص")
        let s = NavHUD.shareText(target: "حطين", eta: eta, seconds: 22 * 60)
        XCTAssertTrue(s.contains("إلى حطين") && s.contains("١٢:٥٦ ص") && s.contains("٢٢ د"), s)
    }

    func testCongestionBands() {
        XCTAssertEqual(NavCongestion(numeric: 10), .low)
        XCTAssertEqual(NavCongestion(numeric: 45), .moderate)
        XCTAssertEqual(NavCongestion(numeric: 70), .heavy)
        XCTAssertEqual(NavCongestion(numeric: 95), .severe)
        XCTAssertEqual(NavCongestion(numeric: nil), .unknown)
        XCTAssertEqual([NavCongestion.unknown, .low, .moderate, .heavy, .severe].map(\.band), [0, 0, 1, 2, 3])
    }

    func testTrafficRunsMergeAndTrimBehindTheCar() {
        /* Five ~111 m segments north. */
        let pts = (0...5).map { LngLat(lng: 46.7, lat: 24.7 + Double($0) * 0.001) }
        let c: [NavCongestion] = [.low, .low, .heavy, .severe, .moderate]
        let all = NavTraffic.runs(pts, congestion: c, from: 0)!
        XCTAssertEqual(all.map(\.band), [0, 2, 3, 1])
        XCTAssertEqual(all[0].coordinates.count, 3, "two low segments merge")
        /* 1.5 segments driven: the first run starts mid-segment, still blue. */
        let seg = Vehicle.distanceMeters(pts[0], pts[1])
        let ahead = NavTraffic.runs(pts, congestion: c, from: seg * 1.5)!
        XCTAssertEqual(ahead.map(\.band), [0, 2, 3, 1])
        XCTAssertEqual(ahead[0].coordinates.first!.lat, 24.7015, accuracy: 0.0001)
        /* Past the jam: only what is ahead. */
        XCTAssertEqual(NavTraffic.runs(pts, congestion: c, from: seg * 3.5)!.map(\.band), [3, 1])
    }

    func testNoTrafficMeansOnePlainColour() {
        let pts = (0...3).map { LngLat(lng: 46.7, lat: 24.7 + Double($0) * 0.001) }
        XCTAssertNil(NavTraffic.runs(pts, congestion: nil, from: 0), "Valhalla / the desert: no annotation")
        XCTAssertNil(NavTraffic.runs(pts, congestion: [.low, .low, .low], from: 0), "all free: the plain route")
        XCTAssertNil(NavTraffic.runs(pts, congestion: [.heavy], from: 0), "a mismatched annotation is never drawn")
    }
}

/// Build 36 report: the blue route was hard to tell from the desert imagery and turns were not
/// marked on the line.
final class RouteVisibilityTests: XCTestCase {
    /// ~10 m per 0.0001° of latitude near Riyadh.
    private let corner = LngLat(lng: 46.7, lat: 24.7)
    /// North 200 m, then east 200 m (a right turn at `corner`).
    private var lRoute: [LngLat] {
        [LngLat(lng: 46.7, lat: 24.698), corner, LngLat(lng: 46.702, lat: 24.7)]
    }

    func testArrowRunsAlongTheRouteThroughTheTurn() throws {
        let s = try XCTUnwrap(NavManeuverArrow.shaft(lRoute, at: corner))
        XCTAssertEqual(s.count, 3, "start, the corner, end")
        XCTAssertEqual(Vehicle.distanceMeters(s[0], corner), NavManeuverArrow.beforeM, accuracy: 1)
        XCTAssertEqual(Vehicle.distanceMeters(corner, s[2]), NavManeuverArrow.afterM, accuracy: 1)
        XCTAssertEqual(s[1], corner)
        let b = try XCTUnwrap(NavManeuverArrow.headBearing(s))
        XCTAssertEqual(b, 90, accuracy: 1, "points east, the way the turn goes")
    }

    func testArrowSnapsAManeuverSlightlyOffTheLine() throws {
        let off = LngLat(lng: 46.70005, lat: 24.69998)
        let s = try XCTUnwrap(NavManeuverArrow.shaft(lRoute, at: off))
        XCTAssertGreaterThanOrEqual(s.count, 2)
    }

    func testNoArrowFarFromTheRouteOrAtItsEnd() {
        XCTAssertNil(NavManeuverArrow.shaft(lRoute, at: LngLat(lng: 46.71, lat: 24.71)), "another route's maneuver")
        XCTAssertNil(NavManeuverArrow.shaft(lRoute, at: lRoute.last!), "nothing after it to point along")
        XCTAssertNil(NavManeuverArrow.shaft([corner], at: corner))
    }

    func testShortRouteClampsToItsEnds() throws {
        let r = [LngLat(lng: 46.7, lat: 24.6999), corner, LngLat(lng: 46.7001, lat: 24.7)]
        let s = try XCTUnwrap(NavManeuverArrow.shaft(r, at: corner))
        XCTAssertEqual(s.first, r.first)
        XCTAssertEqual(s.last, r.last)
    }

    func testOnlyRealTurnsGetAnArrow() {
        XCTAssertTrue(NavManeuverArrow.shows(NavManeuver(kind: .turn, direction: .left)))
        XCTAssertTrue(NavManeuverArrow.shows(NavManeuver(kind: .roundabout, direction: nil, exit: 2)))
        XCTAssertTrue(NavManeuverArrow.shows(NavManeuver(kind: .offRamp, direction: .slightRight)))
        XCTAssertFalse(NavManeuverArrow.shows(NavManeuver(kind: .turn, direction: .straight)))
        XCTAssertFalse(NavManeuverArrow.shows(NavManeuver(kind: .continue, direction: .straight)))
        XCTAssertFalse(NavManeuverArrow.shows(NavManeuver(kind: .arrive, direction: nil)))
        XCTAssertFalse(NavManeuverArrow.shows(NavManeuver(kind: .depart, direction: .right)))
    }

    func testRouteHasADarkHaloAndATurnArrowLayer() {
        for id in [NavMapDrawer.haloLayer, "sary-nav-maneuver-casing", "sary-nav-maneuver", "sary-nav-maneuver-head"] {
            XCTAssertTrue(NavMapDrawer.layerIds.contains(id), id)
        }
        let halo = NavMapDrawer.layerIds.firstIndex(of: NavMapDrawer.haloLayer)!
        XCTAssertLessThan(halo, NavMapDrawer.layerIds.firstIndex(of: "sary-nav-main-casing")!, "under the white casing")
        XCTAssertGreaterThan(halo, NavMapDrawer.layerIds.firstIndex(of: "sary-nav-alt")!, "over the alternatives")
        XCTAssertGreaterThanOrEqual(NavMapDrawer.haloOpacity, 0.5)
        XCTAssertEqual(NavMapDrawer.arrowHead().size.width, 40)
    }

    func testRouteIsWiderAtGuidanceZooms() {
        let e = NavMapDrawer.width(8)
        var stops: [Double: Double] = [:]
        var i = 3
        while i + 1 < e.count {
            if let z = e[i] as? Double, let v = e[i + 1] as? Double { stops[z] = v }
            i += 2
        }
        XCTAssertGreaterThanOrEqual(stops[15] ?? 0, 8 * 1.15 - 0.01)
        XCTAssertGreaterThanOrEqual(stops[17] ?? 0, 8 * 1.5 - 0.01, "Build 36 had ×1.3 at z17")
    }

    func testMyCarHasAHaloUnderIt() {
        let l = Vehicle.myHaloLayer(id: Vehicle.haloId("sary-vehicle-spot"), source: "sary-vehicle")
        XCTAssertEqual(l["id"] as? String, "sary-vehicle-spot-halo")
        XCTAssertEqual(l["type"] as? String, "circle")
        let p = l["paint"] as? [String: Any]
        XCTAssertEqual(p?["circle-stroke-color"] as? String, "#ffffff")
    }
}
