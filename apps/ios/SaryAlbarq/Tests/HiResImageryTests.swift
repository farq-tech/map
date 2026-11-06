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
        XCTAssertEqual(at(8), .on)
        XCTAssertEqual(at(14.9), .paused, "driving: only the tiles already in RAM")
        XCTAssertEqual(at(15), .paused, "15 km/h itself keeps the layer (> 15 is the rule)")
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

    // MARK: round 3: «قوي» / «خفيف», heat, coverage, zoom cap

    func testDrivingPausesNewWorkAbove8KmH() {
        let at = { (kmh: Double) in self.decide(HiResRequest(surface: .exploration, speedMps: kmh / 3.6)) }
        XCTAssertEqual(at(7.9), .on)
        XCTAssertEqual(at(8.5), .paused)
        XCTAssertTrue(at(8.5).drawsLayer, "the enhanced tiles in RAM stay")
        XCTAssertFalse(at(8.5).enhancesNew, "no new model run while driving")
        XCTAssertEqual(at(40), .off(.moving))
    }

    func testHeatFallsBackToLightThenStops() {
        XCTAssertEqual(HiResPolicy.level(.strong, device: HiResDeviceState()), .strong)
        XCTAssertEqual(HiResPolicy.level(.light, device: HiResDeviceState()), .light)
        XCTAssertEqual(HiResPolicy.level(.strong, device: HiResDeviceState(thermal: .fair)), .light, "warm: «خفيف»")
        XCTAssertEqual(decide(HiResRequest(surface: .exploration), device: HiResDeviceState(thermal: .fair)), .on)
        XCTAssertFalse(decide(HiResRequest(surface: .exploration), device: HiResDeviceState(thermal: .serious)).enhancesNew, "stops from .serious")
        XCTAssertFalse(decide(HiResRequest(surface: .exploration), device: HiResDeviceState(lowPower: true)).enhancesNew)
    }

    func testStrongCoversTheDesertFromZ14() {
        let nafud = (lat: 28.30, lng: 41.40), riyadh = (lat: 24.6900, lng: 46.6850)
        XCTAssertTrue(HiResZoom.wantsLayer(zoom: 14, lat: nafud.lat, lng: nafud.lng, level: .strong))
        XCTAssertFalse(HiResZoom.wantsLayer(zoom: 15, lat: nafud.lat, lng: nafud.lng, level: .light))
        XCTAssertNil(HiResZoom.plan(.containing(lat: nafud.lat, lng: nafud.lng, z: 13), level: .strong))
        for z in 14...17 {
            let p = try! XCTUnwrap(HiResZoom.plan(.containing(lat: nafud.lat, lng: nafud.lng, z: z), level: .strong))
            XCTAssertEqual(p.factor, 1, "z\(z): the tile itself, made sharper")
            XCTAssertEqual(p.parent, p.tile)
            XCTAssertEqual(p.inferences, 4)
        }
        let z18 = try! XCTUnwrap(HiResZoom.plan(.containing(lat: nafud.lat, lng: nafud.lng, z: 18), level: .strong))
        XCTAssertEqual(z18.factor, 2)
        XCTAssertEqual(z18.inferences, 1)
        /* Cities keep their own, later start whatever the level. */
        for z in 14...18 { XCTAssertNil(HiResZoom.plan(.containing(lat: riyadh.lat, lng: riyadh.lng, z: z), level: .strong), "Olaya z\(z)") }
        XCTAssertEqual(HiResZoom.plan(.containing(lat: riyadh.lat, lng: riyadh.lng, z: 19), level: .strong)?.factor, 2)
    }

    func testDesertMeansSarySandOverHalf() {
        /* Just outside Riyadh's box (≈1 km): `sarySand` ≈ 0.3, so city rules. */
        let edge = (lat: 24.70, lng: 47.06)
        XCTAssertLessThanOrEqual(SandGrade.sand(urban: UrbanAreas.weight(lat: edge.lat, lng: edge.lng)), 0.5)
        XCTAssertTrue(HiResZoom.isCity(lat: edge.lat, lng: edge.lng))
        /* ≈ 5 km out: open desert. */
        XCTAssertFalse(HiResZoom.isCity(lat: 24.70, lng: 47.10))
        XCTAssertFalse(HiResZoom.isCity(lat: 24.20, lng: 47.60), "Dahna")
    }

    func testProfiles() {
        let strong = HiResProfile.of(.strong, city: false), light = HiResProfile.of(.light, city: false), city = HiResProfile.of(.strong, city: true)
        XCTAssertGreaterThan(strong.gain, light.gain)
        XCTAssertGreaterThan(strong.splitScale, light.splitScale)
        XCTAssertGreaterThan(strong.sharpen, light.sharpen)
        XCTAssertEqual(strong.outputSize, 1024)
        XCTAssertEqual(light.outputSize, 512)
        XCTAssertEqual(city.localContrast, 0, "cities: no clarity")
        XCTAssertLessThan(city.gain, light.gain, "cities: lighter than «خفيف»")
        XCTAssertEqual(city.splitScale, 1)
        XCTAssertLessThan(light.inferencesPerMinute, strong.inferencesPerMinute)
    }

    func testRateLimitPerMinute() {
        var r = HiResRateLimit(perMinute: 5)
        XCTAssertTrue(r.take(now: 0, count: 4))
        XCTAssertTrue(r.take(now: 1))
        XCTAssertFalse(r.take(now: 2), "budget used")
        XCTAssertEqual(r.wait(now: 2), 58, accuracy: 0.001)
        XCTAssertTrue(r.take(now: 60.5), "a minute later")
    }

    func testZoomCapIsNativePlusTwoPerRegion() {
        let base = SatelliteLabels.imageryMaxZoom
        XCTAssertEqual(base, 18)
        XCTAssertEqual(HiResZoomCap.cap(lat: 28.30, lng: 41.40, base: base, enhancing: true), 19, "desert z17 + 2")
        XCTAssertEqual(HiResZoomCap.cap(lat: 24.69, lng: 46.685, base: base, enhancing: true), 21, "city z19 + 2")
        XCTAssertEqual(HiResZoomCap.cap(lat: 28.30, lng: 41.40, base: base, enhancing: false), 18, "paused / off: never a blurry over-zoom")
        XCTAssertEqual(HiResZoomCap.cap(lat: 28.30, lng: 41.40, base: 20, enhancing: false), 20, "vector layers keep theirs")
        XCTAssertEqual(HiResZoomCap.bound(cap: 19, base: 18), 19 + HiResZoomCap.overshoot, accuracy: 0.001, "soft: a little stretch")
        XCTAssertEqual(HiResZoomCap.bound(cap: 18, base: 18), 18, "no stretch past the plain cap")
        XCTAssertEqual(HiResZoomCap.settle(zoom: 19.3, cap: 19), 19)
        XCTAssertNil(HiResZoomCap.settle(zoom: 18.99, cap: 19))
        /* Every zoom the cap allows has an enhanced, never-blurry tile: the parent is real detail, ≤ 2 up. */
        for (lat, lng) in [(28.30, 41.40), (24.69, 46.685)] {
            let cap = Int(HiResZoomCap.cap(lat: lat, lng: lng, base: base, enhancing: true))
            for z in (HiResZoom.nativeMax(lat: lat, lng: lng) + 1)...cap {
                let p = try! XCTUnwrap(HiResZoom.plan(.containing(lat: lat, lng: lng, z: z), level: .light))
                XCTAssertLessThanOrEqual(Int(p.parent.z), HiResZoom.nativeMax(lat: lat, lng: lng))
                XCTAssertLessThanOrEqual(p.factor, 4)
            }
        }
    }

    func testPrefetchRingCentreFirst() {
        let c = HiResTileID.containing(lat: 28.30, lng: 41.40, z: 16)
        let ctr = c.center
        let tiles = HiResZoom.prefetch(west: ctr.lng - 0.001, south: ctr.lat - 0.001, east: ctr.lng + 0.001, north: ctr.lat + 0.001,
                                       z: 16, ring: 1, deeper: true)
        XCTAssertEqual(tiles.first, c, "the centre first")
        XCTAssertEqual(tiles.filter { $0.z == 16 }.count, 9, "the tile and its ring")
        XCTAssertEqual(tiles.filter { $0.z == 17 }.count, 4, "the next zoom under the centre")
        XCTAssertLessThanOrEqual(HiResZoom.prefetch(west: 40, south: 27, east: 42, north: 29, z: 16, ring: 1, deeper: false).count, 0,
                                 "a huge view (far, pitched) is not prefetched")
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
        XCTAssertEqual(HiResImagery.enhanced.limit, 48 << 20)
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
        /* «قوي»: a z15 desert tile made from itself (four runs) and a z18 one (one run), 1024 px out. */
        for z in [15, 18] {
            let p = try XCTUnwrap(HiResZoom.plan(HiResTileID.containing(lat: 28.30, lng: 41.40, z: z), level: .strong))
            let t = CFAbsoluteTimeGetCurrent()
            let img = try XCTUnwrap(e.enhance(parent: parent, plan: p, profile: .strong))
            XCTAssertEqual(img.cgImage?.width, HiResEnhancer.tileSize, "handed to Mapbox at the tile size")
            print("HIRES-BENCH strong z\(z) x\(p.factor) runs \(p.inferences): \(Int((CFAbsoluteTimeGetCurrent() - t) * 1000)) ms (simulator, CPU)")
        }
    }
}
