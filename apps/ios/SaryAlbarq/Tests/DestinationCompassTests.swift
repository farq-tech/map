import XCTest
@testable import SaryAlbarq

/// «البوصلة» while driving: the pure rules (`DestinationCompass`, `CompassRain`, `CompassSpring`).
final class DestinationCompassTests: XCTestCase {
    private let riyadh = LngLat(lng: 46.6753, lat: 24.7136)

    /// About `m` metres from `p` toward `bearing` (equirectangular, fine at these distances).
    private func offset(_ p: LngLat, _ m: Double, bearing: Double) -> LngLat {
        let r = 6_371_000.0, k = Double.pi / 180
        let dy = m * cos(bearing * k), dx = m * sin(bearing * k)
        return LngLat(lng: p.lng + dx / (r * cos(p.lat * k)) / k, lat: p.lat + dy / r / k)
    }

    // MARK: needle, rose, distance

    func testCourseUpNeedleIsRelativeToHeading() {
        let target = offset(riyadh, 8000, bearing: 45)
        let r = DestinationCompass.reading(me: riyadh, course: 90, speed: 15, target: target, kind: .destination)
        XCTAssertTrue(r.headingUp)
        XCTAssertEqual(r.roseDegrees, -90, accuracy: 1e-9)
        XCTAssertEqual(r.needleDegrees, -45, accuracy: 0.5)
        XCTAssertEqual(r.distanceM, 8000, accuracy: 20)
        XCTAssertEqual(r.straightM, r.distanceM, accuracy: 1e-9)
        XCTAssertFalse(r.onPath)
        XCTAssertNil(r.markerDegrees)
        XCTAssertEqual(DestinationCompass.caption(r), "خط مستقيم")
    }

    func testNeedleWrapsAcrossNorth() {
        let target = offset(riyadh, 5000, bearing: 10)
        let r = DestinationCompass.reading(me: riyadh, course: 350, speed: 20, target: target, kind: .destination)
        XCTAssertEqual(r.needleDegrees, 20, accuracy: 0.5)
        XCTAssertEqual(r.roseDegrees, 10, accuracy: 1e-9)
        let behind = DestinationCompass.reading(me: riyadh, course: 45, speed: 20, target: offset(riyadh, 5000, bearing: 225), kind: .destination)
        XCTAssertEqual(abs(behind.needleDegrees), 180, accuracy: 0.5)
    }

    func testNorthUpWhenSlowOrNoHeading() {
        let target = offset(riyadh, 3000, bearing: 120)
        let cases: [(Double?, Double?)] = [(200, 1), (nil, 20), (200, nil)]
        for (course, speed) in cases {
            let r = DestinationCompass.reading(me: riyadh, course: course, speed: speed, target: target, kind: .back)
            XCTAssertFalse(r.headingUp)
            XCTAssertEqual(r.roseDegrees, 0)
            XCTAssertEqual(r.needleDegrees, 120, accuracy: 0.5)
        }
    }

    func testQiblaUsesTheKaaba() {
        let r = DestinationCompass.reading(me: riyadh, course: nil, speed: nil, target: DestinationCompass.kaaba, kind: .qibla)
        XCTAssertEqual(r.targetBearing, 244, accuracy: 2)
        XCTAssertEqual(r.distanceM / 1000, 790, accuracy: 30)
    }

    func testUnwrapTakesTheShortWayRound() {
        XCTAssertEqual(DestinationCompass.unwrap(previous: 359, next: 1), 361, accuracy: 1e-9)
        XCTAssertEqual(DestinationCompass.unwrap(previous: -170, next: 170), -190, accuracy: 1e-9)
        XCTAssertEqual(DestinationCompass.unwrap(previous: 720, next: 90), 810, accuracy: 1e-9)
    }


    // MARK: the needle is the target relative to the car

    func testCarTurnsLeftDestinationOnRightNeedleTurnsRight() {
        let target = offset(riyadh, 5000, bearing: 90)           // due east
        let ahead = DestinationCompass.reading(me: riyadh, course: 90, speed: 20, target: target, kind: .destination)
        XCTAssertEqual(ahead.needleDegrees, 0, accuracy: 0.5)     // facing it: straight up
        let left = DestinationCompass.reading(me: riyadh, course: 45, speed: 20, target: target, kind: .destination)
        XCTAssertEqual(left.needleDegrees, 45, accuracy: 0.5)     // the car turned left: the needle moves right
        let lefter = DestinationCompass.reading(me: riyadh, course: 0, speed: 20, target: target, kind: .destination)
        XCTAssertEqual(lefter.needleDegrees, 90, accuracy: 0.5)
        XCTAssertGreaterThan(lefter.needleDegrees, left.needleDegrees)
    }

    func testDestinationAheadIsZero() {
        let r = DestinationCompass.reading(me: riyadh, course: 30, speed: 20, target: offset(riyadh, 4000, bearing: 30), kind: .destination)
        XCTAssertEqual(r.needleDegrees, 0, accuracy: 0.5)
        XCTAssertEqual(r.headingSource, .course)
    }

    func testStoppedUsesTheMagnetometer() {
        let target = offset(riyadh, 3000, bearing: 90)
        let r = DestinationCompass.reading(me: riyadh, course: 200, speed: 0.2, compass: 0, target: target, kind: .destination)
        XCTAssertTrue(r.headingUp)
        XCTAssertEqual(r.headingSource, .magnetometer)
        XCTAssertEqual(r.needleDegrees, 90, accuracy: 0.5)
        XCTAssertEqual(r.roseDegrees, 0, accuracy: 1e-9)
        let turned = DestinationCompass.reading(me: riyadh, course: nil, speed: nil, compass: 270, target: target, kind: .destination)
        XCTAssertEqual(abs(turned.needleDegrees), 180, accuracy: 0.5)
        XCTAssertEqual(turned.roseDegrees, 90, accuracy: 1e-9)
        /* A trusted course wins over the magnetometer. */
        let moving = DestinationCompass.reading(me: riyadh, course: 90, speed: 20, compass: 270, target: target, kind: .destination)
        XCTAssertEqual(moving.headingSource, .course)
        XCTAssertEqual(moving.needleDegrees, 0, accuracy: 0.5)
        /* Neither: north up. */
        let none = DestinationCompass.reading(me: riyadh, course: nil, speed: 0, compass: nil, target: target, kind: .destination)
        XCTAssertEqual(none.headingSource, .none)
        XCTAssertFalse(none.headingUp)
        XCTAssertEqual(none.needleDegrees, 90, accuracy: 0.5)
    }

    func testMagnetometerFilter() {
        XCTAssertEqual(DeviceHeading.accept(trueHeading: 123, magneticHeading: 120, accuracy: 10), 123)
        XCTAssertEqual(DeviceHeading.accept(trueHeading: -1, magneticHeading: 120, accuracy: 10), 120)
        XCTAssertNil(DeviceHeading.accept(trueHeading: 123, magneticHeading: 120, accuracy: -1))
        XCTAssertNil(DeviceHeading.accept(trueHeading: 123, magneticHeading: 120, accuracy: 80))
    }

    func testNeedleTakesTheShortArcAcrossNorth() {
        let target = offset(riyadh, 4000, bearing: 0)
        let a = DestinationCompass.reading(me: riyadh, course: 359, speed: 20, target: target, kind: .destination)
        let b = DestinationCompass.reading(me: riyadh, course: 1, speed: 20, target: target, kind: .destination)
        XCTAssertEqual(a.needleDegrees, 1, accuracy: 0.5)
        XCTAssertEqual(b.needleDegrees, -1, accuracy: 0.5)
        /* The animated angle moves 2°, not 358°. */
        XCTAssertEqual(DestinationCompass.unwrap(previous: a.needleDegrees, next: b.needleDegrees), -1, accuracy: 0.5)
        XCTAssertEqual(DestinationCompass.unwrap(previous: a.roseDegrees, next: b.roseDegrees), -1, accuracy: 0.01)
        XCTAssertEqual(DestinationCompass.unwrap(previous: 359, next: 1), 361, accuracy: 1e-9)
    }

    func testRolesSwapNeedleIsTargetMarkerIsPath() throws {
        /* Path north 1 km then east 1 km; I am at the start, facing north. */
        let corner = offset(riyadh, 1000, bearing: 0)
        let path = northPath(1000) + stride(from: 100.0, through: 1000, by: 100).map { offset(corner, $0, bearing: 90) }
        let g = try XCTUnwrap(DestinationCompass.guide(path: path, me: riyadh, speedMps: 20))
        let r = DestinationCompass.reading(me: riyadh, course: 0, speed: 20, target: path[path.count - 1], kind: .destination, guide: g)
        XCTAssertEqual(r.needleDegrees, 45, accuracy: 1, "the needle is the straight line to the target")
        XCTAssertEqual(try XCTUnwrap(r.markerDegrees), 0, accuracy: 1, "the small marker is the path's lookahead")
        let noPath = DestinationCompass.reading(me: riyadh, course: 0, speed: 20, target: path[path.count - 1], kind: .destination)
        XCTAssertNil(noPath.markerDegrees)
        XCTAssertEqual(noPath.needleDegrees, r.needleDegrees, accuracy: 1e-9)
    }

    func testQiblaNeedleFollowsTheCar() {
        let r = DestinationCompass.reading(me: riyadh, course: nil, speed: 0, compass: 244, target: DestinationCompass.kaaba, kind: .qibla)
        XCTAssertEqual(r.needleDegrees, 0, accuracy: 2)
    }

    // MARK: path lookahead

    private func northPath(_ m: Double) -> [LngLat] {
        stride(from: 0.0, through: m, by: 100).map { offset(riyadh, $0, bearing: 0) }
    }

    func testLookaheadDistanceFollowsSpeed() {
        XCTAssertEqual(DestinationCompass.lookahead(speedMps: nil), 150)
        XCTAssertEqual(DestinationCompass.lookahead(speedMps: 5), 150)
        XCTAssertEqual(DestinationCompass.lookahead(speedMps: 15), 300)
    }

    func testLookaheadAlongPolyline() throws {
        let path = northPath(2000)
        let me = offset(riyadh, 500, bearing: 0)
        let fast = try XCTUnwrap(DestinationCompass.guide(path: path, me: me, speedMps: 20))
        XCTAssertFalse(fast.offPath)
        XCTAssertEqual(PlanGeo.meters(riyadh, fast.aim), 800, accuracy: 3)
        XCTAssertEqual(fast.remainingM, 1500, accuracy: 3)
        let slow = try XCTUnwrap(DestinationCompass.guide(path: path, me: me, speedMps: 3))
        XCTAssertEqual(PlanGeo.meters(riyadh, slow.aim), 650, accuracy: 3)
        /* Near the end the aim stops at the end. */
        let end = try XCTUnwrap(DestinationCompass.guide(path: path, me: offset(riyadh, 1900, bearing: 0), speedMps: 20))
        XCTAssertEqual(PlanGeo.meters(riyadh, end.aim), 2000, accuracy: 3)
    }

    func testOffPathAimsAtNearestPoint() throws {
        let path = northPath(2000)
        let me = offset(offset(riyadh, 1000, bearing: 0), 400, bearing: 90)
        let g = try XCTUnwrap(DestinationCompass.guide(path: path, me: me, speedMps: 20))
        XCTAssertTrue(g.offPath)
        XCTAssertEqual(g.offsetM, 400, accuracy: 3)
        XCTAssertEqual(PlanGeo.meters(riyadh, g.aim), 1000, accuracy: 3)
        XCTAssertEqual(g.remainingM, 1400, accuracy: 5)
        let r = DestinationCompass.reading(me: me, course: 0, speed: 20, target: path[path.count - 1], kind: .destination, guide: g)
        /* The needle is the target itself (1 km north, 0.4 km west of me: about −22°); the marker leads back onto the path (west). */
        XCTAssertEqual(r.needleDegrees, -21.8, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(r.markerDegrees), -90, accuracy: 1)
        XCTAssertEqual(DestinationCompass.caption(r), "ارجع للمسار")
    }

    func testNoPathFallsBackToStraightLine() {
        XCTAssertNil(DestinationCompass.guide(path: [], me: riyadh, speedMps: 20))
        XCTAssertNil(DestinationCompass.guide(path: [riyadh], me: riyadh, speedMps: 20))
    }

    func testOnPathReadingShowsAlongDistanceAndMarker() throws {
        /* An L-shaped path: north 1 km, then east 1 km. The needle points at the end (the target), the marker leads up the path. */
        let corner = offset(riyadh, 1000, bearing: 0)
        let path = northPath(1000) + stride(from: 100.0, through: 1000, by: 100).map { offset(corner, $0, bearing: 90) }
        let end = path[path.count - 1]
        let g = try XCTUnwrap(DestinationCompass.guide(path: path, me: riyadh, speedMps: 20))
        let r = DestinationCompass.reading(me: riyadh, course: 0, speed: 20, target: end, kind: .destination, guide: g)
        XCTAssertTrue(r.onPath)
        XCTAssertEqual(r.needleDegrees, 45, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(r.markerDegrees), 0, accuracy: 1)
        XCTAssertEqual(r.distanceM, 2000, accuracy: 5)
        XCTAssertEqual(DestinationCompass.caption(r), "على المسار")
        XCTAssertTrue(DestinationCompass.accessibility(r).hasPrefix("الوجهة: باقي ٢ كم على المسار، الوجهة نفسها باتجاه"))
    }

    func testTailBeyondRouteEndIsAdded() {
        let g = DestinationCompass.PathGuide(aim: riyadh, remainingM: 1000, offPath: false, offsetM: 0)
        let end = offset(riyadh, 1000, bearing: 0)
        XCTAssertEqual(DestinationCompass.addingTail(g, pathEnd: end, target: offset(end, 50, bearing: 0)).remainingM, 1000)
        XCTAssertEqual(DestinationCompass.addingTail(g, pathEnd: end, target: offset(end, 600, bearing: 0)).remainingM, 1600, accuracy: 2)
    }

    // MARK: targets, visibility, words

    func testResolveDefaults() {
        typealias T = DestinationCompass.Target
        XCTAssertEqual(DestinationCompass.resolve(chosen: nil, available: [.destination, .back, .qibla], returning: true), T.destination)
        XCTAssertEqual(DestinationCompass.resolve(chosen: nil, available: [.back, .qibla], returning: true), T.back)
        XCTAssertEqual(DestinationCompass.resolve(chosen: nil, available: [.back, .qibla], returning: false), T.qibla)
        XCTAssertEqual(DestinationCompass.resolve(chosen: .rain, available: [.destination, .qibla, .rain], returning: false), T.rain)
        /* A choice that is no longer available falls back. */
        XCTAssertEqual(DestinationCompass.resolve(chosen: .spring, available: [.destination, .qibla], returning: false), T.destination)
    }

    func testShowsOnlyWhileDrivingAtPeekOnRoomyScreens() {
        func shows(driving: Bool = true, guiding: Bool = false, offRoad: Bool = false, exploring: Bool = false, ended: Bool = false,
                   peek: Bool = true, sos: Bool = false, bell: Bool = false, height: CGFloat = 852) -> Bool {
            DestinationCompass.shows(driving: driving, guiding: guiding, offRoad: offRoad, exploring: exploring, ended: ended, peek: peek,
                                     sosFocused: sos, bellOpen: bell, screenHeight: height)
        }
        XCTAssertTrue(shows())
        XCTAssertTrue(shows(driving: false, guiding: true))
        XCTAssertFalse(shows(driving: false))
        XCTAssertFalse(shows(offRoad: true))
        XCTAssertFalse(shows(exploring: true))
        XCTAssertFalse(shows(ended: true))
        XCTAssertFalse(shows(peek: false))
        XCTAssertFalse(shows(sos: true))
        XCTAssertFalse(shows(bell: true))
        XCTAssertFalse(shows(height: 667))
    }

    func testAccessibilityStraightLine() {
        let r = DestinationCompass.reading(me: riyadh, course: nil, speed: nil, target: offset(riyadh, 23_000, bearing: 270), kind: .rain)
        XCTAssertEqual(DestinationCompass.accessibility(r), "أقرب مطر: ٢٣ كم، باتجاه الغرب")
    }

    func testFetchCacheAndBbox() {
        let now = Date()
        XCTAssertTrue(DestinationCompass.needsFetch(fetchedAt: nil, origin: nil, me: riyadh, now: now))
        XCTAssertFalse(DestinationCompass.needsFetch(fetchedAt: now.addingTimeInterval(-60), origin: riyadh, me: riyadh, now: now))
        XCTAssertTrue(DestinationCompass.needsFetch(fetchedAt: now.addingTimeInterval(-16 * 60), origin: riyadh, me: riyadh, now: now))
        XCTAssertTrue(DestinationCompass.needsFetch(fetchedAt: now, origin: riyadh, me: offset(riyadh, 40_000, bearing: 0), now: now))
        XCTAssertEqual(DestinationCompass.bbox(around: LngLat(lng: 46.5, lat: 24.5)), "45.00,23.00,48.00,26.00")
    }

    // MARK: «أقرب مطر»

    func testRainPrefersFiveMillimetres() throws {
        let near = CompassRainCell(position: offset(riyadh, 5_000, bearing: 0), mm: 2, hoursAgo: 3)
        let far = CompassRainCell(position: offset(riyadh, 30_000, bearing: 90), mm: 12, hoursAgo: 3)
        let farther = CompassRainCell(position: offset(riyadh, 60_000, bearing: 90), mm: 20, hoursAgo: 1)
        XCTAssertEqual(CompassRain.nearest([farther, near, far], me: riyadh), far)
        /* No ≥ 5 mm: the nearest ≥ 1 mm. */
        let light = CompassRainCell(position: offset(riyadh, 40_000, bearing: 0), mm: 1.5, hoursAgo: nil)
        XCTAssertEqual(CompassRain.nearest([light, near], me: riyadh), near)
        XCTAssertNil(CompassRain.nearest([], me: riyadh))
        XCTAssertNil(CompassRain.nearest([CompassRainCell(position: riyadh, mm: 0.5, hoursAgo: nil)], me: riyadh))
        XCTAssertEqual(CompassRain.line(far), "مطر ١٢ ملم · قبل ٣ ساعات")
    }

    func testRainCellsParseRows() {
        let cells = CompassRain.cells([[46.7, 24.9, 12.3, 3], [46.8, 25.0, 4, nil], [nil, 25, 3, 1], [46.1, 24.0]])
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].mm, 12.3)
        XCTAssertNil(cells[1].hoursAgo)
    }

    // MARK: «أقرب ربيع»

    private func region(_ id: String, area: Double, points: [LngLat], centroid: LngLat? = nil, place: String? = nil) -> GreenRegion {
        GreenRegion(id: id, centroid: centroid.map { [$0.lng, $0.lat] }, area_km2: area, level: "clear", label_ar: "ربيع واضح",
                    points: points.map { [$0.lng, $0.lat] }, place: place.map { GreenRegion.Place(name: $0, kind: "rawdah", distance_km: 1) })
    }

    func testSpringNearestByPoints() throws {
        /* Region a's centroid is far but its edge is near: it wins, and the needle aims at that edge. */
        let edge = offset(riyadh, 4_000, bearing: 0)
        let a = region("a", area: 10, points: [edge, offset(riyadh, 20_000, bearing: 0)], centroid: offset(riyadh, 12_000, bearing: 0))
        let b = region("b", area: 10, points: [offset(riyadh, 8_000, bearing: 180)])
        let pick = try XCTUnwrap(CompassSpring.nearest([b, a], me: riyadh))
        XCTAssertEqual(pick.regionID, "a")
        XCTAssertEqual(pick.point, edge)
        XCTAssertEqual(pick.distanceM, 4_000, accuracy: 5)
        /* No points: the centroid. */
        let c = region("c", area: 5, points: [], centroid: offset(riyadh, 2_000, bearing: 90))
        XCTAssertEqual(CompassSpring.nearest([a, c], me: riyadh)?.regionID, "c")
    }

    func testSpringPrefersANamedPlaceWithinOneAndAHalf() {
        let plain = region("plain", area: 10, points: [offset(riyadh, 4_000, bearing: 0)])
        let rawdah = region("rawdah", area: 10, points: [offset(riyadh, 5_500, bearing: 90)], place: "روضة خريم")
        let farRawdah = region("far", area: 10, points: [offset(riyadh, 7_000, bearing: 90)], place: "روضة نورة")
        XCTAssertEqual(CompassSpring.nearest([plain, rawdah], me: riyadh)?.regionID, "rawdah")
        XCTAssertEqual(CompassSpring.nearest([plain, farRawdah], me: riyadh)?.regionID, "plain")
    }

    func testSpringAreaFloorAndEmpty() {
        let speck = region("speck", area: 2.5, points: [offset(riyadh, 500, bearing: 0)])
        let big = region("big", area: 6.4, points: [offset(riyadh, 9_000, bearing: 0)], place: "روضة خريم")
        let pick = CompassSpring.nearest([speck, big], me: riyadh)
        XCTAssertEqual(pick?.regionID, "big")
        XCTAssertNil(CompassSpring.nearest([], me: riyadh))
        XCTAssertNil(CompassSpring.nearest([speck], me: riyadh))
        XCTAssertEqual(pick.map(CompassSpring.line), "روضة خريم · ربيع واضح · ٦ كم²")
    }
}

/// «زفلت ١٢ كم ← ترابي ٢ كم ← بر مفتوح ٤ كم»: the route's surfaces in driving order (`NavSurfaceAhead`).
final class NavSurfaceAheadTests: XCTestCase {
    private typealias P = NavSurfaceAhead.Piece

    func testMergesAdjacentAndKeepsOrder() {
        let s = NavSurfaceAhead.spans([P(kind: .paved, meters: 8_000), P(kind: .paved, meters: 4_000), P(kind: .unpaved, meters: 2_000),
                                       P(kind: .terrain, meters: 4_000)])
        XCTAssertEqual(s.map(\.kind), [.paved, .unpaved, .terrain])
        XCTAssertEqual(s.map(\.meters), [12_000, 2_000, 4_000])
        XCTAssertEqual(s.map(\.startM), [0, 12_000, 14_000])
        XCTAssertEqual(NavSurfaceAhead.line(s), "زفلت ١٢ كم ← ترابي ٢ كم ← بر مفتوح ٤ كم")
    }

    func testShortRunsFoldIntoANeighbour() {
        /* A 60 m dirt driveway between two asphalt stretches disappears and the asphalt joins up. */
        let s = NavSurfaceAhead.spans([P(kind: .paved, meters: 5_000), P(kind: .unpaved, meters: 60), P(kind: .paved, meters: 3_000),
                                       P(kind: .gridSnap, meters: 40), P(kind: .terrain, meters: 2_000)])
        XCTAssertEqual(s.map(\.kind), [.paved, .terrain])
        XCTAssertEqual(s[0].meters, 8_100, accuracy: 1e-9)
        XCTAssertEqual(s.reduce(0) { $0 + $1.meters }, 10_100, accuracy: 1e-9)
        /* At the very start a sliver goes into the next stretch. */
        let first = NavSurfaceAhead.spans([P(kind: .unknown, meters: 30), P(kind: .paved, meters: 1_000)])
        XCTAssertEqual(first.map(\.kind), [.paved])
        XCTAssertEqual(first[0].meters, 1_030, accuracy: 1e-9)
    }

    func testRemainingCutsUnderTheCar() {
        let s = NavSurfaceAhead.spans([P(kind: .paved, meters: 12_000), P(kind: .unpaved, meters: 2_000), P(kind: .terrain, meters: 4_000)])
        let r = NavSurfaceAhead.remaining(s, done: 9_000)
        XCTAssertEqual(r.map(\.kind), [.paved, .unpaved, .terrain])
        XCTAssertEqual(r[0].meters, 3_000, accuracy: 1e-9)
        XCTAssertEqual(r[0].startM, 9_000, accuracy: 1e-9)
        XCTAssertEqual(NavSurfaceAhead.remaining(s, done: 13_000).map(\.kind), [.unpaved, .terrain])
        /* 50 m of asphalt left: folded into the dirt that follows. */
        let sliver = NavSurfaceAhead.remaining(s, done: 11_950)
        XCTAssertEqual(sliver.map(\.kind), [.unpaved, .terrain])
        XCTAssertEqual(sliver[0].meters, 2_050, accuracy: 1e-9)
        XCTAssertTrue(NavSurfaceAhead.remaining(s, done: 18_000).isEmpty)
    }

    func testShowsOnlyWithDirtOrOffRoad() {
        XCTAssertFalse(NavSurfaceAhead.shows(NavSurfaceAhead.spans([P(kind: .paved, meters: 9_000)])))
        XCTAssertFalse(NavSurfaceAhead.shows(NavSurfaceAhead.spans([P(kind: .paved, meters: 9_000), P(kind: .unknown, meters: 500)])))
        XCTAssertFalse(NavSurfaceAhead.shows([]))
        XCTAssertTrue(NavSurfaceAhead.shows(NavSurfaceAhead.spans([P(kind: .paved, meters: 9_000), P(kind: .rough, meters: 500)])))
    }

    func testLineListsThreeThenPlus() {
        let s = NavSurfaceAhead.spans([P(kind: .paved, meters: 3_000), P(kind: .unpaved, meters: 1_000), P(kind: .terrain, meters: 2_000),
                                       P(kind: .rough, meters: 500)])
        XCTAssertEqual(NavSurfaceAhead.line(s), "زفلت ٣ كم ← ترابي ١ كم ← بر مفتوح ٢ كم ← +")
        XCTAssertEqual(NavSurfaceAhead.accessibility(s), "الباقي من الطريق: زفلت ٣ كم، ثم ترابي ١ كم، ثم بر مفتوح ٢ كم، ثم وعر ٥٠٠ م")
    }

    func testPiecesFromRunsUseTheCachedSums() {
        let a = LngLat(lng: 46.70, lat: 24.70), b = LngLat(lng: 46.70, lat: 24.71), c = LngLat(lng: 46.70, lat: 24.72)
        let runs = [NavSurfaceRun(kind: .paved, coordinates: [a, b]), NavSurfaceRun(kind: .unpaved, coordinates: [b, c]),
                    NavSurfaceRun(kind: .terrain, coordinates: [c])]
        let measured = NavSurfaceAhead.pieces(runs)
        let cached = NavSurfaceAhead.pieces(runs, cum: NavRouteMetrics.surfaceCumulative(runs))
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(measured.map(\.kind), cached.map(\.kind))
        XCTAssertEqual(measured[1].meters, cached[1].meters, accuracy: 1e-6)
    }
}
