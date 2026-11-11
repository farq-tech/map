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

/// The modelled expedition SUV (Resources/Models/SuvExpedition.glb) and its per-member paint.
final class SuvAssetTests: XCTestCase {
    private func json(_ glb: Data) throws -> [String: Any] {
        let len = Int(glb.subdata(in: 12 ..< 16).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: glb.subdata(in: 20 ..< 20 + len)) as? [String: Any])
    }

    private func color(_ glb: Data, _ material: String) throws -> [Double] {
        let mats = try XCTUnwrap(try json(glb)["materials"] as? [[String: Any]])
        let m = try XCTUnwrap(mats.first { $0["name"] as? String == material })
        return try XCTUnwrap((m["pbrMetallicRoughness"] as? [String: Any])?["baseColorFactor"] as? [Double])
    }

    private let members: [UInt32] = [0xE8EEF0, 0xD6452F, 0x2F6FD6, 0xF2B630, 0x2FA56A, 0x8A4FD1, 0xF07F2F, 0x1FB8C4, 0xE05A9C, 0x15191C]

    func testAssetIsBundledSmallAndHasTheMaterialContract() throws {
        let glb = try XCTUnwrap(SuvModel.bundledGlb())
        XCTAssertLessThan(glb.count, 1_000_000)
        let names = Set(try XCTUnwrap(try json(glb)["materials"] as? [[String: Any]]).compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["BODY", "TRIM", "GLASS", "TYRE", "RIM", "HEADLIGHT", "TAILLIGHT", "SHADOW"]))
    }

    func testAssetSitsOnTheGroundNoseForwardAtCarSize() throws {
        let j = try json(try XCTUnwrap(SuvModel.bundledGlb()))
        let accessors = try XCTUnwrap(j["accessors"] as? [[String: Any]])
        let prims = try XCTUnwrap((j["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])
        let mats = try XCTUnwrap(j["materials"] as? [[String: Any]])
        var mn = [Double.infinity, .infinity, .infinity], mx = [-Double.infinity, -.infinity, -.infinity]
        var spareZ = 0.0, headZ = 0.0
        for p in prims {
            let name = mats[p["material"] as! Int]["name"] as? String ?? ""
            guard !name.hasPrefix("SHADOW"), name != "RIMLIGHT" else { continue }
            let a = accessors[(p["attributes"] as! [String: Int])["POSITION"]!]
            let lo = a["min"] as! [Double], hi = a["max"] as! [Double]
            for k in 0 ..< 3 { mn[k] = min(mn[k], lo[k]); mx[k] = max(mx[k], hi[k]) }
            if name == "HEADLIGHT" { headZ = hi[2] }
            if name == "TYRE" { spareZ = lo[2] }
        }
        XCTAssertEqual(mn[1], 0, accuracy: 0.03)            // on the ground
        XCTAssertEqual(mx[2] - mn[2], 4.9, accuracy: 0.2)   // length incl. the spare (Z)
        XCTAssertEqual(mx[0] - mn[0], 1.95, accuracy: 0.15) // width incl. mirrors (X)
        XCTAssertEqual(mx[1], 1.9, accuracy: 0.12)          // height incl. rack and awning (Y)
        XCTAssertEqual(mn[0] + mx[0], 0, accuracy: 0.15)    // centred
        XCTAssertGreaterThan(headZ, 2)                      // nose at +Z, as `Vehicle.rotation` expects
        XCTAssertLessThan(spareZ, -2.2)                     // spare tyre at the tail
    }

    func testEachMemberColourPaintsOnlyTheBody() throws {
        let src = try XCTUnwrap(SuvModel.bundledGlb())
        let glass = try color(src, "GLASS")
        for c in members {
            let out = try XCTUnwrap(SuvModel.recolored(src, body: c))
            let body = try color(out, "BODY")
            let rgb = SuvModel.linear(c)
            for k in 0 ..< 3 { XCTAssertEqual(body[k], rgb[k], accuracy: 1e-9) }
            XCTAssertEqual(body[3], 1)
            for (a, b) in zip(try color(out, "GLASS"), glass) { XCTAssertEqual(a, b, accuracy: 1e-9) }
            /* Binary chunk is untouched: same total minus the JSON difference. */
            XCTAssertEqual(out.count % 4, 0)
            let len = Int(out.subdata(in: 8 ..< 12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            XCTAssertEqual(len, out.count)
        }
    }

    func testBlackBodyGetsLighterTrimOthersKeepBlack() throws {
        let src = try XCTUnwrap(SuvModel.bundledGlb())
        let black = try XCTUnwrap(SuvModel.recolored(src, body: 0x15191C))
        XCTAssertEqual(try color(black, "TRIM")[0], SuvModel.linear(SuvModel.darkBodyTrimHex)[0], accuracy: 1e-9)
        XCTAssertGreaterThan(try color(black, "TRIM")[0], try color(black, "BODY")[0] * 3)
        for c in members.dropLast() {
            XCTAssertFalse(SuvModel.needsLightTrim(c), String(c, radix: 16))
            for (a, b) in zip(try color(try XCTUnwrap(SuvModel.recolored(src, body: c)), "TRIM"), try color(src, "TRIM")) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        }
        XCTAssertTrue(SuvModel.needsLightTrim(0x15191C))
        XCTAssertEqual(SuvModel.trim(for: 0x15191C), SuvModel.darkBodyTrimHex)
        XCTAssertEqual(SuvModel.trim(for: 0xD6452F), SuvModel.trimHex)
    }

    func testFallsBackToTheProceduralCar() throws {
        XCTAssertNil(SuvModel.recolored(Data("not a glb".utf8), body: 0xD6452F))
        XCTAssertNil(SuvModel.recolored(SuvModel.glb(body: 0xD6452F), body: 0xD6452F)) // no BODY material
        let empty = Bundle(for: SuvAssetTests.self) // the test bundle has no SuvExpedition.glb
        let m = SuvModel.modelData(body: 0xD6452F, bundle: empty)
        XCTAssertFalse(m.modelled)
        XCTAssertEqual(m.data, SuvModel.glb(body: 0xD6452F))
        XCTAssertTrue(SuvModel.modelData(body: 0xD6452F).modelled)
    }

    func testCarCamArgument() throws {
        let c = try XCTUnwrap(CarCam.parse(["x", "-SaryCarCam", "17.5,60,30"]))
        XCTAssertEqual(c.zoom, 17.5); XCTAssertEqual(c.pitch, 60); XCTAssertEqual(c.bearing, 30)
        XCTAssertEqual(CarCam.parse(["-SaryCarCam", "14"])?.pitch, 0)
        XCTAssertNil(CarCam.parse(["-SaryCarCam", "zoom"]))
        XCTAssertNil(CarCam.parse(["-SaryCarCam"]))
        XCTAssertEqual(CarCam.parse(["-SaryCarCam", "19,60,0,25.25,46.62"])?.at, LngLat(lng: 46.62, lat: 25.25))
    }

    func testCachedFilesPerColourAndKind() throws {
        let url = try XCTUnwrap(SuvModel.fileURL(body: 0x2F6FD6))
        let version = SuvModel.geometryVersion(try XCTUnwrap(SuvModel.bundledGlb()))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("2f6fd6-\(version).glb"))
        XCTAssertNotEqual(version, SuvModel.geometryVersion(Data([1, 2, 3])))
        XCTAssertEqual(try Data(contentsOf: url), SuvModel.modelData(body: 0x2F6FD6).data)
        let fb = try XCTUnwrap(SuvModel.fileURL(body: 0x2F6FD6, bundle: Bundle(for: SuvAssetTests.self)))
        XCTAssertTrue(fb.lastPathComponent.hasSuffix("-\(SuvModel.fallbackGeometryVersion).glb"))
        XCTAssertNotEqual(url, fb)
    }
}

/// The 2D car icon: layers bundled, each member's colour paints only the paint.
final class CarIconTests: XCTestCase {
    private let members: [UInt32] = [0xE8EEF0, 0xD6452F, 0x2F6FD6, 0xF2B630, 0x2FA56A, 0x8A4FD1, 0xF07F2F, 0x1FB8C4, 0xE05A9C, 0x15191C]

    func testLayersAreBundledAndMatch() throws {
        let l = try XCTUnwrap(CarIcon.loadLayers())
        XCTAssertEqual(l.base.count, l.width * l.height * 4)
        XCTAssertEqual(l.body.count, l.base.count)
        XCTAssertGreaterThan(l.height, l.width) // nose up, portrait
        let paint = stride(from: 2, to: l.body.count, by: 4).filter { l.body[$0] > 250 }.count
        XCTAssertGreaterThan(paint, l.width * l.height / 10) // plenty of paint to carry the colour
    }

    func testPaintTakesTheColourAndLeavesTrimAlone() throws {
        let l = try XCTUnwrap(CarIcon.loadLayers())
        let red = CarIcon.paint(l, color: 0xD6452F), blue = CarIcon.paint(l, color: 0x2F6FD6)
        var paintR = (0, 0), paintB = (0, 0)
        for i in stride(from: 0, to: l.body.count, by: 4) {
            if l.body[i + 2] == 255 {
                paintR.0 += Int(red[i]); paintR.1 += Int(red[i + 2])
                paintB.0 += Int(blue[i]); paintB.1 += Int(blue[i + 2])
            } else if l.body[i + 2] == 0 {
                /* not paint: identical whatever the colour (trim, rack, tyres, glass, shadow) */
                XCTAssertEqual(red[i ..< i + 4], blue[i ..< i + 4])
                XCTAssertEqual(Array(red[i ..< i + 4]), Array(l.base[i ..< i + 4]))
            }
        }
        /* glossy paint carries white reflections, so compare the two cars: red is redder, blue bluer */
        XCTAssertGreaterThan(paintR.0, paintR.1 * 13 / 10)
        XCTAssertGreaterThan(paintB.1, paintB.0 * 13 / 10)
        XCTAssertGreaterThan(paintR.0, paintB.0 * 3 / 2)
        XCTAssertGreaterThan(paintB.1, paintR.1 * 3 / 2)
    }

    func testPaintPixelFollowsTheRendererFormula() throws {
        let l = try XCTUnwrap(CarIcon.loadLayers())
        let i = try XCTUnwrap(stride(from: 0, to: l.body.count, by: 4).first { l.body[$0 + 2] == 255 && l.body[$0] > 100 })
        let out = CarIcon.paint(l, color: 0x2FA56A)
        let lin = SuvModel.linear(0x2FA56A)
        let d = CarIcon.decode(l.body[i]), k = CarIcon.decode(l.body[i + 1])
        for c in 0 ..< 3 {
            XCTAssertEqual(Double(out[i + c]), (CarIcon.encode(CarIcon.tone(lin[c] * d + k)) * 255).rounded(), accuracy: 1)
        }
        XCTAssertEqual(out[i + 3], 255)
    }

    func testEveryMemberGetsAnImageAndBlackStaysReadable() throws {
        for c in members {
            let img = try XCTUnwrap(CarIcon.image(c))
            XCTAssertEqual(img.scale, CarIcon.imageScale)
            XCTAssertGreaterThan(img.size.height, img.size.width)
        }
        /* The black car keeps a light outline around it (readable on night maps). */
        let l = try XCTUnwrap(CarIcon.loadLayers())
        let px = CarIcon.paint(l, color: 0x15191C)
        let light = stride(from: 0, to: px.count, by: 4).filter { px[$0 + 3] > 200 && px[$0] > 220 && l.body[$0 + 2] == 0 }.count
        XCTAssertGreaterThan(light, 300)
    }

    func testMemberColoursShipPreRenderedOthersArePainted() throws {
        for c in members {
            let r = try XCTUnwrap(CarIcon.rendered(c), String(c, radix: 16))
            XCTAssertEqual(r.scale, CarIcon.imageScale)
            XCTAssertEqual(r.size, try XCTUnwrap(CarIcon.image(c)).size)
        }
        XCTAssertNil(CarIcon.rendered(0x7A5C3E))
        let other = try XCTUnwrap(CarIcon.image(0x7A5C3E))
        let l = try XCTUnwrap(CarIcon.loadLayers())
        XCTAssertEqual(other.size, CGSize(width: CGFloat(l.width) / CarIcon.imageScale, height: CGFloat(l.height) / CarIcon.imageScale))
        XCTAssertEqual(try XCTUnwrap(CarIcon.rendered(0xD6452F)).size, other.size) // same canvas, any colour
    }

    func testMissingLayersFallBackToTheModel() {
        XCTAssertNil(CarIcon.loadLayers(Bundle(for: CarIconTests.self)))
        XCTAssertNil(CarIcon.image(0xD6452F, bundle: Bundle(for: CarIconTests.self)))
    }

    func testRotationAndSize() {
        XCTAssertEqual(CarIcon.rotate(0), 0)
        XCTAssertEqual(CarIcon.rotate(-90), 270)
        XCTAssertEqual(CarIcon.rotate(nil), 0)
        XCTAssertEqual(CarIcon.rotate(.nan), 0)
        XCTAssertEqual(CarIcon.imageId(0xD6452F), "sary-car-d6452f")
        let s = CarIcon.sizeStops
        XCTAssertEqual(s.first?.size, s[1].size)                       // constant at map zooms
        XCTAssertTrue(zip(s, s.dropFirst()).allSatisfy { $0.size <= $1.size }) // only grows
        XCTAssertEqual(Vehicle.marker, .icon)
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

/// The navigation layer re-sends only the GeoJSON sources whose drawing changed.
final class NavSourceChangesTests: XCTestCase {
    private func drawing() -> MapNavDrawing {
        var d = MapNavDrawing()
        d.routes = [.init(id: "r1", coordinates: [LngLat(lng: 46.6, lat: 24.7), LngLat(lng: 46.7, lat: 24.8)], selected: true)]
        d.offRoad = [LngLat(lng: 46.7, lat: 24.8), LngLat(lng: 46.71, lat: 24.81)]
        d.maneuver = [LngLat(lng: 46.65, lat: 24.75), LngLat(lng: 46.66, lat: 24.76)]
        d.target = LngLat(lng: 46.71, lat: 24.81)
        return d
    }

    func testNothingDrawnYetSendsEverything() {
        XCTAssertEqual(NavSourceChanges.between(drawn: nil, next: MapNavDrawing()), .all)
        XCTAssertEqual(NavSourceChanges.between(drawn: nil, next: drawing()), .all)
    }

    func testSameDrawingSendsNothing() {
        let d = drawing()
        XCTAssertEqual(NavSourceChanges.between(drawn: d, next: d), NavSourceChanges(routes: false, offRoad: false, maneuver: false))
    }

    func testOnlyTheChangedSourceIsSent() {
        let d = drawing()
        var off = d
        off.offRoad = [LngLat(lng: 46.701, lat: 24.801), LngLat(lng: 46.71, lat: 24.81)]
        XCTAssertEqual(NavSourceChanges.between(drawn: d, next: off), NavSourceChanges(routes: false, offRoad: true, maneuver: false))
        var arrow = d
        arrow.maneuver = nil
        XCTAssertEqual(NavSourceChanges.between(drawn: d, next: arrow), NavSourceChanges(routes: false, offRoad: false, maneuver: true))
        var route = d
        route.routes[0].selected = false
        XCTAssertEqual(NavSourceChanges.between(drawn: d, next: route), NavSourceChanges(routes: true, offRoad: false, maneuver: false))
    }

    func testPinOnlyChangesSendNoSource() {
        let d = drawing()
        var note = d
        note.targetNote = "آخر موقع معروف"
        note.cameraKey += 1
        note.labels = [.init(id: "r1", at: LngLat(lng: 46.65, lat: 24.75), text: "12", selected: true)]
        XCTAssertEqual(NavSourceChanges.between(drawn: d, next: note), NavSourceChanges(routes: false, offRoad: false, maneuver: false))
    }

    func testOffRoadRemovedIsSent() {
        let d = drawing()
        var gone = d
        gone.offRoad = nil
        XCTAssertTrue(NavSourceChanges.between(drawn: d, next: gone).offRoad)
    }
}
