import SwiftUI
import XCTest
@testable import SaryAlbarq

final class SaryFoundationsTests: XCTestCase {
    func testTypeRolesAndSizeBudget() {
        XCTAssertEqual(SaryType.allCases.count, 6)
        XCTAssertEqual(SaryType.display.weight, .heavy)
        XCTAssertEqual(SaryType.body.weight, .regular)
        XCTAssertTrue(SaryType.numeric.isNumeric)
        XCTAssertTrue(SaryType.withinBudget([.title, .body, .caption, .title, .body]))
        XCTAssertFalse(SaryType.withinBudget([.display, .title, .headline, .body]))
        // Ramp is descending display > title > headline > body > caption.
        let sizes = [SaryType.display, .title, .headline, .body, .caption].map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testDesignScaleAndRadii() {
        XCTAssertEqual(SarySpace.designScale.map(\.rawValue), [4, 8, 12, 16, 24])
        XCTAssertEqual([SaryRadius.control, SaryRadius.card, SaryRadius.bar, SaryRadius.sheet], [18, 24, 28, 30])
        XCTAssertEqual(SaryMetrics.primaryHeight, 58)
        XCTAssertGreaterThanOrEqual(SaryMetrics.secondaryHeight, SaryMetrics.minHit)
    }

    func testDarkTokensMatchDesignerPrompt() {
        let r = SaryPalette.dark().raw
        XCTAssertEqual(r.background, 0x1A1612)
        XCTAssertEqual(r.surface, 0x2B251F)
        XCTAssertEqual(r.textPrimary, 0xF4EFE6)
        XCTAssertEqual(r.textSecondary, 0xB9AE9C)
        XCTAssertEqual(r.accentText, 0xE8842C)
        XCTAssertGreaterThanOrEqual(SaryContrast.ratio(0x1A1612, 0xE8842C), 4.5) // on-Ember ink
    }

    func testNumericUsesArabicIndicDigitsAndDecimalMark() {
        XCTAssertEqual(SaryFormat.digits("24.5"), "٢٤٫٥")
    }
}
