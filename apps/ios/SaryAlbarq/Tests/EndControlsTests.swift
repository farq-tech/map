import XCTest
@testable import SaryAlbarq

/// «إنهاء الرحلة» vs «إنهاء الطلعة»: which end actions each state offers (pure rule, `EndControls`).
final class EndControlsTests: XCTestCase {
    private func offered(solo: Bool = false, guiding: Bool = false, running: Bool = true, owner: Bool = false, leave: Bool = true) -> [EndControls.Action] {
        EndControls.offered(.init(solo: solo, guiding: guiding, outingRunning: running, iOwn: owner, canLeave: leave))
    }

    func testSoloOffersOneActionThatEndsTheTrip() {
        XCTAssertEqual(offered(solo: true, guiding: true, leave: false), [.endSolo])
        XCTAssertEqual(offered(solo: true, guiding: false, leave: false), [.endSolo])
        XCTAssertEqual(offered(solo: true, guiding: false, running: false, leave: false), [])
    }

    func testMemberGuidingGetsTripThenLeave() {
        XCTAssertEqual(offered(guiding: true), [.endTrip, .leaveOuting])
        XCTAssertEqual(offered(guiding: false), [.leaveOuting], "no guidance: no trip to end")
    }

    func testOwnerGuidingGetsTripEndForAllAndLeaveOnly() {
        XCTAssertEqual(offered(guiding: true, owner: true), [.endTrip, .endOutingForAll, .leaveOnly])
        XCTAssertEqual(offered(guiding: false, owner: true), [.endOutingForAll, .leaveOnly])
    }

    func testOwnerWithoutLeaveOnlyEndsForAll() {
        XCTAssertEqual(offered(guiding: true, owner: true, leave: false), [.endTrip, .endOutingForAll])
    }

    func testEndedOutingOffersNoEndForAll() {
        XCTAssertEqual(offered(guiding: false, running: false, owner: true), [.leaveOuting])
        XCTAssertEqual(offered(guiding: false, running: false, owner: true, leave: false), [])
    }

    func testTheTripAndTheOutingAreNeverTheSameAction() {
        for g in [true, false] { for o in [true, false] {
            let a = offered(guiding: g, owner: o)
            XCTAssertEqual(Set(a.map(EndControls.title)).count, a.count, "every choice has its own name")
            XCTAssertFalse(a.contains(.endTrip) && EndControls.isDestructive(.endTrip))
        } }
    }

    func testCopyNamesWhatHappens() {
        XCTAssertEqual(EndControls.title(.endTrip), "إنهاء الرحلة")
        XCTAssertTrue(EndControls.sentence(.endTrip, guiding: true).contains("جوالك فقط"))
        XCTAssertTrue(EndControls.sentence(.endTrip, guiding: true).contains("الطلعة"), "says the outing goes on")
        XCTAssertTrue(EndControls.sentence(.endOutingForAll, guiding: true).contains("كل الأصدقاء"))
        XCTAssertTrue(EndControls.sentence(.leaveOnly, guiding: true).contains("مشاركة موقعك"))
        XCTAssertFalse(EndControls.sentence(.endOutingForAll, guiding: false).contains("التوجيه"))
    }
}

/// Owner's Build 44 report: «خلال الطلعة لا يمكنني الضغط على الطبقات». With the sheet raised the side column vanished.
final class SideColumnDetentTests: XCTestCase {
    private let items = [SaryMapControlItem.layers(), .init(id: "locate", systemImage: "scope", label: "موقعي", accessibilityID: "outing-locate")]

    func testPeekKeepsEverythingHalfKeepsTheLayersButtonFullNothing() {
        XCTAssertEqual(LiveCalmRules.sideItems(items, detent: .peek).map(\.id), ["layers", "locate"])
        XCTAssertEqual(LiveCalmRules.sideItems(items, detent: .half).map(\.id), ["layers"], "the layers button is still there with the sheet half open")
        XCTAssertTrue(LiveCalmRules.sideItems(items, detent: .full).isEmpty)
    }
}
