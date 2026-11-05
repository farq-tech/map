import XCTest
@testable import SaryAlbarq

/// «الوضع الواقعي» (Apple MapKit realistic 3D imagery): entry gating, overlay mapping, camera.
@MainActor
final class RealisticTests: XCTestCase {
    private func member(_ id: String, _ presence: Policy.Freshness, me: Bool = false, heading: Double? = 90, color: UInt32 = 0x3A8DDE) -> MapMember {
        MapMember(id: id, position: LngLat(lng: 46.67, lat: 24.71), color: color, name: id, presence: presence,
                  heading: heading, accuracyM: 8, atMs: 0, note: nil, isMe: me)
    }

    // MARK: gating

    func testGateOpensOnlyStoppedOnlineAndNotGuiding() {
        XCTAssertEqual(RealisticRules.gate(speedMps: nil, navigating: false, online: true), .ok)
        XCTAssertEqual(RealisticRules.gate(speedMps: 15 / 3.6, navigating: false, online: true), .ok, "exactly 15 km/h is still allowed")
        XCTAssertEqual(RealisticRules.gate(speedMps: 16 / 3.6, navigating: false, online: true), .moving, "above 15 km/h")
        XCTAssertEqual(RealisticRules.gate(speedMps: 0, moving: true, navigating: false, online: true), .moving, "the trip's motion hysteresis says moving")
        XCTAssertEqual(RealisticRules.gate(speedMps: -1, navigating: false, online: true), .ok, "CoreLocation's -1 (unknown) is not movement")
        XCTAssertEqual(RealisticRules.gate(speedMps: 0, navigating: false, online: false), .offline)
        XCTAssertEqual(RealisticRules.gate(speedMps: 30, navigating: true, online: false), .navigating, "navigation wins: it stays on Mapbox")
        XCTAssertEqual(RealisticRules.gate(speedMps: 30, navigating: false, online: false), .moving)
    }

    func testOfflineSaysItNeedsInternet() {
        XCTAssertFalse(RealisticGate.offline.allowsMap)
        XCTAssertEqual(RealisticGate.offline.title, "يحتاج إنترنت")
        XCTAssertTrue(RealisticGate.offline.detail.contains("لا تُحفظ"), "honest: Apple imagery is never stored")
        XCTAssertTrue(RealisticGate.ok.allowsMap)
        for g in [RealisticGate.moving, .navigating, .offline] { XCTAssertFalse(g.title.isEmpty) }
    }

    // MARK: overlays

    func testMembersKeepColoursDropLostAndDrawMeLast() {
        let out = RealisticRules.members([
            member("me", .live, me: true, color: 0x111111),
            member("a", .live, color: 0xE5772A),
            member("b", .recent, heading: 10),
            member("c", .lost),
        ])
        XCTAssertEqual(out.map(\.id), ["a", "b", "me"], "lost dropped; me last (on top)")
        XCTAssertEqual(out.first { $0.id == "a" }?.color, 0xE5772A, "same colour as on the trip map")
        XCTAssertEqual(out.first { $0.id == "a" }?.heading, 90)
        XCTAssertEqual(out.first { $0.id == "b" }?.stale, true)
        XCTAssertNil(out.first { $0.id == "b" }?.heading, "no heading arrow on an old position")
        XCTAssertEqual(out.last?.isMe, true)
        XCTAssertEqual(RealisticRules.members([member("me", .lost, me: true)]).count, 1, "my own car is always drawn")
    }

    func testMarkersFromDestinationRallyWaypointsPlaces() {
        let place = SavedPlace(id: "p1", name: "المخيم", icon: .camp, lat: 25.1, lng: 46.1, createdAt: Date())
        let out = RealisticRules.markers(destination: OutingDestination(name: "", lat: 24.9, lng: 46.2),
                                         rally: MapRallyPoint(position: LngLat(lng: 46.3, lat: 24.8), label: "عند الشجرة"),
                                         waypoints: [MapWaypoint(id: "w", position: LngLat(lng: 46.4, lat: 24.7), kind: WaypointKind.allCases[0], title: "ماء")],
                                         places: [place])
        XCTAssertEqual(out.map(\.kind), [.destination, .rally, .waypoint, .place])
        XCTAssertEqual(out[0].title, "الوجهة", "an unnamed destination still reads")
        XCTAssertEqual(out[1].title, "عند الشجرة")
        XCTAssertEqual(out[3].systemImage, SavedPlaceIcon.camp.systemImage)
        XCTAssertEqual(out[3].position, place.position)
        XCTAssertTrue(RealisticRules.markers(destination: nil, rally: nil).isEmpty)
    }

    func testSpeedGradientFollowsTheTrackRamp() {
        let pts = (0..<5).map { LngLat(lng: 46.0 + Double($0) * 0.01, lat: 25.0) }
        let line = TrackLine(points: pts, speeds: [1, 1, 30, 30])
        let stops = RealisticRules.speedStops(line)
        XCTAssertNotNil(stops)
        XCTAssertEqual(stops?.first?.location, 0)
        XCTAssertEqual(stops?.last?.location, 1)
        XCTAssertEqual(stops?.first?.rgb, TrackGradient.rgb(kmh: 5), "slow start: light")
        XCTAssertEqual(stops?.last?.rgb, TrackGradient.rgb(kmh: 110), "fast end: dark (30 m/s ≈ 108 → 110 km/h bin)")
        XCTAssertEqual(stops?.count, 2, "equal neighbours merge")
        XCTAssertNil(RealisticRules.speedStops(TrackLine(points: pts)), "no speeds: a plain line")
        let many = TrackLine(points: (0..<400).map { LngLat(lng: 46 + Double($0) * 0.001, lat: 25) }, speeds: (0..<399).map { Double($0 % 40) })
        XCTAssertLessThanOrEqual(RealisticRules.speedStops(many, maxStops: 48)?.count ?? 0, 48)
    }

    // MARK: scenes & camera

    func testScenesFromEachEntry() {
        let p = LngLat(lng: 37.92, lat: 26.62)
        let point = RealisticScene.point(p, name: nil)
        XCTAssertEqual(point.focus, p)
        XCTAssertEqual(point.markers.count, 1)
        let place = RealisticScene.place(SavedPlace(id: "x", name: "الفيل", icon: .view, lat: 26.66, lng: 37.95, createdAt: Date()))
        XCTAssertEqual(place.title, "الفيل")
        XCTAssertEqual(place.markers.first?.kind, .place)
        let line = TrackLine(points: [LngLat(lng: 46.10, lat: 25.12), LngLat(lng: 46.12, lat: 25.13)])
        let track = RealisticScene.track(FollowSubject(id: "t", name: "شعيب", kind: .gpx, line: line, stats: TrackStats(distanceM: line.lengthM, maxKmh: nil, movingS: nil)))
        XCTAssertEqual(track.track, line)
        XCTAssertEqual(track.markers.map(\.id), ["start", "end"])
        XCTAssertNil(track.focus, "a track frames itself")
    }

    func testInitialCameraIsTiltedAndFitsEverything() {
        let near = RealisticRules.initialCamera(.point(LngLat(lng: 46.674, lat: 24.711), name: "برج المملكة"))
        XCTAssertEqual(near?.pitch, RealisticRules.tiltedPitch)
        XCTAssertEqual(near?.distance, 1_200, "a single point: a close 3D look")
        let line = TrackLine(points: [LngLat(lng: 46.0, lat: 25.0), LngLat(lng: 46.1, lat: 25.0)])
        let far = RealisticRules.initialCamera(RealisticScene(title: "", track: line))
        XCTAssertEqual(far?.center.lng ?? 0, 46.05, accuracy: 1e-9)
        XCTAssertGreaterThan(far?.distance ?? 0, 10_000, "~10 km track fits")
        XCTAssertLessThanOrEqual(far?.distance ?? .infinity, RealisticRules.maxDistance)
        XCTAssertNil(RealisticRules.initialCamera(RealisticScene(title: "")), "nothing to look at")
    }

    func testDroneOrbitsTheSameCentre() {
        let c = RealisticRules.Camera(center: LngLat(lng: 41.5, lat: 28), distance: 2_000, heading: 355, pitch: 20)
        let n = RealisticRules.droneStep(c)
        XCTAssertEqual(n.center, c.center)
        XCTAssertEqual(n.distance, c.distance)
        XCTAssertEqual(n.heading, (355 + RealisticRules.droneStepDegrees).truncatingRemainder(dividingBy: 360), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(n.pitch, 55, "a drone looks across, not straight down")
    }

    func testExplorationOffersTheRealisticEntry() {
        XCTAssertTrue(SaryMapControlItem.explore(terrain3D: false, tracksShown: 0).contains { $0.accessibilityID == "explore-realistic" })
    }

    // MARK: «اعرضها بالوضع الواقعي»

    func testMapboxCameraBecomesTheSameRealisticCamera() {
        let haram = LngLat(lng: 39.8262, lat: 21.4225)
        let c = RealisticRules.camera(fromMapbox: haram, zoom: 15.3, pitch: 58, bearing: -190, viewHeight: 874)
        XCTAssertEqual(c.center, haram)
        XCTAssertEqual(c.pitch, 58)
        XCTAssertEqual(c.heading, 170, accuracy: 1e-9, "bearing normalised to 0…360")
        /* z15.3 on an 874-pt view: ≈ 1.5 × 874 × 1.77 m/pt ≈ 2.3 km from the camera to the centre. */
        XCTAssertEqual(c.distance, 2_320, accuracy: 120)
        let closer = RealisticRules.camera(fromMapbox: haram, zoom: 16.3, pitch: 58, bearing: 0, viewHeight: 874)
        XCTAssertEqual(closer.distance, c.distance / 2, accuracy: 1, "one zoom level: half the distance")
    }

    func testSceneCameraWinsAndIsClampedToMapKit() {
        var s = RealisticScene.point(LngLat(lng: 39.8262, lat: 21.4225), name: "المسجد الحرام")
        s.camera = RealisticRules.Camera(center: LngLat(lng: 39.8262, lat: 21.42), distance: 120, heading: 170, pitch: 80)
        let c = RealisticRules.initialCamera(s)
        XCTAssertEqual(c?.center, LngLat(lng: 39.8262, lat: 21.42), "the trip map's own centre, not the point")
        XCTAssertEqual(c?.heading, 170)
        XCTAssertEqual(c?.distance, RealisticRules.minDistance)
        XCTAssertEqual(c?.pitch, RealisticRules.tiltedPitch)
    }
}
