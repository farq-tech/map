import XCTest
@testable import SaryAlbarq

/// «صور عالية الوضوح» (Sources/Map/AIEnhance): gating, zoom rules, cache, kill switch, badge state.
final class HiResImageryTests: XCTestCase {
    private let calm = HiResDeviceState()
    private func decide(_ r: HiResRequest, user: Bool = true, remote: Bool = true, device: HiResDeviceState = HiResDeviceState()) -> HiResDecision {
        HiResPolicy.decide(r, userOn: user, remoteOn: remote, device: device)
    }

    // MARK: where it is on

    func testOnInExplorationPointViewAndTrackDetail() {
        for s in [HiResSurface.exploration, .pointView, .trackDetail] {
            XCTAssertEqual(decide(HiResRequest(surface: s)), .on, "\(s)")
        }
        XCTAssertEqual(decide(HiResRequest(surface: .off)), .off(.surface), "the trip map / follow map keep the original")
        XCTAssertEqual(decide(.off), .off(.surface))
    }

    func testOnlyOverSatellite() {
        XCTAssertEqual(decide(HiResRequest(surface: .exploration, satellite: false)), .off(.notSatellite))
    }

    // MARK: motion / navigation gating (safety)

    func testAlwaysOffInNavigationFollowAndSOS() {
        XCTAssertEqual(decide(HiResRequest(surface: .exploration, navigating: true)), .off(.navigating))
        XCTAssertEqual(decide(HiResRequest(surface: .trackDetail, following: true)), .off(.following))
        XCTAssertEqual(decide(HiResRequest(surface: .exploration, sos: true)), .off(.sos))
        /* Safety beats the person's toggle and the server: still off. */
        XCTAssertFalse(decide(HiResRequest(surface: .exploration, navigating: true), user: true, remote: true).drawsLayer)
    }

    func testOffAbove15KmH() {
        let at = { (kmh: Double) in self.decide(HiResRequest(surface: .exploration, speedMps: kmh / 3.6)) }
        XCTAssertEqual(at(0), .on)
        XCTAssertEqual(at(14.9), .on)
        XCTAssertEqual(at(15), .on, "15 km/h itself is allowed (> 15 is the rule)")
        XCTAssertEqual(at(15.5), .off(.moving))
        XCTAssertEqual(at(90), .off(.moving))
        XCTAssertEqual(decide(HiResRequest(surface: .exploration, speedMps: nil)), .on, "unknown speed = stopped")
    }

    func testLowPowerAndHeatPauseButKeepTheLayer() {
        let lp = decide(HiResRequest(surface: .exploration), device: HiResDeviceState(lowPower: true))
        XCTAssertEqual(lp, .paused)
        XCTAssertTrue(lp.drawsLayer)
        XCTAssertFalse(lp.enhancesNew)
        XCTAssertEqual(decide(HiResRequest(surface: .exploration), device: HiResDeviceState(thermal: .serious)), .paused)
        XCTAssertEqual(decide(HiResRequest(surface: .exploration), device: HiResDeviceState(thermal: .critical)), .paused)
        XCTAssertEqual(decide(HiResRequest(surface: .exploration), device: HiResDeviceState(thermal: .fair)), .on)
    }

    func testMissingModelIsOff() {
        XCTAssertEqual(HiResPolicy.decide(HiResRequest(surface: .exploration), userOn: true, remoteOn: true, device: calm, modelAvailable: false), .off(.noModel))
    }

    // MARK: zoom gating

    func testDesertEnhancesFromZ17AndCityFromZ19() {
        let shuaib = (lat: 25.12, lng: 46.10)   // Huraymila, outside Riyadh's box
        let riyadh = (lat: 24.80, lng: 46.68)
        XCTAssertFalse(HiResZoom.isCity(lat: shuaib.lat, lng: shuaib.lng))
        XCTAssertTrue(HiResZoom.isCity(lat: riyadh.lat, lng: riyadh.lng))
        XCTAssertFalse(HiResZoom.wantsLayer(zoom: 15.9, lat: shuaib.lat, lng: shuaib.lng))
        XCTAssertTrue(HiResZoom.wantsLayer(zoom: 16, lat: shuaib.lat, lng: shuaib.lng))
        XCTAssertFalse(HiResZoom.wantsLayer(zoom: 17.5, lat: riyadh.lat, lng: riyadh.lng))
        XCTAssertTrue(HiResZoom.wantsLayer(zoom: 18, lat: riyadh.lat, lng: riyadh.lng))
        for z in 14...16 { XCTAssertNil(HiResZoom.plan(.containing(lat: shuaib.lat, lng: shuaib.lng, z: z)), "desert z\(z): untouched") }
        for z in 15...18 { XCTAssertNil(HiResZoom.plan(.containing(lat: riyadh.lat, lng: riyadh.lng, z: z)), "city z\(z): untouched") }
        let z17 = HiResZoom.plan(.containing(lat: shuaib.lat, lng: shuaib.lng, z: 17))!
        XCTAssertEqual(z17.parent.z, 16, "one level earlier: z17 from z16 (×2)")
        XCTAssertEqual(z17.factor, 2)
        let c19 = HiResZoom.plan(.containing(lat: riyadh.lat, lng: riyadh.lng, z: 19))!
        XCTAssertEqual(c19.parent.z, 18)
        XCTAssertEqual(HiResZoom.plan(.containing(lat: riyadh.lat, lng: riyadh.lng, z: 21))!.parent.z, 19, "city ×4 from the real z19")
    }

    func testTilePlanCropsTheParentQuadrant() {
        let t = HiResTileID.containing(lat: 25.12, lng: 46.10, z: 18)
        let p = HiResZoom.plan(t)!
        XCTAssertEqual(p.parent.z, 17)
        XCTAssertEqual(p.factor, 2)
        XCTAssertEqual(p.cropSize, 256)
        XCTAssertEqual(p.cropX, Int(t.x % 2) * 256)
        XCTAssertEqual(p.cropY, Int(t.y % 2) * 256)
        XCTAssertEqual(p.parent.x, t.x / 2)
        /* z19 in the desert: from the real z17 (×4), never from the blurry z18. */
        let t19 = HiResTileID.containing(lat: 25.12, lng: 46.10, z: 19)
        let p19 = HiResZoom.plan(t19)!
        XCTAssertEqual(p19.parent.z, 17)
        XCTAssertEqual(p19.factor, 4)
        XCTAssertEqual(p19.cropSize, 128)
        /* At most two levels up (z20 desert uses z18). */
        XCTAssertEqual(HiResZoom.plan(.containing(lat: 25.12, lng: 46.10, z: 20))!.parent.z, 18)
    }

    func testTileCenterRoundTrip() {
        let t = HiResTileID.containing(lat: 28.0, lng: 41.5, z: 18)
        let c = t.center
        XCTAssertEqual(HiResTileID.containing(lat: c.lat, lng: c.lng, z: 18), t)
    }

    // MARK: cache eviction

    func testCacheEvictsLeastRecentlyUsedByCost() {
        let c = HiResTileCache<Int>(limitBytes: 3)
        let a = HiResTileID(z: 18, x: 1, y: 1), b = HiResTileID(z: 18, x: 2, y: 1), d = HiResTileID(z: 18, x: 3, y: 1), e = HiResTileID(z: 18, x: 4, y: 1)
        c.set(a, 1, cost: 1)
        c.set(b, 2, cost: 1)
        c.set(d, 3, cost: 1)
        XCTAssertEqual(c.get(a), 1, "touch a: b is now the oldest")
        c.set(e, 4, cost: 1)
        XCTAssertNil(c.get(b), "b evicted")
        XCTAssertEqual(c.get(a), 1)
        XCTAssertEqual(c.count, 3)
        XCTAssertLessThanOrEqual(c.bytes, 3)
        c.set(a, 9, cost: 3)
        XCTAssertEqual(c.count, 1, "one big entry pushes the rest out")
        c.removeAll()
        XCTAssertEqual(c.count, 0)
        XCTAssertEqual(c.bytes, 0)
    }

    func testProductionCacheBudgetsAreRAMSized() {
        XCTAssertEqual(HiResImagery.enhanced.limit, 40 << 20)
        XCTAssertEqual(HiResImagery.raw.limit, 8 << 20)
    }

    // MARK: kill switch

    private func freshDefaults() -> UserDefaults {
        let name = "hires-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRemoteDefaultsOnAndKeepsLastKnownWhenUnreachable() {
        let d = freshDefaults()
        let s = HiResSettings(defaults: d)
        XCTAssertTrue(s.remoteOn, "initially ON")
        XCTAssertTrue(s.userOn, "the toggle defaults ON")
        s.applyRemote(false)
        XCTAssertFalse(s.remoteOn, "kill switch")
        s.applyRemote(nil)
        XCTAssertFalse(s.remoteOn, "unreachable: keep the last known value")
        XCTAssertFalse(HiResSettings(defaults: d).remoteOn, "remembered across launches")
        s.applyRemote(true)
        XCTAssertTrue(s.remoteOn)
    }

    func testRemoteKillBeatsEverything() {
        XCTAssertEqual(decide(HiResRequest(surface: .exploration), user: true, remote: false), .off(.remoteKill))
        XCTAssertEqual(decide(HiResRequest(surface: .exploration), user: false, remote: true), .off(.userOff))
    }

    func testParsesTheServerAnswer() {
        XCTAssertEqual(HiResSettings.parse(Data(#"{"version":1,"hiResImagery":{"enabled":false}}"#.utf8)), false)
        XCTAssertEqual(HiResSettings.parse(Data(#"{"version":1,"hiResImagery":{"enabled":true}}"#.utf8)), true)
        XCTAssertNil(HiResSettings.parse(Data(#"{"version":1}"#.utf8)), "missing field = unknown, not off")
        XCTAssertNil(HiResSettings.parse(Data("<html>".utf8)))
    }

    // MARK: badge state

    func testBadgeOnlyWhileAnEnhancedTileIsOnScreen() {
        var v = HiResVisibleSet()
        let t = HiResTileID(z: 18, x: 10, y: 20), u = HiResTileID(z: 18, x: 11, y: 20)
        XCTAssertFalse(v.badge)
        v.required(t)
        XCTAssertFalse(v.badge, "requested but still the original")
        v.delivered(t)
        XCTAssertTrue(v.badge)
        v.required(u)
        v.notNeeded(t)
        XCTAssertFalse(v.badge, "the enhanced tile left the view")
        v.delivered(u)
        XCTAssertTrue(v.badge)
        v.reset()
        XCTAssertFalse(v.badge, "layer removed (navigation, kill switch…)")
    }

    // MARK: copy

    func testNoUserFacingAIWording() {
        for s in ["صور عالية الوضوح", "قد تتضمن الصورة تفاصيل تقديرية عند التقريب", "مُحسّنة", "المس مطولاً لعرض الصورة الأصلية", "الأصلية"] {
            XCTAssertFalse(s.contains("ذكاء"), s)
            XCTAssertFalse(s.uppercased().contains("AI"), s)
        }
    }

    func testModelAndLicenceAreBundled() {
        XCTAssertNotNil(HiResEnhancer.bundledURL, "SatelliteEnhancer.mlmodelc in the app")
        XCTAssertTrue(HiResLicenseNotice.text.contains("BSD 3-Clause"))
        XCTAssertTrue(HiResLicenseNotice.text.contains("Xintao Wang"))
    }

    /// One real inference on the simulator: 512 px tile out of a 256 crop (latency is logged).
    func testEnhancerProducesA512Tile() throws {
        let url = try XCTUnwrap(HiResEnhancer.bundledURL)
        let e = try HiResEnhancer(url: url)
        let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(UIColor.brown.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 100, y: 100, width: 60, height: 20))
        let parent = ctx.makeImage()!
        let plan = HiResZoom.plan(HiResTileID.containing(lat: 25.12, lng: 46.10, z: 18))!
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try XCTUnwrap(e.enhance(parent: parent, plan: plan))
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("HIRES-BENCH first-tile \(Int(ms)) ms (simulator, CPU)")
        XCTAssertEqual(out.cgImage?.width, 512)
        XCTAssertEqual(out.cgImage?.height, 512)
        var times: [Double] = []
        for _ in 0..<3 {
            let t = CFAbsoluteTimeGetCurrent()
            _ = e.enhance(parent: parent, plan: plan)
            times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        print("HIRES-BENCH steady \(times.map { Int($0) }) ms (simulator, CPU)")
    }
}

/// `HiResBlend`: an enhanced tile keeps the colour of the imagery it covers and fades out at its
/// border (Build 36 report: tiles of different colour, visible seams).
final class HiResBlendTests: XCTestCase {
    private func solid(_ size: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i + 1] = g; px[i + 2] = b }
        return px
    }

    /// A ramp, so the channels have a spread (contrast) to match.
    private func ramp(_ size: Int, offset: Int, scale: Double) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let v = UInt8(min(255, max(0, Double(offset) + scale * Double(x * 255 / (size - 1)))))
                let i = (y * size + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v
            }
        }
        return px
    }

    func testEdgeFadesToTransparentAndInsideStaysOpaque() {
        let n = 64, f = 8
        XCTAssertLessThan(HiResBlend.edgeAlpha(x: 0, y: 30, size: n, feather: f), 0.05, "the border shows the imagery underneath")
        XCTAssertLessThan(HiResBlend.edgeAlpha(x: 30, y: n - 1, size: n, feather: f), 0.05)
        XCTAssertEqual(HiResBlend.edgeAlpha(x: 30, y: 30, size: n, feather: f), 1)
        XCTAssertEqual(HiResBlend.edgeAlpha(x: f, y: 30, size: n, feather: f), 1)
        var prev = 0.0
        for x in 0...f {
            let a = HiResBlend.edgeAlpha(x: x, y: 30, size: n, feather: f)
            XCTAssertGreaterThanOrEqual(a, prev, "monotonic, no ring")
            prev = a
        }
    }

    func testSameImageComesBackUnchangedInside() {
        let n = 32
        let img = ramp(n, offset: 40, scale: 0.6)
        let out = HiResBlend.blend(enhanced: img, base: img, size: n, feather: 4)
        let i = (16 * n + 16) * 4
        XCTAssertEqual(Int(out[i]), Int(img[i]), accuracy: 1)
        XCTAssertEqual(out[i + 3], 255)
    }

    func testColourShiftOfTheModelIsPulledBackToTheImagery() {
        let n = 32
        let base = ramp(n, offset: 60, scale: 0.5)
        /* The "model" made it brighter and more contrasted. */
        let enhanced = ramp(n, offset: 110, scale: 0.6)
        let out = HiResBlend.blend(enhanced: enhanced, base: base, size: n, feather: 0)
        let mb = HiResBlend.stats(base).mean[0], mo = HiResBlend.stats(out).mean[0], me = HiResBlend.stats(enhanced).mean[0]
        XCTAssertEqual(mo, mb, accuracy: 2, "same mean as the imagery under it")
        XCTAssertGreaterThan(me - mb, 40, "the test really shifts it")
    }

    func testFlatModelPatchesKeepSomeOfTheRealTexture() {
        let n = 32
        let base = ramp(n, offset: 60, scale: 0.5)
        let flat = solid(n, 120, 120, 120)
        let out = HiResBlend.blend(enhanced: flat, base: base, size: n, feather: 0)
        XCTAssertGreaterThan(HiResBlend.stats(out).std[0], HiResBlend.stats(base).std[0] * (1 - HiResBlend.detail) * 0.9,
                             "a flat patch from the model does not wipe the ground's texture")
    }

    func testOutputIsPremultiplied() {
        let n = 32
        let img = solid(n, 200, 150, 100)
        let out = HiResBlend.blend(enhanced: img, base: img, size: n, feather: 8)
        for x in [0, 2, 5] {
            let i = (16 * n + x) * 4
            XCTAssertLessThanOrEqual(out[i], out[i + 3], "colour never exceeds alpha")
        }
    }

    func testRoundTripThroughCGImage() throws {
        let n = 16
        let img = solid(n, 10, 20, 30)
        let cg = try XCTUnwrap(HiResBlend.image(img, size: n))
        let back = try XCTUnwrap(HiResBlend.rgba(cg, size: n))
        XCTAssertEqual(Int(back[0]), 10, accuracy: 1)
        XCTAssertEqual(Int(back[2]), 30, accuracy: 1)
    }
}
