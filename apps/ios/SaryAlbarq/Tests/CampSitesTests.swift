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

    private func night(from: Double, gust: Double) -> CampNight {
        CampNight(windKmh: gust * 0.7, gustKmh: gust, fromDeg: from, rainProbability: 0, rainMm: 0, dust: nil, pm10: nil, sunset: nil)
    }
}
