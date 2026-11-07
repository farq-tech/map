import XCTest
@testable import SaryAlbarq

/// The map-first home (UX simplification): shortcuts, categories, the sheet's rules.
final class HomeFlowTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "home-flow-tests")
        defaults.removePersistentDomain(forName: "home-flow-tests")
    }

    func testShortcutsAreKeptAndCleared() {
        XCTAssertTrue(HomeShortcutStore.load(defaults: defaults).isEmpty)
        let home = OutingDestination(name: "البيت", lat: 24.71, lng: 46.67)
        HomeShortcutStore.set(.home, home, defaults: defaults)
        HomeShortcutStore.set(.work, OutingDestination(name: "الشغل", lat: 24.77, lng: 46.64), defaults: defaults)
        XCTAssertEqual(HomeShortcutStore.load(defaults: defaults)[.home], home)
        XCTAssertEqual(HomeShortcutStore.load(defaults: defaults).count, 2)
        HomeShortcutStore.set(.home, nil, defaults: defaults)
        XCTAssertNil(HomeShortcutStore.load(defaults: defaults)[.home])
        XCTAssertNotNil(HomeShortcutStore.load(defaults: defaults)[.work])
    }

    func testAnInvalidStoredPointIsDropped() {
        HomeShortcutStore.set(.home, OutingDestination(name: "x", lat: 200, lng: 46), defaults: defaults)
        XCTAssertNil(HomeShortcutStore.load(defaults: defaults)[.home])
    }

    func testCategoriesHoldTheCityAndTheDesert() {
        let labels = HomeCategory.all.map(\.label)
        for l in ["مطاعم", "مقاهي", "مساجد", "محطات وقود", "المطارات", "نفود", "روضة", "فيضة", "مخيمات", "أمطار وربيع"] {
            XCTAssertTrue(labels.contains(l), l)
        }
        XCTAssertEqual(Set(HomeCategory.all.map(\.id)).count, HomeCategory.all.count, "unique ids")
        XCTAssertTrue(HomeCategory.desertOnes.allSatisfy(\.desert))
        XCTAssertFalse(HomeCategory.city.contains(where: \.desert))
    }

    func testSheetSettles() {
        XCTAssertTrue(HomeSheetRules.settle(expanded: false, translation: -120, velocity: 0), "pulled up: raise")
        XCTAssertFalse(HomeSheetRules.settle(expanded: false, translation: -20, velocity: 0), "a nudge: stays")
        XCTAssertFalse(HomeSheetRules.settle(expanded: true, translation: 140, velocity: 0), "pulled down: lower")
        XCTAssertTrue(HomeSheetRules.settle(expanded: true, translation: 30, velocity: 0))
        XCTAssertFalse(HomeSheetRules.settle(expanded: true, translation: 10, velocity: 900), "a flick down lowers it")
        XCTAssertGreaterThan(HomeSheetRules.expandedHeight(screen: 874), HomeSheetRules.collapsedHeight)
    }

    /// The cinematic intro is off by default (the owner: the moving logo looked laggy).
    func testIntroIsStaticByDefault() {
        XCTAssertFalse(IntroPolicy.enabledByDefault)
        XCTAssertEqual(IntroPolicy.mode(IntroFacts(enabled: IntroPolicy.enabled(defaults))), .still)
    }
}
