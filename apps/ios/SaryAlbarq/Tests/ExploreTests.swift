import XCTest
@testable import SaryAlbarq

/// Build 9 stage A — exploration (docs/IA-REDESIGN.md §6).
@MainActor
final class ExploreTests: XCTestCase {
    func testFarFromGroupNeedsALiveReference() {
        let c = LngLat(lng: 46.6753, lat: 24.7136)
        XCTAssertFalse(ExploreRules.farFromGroup(center: c, live: []), "no live car: nothing to be far from")
        XCTAssertFalse(ExploreRules.farFromGroup(center: c, live: [LngLat(lng: 46.70, lat: 24.72)]), "≈ 2.6 km: still with the group")
        XCTAssertTrue(ExploreRules.farFromGroup(center: c, live: [LngLat(lng: 46.80, lat: 24.80)]), "≈ 16 km away")
        XCTAssertFalse(ExploreRules.farFromGroup(center: c, live: [LngLat(lng: 46.80, lat: 24.80), LngLat(lng: 46.676, lat: 24.714)]),
                       "near any one car is near the group")
    }

    func testElevationIsNeverInvented() {
        XCTAssertEqual(ExploreRules.elevationText(nil), "الارتفاع غير متاح")
        XCTAssertEqual(ExploreRules.elevationText(.nan), "الارتفاع غير متاح")
        XCTAssertEqual(ExploreRules.elevationText(612.4), "الارتفاع ٦١٢ م")
        XCTAssertEqual(ExploreRules.elevationText(-3.6), "الارتفاع -٤ م")
    }

    func testCoordinateFormats() {
        let p = LngLat(lng: 46.6753, lat: 24.7136)
        XCTAssertEqual(ExploreRules.coordinateText(p, .decimal), CoordinateShare.displayDecimal(p))
        XCTAssertTrue(ExploreRules.coordinateText(p, .dms).contains("°"))
        /* On screen: the Arabic decimal separator «٫», never "." or ","; the copy stays ASCII. */
        let shown = ExploreRules.coordinateText(LngLat(lng: 45, lat: 24.5), .decimal)
        XCTAssertEqual(shown, "٢٤٫٥٠٠٠٠، ٤٥٫٠٠٠٠٠")
        XCTAssertFalse(shown.contains(",") || shown.contains("."))
        XCTAssertEqual(CoordinateShare.copyDecimal(LngLat(lng: 45, lat: 24.5)), "24.50000, 45.00000")
    }

    func testOfflineNotesAreHonest() {
        XCTAssertTrue(ExploreRules.offlineNote(.standard, areas: 3, topoAreas: 3).contains("يحتاج إنترنت دائمًا"))
        XCTAssertTrue(ExploreRules.offlineNote(.topo, areas: 3, topoAreas: 0).hasPrefix("يحتاج إنترنت"), "satellite areas do not cover topo")
        XCTAssertTrue(ExploreRules.offlineNote(.topo, areas: 3, topoAreas: 1).contains("بلا إنترنت"))
        XCTAssertTrue(ExploreRules.offlineNote(.satellite, areas: 0, topoAreas: 0).hasPrefix("يحتاج إنترنت"))
        XCTAssertFalse(MapLayer.standard.canBeOffline)
    }

    func testLayersAreRealMapboxStyles() {
        XCTAssertEqual(MapLayer.satellite.styleURI.rawValue, "mapbox://styles/mapbox/standard-satellite")
        XCTAssertEqual(MapLayer.standard.styleURI.rawValue, "mapbox://styles/mapbox/standard")
        XCTAssertEqual(MapLayer.topo.styleURI.rawValue, "mapbox://styles/mapbox/outdoors-v12")
        XCTAssertFalse(MapLayer.topo.isImport)
    }

    func testSavedPlaces() {
        let store = SavedPlacesStore(fileName: "test-places-\(UUID().uuidString).json")
        defer { store.wipe() }
        XCTAssertNil(store.add(name: "x", icon: .pin, at: LngLat(lng: 200, lat: 0)), "invalid coordinate refused")
        let a = store.add(name: "   ", icon: .camp, at: LngLat(lng: 46.6, lat: 24.7), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(a?.name, "مكان محفوظ")
        let b = store.add(name: String(repeating: "ب", count: 90), icon: .water, at: LngLat(lng: 46.7, lat: 24.8), now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(b?.name.count, SavedPlace.nameMax)
        XCTAssertEqual(store.places.first?.id, b?.id, "newest first")
        store.update(a!.id, name: "مخيم", icon: .flag)
        XCTAssertEqual(store.places.first { $0.id == a!.id }?.name, "مخيم")
        store.delete(b!.id)
        XCTAssertEqual(store.places.map(\.id), [a!.id])
    }

    func testTrackLibraryDedupesAndCaps() {
        let lib = TrackLibrary(fileName: "test-tracks-\(UUID().uuidString).json")
        defer { lib.wipe() }
        let pts = [LngLat(lng: 46.0, lat: 24.0), LngLat(lng: 46.01, lat: 24.0)]
        XCTAssertNil(lib.add(name: "x", origin: .imported, points: [pts[0]]), "one point is not a track")
        let id1 = lib.add(name: nil, origin: .exported, points: pts)
        let id2 = lib.add(name: "خطة", origin: .exported, points: pts)
        XCTAssertEqual(id1, id2, "same export twice is one entry")
        XCTAssertEqual(lib.tracks.count, 1)
        XCTAssertEqual(lib.tracks[0].name, "خطة")
        XCTAssertEqual(lib.tracks[0].lengthM, 1012, accuracy: 15)
        lib.toggleShown(id1!)
        XCTAssertTrue(lib.shown.contains(id1!))
        lib.delete(id1!)
        XCTAssertTrue(lib.tracks.isEmpty)
        XCTAssertFalse(lib.shown.contains(id1!))
    }

    func testTrackGPXRoundTrips() {
        let pts = [LngLat(lng: 46.1, lat: 24.1), LngLat(lng: 46.2, lat: 24.2), LngLat(lng: 46.3, lat: 24.25)]
        let gpx = RouteFile.gpx(name: "وادي <حنيفة>", points: pts)
        XCTAssertTrue(gpx.contains("&lt;حنيفة&gt;"))
        guard case let .success(im) = RouteFile.parse(Data(gpx.utf8), fileName: "a.gpx") else { return XCTFail("parses") }
        XCTAssertEqual(im.points.count, 3)
        XCTAssertEqual(im.points.last?.lat ?? 0, 24.25, accuracy: 1e-6)
    }
}
