@testable import SaryAlbarq
import XCTest

/// «دليل البر»: decoding, the chips' filtering and ranking (nearest first, to the edge of a sand
/// sea), the free-text source and the rain/green seam.
final class DesertGazetteerTests: XCTestCase {
    static let riyadh = LngLat(lng: 46.6753, lat: 24.7136)

    static let json = """
    {"version":1,"attribution":["© OpenStreetMap contributors (ODbL 1.0)"],"entries":[
     {"id":"osm:relation/1","kind":"nafud","name_ar":"الدهناء","name_en":"Ad Dahna","alt":["Dahna"],"point":[47.9,25.5],
      "bbox":[47.5,23.0,48.5,28.0],"polygon":[[[47.5,23.0],[48.5,23.0],[48.5,28.0],[47.5,28.0]]],
      "sources":[{"id":"osm:relation/1","licence":"ODbL-1.0"},{"id":"geonames:2","licence":"CC-BY-4.0"}]},
     {"id":"geonames:10","kind":"nafud","name_ar":"نفود الثويرات","name_en":"Nafud ath Thuwayrat","point":[44.5,26.6],
      "sources":[{"id":"geonames:10","licence":"CC-BY-4.0"}]},
     {"id":"osm:node/5","kind":"rawda","name_ar":"روضة خريم","name_en":"Rawdat Khuraym","point":[47.30,25.38],"sources":[]},
     {"id":"osm:node/6","kind":"rawda","name_ar":"روضة التنهات","point":[46.9,25.6],"sources":[]},
     {"id":"geonames:7","kind":"fayda","name_en":"Faydat as Sirr","point":[45.6,25.6],"sources":[]},
     {"id":"camp:thumamah-001","kind":"camp","name_ar":"كشتة مقترحة قرب طعس دليل","point":[46.71,25.31],"region":"thumamah","rank":1,"sources":[]},
     {"id":"bad","kind":"lake","name_ar":"x","point":[46,24]},
     {"id":"bad2","kind":"rawda","name_ar":"y","point":[500,24]}
    ]}
    """

    var g: DesertGazetteer { DesertGazetteer.decode(Data(Self.json.utf8))! }

    func testDecodesAndSkipsBadEntries() {
        let g = g
        XCTAssertEqual(g.places.count, 6, "an unknown kind and an impossible point are dropped, not the file")
        let d = g.places.first { $0.id == "osm:relation/1" }!
        XCTAssertEqual(d.kind, .nafud)
        XCTAssertEqual(d.title, "الدهناء")
        XCTAssertEqual(d.secondary, "Ad Dahna")
        XCTAssertEqual(d.polygon?.first?.count, 4)
        XCTAssertEqual(d.sources.map(\.id), ["osm:relation/1", "geonames:2"])
        let f = g.places.first { $0.id == "geonames:7" }!
        XCTAssertEqual(f.title, "Faydat as Sirr", "the Latin name when no source has an Arabic one")
        XCTAssertNil(f.secondary)
        XCTAssertNil(DesertGazetteer.decode(Data("{\"version\":2,\"entries\":[]}".utf8)))
    }

    func testBundledFileIsThereAndCoversEveryKind() {
        let b = DesertGazetteer.bundled
        XCTAssertGreaterThan(b.places.count, 100)
        for k in DesertKind.allCases { XCTAssertTrue(b.places.contains { $0.kind == k }, "\(k)") }
        XCTAssertEqual(Set(b.places.map(\.id)).count, b.places.count, "ids are unique")
        XCTAssertTrue(b.places.allSatisfy { !$0.title.isEmpty && !$0.sources.isEmpty })
    }

    func testCategoryFiltersByKind() {
        let g = g
        XCTAssertEqual(g.nearest(.rawda, from: Self.riyadh).map(\.place.id).sorted(), ["osm:node/5", "osm:node/6"])
        XCTAssertEqual(g.nearest(.fayda, from: Self.riyadh).map(\.place.id), ["geonames:7"])
        XCTAssertEqual(g.nearest(.camp, from: Self.riyadh).map(\.place.id), ["camp:thumamah-001"])
    }

    func testRankingIsNearestFirstAndToTheEdgeOfASandSea() {
        let hits = g.nearest(.nafud, from: Self.riyadh)
        XCTAssertEqual(hits.map(\.place.id), ["osm:relation/1", "geonames:10"])
        /* Riyadh → the Dahna's western edge (47.5°E) ≈ 83 km, not its centre point (≈ 150 km). */
        XCTAssertEqual(hits[0].meters, 83_000, accuracy: 3_000)
        XCTAssertLessThan(hits[0].meters, PlanGeo.meters(Self.riyadh, hits[0].place.point))
        let inside = g.nearest(.nafud, from: LngLat(lng: 48.0, lat: 25.0))
        XCTAssertTrue(inside[0].inside)
        XCTAssertEqual(inside[0].meters, 0)
        XCTAssertEqual(g.nearest(.rawda, from: Self.riyadh, limit: 1).count, 1)
    }

    func testApproachIsTheNearestEdge() {
        let d = g.places.first { $0.id == "osm:relation/1" }!
        let a = d.approach(from: Self.riyadh)
        XCTAssertEqual(a.lng, 47.5, accuracy: 0.001)
        XCTAssertEqual(a.lat, 24.71, accuracy: 0.02)
        XCTAssertEqual(d.approach(from: LngLat(lng: 48, lat: 25)), d.point, "inside: its own point")
    }

    func testEdgeDistanceGeometry() {
        let sq = [[LngLat(lng: 46, lat: 24), LngLat(lng: 47, lat: 24), LngLat(lng: 47, lat: 25), LngLat(lng: 46, lat: 25)]]
        XCTAssertTrue(DesertGeo.inside(LngLat(lng: 46.5, lat: 24.5), sq))
        XCTAssertEqual(DesertGeo.distanceToEdge(LngLat(lng: 47.1, lat: 24.5), sq), 10_120, accuracy: 300)
        XCTAssertEqual(DesertGeo.bbox(sq), [46, 24, 47, 25])
    }

    func testFreeTextFindsDesertNamesInBothLanguages() {
        let g = g
        XCTAssertEqual(g.search("الدهناء", near: Self.riyadh).first?.place.id, "osm:relation/1")
        XCTAssertEqual(g.search("دهناء", near: nil).first?.place.id, "osm:relation/1")
        XCTAssertEqual(g.search("روضه خريم", near: nil).first?.place.id, "osm:node/5")
        XCTAssertEqual(g.search("Nafūd ath Thuwayrāt", near: nil).first?.place.id, "geonames:10")
        XCTAssertEqual(g.search("روضة", near: Self.riyadh).count, 2)
        XCTAssertTrue(g.search("كشتة", near: nil).isEmpty, "camp suggestions are not names")
        XCTAssertTrue(g.search("ر", near: nil).isEmpty, "too short")
    }

    func testHomeSearchPutsTheGazetteerFirstWithoutDuplicates() {
        let desert = HomeDesertRules.searchPlaces(g, "روضة خريم", near: Self.riyadh)
        XCTAssertEqual(desert.first?.id, "gazetteer:osm:node/5")
        XCTAssertEqual(desert.first?.category, "روضة")
        let other = [PlaceSearch.Place(id: "mb1", name: "روضه خريم", point: LngLat(lng: 47.31, lat: 25.38)),
                     PlaceSearch.Place(id: "mb2", name: "استراحة خريم", point: LngLat(lng: 47.5, lat: 25.6))]
        XCTAssertEqual(HomeDesertRules.merge(desert: desert, places: other).map(\.id), ["gazetteer:osm:node/5", "mb2"])
    }

    func testChipsGoThroughTheDesertSeam() {
        let byId = Dictionary(uniqueKeysWithValues: HomeCategory.desertOnes.map { ($0.id, $0) })
        XCTAssertEqual(byId["nufud"]?.desertSource, .gazetteer(.nafud))
        XCTAssertEqual(byId["rawda"]?.desertSource, .gazetteer(.rawda))
        XCTAssertEqual(byId["faydah"]?.desertSource, .gazetteer(.fayda))
        XCTAssertEqual(byId["camps"]?.desertSource, .gazetteer(.camp))
        XCTAssertEqual(byId["rain"]?.desertSource, .rainGreen("مطر|ربيع"))
        XCTAssertTrue(HomeCategory.city.allSatisfy { $0.desertSource == nil })
        XCTAssertEqual(HomeDesertRules.heading(byId["camps"]!), "أماكن مقترحة للكشتة")
    }

    func testGazetteerServiceListsNearestWithDistance() async {
        let s = GazetteerCategoryService(gazetteer: g)
        let nufud = HomeCategory.desertOnes.first { $0.id == "nufud" }!
        guard case let .places(items) = await s.search(nufud, near: Self.riyadh) else { return XCTFail() }
        XCTAssertEqual(items.map(\.id), ["osm:relation/1", "geonames:10"])
        XCTAssertEqual(items[0].meters ?? 0, 83_000, accuracy: 3_000)
        XCTAssertEqual(items[0].detail, "Ad Dahna")
        XCTAssertNotNil(items[0].polygon)
        XCTAssertEqual(items[0].approach?.lng ?? 0, 47.5, accuracy: 0.001)
        /* No fix: ranked from Riyadh all the same. */
        guard case let .places(noFix) = await s.search(nufud, near: nil) else { return XCTFail() }
        XCTAssertEqual(noFix.map(\.id), items.map(\.id))
    }

    func testRainGreenSaysSoonUntilTheEndpointAnswers() async {
        let rain = HomeCategory.desertOnes.first { $0.id == "rain" }!
        var s = RainGreenCategoryService()
        s.fetch = { _ in (Data("Not found".utf8), 404) }
        let r404 = await s.search(rain, near: Self.riyadh)
        XCTAssertEqual(r404, .comingSoon(RainGreenCategoryService.comingSoon))
        s.fetch = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await s.search(rain, near: Self.riyadh)
        XCTAssertEqual(offline, .comingSoon(RainGreenCategoryService.comingSoon))
        s.enabled = false
        let off = await s.search(rain, near: Self.riyadh)
        XCTAssertEqual(off, .comingSoon(RainGreenCategoryService.comingSoon))
    }

    func testRainGreenRequestAndContractShape() async throws {
        let req = try XCTUnwrap(RainGreenCategoryService.request(base: URL(string: "https://x.test")!, q: "مطر|ربيع", near: Self.riyadh))
        let c = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.path, "/api/desert/categories/search")
        XCTAssertEqual(c.queryItems?.first { $0.name == "q" }?.value, "مطر|ربيع")
        XCTAssertEqual(c.queryItems?.first { $0.name == "near" }?.value, "24.714,46.675")
        let body = """
        {"ok":true,"query":"مطر|ربيع","intents":["rain","green"],"count":1,"results":[
         {"id":"places:123456","type":"place","name_ar":"روضة التنهات","kind":"rawdah","kind_ar":"روضة","lat":24.5,"lng":46.5,
          "distance_km":29.4,"score":0.81,"headline_ar":"نزل مطر هنا قبل ٣ أيام (حوالي ١٨ ملم)","signals":{"rain_mm_7d":18},"source":"osm"}]}
        """
        var s = RainGreenCategoryService()
        s.fetch = { _ in (Data(body.utf8), 200) }
        let rain = HomeCategory.desertOnes.first { $0.id == "rain" }!
        guard case let .places(items) = await s.search(rain, near: Self.riyadh) else { return XCTFail() }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "روضة التنهات")
        XCTAssertEqual(items[0].detail, "نزل مطر هنا قبل ٣ أيام (حوالي ١٨ ملم)")
        XCTAssertEqual(items[0].meters ?? 0, 29_400, accuracy: 1)
        XCTAssertEqual(items[0].systemImage, DesertKind.rawda.systemImage)
    }

    func testRouterSendsEachChipToItsService() async {
        let router = DesertCategoryRouter(gazetteer: GazetteerCategoryService(gazetteer: g), rainGreen: RainGreenCategoryService(enabled: false))
        let camps = HomeCategory.desertOnes.first { $0.id == "camps" }!
        guard case let .places(items) = await router.search(camps, near: Self.riyadh) else { return XCTFail() }
        XCTAssertEqual(items.first?.title, "كشتة مقترحة قرب طعس دليل")
        let rain = HomeCategory.desertOnes.first { $0.id == "rain" }!
        let soon = await router.search(rain, near: Self.riyadh)
        XCTAssertEqual(soon, .comingSoon(RainGreenCategoryService.comingSoon))
    }

    func testOverlayFeatures() {
        let items = GazetteerCategoryService.items(g, kind: .nafud, near: Self.riyadh, limit: 5)
        let fc = DesertGazetteerMapLayer.collection(DesertOverlay(items: items, selected: items.first?.id))
        XCTAssertEqual(fc.features.count, 3, "one outline + two markers")
        XCTAssertNil(DesertGazetteerMapLayer.collection(nil).features.first)
    }
}
