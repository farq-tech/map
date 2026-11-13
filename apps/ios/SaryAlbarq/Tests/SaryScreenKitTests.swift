import XCTest
@testable import SaryAlbarq

final class SaryScreenKitTests: XCTestCase {
    func testRowsAreAtLeastTheTouchTargetAndShareOneHeight() {
        XCTAssertGreaterThanOrEqual(SaryMetrics.rowHeight, SaryMetrics.minHit)
        XCTAssertEqual(SaryMetrics.rowHeight, 56)
    }

    func testDisclosureChevronIsTheDirectionalSymbol() {
        // `chevron.forward` mirrors with the layout direction: it points left in Arabic.
        XCTAssertEqual(SaryIcon.disclosure, "chevron.forward")
    }

    func testAvatarStackOverflow() {
        XCTAssertEqual(SaryAvatarStack.overflow(count: 2, maxShown: 3), 0)
        XCTAssertEqual(SaryAvatarStack.overflow(count: 3, maxShown: 3), 0)
        XCTAssertEqual(SaryAvatarStack.overflow(count: 5, maxShown: 3), 2)
        XCTAssertEqual(SaryAvatarStack.overflow(count: 5, maxShown: -1), 5)
    }

    func testStateKindsAreDistinct() {
        XCTAssertNotEqual(SaryScreenStateKind.empty, SaryScreenStateKind.error)
    }

    func testScreenTypeRolesStayWithinTheThreeSizeBudget() {
        // The kit uses headline (titles, state message), caption (secondary, chips, pills) and title (header).
        XCTAssertTrue(SaryType.withinBudget([.title, .headline, .caption]))
    }
}
