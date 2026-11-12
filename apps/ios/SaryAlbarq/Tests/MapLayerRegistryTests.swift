import XCTest
@testable import SaryAlbarq

/// S1 of docs/ONE-MAP-UNIFICATION.md: the registry reads and writes the SAME stored key as `MapLayer`.
final class MapLayerRegistryTests: XCTestCase {
    private var suite: UserDefaults!
    private var domain = ""

    override func setUp() {
        super.setUp()
        domain = "MapLayerRegistryTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: domain)
    }
    override func tearDown() { suite.removePersistentDomain(forName: domain); super.tearDown() }

    private func registry(_ layers: [MapLayerDescriptor] = MapLayerCatalog.all) -> MapLayerRegistry {
        MapLayerRegistry(layers: layers, defaults: suite)
    }

    // MARK: Registration

    func testCatalogIsConsistent() {
        XCTAssertEqual(MapLayerCatalogCheck.issues(MapLayerCatalog.all), [])
    }

    func testEveryLegacyLayerIsRegisteredWithItsOwnKeyAndValue() {
        XCTAssertEqual(MapLayerCatalog.base.count, MapLayer.allCases.count)
        for l in MapLayer.allCases {
            let d = registry().descriptor(MapLayerCatalog.baseID(l))
            XCTAssertNotNil(d, "\(l)")
            XCTAssertEqual(d?.persistence, .choice(key: "sary.map.layer.v1", value: l.rawValue))
            XCTAssertEqual(d?.title, l.label)
            XCTAssertEqual(d?.category, .base)
            XCTAssertEqual(MapLayerCatalog.legacy(d!.id), l)
        }
        XCTAssertEqual(MapLayer.key, "sary.map.layer.v1", "the stored key must not change")
    }

    func testIDsAreUniqueAndTitlesArabic() {
        let all = MapLayerCatalog.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        for l in all {
            XCTAssertFalse(l.title.isEmpty)
            XCTAssertNotNil(l.title.range(of: "\\p{Arabic}", options: .regularExpression), l.id.rawValue)
            XCTAssertFalse(l.availableIn.isEmpty)
        }
    }

    func testAFutureLayerRegistersWithOneDescriptor() {
        let extra = MapLayerDescriptor(id: "overlay.test", title: "طبقة تجريبية", systemImage: "star", category: .overlay,
                                       persistence: .flag(key: "sary.map.layer.overlay.test.v1"), availableIn: [.explore])
        let layers = MapLayerCatalog.all + [extra]
        XCTAssertEqual(MapLayerCatalogCheck.issues(layers), [])
        let r = registry(layers)
        XCTAssertTrue(r.layers(in: .explore, category: .overlay).map(\.id).contains("overlay.test"))
        XCTAssertFalse(r.layers(in: .home, category: .overlay).map(\.id).contains("overlay.test"), "availableIn filters the sheet rows")
        XCTAssertEqual(r.layers(in: .explore, category: .base).count, 3)
    }

    func testCatalogCheckCatchesBrokenRegistrations() {
        let a = MapLayerDescriptor(id: "x", title: "أ", systemImage: "star", category: .overlay, persistence: .flag(key: "k"))
        let dupID = MapLayerDescriptor(id: "x", title: "ب", systemImage: "star", category: .overlay, persistence: .flag(key: "k2"))
        let dupKey = MapLayerDescriptor(id: "y", title: "ب", systemImage: "star", category: .overlay, persistence: .flag(key: "k"))
        let ghost = MapLayerDescriptor(id: "z", title: "ج", systemImage: "star", category: .overlay, conflicts: ["nope"], persistence: .flag(key: "k3"))
        let empty = MapLayerDescriptor(id: "w", title: " ", systemImage: "star", category: .overlay, persistence: .flag(key: "k4"), availableIn: [])
        XCTAssertFalse(MapLayerCatalogCheck.issues([a, dupID]).isEmpty)
        XCTAssertFalse(MapLayerCatalogCheck.issues([a, dupKey]).isEmpty)
        XCTAssertFalse(MapLayerCatalogCheck.issues([ghost]).isEmpty)
        XCTAssertGreaterThanOrEqual(MapLayerCatalogCheck.issues([empty]).count, 2)
        // A choice group with no default, or two, is broken.
        let c1 = MapLayerDescriptor(id: "c1", title: "أ", systemImage: "star", category: .base, persistence: .choice(key: "g", value: "1"))
        XCTAssertFalse(MapLayerCatalogCheck.issues([c1]).isEmpty)
    }

    // MARK: Defaults and persistence

    func testDefaultIsSatelliteAndNothingIsWrittenOnRead() {
        let r = registry()
        XCTAssertEqual(r.activeBase, "base.satellite")
        XCTAssertEqual(r.active.filter { $0.rawValue.hasPrefix("base.") }, ["base.satellite"])
        XCTAssertNil(suite.object(forKey: "sary.map.layer.v1"), "reading never writes")
    }

    func testRoundTripWithTheLegacyKey() {
        // Registry writes -> MapLayer reads (same key).
        let r = registry()
        for l in MapLayer.allCases {
            r.setActive(MapLayerCatalog.baseID(l))
            XCTAssertEqual(suite.string(forKey: MapLayer.key), l.rawValue)
            XCTAssertEqual(r.activeBase, MapLayerCatalog.baseID(l))
            XCTAssertEqual(r.active.filter { $0.rawValue.hasPrefix("base.") }.count, 1, "base layers are exclusive")
        }
        // Legacy writes -> a fresh registry reads.
        for l in MapLayer.allCases {
            suite.set(l.rawValue, forKey: MapLayer.key)
            XCTAssertEqual(registry().activeBase, MapLayerCatalog.baseID(l))
        }
    }

    func testRegistryOnStandardDefaultsMatchesMapLayerSaved() {
        let saved = MapLayer.saved
        defer { MapLayer.saved = saved }
        for l in MapLayer.allCases {
            MapLayer.saved = l
            XCTAssertEqual(MapLayerRegistry(defaults: .standard).activeBase, MapLayerCatalog.baseID(l))
        }
    }

    func testReloadFollowsAnOutsideWrite() {
        let r = registry()
        suite.set("topo", forKey: MapLayer.key)
        XCTAssertEqual(r.activeBase, "base.satellite", "cached until reload")
        r.reload()
        XCTAssertEqual(r.activeBase, "base.topo")
    }

    func testUnknownStoredValueFallsBackToTheDefault() {
        for junk in ["", "hybrid", "SATELLITE", "base.topo", "٣"] {
            suite.set(junk, forKey: MapLayer.key)
            XCTAssertEqual(registry().activeBase, "base.satellite", "stored '\(junk)'")
        }
        suite.set(7, forKey: MapLayer.key) // wrong type
        XCTAssertEqual(registry().activeBase, "base.satellite")
        XCTAssertNil(MapLayer(rawValue: "hybrid"), "the legacy reader falls back the same way")
    }

    func testUnknownIDIsIgnored() {
        let r = registry()
        r.setActive("base.nope")
        XCTAssertEqual(r.activeBase, "base.satellite")
        XCTAssertNil(suite.object(forKey: MapLayer.key))
    }

    func testBaseChoiceCannotBeSwitchedOff() {
        let r = registry()
        r.setActive("base.topo")
        r.setActive("base.topo", false)
        XCTAssertEqual(r.activeBase, "base.topo")
    }

    // MARK: Conflicts (flag layers)

    func testConflictSwitchesTheOtherOff() {
        let a = MapLayerDescriptor(id: "o.a", title: "أ", systemImage: "star", category: .overlay, defaultOn: true,
                                   conflicts: ["o.b"], persistence: .flag(key: "ka"))
        let b = MapLayerDescriptor(id: "o.b", title: "ب", systemImage: "star", category: .overlay, conflicts: ["o.a"], persistence: .flag(key: "kb"))
        let r = registry([a, b])
        XCTAssertEqual(r.active, ["o.a"], "defaultOn applies when nothing is stored")
        r.setActive("o.b")
        XCTAssertEqual(r.active, ["o.b"])
        XCTAssertEqual(suite.object(forKey: "ka") as? Bool, false)
        XCTAssertEqual(suite.object(forKey: "kb") as? Bool, true)
        r.setActive("o.b", false)
        XCTAssertTrue(r.active.isEmpty)
        XCTAssertTrue(registry([a, b]).active.isEmpty, "off survives a relaunch even for a defaultOn layer")
    }

    func testFlagWithoutConflictsIsIndependent() {
        let a = MapLayerDescriptor(id: "o.a", title: "أ", systemImage: "star", category: .overlay, persistence: .flag(key: "ka"))
        let b = MapLayerDescriptor(id: "o.b", title: "ب", systemImage: "star", category: .overlay, persistence: .flag(key: "kb"))
        let r = registry([a, b])
        r.setActive("o.a"); r.setActive("o.b")
        XCTAssertEqual(r.active, ["o.a", "o.b"])
    }
}
