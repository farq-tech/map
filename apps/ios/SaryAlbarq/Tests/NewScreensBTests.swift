import XCTest
@testable import SaryAlbarq

/// Build 47 • screens group B rules that do not need the UI.
final class NewScreensBTests: XCTestCase {
    func testOnlyTheFirstCampSuggestionHasThePrimaryGoInTheNewUI() {
        XCTAssertTrue(NewScreens.campGoIsPrimary(rank: 1, newUI: true))
        XCTAssertFalse(NewScreens.campGoIsPrimary(rank: 2, newUI: true))
        XCTAssertFalse(NewScreens.campGoIsPrimary(rank: 5, newUI: true))
        XCTAssertTrue(NewScreens.campGoIsPrimary(rank: 3, newUI: false), "the legacy UI keeps every «اتجه» primary")
    }

    func testRowsShareTheDesignerHeightOnlyWhenTheNewUIIsOn() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: NewUI.key)
        defer { if let old { defaults.set(old, forKey: NewUI.key) } else { defaults.removeObject(forKey: NewUI.key) } }
        defaults.set(true, forKey: NewUI.key)
        XCTAssertEqual(NewScreens.rowMinHeight(legacy: 43), SaryMetrics.rowHeight)
        defaults.set(false, forKey: NewUI.key)
        XCTAssertEqual(NewScreens.rowMinHeight(legacy: 43), 43)
    }
}
