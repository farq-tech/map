import XCTest
@testable import SaryAlbarq

/// «اقترح لي مكان كشتة» / «أماكن مقترحة للكشتة»: bundled data, tonight's wind, ranking, wording.
/// The terrain rules themselves (wadi beds, sabkha, slope…) are tested in Python:
/// scripts/camp-sites/tests/test_model.py.
final class CampSitesTests: XCTestCase {
    private let riyadh = LngLat(lng: 46.6744, lat: 24.7113)

    // MARK: bundled data

    func testBundledRegionsLoadAndAreSafe() {
        let all = CampSiteCatalog.all
        for r in CampSiteCatalog.regions {
            XCTAssertGreaterThanOrEqual(all.filter { $0.region == r }.count, 30, r)
        }
        for s in all {
            XCTAssertEqual(s.shelter.count, 8, s.id)
            for v in [s.safety, s.comfort, s.beauty, s.access] + s.shelter { XCTAssertTrue((0...1).contains(v), s.id) }
            /* The wadi-bed exclusion upstream: no bundled site sits in a channel's flood buffer (≥ 75 m). */
            XCTAssertGreaterThanOrEqual(s.dChannelM, 75, "\(s.id) is in a wadi buffer")
            XCTAssertTrue(s.reasons.allSatisfy { CampReason.text[$0] != nil }, s.id)
        }
    }

    func testDecodeOneFeature() {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[46.65,25.24]},
        "properties":{"id":"t-001","region":"thumamah","safety":0.9,"comfort":0.8,"beauty":0.5,"access":0.6,
        "shelter":[1,0.5,0,0,0,0,0,0.4],"reasons":["sunset","flat"],"hand_m":12.5,"d_channel_m":900,"d_track_m":400,
        "ground":"sand","near_name":"روضة ملهم","protected":null}}]}
        """
        let s = CampSiteCatalog.decode(Data(json.utf8))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].lat, 25.24)
        XCTAssertEqual(s[0].nearName, "روضة ملهم")
        XCTAssertNil(s[0].protected)
    }

    // MARK: wind

    func testRankingFlipsWithWindDirection() {
        let leeOfNorth = CampSite(id: "a", lat: 25.2, lng: 46.7, shelter: [0.9, 0.5, 0, 0, 0, 0, 0, 0.5])
        let leeOfSouth = CampSite(id: "b", lat: 25.2, lng: 46.71, shelter: [0, 0, 0, 0.5, 0.9, 0.5, 0, 0])
        let north = night(from: 0, gust: 35), south = night(from: 180, gust: 35)
        XCTAssertEqual(CampRanker.top([leeOfNorth, leeOfSouth], near: riyadh, radiusKm: 200, night: north).first?.id, "a")
        XCTAssertEqual(CampRanker.top([leeOfNorth, leeOfSouth], near: riyadh, radiusKm: 200, night: south).first?.id, "b")
    }

    func testWindWeighsMoreInStrongerWind() {
        XCTAssertLessThan(CampRanker.windWeight(gustKmh: 10), CampRanker.windWeight(gustKmh: 35))
        XCTAssertEqual(CampRanker.windWeight(gustKmh: 80), 0.6, accuracy: 1e-9)
        /* A beautiful exposed spot beats a plain sheltered one in calm air, not in a gale. */
        let pretty = CampSite(id: "p", lat: 25, lng: 46.7, comfort: 1, beauty: 1, access: 1, shelter: Array(repeating: 0, count: 8))
        let snug = CampSite(id: "s", lat: 25, lng: 46.7, comfort: 0.5, beauty: 0.3, access: 0.5, shelter: Array(repeating: 1, count: 8))
        XCTAssertGreaterThan(CampRanker.score(pretty, night: night(from: 0, gust: 10)), CampRanker.score(snug, night: night(from: 0, gust: 10)))
        XCTAssertLessThan(CampRanker.score(pretty, night: night(from: 0, gust: 55)), CampRanker.score(snug, night: night(from: 0, gust: 55)))
    }

    func testMissingForecastDoesNotGuessWindOrIgnoreFloodPrecautions() {
        let exposed = CampSite(id: "exposed", lat: 25.2, lng: 46.7, safety: 0.9, comfort: 0.8, beauty: 0.6, access: 0.7,
                               shelter: Array(repeating: 0, count: 8), handM: 3, dChannelM: 500)
        let sheltered = CampSite(id: "sheltered", lat: 25.2, lng: 46.71, safety: 0.9, comfort: 0.8, beauty: 0.6, access: 0.7,
                                 shelter: Array(repeating: 1, count: 8), handM: 3, dChannelM: 500)
        XCTAssertEqual(CampRanker.score(exposed, night: nil), CampRanker.score(sheltered, night: nil),
                       "unknown forecast must not assume a northerly wind")

        let low = CampSite(id: "low", lat: 25.2, lng: 46.72, handM: 1, dChannelM: 150)
        XCTAssertEqual(CampRanker.top([low, exposed], near: riyadh, radiusKm: 200, night: nil).map(\.id), ["exposed"],
                       "unknown rainfall keeps low ground near channels out of recommendations")
    }

    func testShelterInterpolatesBetweenDirections() {
        let s = [1.0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(CampRanker.shelter(s, fromDeg: 0), 1)
        XCTAssertEqual(CampRanker.shelter(s, fromDeg: 22.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CampRanker.shelter(s, fromDeg: 337.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CampRanker.shelter(s, fromDeg: 180), 0)
    }

    func testVerdicts() {
        XCTAssertEqual(night(from: 0, gust: 20).verdict, .fine)
        XCTAssertEqual(night(from: 0, gust: 36).verdict, .windy)
        XCTAssertEqual(night(from: 0, gust: 52).verdict, .notTonight)
        var dusty = night(from: 0, gust: 15)
        dusty.dust = 400
        XCTAssertEqual(dusty.verdict, .windy)
        XCTAssertTrue(CampReason.verdictLine(night(from: 0, gust: 52))!.contains("ما ننصح بالكشتة الليلة"))
    }

    func testNightSummaryFromForecast() {
        /* 21:00 Riyadh; hours until 06:00; wind from 350° and 10° average to north. */
        let now = Date(timeIntervalSince1970: 1_793_901_600) // 2026-11-05 18:00 UTC = 21:00 Riyadh
        var hours: [WeatherHour] = []
        for h in 0..<24 {
            let t = now.addingTimeInterval(Double(h) * 3600)
            hours.append(WeatherHour(time: t, precipitationMm: 0, precipitationProbability: h == 3 ? 50 : 5, windKmh: 20,
                                     gustKmh: h == 20 ? 90 : 30, windFromDeg: h % 2 == 0 ? 350 : 10, dust: 40, pm10: 80))
        }
        let r = WeatherReport(area: WeatherArea(around: 25.2, lng: 46.6), fetchedAt: now, current: nil, hours: hours, airAvailable: true)
        let n = CampNight.from(r, now: now, lat: 25.2, lng: 46.6)!
        XCTAssertEqual(n.windKmh, 20, accuracy: 0.01)
        XCTAssertEqual(n.gustKmh, 30, "the 90 km/h gust is tomorrow afternoon, not tonight")
        XCTAssertTrue(n.fromDeg < 1 || n.fromDeg > 359, "\(n.fromDeg)")
        XCTAssertTrue(n.rainy)
        XCTAssertEqual(n.dust, 40)
    }

    // MARK: rain and radius

    func testRainKeepsOnlyHighGroundAwayFromChannels() {
        let low = CampSite(id: "low", lat: 25, lng: 46.7, comfort: 1, beauty: 1, handM: 0.8, dChannelM: 150)
        let high = CampSite(id: "high", lat: 25, lng: 46.71, comfort: 0.5, beauty: 0.4, handM: 6, dChannelM: 900)
        var wet = night(from: 0, gust: 20)
        wet.rainProbability = 70
        XCTAssertEqual(CampRanker.top([low, high], near: riyadh, radiusKm: 200, night: wet).map(\.id), ["high"])
        XCTAssertEqual(CampRanker.top([low, high], near: riyadh, radiusKm: 200, night: night(from: 0, gust: 20)).first?.id, "low")
        XCTAssertNotNil(CampReason.rainLine(wet))
    }

    func testRadiusAndTopFive() {
        let far = CampSite(id: "far", lat: 28.3, lng: 41.4)
        let near = (0..<8).map { CampSite(id: "n\($0)", lat: 25.0 + Double($0) * 0.01, lng: 46.7, beauty: Double($0) / 10) }
        let top = CampRanker.top(near + [far], near: riyadh, radiusKm: 100, night: nil)
        XCTAssertEqual(top.count, 5)
        XCTAssertFalse(top.contains { $0.id == "far" })
        XCTAssertEqual(top.first?.id, "n7")
        XCTAssertTrue(CampRanker.top(near, near: riyadh, radiusKm: 25, night: nil).isEmpty)
    }

    // MARK: wording

    func testCardReasonsLeadWithTonightsShelter() {
        let s = CampSite(id: "a", lat: 25, lng: 46.7, shelter: [0.9, 0, 0, 0, 0, 0, 0, 0.6], reasons: ["sunset", "dark", "green", "flat"],
                         ground: "sand")
        let r = CampReason.top3(s, night: night(from: 0, gust: 25))
        XCTAssertEqual(r, ["في ظل طعس من الشمال", "الغروب مفتوح", "بعيد عن الأنوار، النجوم واضحة"])
        XCTAssertEqual(CampReason.top3(s, night: night(from: 180, gust: 25)).first, "الغروب مفتوح", "no shelter from the south")
        let line = CampReason.windLine(s, night: night(from: 0, gust: 25))
        XCTAssertTrue(line.hasPrefix("الريح الليلة: شمالية"), line)
        XCTAssertTrue(line.contains("المكان في ظل طعس من الشمال"), line)
    }

    func testFameReasonNamesThePlace() {
        let s = CampSite(id: "a", lat: 25, lng: 46.7, reasons: ["fame"], nearName: "روضة ملهم")
        XCTAssertEqual(CampReason.top3(s, night: nil), ["مكان معروف للكشتات (روضة ملهم)"])
    }

    func testWindAdjectives() {
        XCTAssertEqual(CampReason.windAdjective(0), "شمالية")
        XCTAssertEqual(CampReason.windAdjective(225), "جنوبية غربية")
        XCTAssertEqual(CampReason.fromSide(315), "الشمال الغربي")
    }

    func testCampSuggestIsNotDuplicatedInMore() {
        /* The single entry lives in map layers (verified by CampSitesUITests), not in «المزيد». */
        XCTAssertFalse(LiveActionCatalog.groups(.init()).flatMap(\.items).contains { $0.id == "camp" })
        XCTAssertFalse(LiveActionCatalog.groups(.init(ended: true)).flatMap(\.items).contains { $0.id == "camp" })
    }

    func testMapLayerVisibility() {
        XCTAssertFalse(CampSitesMapLayer.visible(layerOn: false, highlighted: [:]))
        XCTAssertTrue(CampSitesMapLayer.visible(layerOn: true, highlighted: [:]))
        XCTAssertTrue(CampSitesMapLayer.visible(layerOn: false, highlighted: ["x": 1]), "tonight's five show while suggested")
    }

    func testRoutePreviewRevealsFromZeroAndThePickPops() {
        for k in [RouteReveal.Kind.selected, .other, .hard] {
            XCTAssertEqual(RouteReveal.opacity(k, shown: false), 0, "no preview: zero, so the next one fades in")
            XCTAssertGreaterThan(RouteReveal.opacity(k, shown: true), 0)
        }
        XCTAssertGreaterThan(RouteReveal.opacity(.selected, shown: true), RouteReveal.opacity(.other, shown: true), "the pick stands out")
        XCTAssertGreaterThan(RouteReveal.popWidth, RouteReveal.selectedWidth)
        XCTAssertLessThanOrEqual(RouteReveal.popSeconds, 0.25, "a pop, not a wait")
        XCTAssertEqual(RouteReveal.popTransition["duration"] as? Int, 180)
    }

    // MARK: «دروب البر» on the home map

    private func option(_ m: DesertRouter.Mode, _ pts: [LngLat], hard: [DesertRouter.HardStretch] = []) -> DesertRouter.Option {
        DesertRouter.Option(mode: m, points: pts, distanceM: 1_000, minutes: 10, trackPercent: 50, hard: hard)
    }

    func testHomeOverlayCarriesTheRoutesWithThePlaces() {
        let a = LngLat(lng: 46.70, lat: 24.90), b = LngLat(lng: 46.72, lat: 24.95)
        let opts = [option(.easy, [a, b]), option(.short, [a, b])]
        XCTAssertNil(HomeDesertRules.overlay(nil, routes: [], selected: .easy), "no routes, no chip: nothing drawn")
        let routesOnly = HomeDesertRules.overlay(nil, routes: opts, selected: .short)
        XCTAssertEqual(routesOnly?.routes, opts)
        XCTAssertEqual(routesOnly?.selectedRoute, .short, "the picked one is the highlighted line")
        XCTAssertEqual(routesOnly?.items, [])
        let item = DesertCategoryItem(id: "n1", title: "نفود", point: b, meters: nil, systemImage: DesertKind.nafud.systemImage)
        let picked = DesertOverlay(items: [item], selected: "n1")
        let both = HomeDesertRules.overlay(picked, routes: opts, selected: .easy)
        XCTAssertEqual(both?.items, [item], "the picked place stays drawn under the routes")
        XCTAssertEqual(both?.selected, "n1")
        XCTAssertEqual(HomeDesertRules.overlay(picked, routes: [], selected: .easy), picked, "routes closed: as before")
    }

    func testRouteLinesDrawEveryOptionAndOnlyThePicksHardStretches() {
        let a = LngLat(lng: 46.70, lat: 24.90), b = LngLat(lng: 46.72, lat: 24.95)
        let hard = DesertRouter.HardStretch(reason: .sabkha, points: [a, b], meters: 300)
        let opts = [option(.easy, [a, b], hard: [hard]), option(.balanced, [a, b], hard: [hard]), option(.short, [a, b])]
        XCTAssertEqual(DesertRouteLayers.collection(opts, selected: .easy).features.count, 4, "three lines + the pick's hard stretch")
        XCTAssertEqual(DesertRouteLayers.collection(opts, selected: .short).features.count, 3)
        XCTAssertEqual(DesertRouteLayers.collection([], selected: .easy).features.count, 0)
        /* The live map and the home map share the same layers (the alternatives' `-alt` included). */
        XCTAssertEqual(Set(DesertRouteLayers.kinds.map(\.id)), ["sary-desert-routes-line", "sary-desert-routes-alt", "sary-desert-routes-hard"])
        XCTAssertEqual(Set(DesertRouter.Mode.allCases.map(DesertRouteLayers.hex)).count, 3, "each route its own colour")
    }

    func testHomeRoutesFitLandAboveTheHalfSheet() {
        let pts = [LngLat(lng: 46.70, lat: 24.90), LngLat(lng: 46.80, lat: 25.00), LngLat(lng: 46.75, lat: 24.95)]
        let fit = HomeDesertRules.routesFit(pts)
        XCTAssertEqual(fit.count, 3)
        let south = fit.map(\.lat).min() ?? 0, north = fit.map(\.lat).max() ?? 0
        XCTAssertEqual(north, 25.00, accuracy: 1e-9)
        /* Half the screen under the sheet: the framed area is twice the routes' height. */
        XCTAssertEqual((25.00 - 24.90) / (north - south), 0.5, accuracy: 1e-6)
        XCTAssertEqual(fit.map(\.lng).min() ?? 0, 46.70, accuracy: 1e-9)
        XCTAssertEqual(fit.map(\.lng).max() ?? 0, 46.80, accuracy: 1e-9)
        XCTAssertTrue(HomeDesertRules.routesFit([pts[0]]).isEmpty, "one point: nothing to fit")
    }

    private func night(from: Double, gust: Double) -> CampNight {
        CampNight(windKmh: gust * 0.7, gustKmh: gust, fromDeg: from, rainProbability: 0, rainMm: 0, dust: nil, pm10: nil, sunset: nil)
    }

    // MARK: the site's own name

    private func square(_ c: LngLat, halfDeg: Double) -> [[LngLat]] {
        [[LngLat(lng: c.lng - halfDeg, lat: c.lat - halfDeg), LngLat(lng: c.lng + halfDeg, lat: c.lat - halfDeg),
          LngLat(lng: c.lng + halfDeg, lat: c.lat + halfDeg), LngLat(lng: c.lng - halfDeg, lat: c.lat + halfDeg)]]
    }

    private func site(_ lat: Double, _ lng: Double, near: String? = nil, region: String = "thumamah") -> CampSite {
        CampSite(id: "n", region: region, lat: lat, lng: lng, nearName: near)
    }

    func testInsideSandSeaSaysFi() {
        let c = LngLat(lng: 46.7, lat: 25.3)
        let sea = DesertPlace(id: "a", kind: .nafud, nameAr: "نفود الثمامة", point: c, polygon: square(c, halfDeg: 0.2))
        let n = CampNaming.resolve(site(25.31, 46.71), places: [sea])
        XCTAssertEqual(n.relation, .inside)
        XCTAssertEqual(n.title, "في نفود الثمامة")
        XCTAssertEqual(n.routeTitle, "في نفود الثمامة")
    }

    func testNearRawdaShowsRoundedKm() {
        /* 0.027° of latitude ≈ 3.0 km north of the rawdah's point. */
        let r = DesertPlace(id: "r", kind: .rawda, nameAr: "روضة نورة", point: LngLat(lng: 46.7, lat: 25.3))
        let n = CampNaming.resolve(site(25.327, 46.7), places: [r])
        guard case .near(let m) = n.relation else { return XCTFail("\(n.relation)") }
        XCTAssertEqual(m, 3000, accuracy: 100)
        XCTAssertEqual(n.title, "قرب روضة نورة \u{200F}•\u{200F} ٣ كم")
        XCTAssertEqual(n.routeTitle, "قرب روضة نورة")
        XCTAssertNil(n.subtitle, "the name already says روضة")
    }

    func testOnTheEdgeAndKindLabel() {
        let c = LngLat(lng: 46.7, lat: 25.3)
        let sea = DesertPlace(id: "a", kind: .nafud, nameAr: "الثويرات", point: c, polygon: square(c, halfDeg: 0.1))
        /* 100 m east of the east edge. */
        let n = CampNaming.resolve(site(25.3, 46.8 + 0.001), places: [sea])
        XCTAssertEqual(n.relation, .edge)
        XCTAssertEqual(n.title, "على طرف الثويرات")
        XCTAssertEqual(n.subtitle, "نفود")
    }

    func testUnnamedStaysCampSiteWithCoordinatesInSubtitle() {
        let far = DesertPlace(id: "r", kind: .rawda, nameAr: "روضة بعيدة", point: LngLat(lng: 48.5, lat: 26.5))
        let n = CampNaming.resolve(site(25.3, 46.7), places: [far])
        XCTAssertEqual(n.relation, .unnamed)
        XCTAssertEqual(n.title, "موقع كشتة")
        XCTAssertFalse(n.title.contains("جلسة"))
        XCTAssertTrue(n.subtitle?.contains("الثمامة") == true)
        XCTAssertTrue(n.subtitle?.contains("٢٥٫٣٠٠") == true, n.subtitle ?? "")
    }

    func testEqualDistancesPickByKindThenId() {
        let me = LngLat(lng: 46.7, lat: 25.0)
        let a = DesertPlace(id: "z-fayda", kind: .fayda, nameAr: "فيضة الحلوة", point: LngLat(lng: 46.7, lat: 25.125))
        let b = DesertPlace(id: "a-rawda", kind: .rawda, nameAr: "روضة ملهم", point: LngLat(lng: 46.7, lat: 24.875))
        let n1 = CampNaming.resolve(site(me.lat, me.lng), places: [a, b])
        let n2 = CampNaming.resolve(site(me.lat, me.lng), places: [b, a])
        XCTAssertEqual(n1, n2)
        XCTAssertEqual(n1.name, "روضة ملهم")
    }

    func testFamousNameBeatsAFarGazetteerPlaceButNotACloseOne() {
        let r = DesertPlace(id: "r", kind: .rawda, nameAr: "روضة بعيدة", point: LngLat(lng: 46.7, lat: 25.3 + 0.09))  // ≈ 10 km
        XCTAssertEqual(CampNaming.resolve(site(25.3, 46.7, near: "خشوم الثمامة"), places: [r]).title, "قرب خشوم الثمامة")
        let close = DesertPlace(id: "c", kind: .rawda, nameAr: "روضة قريبة", point: LngLat(lng: 46.7, lat: 25.3 + 0.018))  // ≈ 2 km
        XCTAssertEqual(CampNaming.resolve(site(25.3, 46.7, near: "خشوم الثمامة"), places: [close]).name, "روضة قريبة")
        XCTAssertEqual(CampNaming.resolve(site(25.3, 46.7, near: "خشوم الثمامة"), places: []).title, "قرب خشوم الثمامة")
    }

    func testSmallestContainingOutlineWinsAndBareKindNamesAreNotNames() {
        let c = LngLat(lng: 46.7, lat: 25.3)
        let big = DesertPlace(id: "big", kind: .nafud, nameAr: "نفود الثمامة", point: c, polygon: square(c, halfDeg: 0.5))
        let small = DesertPlace(id: "small", kind: .fayda, nameAr: "فيضة ام جرس", point: c, polygon: square(c, halfDeg: 0.02))
        let bare = DesertPlace(id: "bare", kind: .fayda, nameAr: "فيضة", point: c, polygon: square(c, halfDeg: 0.01))
        XCTAssertEqual(CampNaming.resolve(site(25.3, 46.7), places: [big, small, bare]).name, "فيضة ام جرس")
    }

    func testBundledSitesGetANameAndNeverJalsa() {
        let places = DesertGazetteer.bundled.places
        try? XCTSkipIf(places.isEmpty, "gazetteer not bundled in this host")
        var named = 0
        for s in CampSiteCatalog.all {
            let n = CampNaming.resolve(s, places: places)
            XCTAssertFalse(n.title.contains("جلسة"), s.id)
            if n.relation != .unnamed { named += 1 }
        }
        print("camp-names: \(named)/\(CampSiteCatalog.all.count) named")
        XCTAssertGreaterThan(named, CampSiteCatalog.all.count / 2)
    }

    // MARK: protected areas are never suggested

    func testSiteInsideProtectedAreaIsExcludedAndOutsideOneIsKept() {
        let inside = CampSite(id: "in", lat: 24.9, lng: 46.7, protected: "محمية الملك خالد الملكية")
        let outside = CampSite(id: "out", lat: 24.9, lng: 46.71)
        let top = CampRanker.top([inside, outside], near: riyadh, radiusKm: 100, night: nil)
        XCTAssertEqual(top.map(\.id), ["out"])
    }

    func testAllSitesProtectedGivesEmptyListAndCount() {
        let sites = (0..<4).map { CampSite(id: "p\($0)", lat: 24.9, lng: 46.7 + Double($0) * 0.01, protected: "محمية") }
        XCTAssertTrue(CampRanker.top(sites, near: riyadh, radiusKm: 100, night: nil).isEmpty)
        XCTAssertEqual(CampRanker.protectedCount(sites, near: riyadh, radiusKm: 100), 4)
        /* Out of the radius they do not count: the plain empty state, not «كلها داخل محميات». */
        XCTAssertEqual(CampRanker.protectedCount(sites, near: riyadh, radiusKm: 5), 0)
    }

    func testTopFillsFiveFromOutsideProtectedAreas() {
        var sites = (0..<5).map { CampSite(id: "p\($0)", lat: 24.9, lng: 46.7 + Double($0) * 0.01, comfort: 1, beauty: 1, access: 1, protected: "محمية") }
        sites += (0..<6).map { CampSite(id: "o\($0)", lat: 25.0, lng: 46.7 + Double($0) * 0.01, comfort: 0.3, beauty: 0.3, access: 0.3) }
        let top = CampRanker.top(sites, near: riyadh, radiusKm: 100, night: nil)
        XCTAssertEqual(top.count, 5)
        XCTAssertTrue(top.allSatisfy { $0.site.protected == nil })
    }

    func testBundledProtectedCoverageIsWhatTheDataSays() {
        /* Documented in the PR: only sites flagged by the build can be excluded. */
        let all = CampSiteCatalog.all
        try? XCTSkipIf(all.isEmpty)
        let flagged = all.filter(\.protected.isSome)
        print("camp-protected: \(flagged.count)/\(all.count)", Dictionary(grouping: flagged, by: { $0.protected! }).mapValues(\.count))
        XCTAssertTrue(CampRanker.top(flagged, near: riyadh, radiusKm: 2000, night: nil).isEmpty)
    }
}

private extension Optional { var isSome: Bool { self != nil } }
