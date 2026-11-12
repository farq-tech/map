import XCTest
@testable import SaryAlbarq

/// S2: the sheet's rows are generated from the registry, never written by hand.
final class MapLayersSheetModelTests: XCTestCase {
    private var suite: UserDefaults!
    private var domain = ""

    override func setUp() {
        super.setUp()
        domain = "MapLayersSheetModelTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: domain)
    }
    override func tearDown() { suite.removePersistentDomain(forName: domain); super.tearDown() }

    func testBaseRowsMatchTheCatalogInOrder() {
        let r = MapLayerRegistry(defaults: suite)
        let rows = MapLayersSheetModel.baseRows(registry: r, mode: .explore, areas: 0, topoAreas: 0)
        XCTAssertEqual(rows.map(\.id), MapLayerCatalog.base.map(\.id))
        XCTAssertEqual(rows.map(\.title), MapLayer.allCases.map(\.label))
        XCTAssertEqual(rows.map(\.testID), ["layer.satellite", "layer.standard", "layer.topo"], "ids the existing UI tests use")
        XCTAssertEqual(rows.filter(\.isSelected).map(\.testID), ["layer.satellite"], "exactly one selected, the default")
    }

    func testSelectionFollowsTheRegistryAndTheLegacyKey() {
        let r = MapLayerRegistry(defaults: suite)
        r.setActive(MapLayerCatalog.baseID(.topo))
        XCTAssertEqual(MapLayersSheetModel.baseRows(registry: r, mode: .explore, areas: 0, topoAreas: 0).filter(\.isSelected).map(\.testID), ["layer.topo"])
        XCTAssertEqual(suite.string(forKey: MapLayer.key), "topo")
    }

    func testOfflineNotesComeFromExploreRules() {
        let r = MapLayerRegistry(defaults: suite)
        let rows = MapLayersSheetModel.baseRows(registry: r, mode: .explore, areas: 2, topoAreas: 0)
        for (row, l) in zip(rows, MapLayer.allCases) {
            XCTAssertEqual(row.note, ExploreRules.offlineNote(l, areas: 2, topoAreas: 0))
        }
        XCTAssertTrue(rows[0].noteIsPositive, "satellite works offline with saved areas")
        XCTAssertFalse(rows[1].noteIsPositive)
        XCTAssertFalse(rows[2].noteIsPositive, "topo needs areas saved with it")
    }

    func testRowsFilterByModeAndAFutureLayerAppearsWithoutSheetChanges() {
        let extra = MapLayerDescriptor(id: "overlay.test", title: "طبقة تجريبية", systemImage: "star", category: .overlay,
                                       persistence: .flag(key: "sary.map.layer.overlay.test.v1"), availableIn: [.explore])
        let r = MapLayerRegistry(layers: MapLayerCatalog.all + [extra], defaults: suite)
        XCTAssertTrue(MapLayersSheetModel.switchLayers(registry: r, mode: .explore).map(\.id).contains("overlay.test"))
        XCTAssertFalse(MapLayersSheetModel.switchLayers(registry: r, mode: .home).map(\.id).contains("overlay.test"))
        let section = MapLayersSheetModel.sections(registry: r, mode: .explore).first { $0.id == "category.overlay" }
        XCTAssertEqual(section?.rows.map(\.id), ["overlay.test"], "an unknown overlay gets its own section with no sheet change")
        XCTAssertEqual(MapLayersSheetModel.baseRows(registry: r, mode: .home, areas: 0, topoAreas: 0).count, 3)
    }

    func testLiveMapSheetModeAndRowsPerMode() {
        XCTAssertEqual(MapLayersSheetModel.mode(exploring: true, navigating: false), .explore)
        XCTAssertEqual(MapLayersSheetModel.mode(exploring: true, navigating: true), .explore)
        XCTAssertEqual(MapLayersSheetModel.mode(exploring: false, navigating: true), .navigate)
        XCTAssertEqual(MapLayersSheetModel.mode(exploring: false, navigating: false), .outing)
        let r = MapLayerRegistry(defaults: suite)
        for m in [MapLayerMode.outing, .navigate] {
            XCTAssertEqual(MapLayersSheetModel.baseRows(registry: r, mode: m, areas: 0, topoAreas: 0).count, 3, "base layer choice in \(m)")
            XCTAssertFalse(MapLayersSheetModel.sections(registry: r, mode: m).isEmpty, "data layers in \(m)")
        }
    }

    func testSOSReserveCoversTheDiscAndItsMargins() {
        XCTAssertEqual(MapLayersSheetModel.sosReserve(disc: 64, small: 8), 88)
        XCTAssertGreaterThan(MapLayersSheetModel.sosReserve(disc: 76, small: 8), 76 + 16, "more than the disc's own box")
    }
}
