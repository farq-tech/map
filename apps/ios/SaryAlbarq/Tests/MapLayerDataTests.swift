import XCTest
@testable import SaryAlbarq

/// S3 of docs/ONE-MAP-UNIFICATION.md: the data layers are registered with the keys the app already used,
/// so nothing a person chose before is lost, and the registry and the layers' own owners always agree.
@MainActor
final class MapLayerDataTests: XCTestCase {
    private var suite: UserDefaults!
    private var domain = ""

    override func setUp() {
        super.setUp()
        domain = "MapLayerDataTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: domain)
    }
    override func tearDown() { suite.removePersistentDomain(forName: domain); super.tearDown() }

    private func registry() -> MapLayerRegistry { MapLayerRegistry(defaults: suite) }

    // MARK: Descriptors

    func testCatalogStaysConsistentWithDataLayers() {
        XCTAssertEqual(MapLayerCatalogCheck.issues(MapLayerCatalog.all), [])
        XCTAssertEqual(MapLayerCatalog.all.count, 3 + 4 + 3 + 2, "3 base + 4 weather + camp/osm/qibla + hires/terrain")
    }

    func testEveryDataDescriptorHasIDTitleIconCategoryAndDefault() {
        let expected: [(MapLayerID, String, MapLayerCategory, Bool)] = [
            ("weather.clouds", "السحاب الآن", .overlay, false), ("weather.rain", "وين نزل مطر", .overlay, false),
            ("weather.wind", "اتجاه الرياح", .overlay, false), ("weather.green", "وين ربّع", .overlay, false),
            ("data.camp", "أماكن مقترحة للكشتة", .data, false), ("data.osmTracks", "مسارات البر (OSM)", .data, true),
            ("data.qibla", "اتجاه القبلة", .data, true),
            ("imagery.hires", "صور عالية الوضوح", .terrain, true), ("terrain.3d", "عرض ثلاثي الأبعاد", .terrain, false),
        ]
        let r = registry()
        for (id, title, category, on) in expected {
            let d = r.descriptor(id)
            XCTAssertNotNil(d, id.rawValue)
            XCTAssertEqual(d?.title, title, id.rawValue)
            XCTAssertEqual(d?.category, category, id.rawValue)
            XCTAssertEqual(d?.defaultOn, on, id.rawValue)
            XCTAssertFalse(d?.systemImage.isEmpty ?? true, id.rawValue)
            XCTAssertNotNil(d?.title.range(of: "\\p{Arabic}", options: .regularExpression), id.rawValue)
            XCTAssertEqual(r.isActive(id), on, "\(id.rawValue): default state when nothing is stored")
        }
    }

    func testPersistenceKeysAreTheExistingOnes() {
        XCTAssertEqual(MapLayerCatalog.weatherKey, WeatherLayers.kindKey)
        XCTAssertEqual(MapLayerCatalog.campSitesKey, CampSitesHub.layerKey)
        XCTAssertEqual(MapLayerCatalog.osmTracksKey, DrivingRealismPrefs.osmKey)
        XCTAssertEqual(MapLayerCatalog.hiResKey, HiResSettings.userKey)
        XCTAssertEqual(MapLayerCatalog.qiblaVisibleKey, "sary.map.qibla.visible.v1", "the key every old install stored")
        let r = registry()
        for k in MapLayerCatalog.weatherKinds {
            XCTAssertEqual(r.descriptor(MapLayerCatalog.weatherID(k))?.persistence, .optionalChoice(key: "sary.map.weather.v1", value: k.rawValue, off: "none"))
        }
        XCTAssertEqual(MapLayerCatalog.camp.persistence, .flag(key: "sary.map.campSites.v1"))
        XCTAssertEqual(MapLayerCatalog.osmTracks.persistence, .flag(key: "sary.map.osmTracks.v1"))
        XCTAssertEqual(MapLayerCatalog.qibla.persistence, .flag(key: "sary.map.qibla.visible.v1"))
        XCTAssertEqual(MapLayerCatalog.hiRes.persistence, .flag(key: "sary.hires.user.v1"))
    }

    func testQiblaIsOneRegistrationNotThree() {
        XCTAssertEqual(MapLayerCatalog.all.filter { $0.storageKey == MapLayerCatalog.qiblaVisibleKey }.count, 1)
    }

    func testAvailabilityMatchesWhereTheLayerIsDrawn() {
        let r = registry()
        XCTAssertEqual(r.descriptor("weather.rain")?.availableIn, [.explore], "the weather overlay is drawn by the exploration map")
        XCTAssertTrue(MapLayerCatalog.qibla.availableIn.contains(.home), "the home map draws the Qibla ray")
        XCTAssertFalse(MapLayerCatalog.qibla.availableIn.contains(.navigate), "the ray hides during guidance")
        XCTAssertTrue(MapLayerCatalog.camp.availableIn.contains(.outing))
        XCTAssertFalse(r.layers(in: .home).contains { $0.id == "terrain.3d" || $0.id == "weather.rain" })
    }

    // MARK: Weather: one key, one at a time, legacy value carries over

    func testStoredWeatherKindBecomesTheActiveWeatherLayer() {
        for k in MapLayerCatalog.weatherKinds {
            suite.set(k.rawValue, forKey: WeatherLayers.kindKey)
            let r = registry()
            XCTAssertEqual(r.active.filter { $0.rawValue.hasPrefix("weather.") }, [MapLayerCatalog.weatherID(k)], k.rawValue)
        }
        for off in ["none", "", "hail", "RAIN"] {
            suite.set(off, forKey: WeatherLayers.kindKey)
            XCTAssertTrue(registry().active.filter { $0.rawValue.hasPrefix("weather.") }.isEmpty, "stored '\(off)' means no weather layer")
        }
        suite.removeObject(forKey: WeatherLayers.kindKey)
        _ = registry()
        XCTAssertNil(suite.object(forKey: WeatherLayers.kindKey), "reading never writes")
    }

    func testWeatherLayersAreMutuallyExclusiveAndWriteTheLegacyValue() {
        let r = registry()
        r.setActive("weather.rain")
        XCTAssertEqual(suite.string(forKey: WeatherLayers.kindKey), "rain")
        XCTAssertEqual(WeatherLayers(defaults: suite).kind, .rain, "the legacy owner reads what the registry wrote")
        r.setActive("weather.clouds")
        XCTAssertEqual(r.active.filter { $0.rawValue.hasPrefix("weather.") }, ["weather.clouds"], "choosing one turns the others off")
        XCTAssertEqual(suite.string(forKey: WeatherLayers.kindKey), "clouds")
        r.setActive("weather.rain", false)
        XCTAssertTrue(r.isActive("weather.clouds"), "switching off a layer that is not on changes nothing")
        r.setActive("weather.clouds", false)
        XCTAssertEqual(suite.string(forKey: WeatherLayers.kindKey), "none", "off is stored as the legacy «none»")
        XCTAssertEqual(WeatherLayers(defaults: suite).kind, WeatherOverlayKind.none)
        XCTAssertTrue(registry().active.filter { $0.rawValue.hasPrefix("weather.") }.isEmpty, "off survives a relaunch")
    }

    func testLegacyWeatherWriteIsSeenByTheRegistry() {
        let legacy = WeatherLayers(defaults: suite)
        let r = registry()
        legacy.kind = .wind
        r.reload()
        XCTAssertTrue(r.isActive("weather.wind"))
        legacy.kind = .none
        r.reload()
        XCTAssertFalse(r.isActive("weather.wind"))
    }

    func testWeatherConflictsAreTheOtherThree() {
        for k in MapLayerCatalog.weatherKinds {
            let d = MapLayerCatalog.weather.first { $0.id == MapLayerCatalog.weatherID(k) }
            XCTAssertEqual(d?.conflicts, Set(MapLayerCatalog.weatherKinds.filter { $0 != k }.map(MapLayerCatalog.weatherID)))
        }
    }

    // MARK: Flag layers: default, stored value, legacy reader agrees

    func testCampSitesFlag() {
        let r = registry()
        XCTAssertFalse(r.isActive("data.camp"), "off unless chosen, as before")
        r.setActive("data.camp")
        XCTAssertEqual(suite.object(forKey: CampSitesHub.layerKey) as? Bool, true)
        XCTAssertTrue(registry().isActive("data.camp"))
        r.setActive("data.camp", false)
        XCTAssertEqual(suite.object(forKey: CampSitesHub.layerKey) as? Bool, false)
    }

    func testOSMTracksFlagMatchesDrivingRealismPrefs() {
        let r = registry()
        XCTAssertTrue(r.isActive("data.osmTracks"), "on by default, like DrivingRealismPrefs")
        XCTAssertTrue(DrivingRealismPrefs.snapshot(suite).osmTracks)
        r.setActive("data.osmTracks", false)
        XCTAssertFalse(DrivingRealismPrefs.snapshot(suite).osmTracks, "the motion layer reads the value the registry stored")
        suite.set(true, forKey: DrivingRealismPrefs.osmKey)
        r.reload()
        XCTAssertTrue(r.isActive("data.osmTracks"))
    }

    func testHiResFlagMatchesHiResSettings() {
        let r = registry()
        XCTAssertTrue(r.isActive("imagery.hires"))
        XCTAssertTrue(HiResSettings(defaults: suite).userOn)
        r.setActive("imagery.hires", false)
        XCTAssertFalse(HiResSettings(defaults: suite).userOn)
        XCTAssertFalse(registry().isActive("imagery.hires"))
    }

    func testQiblaFlagMatchesTheStoredBool() {
        let r = registry()
        XCTAssertTrue(r.isActive("data.qibla"), "shown by default, as the three views had it")
        r.setActive("data.qibla", false)
        XCTAssertEqual(suite.object(forKey: "sary.map.qibla.visible.v1") as? Bool, false)
        // What an old install had stored (written through @AppStorage) is read back unchanged.
        suite.set(true, forKey: "sary.map.qibla.visible.v1")
        XCTAssertTrue(registry().isActive("data.qibla"))
    }

    func testWrongTypeInAFlagKeyFallsBackToTheDefault() {
        suite.set("yes", forKey: MapLayerCatalog.campSitesKey)
        suite.set("no", forKey: MapLayerCatalog.osmTracksKey)
        let r = registry()
        XCTAssertFalse(r.isActive("data.camp"))
        XCTAssertTrue(r.isActive("data.osmTracks"))
    }

    // MARK: Terrain: not stored

    func testTerrainIsASessionLayerAndNeverWritesDefaults() {
        let r = registry()
        XCTAssertFalse(r.isActive("terrain.3d"))
        r.setActive("terrain.3d")
        XCTAssertTrue(r.isActive("terrain.3d"))
        XCTAssertTrue(suite.dictionaryRepresentation().keys.filter { $0.contains("terrain") }.isEmpty, "3D terrain was never stored; it still is not")
        XCTAssertFalse(registry().isActive("terrain.3d"), "a new run starts flat, as before")
        r.setActive("terrain.3d", false)
        XCTAssertFalse(r.isActive("terrain.3d"))
    }

    // MARK: Catalog rules for the new persistence kinds

    func testCatalogCheckCatchesBrokenOptionalGroupsAndSessions() {
        func opt(_ id: String, _ v: String, off: String = "none", on: Bool = false) -> MapLayerDescriptor {
            MapLayerDescriptor(id: MapLayerID(rawValue: id), title: "أ", systemImage: "star", category: .overlay, defaultOn: on,
                               persistence: .optionalChoice(key: "k", value: v, off: off))
        }
        XCTAssertEqual(MapLayerCatalogCheck.issues([opt("a", "1"), opt("b", "2")]), [])
        XCTAssertFalse(MapLayerCatalogCheck.issues([opt("a", "1", on: true), opt("b", "2", on: true)]).isEmpty, "two defaults")
        XCTAssertFalse(MapLayerCatalogCheck.issues([opt("a", "none")]).isEmpty, "a member value equals the off value")
        XCTAssertFalse(MapLayerCatalogCheck.issues([opt("a", "1"), opt("b", "2", off: "zero")]).isEmpty, "members disagree on off")
        let clash = MapLayerDescriptor(id: "f", title: "أ", systemImage: "star", category: .data, persistence: .flag(key: "k"))
        XCTAssertFalse(MapLayerCatalogCheck.issues([opt("a", "1"), clash]).isEmpty, "a key cannot be a group and a flag")
        let s1 = MapLayerDescriptor(id: "s1", title: "أ", systemImage: "star", category: .terrain, persistence: .session(name: "x"))
        let s2 = MapLayerDescriptor(id: "s2", title: "أ", systemImage: "star", category: .terrain, persistence: .session(name: "x"))
        XCTAssertFalse(MapLayerCatalogCheck.issues([s1, s2]).isEmpty, "duplicate session name")
    }

    // MARK: Sheet sections come from the catalog

    func testSectionsAreGeneratedFromTheCatalogPerMode() {
        let r = registry()
        let explore = MapLayersSheetModel.sections(registry: r, mode: .explore)
        XCTAssertEqual(explore.map(\.id), ["group.الطقس", "category.data", "category.terrain"])
        XCTAssertEqual(explore[0].rows.map(\.testID), ["weather.layer.clouds", "weather.layer.rain", "weather.layer.wind", "weather.layer.green"])
        XCTAssertEqual(explore[0].off?.testID, "weather.layer.none")
        XCTAssertEqual(explore[0].off?.isSelected, true, "no weather layer: «بدون» is the selected row")
        XCTAssertEqual(explore[1].rows.map(\.testID), ["explore-camp-sites", "explore-osm-tracks", "explore-qibla"])
        XCTAssertEqual(explore[2].rows.map(\.testID), ["explore-hires", "explore-terrain3d"])

        r.setActive("weather.rain")
        let again = MapLayersSheetModel.sections(registry: r, mode: .explore)
        XCTAssertEqual(again[0].rows.filter(\.isOn).map(\.testID), ["weather.layer.rain"])
        XCTAssertEqual(again[0].off?.isSelected, false)

        XCTAssertEqual(MapLayersSheetModel.sections(registry: r, mode: .home).map(\.id), ["category.data"], "home offers only what its map draws")
        XCTAssertEqual(MapLayersSheetModel.sections(registry: r, mode: .home)[0].rows.map(\.id), ["data.qibla"])
        XCTAssertFalse(MapLayersSheetModel.sections(registry: r, mode: .outing).contains { $0.id == "group.الطقس" })
    }

    func testEveryDescriptorAppearsInSomeSheet() {
        let r = registry()
        var seen = Set<MapLayerID>()
        for mode in MapLayerMode.allCases {
            for s in MapLayersSheetModel.sections(registry: r, mode: mode) { for row in s.rows { seen.insert(row.id) } }
            for row in MapLayersSheetModel.baseRows(registry: r, mode: mode, areas: 0, topoAreas: 0) { seen.insert(row.id) }
        }
        XCTAssertEqual(seen, Set(MapLayerCatalog.all.map(\.id)))
    }
}
