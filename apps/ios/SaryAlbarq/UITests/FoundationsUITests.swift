import XCTest

final class FoundationsUITests: XCTestCase {
    func testFoundationComponentsAreReachableAndLargeEnough() {
        let app = XCUIApplication()
        app.launchArguments += ["-SaryFoundations", "-AppleLanguages", "(ar)"]
        app.launch()
        XCTAssertTrue(app.otherElements["foundations-root"].waitForExistence(timeout: 20) || app.scrollViews["foundations-root"].exists)
        let primary = app.buttons["foundations-primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(primary.frame.height, 57.9)
        let close = app.buttons["window-close"]
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        // ✕ sits on the left, the title on the right (RTL).
        let title = app.staticTexts["طلعاتي"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(close.frame.midX, title.frame.midX)
        primary.tap()
        XCTAssertTrue(app.staticTexts["taps 1"].waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(app.buttons["foundations-secondary"].frame.height, 44)
    }
}
