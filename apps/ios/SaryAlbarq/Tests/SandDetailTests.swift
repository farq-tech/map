import CoreGraphics
import XCTest
@testable import SaryAlbarq

/// «تفاصيل الرمال» (`SandDetail`) and the no-new-lines check (`LineGuard`) used by it and by
/// «صور عالية الوضوح».
final class SandDetailTests: XCTestCase {
    private let noon = SandDetail.Light(azimuthDeg: 160, strength: 0.8, night: false)

    private func tile(_ lat: Double, _ lng: Double, z: Int, light: SandDetail.Light? = nil) -> (HiResTileID, SandDetail.Tile?) {
        let t = HiResTileID.containing(lat: lat, lng: lng, z: z)
        return (t, SandDetail.render(z: z, x: Int(t.x), y: Int(t.y), light: light ?? noon))
    }

    /// The tile over plain sand (the colour the grade gives the Nafud), as the map composites it.
    private func overSand(_ t: SandDetail.Tile) -> [UInt8] {
        var o = [UInt8](repeating: 255, count: t.size * t.size * 4)
        let sand: [Float] = [214, 150, 96]
        for i in 0..<(t.size * t.size) {
            let a = Float(t.rgba[i * 4 + 3]) / 255
            for c in 0..<3 { o[i * 4 + c] = UInt8(min(255, Float(t.rgba[i * 4 + c]) + sand[c] * (1 - a))) }
        }
        return o
    }

    private func flatScore() -> Float {
        let flat = (0..<(512 * 512 * 4)).map { UInt8([214, 150, 96, 255][$0 % 4]) }
        return LineGuard.score(LineGuard.gray(rgba: flat, width: 512, height: 512, to: 256), width: 256, height: 256)
    }

    // MARK: where it draws

    func testNothingFromAfarOrOverACity() {
        XCTAssertNil(tile(28.30, 41.40, z: 13).1, "no detail shallower than z14")
        XCTAssertNil(tile(24.7113, 46.6744, z: 17).1, "Riyadh: the city stays as the photo shows it")
        XCTAssertNil(tile(21.54, 39.17, z: 17).1, "Jeddah")
        XCTAssertNotNil(tile(28.30, 41.40, z: 17).1, "the Nafud")
        XCTAssertNotNil(tile(24.20, 47.60, z: 16).1, "the Dahna")
    }

    func testOpacityFadesInWithTheZoom() {
        let e = SandDetail.opacityExpression(scale: 1)
        XCTAssertEqual(e[3] as? Double, 14.2)
        XCTAssertEqual(e[4] as? Double, 0)
        XCTAssertEqual(e.last as? Double, 1)
        XCTAssertEqual(SandDetail.opacityExpression(scale: 0.7).last as? Double, 0.7)
    }

    func testBudget() {
        var s = VisualEffectsSettings()
        XCTAssertTrue(VisualBudget.resolve(s, VisualContext()).sandDetail)
        XCTAssertTrue(VisualBudget.resolve(s, VisualContext(driving: true)).sandDetail, "texture, never a shape: stays (softer) while driving")
        XCTAssertEqual(VisualBudget.sandDetailScale(driving: true), 0.7)
        XCTAssertFalse(VisualBudget.resolve(s, VisualContext(lowPower: true)).sandDetail)
        XCTAssertFalse(VisualBudget.resolve(s, VisualContext(layer: .standard)).sandDetail)
        s.sandDetail = false
        XCTAssertFalse(VisualBudget.resolve(s, VisualContext()).sandDetail)
        s = VisualEffectsSettings(master: false)
        XCTAssertFalse(VisualBudget.resolve(s, VisualContext()).sandDetail)
    }

    // MARK: what it is

    func testDeterministicAndSeamless() throws {
        let (t, a) = tile(28.30, 41.40, z: 17)
        let a2 = SandDetail.render(z: Int(t.z), x: Int(t.x), y: Int(t.y), light: noon)
        let ta = try XCTUnwrap(a), tb = try XCTUnwrap(SandDetail.render(z: Int(t.z), x: Int(t.x) + 1, y: Int(t.y), light: noon))
        XCTAssertEqual(ta.rgba, a2?.rgba)
        /* Across the tile edge the texture changes no more than between two inner columns. */
        let n = ta.size
        var seam: Float = 0, inner: Float = 0
        for y in 0..<n {
            seam += abs(ta.delta[y * n + n - 1] - tb.delta[y * n])
            inner += abs(ta.delta[y * n + n - 2] - ta.delta[y * n + n - 1])
        }
        XCTAssertLessThan(seam, inner * 1.6 + 0.5)
    }

    /// An overlay of light and shade around the photo's own brightness: on average it changes nothing.
    func testKeepsTheGradeOnAverage() throws {
        for z in [15, 17, 19] {
            let d = try XCTUnwrap(tile(28.30, 41.40, z: z).1).delta
            let mean = d.reduce(0, +) / Float(d.count)
            XCTAssertLessThan(abs(mean), 0.01, "z\(z)")
            XCTAssertLessThanOrEqual(d.map(abs).max() ?? 1, SandDetail.maxAlpha + 0.001)
        }
    }

    func testWindFollowsTheRegion() {
        XCTAssertEqual(SandDetail.windFrom(lat: 28.3, lng: 41.4), 300, accuracy: 3, "Nafud: north-westerly")
        XCTAssertEqual(SandDetail.windFrom(lat: 25, lng: 47.5), 345, accuracy: 6, "Dahna: Shamal from the north")
        XCTAssertEqual(SandDetail.windFrom(lat: 19, lng: 50), 20, accuracy: 3, "Empty Quarter: north-north-east")
    }

    func testLightFollowsTheSunInSteps() {
        let l = SandDetail.Light.from(SunPosition(altitudeDeg: 30, azimuthDeg: 133, rising: true))
        XCTAssertEqual(l.azimuthDeg, 140)
        XCTAssertFalse(l.night)
        XCTAssertTrue(SandDetail.Light.from(SunPosition(altitudeDeg: -20, azimuthDeg: 0, rising: false)).night)
        XCTAssertTrue(SandDetail.Light.from(SunPosition(altitudeDeg: 30, azimuthDeg: 133, rising: true), night: true).night)
    }

    func testRendersFast() throws {
        let (t, _) = tile(28.30, 41.40, z: 17)
        measure { _ = SandDetail.render(z: Int(t.z), x: Int(t.x), y: Int(t.y), light: noon) }
    }

    // MARK: never a track

    /// The safety rule: over plain sand, at every zoom, light and desert, the detail adds no
    /// straight edge that `LineGuard` would call a line (a track, a road, a fence).
    func testDetailNeverDrawsALine() throws {
        let base = flatScore()
        var worst: Float = 0
        for (lat, lng) in [(28.30, 41.40), (24.20, 47.60), (21.50, 49.00), (19.00, 51.00), (27.00, 44.50)] {
            for az in stride(from: 0.0, to: 360, by: 60) {
                for z in [14, 16, 17, 18, 19, 20, 22] {
                    guard let t = tile(lat, lng, z: z, light: SandDetail.Light(azimuthDeg: az, strength: 1, night: false)).1 else { continue }
                    let s = LineGuard.score(LineGuard.gray(rgba: overSand(t), width: 512, height: 512, to: 256), width: 256, height: 256)
                    worst = max(worst, s)
                    XCTAssertFalse(LineGuard.addsLine(enhanced: s, source: base), "\(lat),\(lng) z\(z) az\(az): \(s)")
                }
            }
        }
        XCTAssertLessThan(worst, LineGuard.lineScore)
    }

    /// «قوي» makes the close-up relief up to 30 % stronger: still never a line.
    func testStrongDetailNeverDrawsALine() throws {
        XCTAssertEqual(SandDetail.closeBoost(z: 15, strong: true), 1)
        XCTAssertEqual(SandDetail.closeBoost(z: 18, strong: true), 1.3, accuracy: 0.001)
        XCTAssertEqual(SandDetail.closeBoost(z: 20, strong: false), 1)
        let base = flatScore()
        var worst: Float = 0
        for (lat, lng) in [(28.30, 41.40), (24.20, 47.60), (19.00, 51.00)] {
            for az in stride(from: 0.0, to: 360, by: 90) {
                for z in [16, 17, 18, 19, 20] {
                    var l = SandDetail.Light(azimuthDeg: az, strength: 1, night: false)
                    l.strong = true
                    guard let t = tile(lat, lng, z: z, light: l).1 else { continue }
                    XCTAssertLessThanOrEqual(t.delta.map(abs).max() ?? 0, SandDetail.maxAlpha * 1.3 + 0.001)
                    let s = LineGuard.score(LineGuard.gray(rgba: overSand(t), width: 512, height: 512, to: 256), width: 256, height: 256)
                    worst = max(worst, s)
                    XCTAssertFalse(LineGuard.addsLine(enhanced: s, source: base), "\(lat),\(lng) z\(z) az\(az): \(s)")
                }
            }
        }
        XCTAssertLessThan(worst, LineGuard.lineScore)
        print("SAND-STRONG worst line score \(worst)")
    }

    func testStrongMergeKeepsShapesAndRefusesATrack() throws {
        /* 1024 px «قوي» merge (looser split, sharpening, clarity): colour and edge still the photo's. */
        let src = image(128) { x, _ in x < 64 ? (200, 140, 90) : (170, 110, 70) }
        let ai = image(1024) { x, y in
            let g = UInt8((x * 7 + y * 13) % 9)
            return x < 600 ? (150 + g, 150 + g, 150 + g) : (90 + g, 90 + g, 90 + g)
        }
        let m = try XCTUnwrap(HiResEnhancer.mergeDetail(ai: ai, source: src, ratio: 8, profile: .strong))
        XCTAssertEqual(m.image.width, 1024)
        let out = try XCTUnwrap(HiResEnhancer.rgba(m.image, 1024))
        let left = (200 * 1024 + 200) * 4, right = (200 * 1024 + 840) * 4
        XCTAssertEqual(Int(out[left]), 200, accuracy: 14)
        XCTAssertEqual(Int(out[left + 2]), 90, accuracy: 14)
        XCTAssertEqual(Int(out[right]), 170, accuracy: 14)
        XCTAssertLessThan(Int(out[(200 * 1024 + 560) * 4]), 190, "the edge stays at the photo's x = 512, not the model's 600")
        XCTAssertFalse(m.addsLine)

        let plain = image(128) { x, y in let g = UInt8((x * 5 + y * 3) % 7); return (205 + g, 145 + g, 92 + g) }
        let ruts = image(1024) { x, y in
            let rut = abs(x - (240 + y / 3)) < 5 || abs(x - (300 + y / 3)) < 5
            return rut ? (120, 80, 50) : (205, 145, 92)
        }
        let t = try XCTUnwrap(HiResEnhancer.mergeDetail(ai: ruts, source: plain, ratio: 8, profile: .strong))
        XCTAssertTrue(t.addsLine, "LineGuard stays on at «قوي»: \(t.scores)")
    }

    func testLineGuardFindsATrackAndIgnoresTexture() {
        let n = 256
        var track = [Float](repeating: 0, count: n * n)
        var texture = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let v = 0.5 + 0.05 * Float(Noise.value(Double(x) / 3, Double(y) / 3))
                track[y * n + x] = v
                texture[y * n + x] = 0.5 + 0.2 * Float(Noise.value(Double(x) / 2, Double(y) / 2))
            }
            /* Two wheel ruts, 2 px each, 9 px apart, slightly slanted. */
            let x0 = 60 + y / 4
            for dx in [0, 1, 9, 10] { track[y * n + x0 + dx] -= 0.15 }
        }
        let ts = LineGuard.score(track, width: n, height: n), xs = LineGuard.score(texture, width: n, height: n)
        XCTAssertGreaterThan(ts, LineGuard.lineScore)
        XCTAssertLessThan(xs, LineGuard.lineScore)
        XCTAssertTrue(LineGuard.addsLine(enhanced: ts, source: xs), "a track that was not in the source is refused")
        XCTAssertFalse(LineGuard.addsLine(enhanced: ts, source: ts), "a real track in the photo is not the enhancer's doing")
    }

    // MARK: «صور عالية الوضوح»: geometry stays the photo's

    private func image(_ n: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var d = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n { for x in 0..<n { let (r, g, b) = f(x, y); let o = (y * n + x) * 4; d[o] = r; d[o + 1] = g; d[o + 2] = b } }
        return HiResEnhancer.cgImage(d, n)!
    }

    func testMergeKeepsTheSourceShapesAndColour() throws {
        /* Source: a soft dune edge. "AI": the same shifted and recoloured, plus fine grain. */
        let src = image(128) { x, _ in x < 64 ? (200, 140, 90) : (170, 110, 70) }
        let ai = image(512) { x, y in
            let g = UInt8((x * 7 + y * 13) % 9)
            return x < 300 ? (150 + g, 150 + g, 150 + g) : (90 + g, 90 + g, 90 + g)
        }
        let m = try XCTUnwrap(HiResEnhancer.mergeDetail(ai: ai, source: src, factor: 4))
        let out = try XCTUnwrap(HiResEnhancer.rgba(m.image, 512))
        /* Far from the edge, the colour is the photo's (±grain), not the model's grey. */
        let left = (100 * 512 + 100) * 4, right = (100 * 512 + 420) * 4
        XCTAssertEqual(Int(out[left]), 200, accuracy: 8)
        XCTAssertEqual(Int(out[left + 2]), 90, accuracy: 8)
        XCTAssertEqual(Int(out[right]), 170, accuracy: 8)
        /* The edge stays at the photo's x = 256, not the model's 300. */
        let at280 = (100 * 512 + 280) * 4
        XCTAssertLessThan(Int(out[at280]), 185)
        XCTAssertFalse(m.addsLine)
    }

    func testMergeRefusesAnInventedTrack() throws {
        let src = image(128) { x, y in let g = UInt8((x * 5 + y * 3) % 7); return (205 + g, 145 + g, 92 + g) }
        let ai = image(512) { x, y in
            let rut = abs(x - (120 + y / 3)) < 3 || abs(x - (150 + y / 3)) < 3
            return rut ? (120, 80, 50) : (205, 145, 92)
        }
        let m = try XCTUnwrap(HiResEnhancer.mergeDetail(ai: ai, source: src, factor: 4))
        XCTAssertTrue(m.addsLine, "scores \(m.scores)")
    }
}
