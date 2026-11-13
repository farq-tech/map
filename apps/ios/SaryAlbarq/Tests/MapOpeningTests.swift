import XCTest
@testable import SaryAlbarq

final class MapOpeningTests: XCTestCase {
    private let buraydah = LngLat(lng: 43.9750, lat: 26.3260)
    private let jeddah = LngLat(lng: 39.1925, lat: 21.4858)
    private let tabuk = LngLat(lng: 36.5662, lat: 28.3838)
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: "MapOpeningTests")!
        store.removePersistentDomain(forName: "MapOpeningTests")
        MapOpening.forgetLive()
    }

    override func tearDown() {
        store.removePersistentDomain(forName: "MapOpeningTests")
        MapOpening.forgetLive()
        super.tearDown()
    }

    func testOrderExplicitThenFixThenPersistedThenRiyadh() {
        XCTAssertEqual(MapOpening.resolve(explicit: tabuk, fix: buraydah, persisted: jeddah), tabuk)
        XCTAssertEqual(MapOpening.resolve(explicit: nil, fix: buraydah, persisted: jeddah), buraydah)
        XCTAssertEqual(MapOpening.resolve(explicit: nil, fix: nil, persisted: jeddah), jeddah)
        XCTAssertEqual(MapOpening.resolve(explicit: nil, fix: nil, persisted: nil), MapOpening.riyadh)
    }

    func testPersistedRoundTripAndStaleIgnored() {
        let now = Date()
        MapOpening.remember(buraydah, store: store, now: now, throttled: false)
        XCTAssertEqual(MapOpening.lastKnown(store: store, now: now.addingTimeInterval(3600)), buraydah)
        XCTAssertEqual(MapOpening.lastKnown(store: store, now: now.addingTimeInterval(29 * 86_400)), buraydah)
        XCTAssertNil(MapOpening.lastKnown(store: store, now: now.addingTimeInterval(31 * 86_400)))
    }

    func testStalePersistedFallsBackToRiyadh() {
        let now = Date()
        MapOpening.remember(buraydah, store: store, now: now.addingTimeInterval(-40 * 86_400), throttled: false)
        MapOpening.forgetLive()
        XCTAssertEqual(MapOpening.center(store: store, now: now), MapOpening.riyadh)
    }

    func testCenterUsesLiveFixThenPersisted() {
        let now = Date()
        XCTAssertEqual(MapOpening.center(store: store, now: now), MapOpening.riyadh)
        MapOpening.remember(buraydah, store: store, now: now, throttled: false)
        XCTAssertEqual(MapOpening.center(store: store, now: now), buraydah)   // live fix
        MapOpening.liveFix = nil
        XCTAssertEqual(MapOpening.center(store: store, now: now), buraydah)   // persisted
        XCTAssertEqual(MapOpening.center(explicit: tabuk, store: store, now: now), tabuk)
    }

    func testWritesAreThrottled() {
        let now = Date()
        MapOpening.remember(buraydah, store: store, now: now)
        MapOpening.remember(jeddah, store: store, now: now.addingTimeInterval(5))
        XCTAssertEqual(MapOpening.lastKnown(store: store, now: now), buraydah)   // second write skipped
        MapOpening.remember(jeddah, store: store, now: now.addingTimeInterval(30))
        XCTAssertEqual(MapOpening.lastKnown(store: store, now: now.addingTimeInterval(30)), jeddah)
        XCTAssertEqual(MapOpening.liveFix, jeddah)
    }

    func testPlanCameraInitialPrefersPickedThenRouteThenMe() {
        MapOpening.remember(buraydah, store: store, throttled: false)
        XCTAssertEqual(PlanCamera.initial(route: [], destination: nil, picked: tabuk), tabuk)
        XCTAssertEqual(PlanCamera.initial(route: [jeddah, tabuk], destination: nil, picked: nil), jeddah)
        XCTAssertEqual(PlanCamera.initial(route: [], destination: nil, picked: nil), buraydah)
    }

    func testDistance() {
        XCTAssertEqual(MapOpening.distanceM(MapOpening.riyadh, buraydah) / 1000, 316, accuracy: 20)
    }
}
