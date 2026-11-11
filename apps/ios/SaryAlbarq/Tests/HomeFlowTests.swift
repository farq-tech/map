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

    func testSheetFrameStaysValidForInitialAndInvalidGeometry() {
        for screen in [0.0, -1, .nan, .infinity] {
            let height = HomeSheetRules.frameHeight(screen: screen, preferred: .nan, drag: .infinity)
            XCTAssertTrue(height.isFinite, "height must be finite for screen=\(screen)")
            XCTAssertGreaterThanOrEqual(height, 160, "height must not be negative or collapse before layout")
        }
        XCTAssertEqual(HomeSheetRules.frameHeight(screen: 874, preferred: 220, drag: 20), 200)
        XCTAssertEqual(HomeSheetRules.frameHeight(screen: 874, preferred: 900, drag: 0), 760)
    }

    // MARK: the one state card (UI-AUDIT §٢ «الرئيسية»)

    private func outing(_ id: String, _ status: OutingStatus, role: String = "owner") -> OutingSummary {
        OutingSummary(id: id, name: id, status: status, role: role, my_status: "joined", member_count: 1)
    }

    func testStateCardPicksTheRunningThenTheUpcomingOuting() {
        let all = [outing("p", .created), outing("z", .paused), outing("a", .active)]
        XCTAssertEqual(HomeStateCard.pick(current: all, phase: .loaded), .active("a"), "«طلعتك جارية» first")
        XCTAssertEqual(HomeStateCard.pick(current: [outing("p", .created), outing("z", .paused)], phase: .loaded), .upcoming("z"),
                       "«طلعتك القادمة»: a paused outing before a planned one")
        XCTAssertEqual(HomeStateCard.pick(current: [outing("p", .created)], phase: .loaded), .upcoming("p"),
                       "a planned outing is no longer hidden")
    }

    func testStateCardFirstTimeLoadingAndFailure() {
        XCTAssertEqual(HomeStateCard.pick(current: [], phase: .loaded), .start, "nothing current: «أنشئ طلعة وادعُ ربعك»")
        XCTAssertEqual(HomeStateCard.pick(current: [outing("e", .ended)], phase: .loaded), .start)
        XCTAssertEqual(HomeStateCard.pick(current: [], phase: .loading), .none, "no flash of «أنشئ طلعة» while loading")
        XCTAssertEqual(HomeStateCard.pick(current: [], phase: .failed("x")), .failed("x"), "a failed list is said, never empty")
    }

    func testTheInviteHintStaysOnTheHome() {
        XCTAssertEqual(HomeStateCard.pick(current: [], phase: .loaded, inviteHint: true), .invite)
        XCTAssertEqual(HomeStateCard.pick(current: [outing("p", .created)], phase: .loaded, inviteHint: true), .invite)
        XCTAssertEqual(HomeStateCard.pick(current: [outing("a", .active)], phase: .loaded, inviteHint: true), .active("a"),
                       "a running outing still comes first")
    }

    func testCollapsedHeightGrowsWithTheCard() {
        XCTAssertEqual(HomeSheetRules.collapsedHeight(card: .none), HomeSheetRules.collapsedHeight)
        XCTAssertGreaterThan(HomeSheetRules.collapsedHeight(card: .active("a")), HomeSheetRules.collapsedHeight)
        XCTAssertGreaterThan(HomeSheetRules.collapsedHeight(card: .start), HomeSheetRules.collapsedHeight(card: .active("a")),
                             "the first-time card has two actions")
    }

    // MARK: the place card's action

    func testPlaceActionNeverMakesASecondOuting() {
        XCTAssertEqual(HomePlaceAction.pick(current: []), .create)
        XCTAssertEqual(HomePlaceAction.pick(current: [outing("a", .active)]), .guideConvoy("a"))
        XCTAssertEqual(HomePlaceAction.pick(current: [outing("a", .active, role: "member")]), .personalLeg("a"))
        XCTAssertEqual(HomePlaceAction.pick(current: [outing("p", .created)]), .addToOuting("p"))
        XCTAssertEqual(HomePlaceAction.pick(current: [outing("z", .paused)]).title, "أضفها لطلعتك")
        XCTAssertEqual(HomePlaceAction.pick(current: [outing("p", .created, role: "member")]), .create,
                       "a member cannot edit the leader's plan")
        XCTAssertEqual(HomePlaceAction.pick(current: [outing("p", .created), outing("a", .active)]), .guideConvoy("a"))
    }

    func testAddingAPlaceFillsTheDestinationThenTheStops() {
        let camp = OutingDestination(name: "روضة خريم", lat: 25.38, lng: 47.27)
        let fuel = OutingDestination(name: "محطة", lat: 25.10, lng: 46.90)
        let first = HomePlanEdit.adding(camp, to: .empty)
        XCTAssertEqual(first.outcome, .destination)
        XCTAssertEqual(first.plan.destination, camp)
        let second = HomePlanEdit.adding(fuel, to: first.plan)
        XCTAssertEqual(second.outcome, .stop)
        XCTAssertEqual(second.plan.stops, [fuel])
        XCTAssertEqual(second.plan.destination, camp, "the destination stays")
        XCTAssertEqual(HomePlanEdit.adding(fuel, to: second.plan).outcome, .already)
        XCTAssertEqual(HomePlanEdit.adding(OutingDestination(name: "x", lat: 25.3801, lng: 47.2701), to: second.plan).outcome, .already,
                       "a few metres from the destination is the same place")
        var full = first.plan
        full.stops = (0..<HomePlanEdit.maxStops).map { OutingDestination(name: "s\($0)", lat: 24 + Double($0) * 0.1, lng: 46) }
        XCTAssertEqual(HomePlanEdit.adding(fuel, to: full).outcome, .full)
    }

    func testListFailureIsSaidInPlainWords() {
        XCTAssertEqual(HomeListCopy.failedDetail("حدث خطأ. أعد المحاولة.", online: true), "صار خلل من طرفنا. جرّب مرة ثانية بعد شوي.")
        XCTAssertEqual(HomeListCopy.failedDetail("الخادم مشغول. أعد المحاولة بعد قليل.", online: true), "الخادم مشغول. أعد المحاولة بعد قليل.")
        XCTAssertTrue(HomeListCopy.failedDetail("x", online: false).contains("إنترنت"))
    }

    // MARK: «اتجه» without an outing, and the desert tools (م6)

    func testStandaloneNavGate() {
        let now = Date()
        let fresh = DeviceFix(lat: 24.7, lng: 46.7, accuracy: 8, heading: nil, speed: nil, atMs: now.timeIntervalSince1970 * 1000 - 2000)
        let old = DeviceFix(lat: 24.7, lng: 46.7, accuracy: 8, heading: nil, speed: nil, atMs: now.timeIntervalSince1970 * 1000 - 600_000)
        XCTAssertEqual(StandaloneNavRules.gate(canLocate: false, fix: fresh, now: now), .needsPermission)
        XCTAssertEqual(StandaloneNavRules.gate(canLocate: true, fix: nil, now: now), .waitingForFix)
        XCTAssertEqual(StandaloneNavRules.gate(canLocate: true, fix: old, now: now), .waitingForFix, "never guide from an old fix")
        XCTAssertEqual(StandaloneNavRules.gate(canLocate: true, fix: fresh, now: now), .ready)
    }

    func testStandaloneNavLine() {
        let a = LngLat(lng: 46.70, lat: 24.70), b = LngLat(lng: 46.70, lat: 24.72), c = LngLat(lng: 46.72, lat: 24.72)
        let target = LngLat(lng: 46.73, lat: 24.73)
        let route = NavRoute(id: "r", coordinates: [a, b, c], distanceM: 4250, durationS: 300, steps: [])
        let leg = NavOffRoadLeg(from: c, to: target, distanceM: 1500, bearing: 45)
        let whole = StandaloneNavRules.line(phase: .guiding, active: route, progress: nil, offRoad: leg, me: a, target: target)
        XCTAssertEqual(whole.first, a)
        XCTAssertEqual(whole.last, target, "the straight last part to an off-road target is drawn too")
        let progress = NavProgress(stepIndex: 0, distanceToManeuverM: 100, distanceRemainingM: 2000, durationRemainingS: 150)
        let ahead = StandaloneNavRules.line(phase: .guiding, active: route, progress: progress, offRoad: nil, me: nil, target: target)
        XCTAssertNotEqual(ahead.first, a, "the line shrinks behind the car")
        XCTAssertEqual(ahead.last, c)
        XCTAssertEqual(StandaloneNavRules.line(phase: .offRoad, active: nil, progress: nil, offRoad: leg, me: b, target: target), [b, target])
        XCTAssertTrue(StandaloneNavRules.line(phase: .planning, active: route, progress: nil, offRoad: leg, me: a, target: target).isEmpty)
        XCTAssertTrue(StandaloneNavRules.line(phase: .arrived, active: route, progress: nil, offRoad: leg, me: a, target: target).isEmpty)
        XCTAssertTrue(StandaloneNavRules.followDue(last: nil, now: Date()))
        XCTAssertFalse(StandaloneNavRules.followDue(last: Date(), now: Date()))
    }

    func testDesertRoutesOnlyForReachableDesertPlaces() {
        let thumamahA = LngLat(lng: 46.60, lat: 25.20), thumamahB = LngLat(lng: 46.75, lat: 25.30)
        XCTAssertFalse(HomeDesertTools.offersRoutes(desertPlace: false, me: thumamahA, target: thumamahB), "a restaurant: no «دروب البر»")
        XCTAssertTrue(HomeDesertTools.offersRoutes(desertPlace: true, me: thumamahA, target: thumamahB), "inside a bundled region")
        XCTAssertTrue(HomeDesertTools.offersRoutes(desertPlace: true, me: nil, target: thumamahB), "unknown position: the sheet says «ننتظر موقعك»")
        XCTAssertFalse(HomeDesertTools.offersRoutes(desertPlace: true, me: LngLat(lng: 2.35, lat: 48.85), target: thumamahB), "outside the Kingdom")
        XCTAssertNil(HomeDesertTools.weatherPoint(me: nil))
        XCTAssertEqual(HomeDesertTools.weatherPoint(me: thumamahA)?.lat, 25.20)
    }

    /// The cinematic intro is off by default (the owner: the moving logo looked laggy).
    func testIntroIsStaticByDefault() {
        XCTAssertFalse(IntroPolicy.enabledByDefault)
        XCTAssertEqual(IntroPolicy.mode(IntroFacts(enabled: IntroPolicy.enabled(defaults))), .still)
    }
}
