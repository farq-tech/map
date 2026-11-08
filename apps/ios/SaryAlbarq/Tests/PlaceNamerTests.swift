import XCTest
@testable import SaryAlbarq

/// «أماكن سابقة» with real names: no more bare «نقطة على الخريطة».
final class PlaceNamerTests: XCTestCase {
    struct FakeGeocoder: ReverseGeocoding {
        var answer: GeocodeAnswer
        var delayS: Double = 0
        func lookup(_ p: LngLat) async -> GeocodeAnswer {
            if delayS > 0 { try? await Task.sleep(nanoseconds: UInt64(delayS * 1e9)) }
            return answer
        }
    }

    let thumama = Gazetteer.Entry(name: "الثمامة", point: LngLat(lng: 46.70, lat: 25.10))
    let riyadh = Gazetteer.Entry(name: "الرياض", point: LngLat(lng: 46.6753, lat: 24.7136))
    var gz: Gazetteer { Gazetteer(entries: [thumama, riyadh]) }
    var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "PlaceNamerTests")!
        defaults.removePersistentDomain(forName: "PlaceNamerTests")
    }

    /// `km` kilometres north of a point.
    func north(_ p: LngLat, km: Double) -> LngLat { LngLat(lng: p.lng, lat: p.lat + km / 110.54) }

    func testGenericNames() {
        XCTAssertTrue(PlaceLabel.isGeneric("نقطة على الخريطة"))
        XCTAssertTrue(PlaceLabel.isGeneric("  "))
        XCTAssertTrue(PlaceLabel.isGeneric("الوجهة"))
        XCTAssertTrue(PlaceLabel.isGeneric("24.7136, 46.6753"))
        XCTAssertFalse(PlaceLabel.isGeneric("روضة خريم"))
        XCTAssertTrue(PlaceLabel.isRelative("شمال الثمامة بـ ١٢ كم"))
        XCTAssertTrue(PlaceLabel.isRelative("قرب الثمامة"))
        XCTAssertFalse(PlaceLabel.isRelative("شمال الرياض"), "a district called «شمال …» is a name")
    }

    func testEightDirections() {
        XCTAssertEqual(PlaceNamer.direction(0), "شمال")
        XCTAssertEqual(PlaceNamer.direction(44), "شمال شرق")
        XCTAssertEqual(PlaceNamer.direction(90), "شرق")
        XCTAssertEqual(PlaceNamer.direction(181), "جنوب")
        XCTAssertEqual(PlaceNamer.direction(270), "غرب")
        XCTAssertEqual(PlaceNamer.direction(350), "شمال")
        XCTAssertEqual(PlaceNamer.direction(-45), "شمال غرب")
    }

    func testDesertPointIsSaidFromTheNearestNamedPlace() {
        let p = north(thumama.point, km: 12)
        XCTAssertEqual(PlaceNamer.compose(nil, at: p, gazetteer: gz), "شمال الثمامة بـ ١٢ كم")
        XCTAssertEqual(PlaceNamer.compose(nil, at: north(thumama.point, km: 0.5), gazetteer: gz), "قرب الثمامة")
    }

    func testGeocoderNamesWinInTown() {
        let p = riyadh.point
        XCTAssertEqual(PlaceNamer.compose(GeocodeParts(areaOfInterest: "بوليفارد رياض سيتي", subLocality: "حطين", locality: "الرياض"), at: p, gazetteer: gz),
                       "بوليفارد رياض سيتي")
        XCTAssertEqual(PlaceNamer.compose(GeocodeParts(subLocality: "العليا", locality: "الرياض"), at: p, gazetteer: gz), "العليا، الرياض")
        XCTAssertEqual(PlaceNamer.compose(GeocodeParts(thoroughfare: "طريق الملك فهد", locality: "الرياض"), at: p, gazetteer: gz), "طريق الملك فهد، الرياض")
        XCTAssertEqual(PlaceNamer.compose(GeocodeParts(thoroughfare: "1234", locality: "الرياض"), at: north(thumama.point, km: 5), gazetteer: gz),
                       "الرياض", "a bare number is not a street name; retain the actual city")
    }

    func testFarFromNamedDesertPlacesDoesNotInventAPlaceName() {
        let p = LngLat(lng: 47.5, lat: 22.0)
        XCTAssertNil(PlaceNamer.compose(nil, at: p, gazetteer: gz), "do not fall back to a distant town")
        XCTAssertEqual(PlaceNamer.compose(GeocodeParts(locality: "ليلى"), at: p, gazetteer: gz), "ليلى")
        XCTAssertNil(PlaceNamer.compose(GeocodeParts(locality: "إمارة منطقة الرياض", admin: "منطقة الرياض"), at: p, gazetteer: gz),
                     "a region name is not a specific place")
    }

    func testBundledGazetteerLoads() {
        let g = Gazetteer.shared
        XCTAssertGreaterThan(g.entries.count, 3000)
        XCTAssertTrue(g.entries.contains { $0.name == "رملة يام" })
        XCTAssertFalse(g.entries.contains { $0.name.hasPrefix("كشتة ") },
                       "proposed campsite coordinates are not place names")
    }

    func testResolverCachesAnswersButNotFailures() async {
        let cache = PlaceNameCache(defaults: defaults)
        let p = north(thumama.point, km: 12)
        let failing = PlaceNameResolver(geocoder: FakeGeocoder(answer: .failed), cache: cache, gazetteer: gz)
        let offline = await failing.name(for: p)
        XCTAssertEqual(offline, "شمال الثمامة بـ ١٢ كم", "offline: the bundled places still answer")
        XCTAssertNil(cache.get(p), "…but ask the geocoder again next time")
        let ok = PlaceNameResolver(geocoder: FakeGeocoder(answer: .found(GeocodeParts(subLocality: "الثمامة", locality: "الرياض"))), cache: cache, gazetteer: gz)
        let named = await ok.name(for: p)
        XCTAssertEqual(named, "الثمامة، الرياض")
        XCTAssertEqual(cache.get(p), "الثمامة، الرياض")
        let again = await PlaceNameResolver(geocoder: FakeGeocoder(answer: .failed), cache: cache, gazetteer: gz).name(for: p)
        XCTAssertEqual(again, "الثمامة، الرياض", "cached")
    }

    func testSlowGeocoderFallsBackInTime() async {
        let r = PlaceNameResolver(geocoder: FakeGeocoder(answer: .nothing, delayS: 3), cache: PlaceNameCache(defaults: defaults), gazetteer: gz)
        let start = Date()
        let name = await r.name(for: north(thumama.point, km: 12), within: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(name, "شمال الثمامة بـ ١٢ كم")
    }

    func testCacheIsBounded() {
        let c = PlaceNameCache(defaults: defaults)
        for i in 0 ..< PlaceNameCache.max + 20 { c.set(LngLat(lng: 46, lat: 20 + Double(i) * 0.01), "\(i)") }
        XCTAssertEqual((defaults.array(forKey: PlaceNameCache.key) ?? []).count, PlaceNameCache.max)
        XCTAssertNil(c.get(LngLat(lng: 46, lat: 20)), "oldest dropped")
        XCTAssertEqual(c.get(LngLat(lng: 46, lat: 20 + Double(PlaceNameCache.max + 19) * 0.01)), "\(PlaceNameCache.max + 19)")
    }

    func testRecentPlacesGetRealNames() async {
        let bare = OutingDestination(name: "نقطة على الخريطة", lat: north(thumama.point, km: 12).lat, lng: thumama.point.lng)
        RecentPlaces.add(OutingDestination(name: "روضة خريم", lat: 25.4, lng: 47.3), defaults: defaults)
        RecentPlaces.add(bare, defaults: defaults)
        let r = PlaceNameResolver(geocoder: FakeGeocoder(answer: .nothing), cache: PlaceNameCache(defaults: defaults), gazetteer: gz)
        let all = await RecentPlaces.resolveNames(defaults: defaults, resolver: r)
        XCTAssertEqual(all.map(\.name), ["شمال الثمامة بـ ١٢ كم", "روضة خريم"])
        XCTAssertEqual(RecentPlaces.load(defaults: defaults).map(\.name), all.map(\.name), "saved")
    }

    @MainActor
    func testSavedPlaceWithoutANameGetsOne() async throws {
        let file = "saved-places-namer-test.json"
        let store = SavedPlacesStore(fileName: file)
        defer { for p in store.places { store.delete(p.id) } }
        let r = PlaceNameResolver(geocoder: FakeGeocoder(answer: .found(GeocodeParts(subLocality: "العليا", locality: "الرياض"))),
                                  cache: PlaceNameCache(defaults: defaults), gazetteer: gz)
        store.namer = r
        let typed = store.add(name: "مخيمنا", icon: SavedPlaceIcon.allCases[0], at: riyadh.point)!
        let bare = store.add(name: "", icon: SavedPlaceIcon.allCases[0], at: north(riyadh.point, km: 1))!
        XCTAssertEqual(bare.name, "مكان محفوظ")
        for _ in 0 ..< 50 where store.places.first(where: { $0.id == bare.id })?.name == "مكان محفوظ" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.places.first { $0.id == bare.id }?.name, "العليا، الرياض")
        XCTAssertEqual(store.places.first { $0.id == typed.id }?.name, "مخيمنا", "a name the person typed is never replaced")
    }

    func testARelativeNameDoesNotNameTheOuting() {
        var f = CreateFlowState(now: Date())
        f.choose(OutingDestination(name: "شمال الثمامة بـ ١٢ كم", lat: 25.2, lng: 46.7))
        XCTAssertEqual(f.name, "طلعة جديدة", "a directional coordinate label must not replace the default outing name")
        var g = CreateFlowState(now: Date())
        g.choose(OutingDestination(name: "العليا، الرياض", lat: 24.7, lng: 46.68))
        XCTAssertEqual(g.name, "طلعة العليا، الرياض")
    }
}
