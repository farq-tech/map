import XCTest
@testable import SaryAlbarq

/// The map logic ported from the web, checked case for case against the web's own
/// tests (`vehicleLayer.test.ts`, `suvModel.test.ts`, `roadSnap.test.ts`,
/// `roadMatch.test.ts`, `carColors.ts`) so both draw the same outing the same way.
final class VehicleTests: XCTestCase {
    func testRotationTurnsCompassHeadingIntoModelRotation() {
        XCTAssertEqual(Vehicle.rotation(0), [0, 0, 180])
        XCTAssertEqual(Vehicle.rotation(90), [0, 0, 270])
        XCTAssertEqual(Vehicle.rotation(270), [0, 0, 90])
        XCTAssertEqual(Vehicle.rotation(nil), [0, 0, 180])
        XCTAssertEqual(Vehicle.rotation(.nan), [0, 0, 180])
    }

    func testKeeps26pxOnScreenThenTrueSize() {
        func px(_ z: Double) -> Double { 4.9 * Vehicle.scaleAt(zoom: z) / (156_543.03 * cos(25 * Double.pi / 180) / pow(2, z)) }
        XCTAssertEqual(px(10), 26, accuracy: 0.5)
        XCTAssertEqual(px(15), 26, accuracy: 0.5)
        XCTAssertEqual(Vehicle.scaleAt(zoom: 21), 1)
        XCTAssertGreaterThan(Vehicle.scaleAt(zoom: 15), Vehicle.scaleAt(zoom: 16) * 1.9)
    }

    func testScaleStopsMatchTheWebExpression() {
        let stops = Vehicle.scaleStops
        XCTAssertEqual(stops.count, 19)
        XCTAssertEqual(stops.first?.zoom, 4)
        XCTAssertEqual(stops.last?.zoom, 22)
        /* Values the web's VEHICLE_SCALE computes (Math.round(v * 100) / 100). */
        XCTAssertEqual(stops.first { $0.zoom == 15 }?.scale, 22.97)
        XCTAssertEqual(stops.first { $0.zoom == 18 }?.scale, 2.87)
        XCTAssertEqual(stops.first { $0.zoom == 22 }?.scale, 1)
        let e = Vehicle.scaleExpression
        XCTAssertEqual(e[0] as? String, "interpolate")
        XCTAssertEqual(e.count, 3 + 19 * 2)
    }

    func testHeightScaleKeepsAnEnlargedCarLow() {
        XCTAssertEqual(Vehicle.heightScale(1), 1)
        XCTAssertLessThan(Vehicle.heightScale(20), 6)
    }

    func testIdsAndKeysAsOnTheWeb() {
        XCTAssertEqual(Vehicle.modelId(0xB3202B), "sary-suv-b3202b")
        XCTAssertEqual(Vehicle.ids("").layer, "sary-vehicle-3d")
        XCTAssertEqual(Vehicle.ids("peer-abc").spot, "sary-vehicle-spot-peer-abc")
        XCTAssertEqual(Vehicle.carKey("0000-4000-aB"), "peer-00004000aB")
    }

    func testOldPositionsAreFaded() {
        XCTAssertEqual(Vehicle.opacity(.live), 1)
        XCTAssertEqual(Vehicle.opacity(.recent), 0.7)
        XCTAssertEqual(Vehicle.opacity(.lost), 0.4)
    }

    func testBearingAndDistanceFromRealMovement() {
        let a = LngLat(lng: 46.67, lat: 24.78)
        XCTAssertEqual(Vehicle.bearing(a, LngLat(lng: 46.67, lat: 24.781)), 0, accuracy: 0.5)
        XCTAssertEqual(Vehicle.bearing(a, LngLat(lng: 46.671, lat: 24.78)), 90, accuracy: 0.5)
        XCTAssertEqual(Vehicle.bearing(a, LngLat(lng: 46.67, lat: 24.779)), 180, accuracy: 0.5)
        XCTAssertEqual(Vehicle.bearing(a, LngLat(lng: 46.669, lat: 24.78)), 270, accuracy: 0.5)
        let d = Vehicle.distanceMeters(a, LngLat(lng: 46.67, lat: 24.781))
        XCTAssertGreaterThan(d, 105)
        XCTAssertLessThan(d, 118)
    }

    func testGlideOnlyBetweenRealFixes() {
        XCTAssertEqual(Motion.tweenMs(gapMs: 4_000, distanceM: 50, reducedMotion: false), 1_000)
        XCTAssertEqual(Motion.tweenMs(gapMs: 400, distanceM: 50, reducedMotion: false), 300)
        XCTAssertEqual(Motion.tweenMs(gapMs: 4_000, distanceM: 2_500, reducedMotion: false), 0, "a long jump is not a slide")
        XCTAssertEqual(Motion.tweenMs(gapMs: 4_000, distanceM: 50, reducedMotion: true), 0)
        let mid = Motion.lerp(LngLat(lng: 0, lat: 0), LngLat(lng: 2, lat: 2), 0.5)
        XCTAssertEqual(mid.lng, 1, accuracy: 1e-9)
        XCTAssertEqual(Motion.lerp(LngLat(lng: 0, lat: 0), LngLat(lng: 2, lat: 2), 3), LngLat(lng: 2, lat: 2), "never past the last fix")
    }

    func testPaletteIsTheWebsInTheSameOrder() {
        let web = ["#e8eef0", "#d6452f", "#2f6fd6", "#f2b630", "#2fa56a", "#8a4fd1", "#f07f2f", "#1fb8c4", "#e05a9c", "#15191c", "#9aa5ad", "#7a5230"]
        XCTAssertEqual(CarColors.palette.map { "#" + Vehicle.hex($0) }, web)
    }
}

final class SuvModelTests: XCTestCase {
    /// Counts and coordinate sums of the web's `buildSuvParts()` (dumped from suvModel.ts with Node).
    private let web: [String: (verts: Int, idx: Int, posSum: Double, nrmAbsSum: Double)] = [
        "body": (72, 108, 107.4, 77.38583649671918),
        "glass": (24, 36, 19.2, 25.28018617583163),
        "trim": (1128, 1692, 1255.2, 1128),
        "tire": (900, 1080, 88.2, 997.2020921104504),
        "rim": (624, 756, 122.4, 693.0962644125068),
        "awning": (24, 36, 54, 24),
        "indicator": (48, 72, 157.44, 48),
        "headlight": (320, 384, 1075.2, 356.0265886554574),
        "taillight": (48, 72, -67.68, 48),
    ]

    func testSameGeometryAsTheWeb() {
        let parts = SuvModel.buildParts()
        XCTAssertEqual(Set(parts.keys), Set(web.keys))
        for (name, w) in web {
            let p = parts[name]!
            XCTAssertEqual(p.positions.count / 3, w.verts, name)
            XCTAssertEqual(p.indices.count, w.idx, name)
            XCTAssertEqual(p.positions.reduce(0, +), w.posSum, accuracy: 1e-6, name)
            XCTAssertEqual(p.normals.reduce(0) { $0 + abs($1) }, w.nrmAbsSum, accuracy: 1e-6, name)
        }
    }

    func testValidGlbWithJsonAndBinChunks() throws {
        let glb = SuvModel.glb(body: 0x1B2A4A)
        func u32(_ o: Int) -> UInt32 { glb.subdata(in: o ..< o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        XCTAssertEqual(u32(0), 0x4654_6C67)
        XCTAssertEqual(u32(4), 2)
        XCTAssertEqual(Int(u32(8)), glb.count)
        let jsonLen = Int(u32(12))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: glb.subdata(in: 20 ..< 20 + jsonLen)) as? [String: Any])
        XCTAssertEqual((json["asset"] as? [String: Any])?["version"] as? String, "2.0")
        let prims = ((json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [Any]) ?? []
        XCTAssertEqual(prims.count, 9)
        XCTAssertEqual(u32(20 + jsonLen + 4), 0x004E_4942)
        /* Same binary payload size as the web's .glb (84 984 bytes of vertices and indices). */
        XCTAssertEqual(Int(u32(20 + jsonLen)), 84_984)
        XCTAssertLessThan(glb.count, 100_000)
    }

    func testRealWorldProportionsOnTheGround() {
        let all = SuvModel.buildParts().values.flatMap(\.positions)
        let xs = stride(from: 0, to: all.count, by: 3).map { all[$0] }
        let ys = stride(from: 1, to: all.count, by: 3).map { all[$0] }
        let zs = stride(from: 2, to: all.count, by: 3).map { all[$0] }
        func span(_ a: [Double]) -> Double { a.max()! - a.min()! }
        XCTAssertGreaterThan(span(zs), 4.8)
        XCTAssertLessThan(span(zs), 5.4)
        XCTAssertGreaterThan(span(xs), 1.8)
        XCTAssertLessThan(span(xs), 2.3)
        XCTAssertEqual(ys.min()!, 0, accuracy: 0.05)
        XCTAssertLessThan(ys.max()!, 2.1)
    }

    func testBodyTakesTheMembersColourInLinearSpace() throws {
        let rgb = SuvModel.linear(0xD6452F)
        /* hexToLinear("#d6452f") on the web. */
        XCTAssertEqual(rgb[0], 0.6724431569576875, accuracy: 1e-12)
        XCTAssertEqual(rgb[1], 0.0595112381629812, accuracy: 1e-12)
        XCTAssertEqual(rgb[2], 0.028426039504420793, accuracy: 1e-12)
        let glb = SuvModel.glb(body: 0xD6452F)
        let jsonLen = Int(glb.subdata(in: 12 ..< 16).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: glb.subdata(in: 20 ..< 20 + jsonLen)) as? [String: Any])
        let mat = try XCTUnwrap((json["materials"] as? [[String: Any]])?.first)
        XCTAssertEqual(mat["name"] as? String, "body")
        let base = try XCTUnwrap((mat["pbrMetallicRoughness"] as? [String: Any])?["baseColorFactor"] as? [Double])
        XCTAssertEqual(base[0], rgb[0], accuracy: 1e-9)
    }
}

final class RoadSnapTests: XCTestCase {
    private let street: [[Double]] = [[46.66, 24.78], [46.67, 24.78]]

    func testMovesAFixInsideAHouseOntoTheStreet() throws {
        let s = try XCTUnwrap(RoadSnap.nearestOnLines(LngLat(lng: 46.665, lat: 24.78018), [street]))
        XCTAssertEqual(s.lat, 24.78, accuracy: 1e-6)
        XCTAssertEqual(s.lng, 46.665, accuracy: 1e-6)
    }

    func testLeavesACarAloneInOpenDesert() {
        XCTAssertNil(RoadSnap.nearestOnLines(LngLat(lng: 46.665, lat: 24.7808), [street]))
    }

    func testPicksTheNearestOfTwoStreets() throws {
        let north: [[Double]] = [[46.66, 24.7802], [46.67, 24.7802]]
        let s = try XCTUnwrap(RoadSnap.nearestOnLines(LngLat(lng: 46.665, lat: 24.78015), [street, north]))
        XCTAssertEqual(s.lat, 24.7802, accuracy: 1e-6)
    }

    func testSnapRadiusFollowsAccuracy25to60() {
        XCTAssertEqual(RoadSnap.snapRadius(5), 25)
        XCTAssertEqual(RoadSnap.snapRadius(30), 45)
        XCTAssertEqual(RoadSnap.snapRadius(65), 60)
        XCTAssertEqual(RoadSnap.snapRadius(nil), 40)
        XCTAssertNil(RoadSnap.nearestOnLines(LngLat(lng: 46.665, lat: 24.78045), [street], maxM: RoadSnap.snapRadius(5)),
                     "a sharp fix 50 m from a main road is not dragged onto it")
        XCTAssertNotNil(RoadSnap.nearestOnLines(LngLat(lng: 46.665, lat: 24.78045), [street]))
    }

    func testOnlyNearbyLinesAreConsidered() {
        let far = RoadSnap.RoadLine(key: "far", coords: [[46.70, 24.80], [46.71, 24.80]])
        let near = RoadSnap.RoadLine(key: "near", coords: street)
        XCTAssertEqual(RoadSnap.nearby([far, near], LngLat(lng: 46.66, lat: 24.7801)).map(\.key), ["near"])
    }
}

final class RoadMatchTests: XCTestCase {
    private let mLat = 1 / 110_540.0
    private let mLng = 1 / (111_320 * cos(24.78 * Double.pi / 180))
    private func at(_ eastM: Double, _ northM: Double) -> LngLat { LngLat(lng: 46.665 + eastM * mLng, lat: 24.78 + northM * mLat) }
    private func ew(_ key: String, _ northM: Double) -> RoadSnap.RoadLine { .init(key: key, coords: [[46.66, 24.78 + northM * mLat], [46.67, 24.78 + northM * mLat]]) }
    private func ns(_ key: String, _ eastM: Double) -> RoadSnap.RoadLine { .init(key: key, coords: [[46.665 + eastM * mLng, 24.775], [46.665 + eastM * mLng, 24.785]]) }
    private var south: RoadSnap.RoadLine { ew("south", 0) }
    private var north: RoadSnap.RoadLine { ew("north", 24) }

    func testDoesNotJumpToAParallelStreetOnOneWanderingFix() {
        let m = RoadSnap.Matcher()
        XCTAssertEqual(m.match(at(0, 4), [south, north], course: 90).key, "south")
        let r = m.match(at(5, 16), [south, north], course: 90)
        XCTAssertEqual(r.key, "south")
        XCTAssertEqual(r.point.lat, 24.78, accuracy: 1e-6)
        XCTAssertEqual(m.match(at(10, 5), [south, north], course: 90).key, "south")
    }

    func testMovesOnceClearlyCloserOnTwoFixesInARow() {
        let m = RoadSnap.Matcher()
        _ = m.match(at(0, 3), [south, north], course: 90)
        XCTAssertEqual(m.match(at(5, 21), [south, north], course: 90).key, "south")
        XCTAssertEqual(m.match(at(10, 22), [south, north], course: 90).key, "north")
    }

    func testNeedsTheTwoBetterFixesInARow() {
        let m = RoadSnap.Matcher()
        _ = m.match(at(0, 3), [south, north], course: 90)
        _ = m.match(at(5, 21), [south, north], course: 90)
        _ = m.match(at(10, 4), [south, north], course: 90)
        XCTAssertEqual(m.match(at(15, 21), [south, north], course: 90).key, "south")
    }

    func testSameFixTwiceIsNotASecondFix() {
        let m = RoadSnap.Matcher()
        _ = m.match(at(0, 3), [south, north], course: 90)
        let p = at(5, 21)
        _ = m.match(p, [south, north], course: 90)
        XCTAssertEqual(m.match(p, [south, north], course: 90).key, "south")
    }

    func testTakesTheNearestAtOnceWhenTheHeldOneIsOutOfReach() {
        let m = RoadSnap.Matcher()
        _ = m.match(at(0, 3), [south, north], course: 90)
        XCTAssertEqual(m.match(at(0, 70), [south, ew("far", 80)], course: 90, maxM: 40).key, "far")
    }

    func testLetsGoInOpenDesertAndDrawsTheRealFix() {
        let m = RoadSnap.Matcher()
        _ = m.match(at(0, 3), [south], course: 90)
        let p = at(0, 200)
        let r = m.match(p, [south], course: 90)
        XCTAssertNil(r.key)
        XCTAssertEqual(r.point, p)
        XCTAssertNil(m.road)
    }

    func testPrefersTheRoadTheCarDrivesAlong() {
        let cross = ns("cross", 0)
        let r = RoadSnap.Matcher().match(at(9, 6), [south, cross], course: 0)
        XCTAssertEqual(r.key, "cross")
        XCTAssertEqual(r.heading ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(RoadSnap.Matcher().match(at(9, 6), [south, cross], course: nil).key, "south", "without a course, nearest wins")
    }

    func testFollowsARealTurnWithinTwoFixes() {
        let cross = ns("cross", 0)
        let m = RoadSnap.Matcher()
        _ = m.match(at(-30, 2), [south, cross], course: 90)
        _ = m.match(at(-10, 1), [south, cross], course: 90)
        let a = m.match(at(1, 12), [south, cross], course: 5)
        let b = m.match(at(1, 25), [south, cross], course: 2)
        XCTAssertTrue([a.key, b.key].contains("cross"))
        XCTAssertEqual(b.key, "cross")
    }

    func testAlignHeading() {
        XCTAssertEqual(RoadSnap.alignHeading(80, 90), 90)
        XCTAssertEqual(RoadSnap.alignHeading(265, 90), 270)
        XCTAssertEqual(RoadSnap.alignHeading(355, 180), 0)
        XCTAssertEqual(RoadSnap.alignHeading(45, 90), 45, "keeps its own course while turning across a road")
        XCTAssertNil(RoadSnap.alignHeading(nil, 90), "never gives a parked car a direction")
    }

    func testRoadDirectionAtTheSnappedPoint() throws {
        let c = try XCTUnwrap(RoadSnap.candidates(at(0, 5), [south]).first)
        XCTAssertEqual(RoadSnap.axialDiff(90, c.bearing), 0, accuracy: 1e-3)
        XCTAssertEqual(c.distM, 5, accuracy: 0.5)
        let m = RoadSnap.Matcher()
        XCTAssertEqual(m.match(at(0, 4), [south], course: 98).heading ?? -1, 90, accuracy: 1e-3)
        XCTAssertEqual(m.match(at(5, 4), [south], course: 278).heading ?? -1, 270, accuracy: 1e-3)
    }
}

final class FramingAndLightTests: XCTestCase {
    func testGroupBoundsPadAbout60m() throws {
        let b = try XCTUnwrap(GroupFraming.bounds([LngLat(lng: 46.6, lat: 24.7), LngLat(lng: 46.7, lat: 24.8)]))
        XCTAssertEqual(b.west, 46.6 - 0.0006, accuracy: 1e-12)
        XCTAssertEqual(b.north, 24.8 + 0.0006, accuracy: 1e-12)
        XCTAssertNil(GroupFraming.bounds([]))
    }

    func testOffScreenCountsTheEdgeAsOut() {
        let view = GroupFraming.Bounds(west: 46.0, south: 24.0, east: 47.0, north: 25.0)
        XCTAssertFalse(GroupFraming.anyOffScreen([LngLat(lng: 46.5, lat: 24.5)], view: view))
        XCTAssertTrue(GroupFraming.anyOffScreen([LngLat(lng: 46.5, lat: 24.5), LngLat(lng: 46.95, lat: 24.5)], view: view), "within 8 % of the edge")
        XCTAssertFalse(GroupFraming.anyOffScreen([LngLat(lng: 46.95, lat: 24.5)], view: view, insetX: 0, insetY: 0))
        XCTAssertTrue(GroupFraming.anyOffScreen([LngLat(lng: 47.1, lat: 24.5)], view: view, insetX: 0, insetY: 0))
    }

    func testLightPresetFromTheSunInRiyadh() {
        let f = ISO8601DateFormatter()
        /* Riyadh is UTC+3: noon, after sunset, and night. */
        XCTAssertEqual(SunLight.preset(f.date(from: "2026-11-03T09:00:00Z")!, lat: 24.71, lng: 46.68), .day)
        XCTAssertEqual(SunLight.preset(f.date(from: "2026-11-03T14:30:00Z")!, lat: 24.71, lng: 46.68), .dusk)
        XCTAssertEqual(SunLight.preset(f.date(from: "2026-11-03T19:00:00Z")!, lat: 24.71, lng: 46.68), .night)
        XCTAssertEqual(SunLight.preset(f.date(from: "2026-11-03T02:55:00Z")!, lat: 24.71, lng: 46.68), .dawn)
    }

    func testTapFindsTheNearestCar() {
        let cars = [(id: "a", x: 100.0, y: 100.0), (id: "b", x: 140.0, y: 100.0)]
        XCTAssertEqual(CarHit.nearest((x: 125, y: 100), cars, radius: 28), "b")
        XCTAssertNil(CarHit.nearest((x: 300, y: 300), cars, radius: 28))
        XCTAssertEqual(CarHit.radius(zoom: 14, metersPerPoint: 0), 28)
        /* At true size (zoom 21, ~0.06 m/pt) the car is long on screen: the radius follows it. */
        XCTAssertGreaterThan(CarHit.radius(zoom: 21, metersPerPoint: 0.06), 40)
    }

    func testChipSaysOldPositionsInWords() {
        var c = MapMember(id: "a", position: LngLat(lng: 46.6, lat: 24.7), color: 0, name: "نورة", presence: .live, heading: nil, accuracyM: 8, atMs: 0, note: nil, isMe: false)
        XCTAssertEqual(c.chipLabel, "نورة")
        c.presence = .recent
        XCTAssertEqual(c.chipLabel, "نورة · آخر موقع")
        c.presence = .lost
        XCTAssertEqual(c.chipLabel, "نورة · انقطع")
        c.presence = .live
        c.accuracyM = 80
        XCTAssertTrue(c.approximate)
        XCTAssertEqual(c.chipLabel, "نورة · تقريبي")
        c.isMe = true
        c.accuracyM = 5
        XCTAssertEqual(c.chipLabel, "أنت")
    }
}
