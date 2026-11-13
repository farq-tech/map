import XCTest

final class ComponentsUITests: XCTestCase {
    private func launch(page: String = "all", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-SaryComponents", "-SaryComponentsPage", page, "-AppleLanguages", "(ar)"] + extra
        app.launch()
        return app
    }

    func testHeaderPrimaryAndSecondaryHitAreas() {
        let app = launch(page: "header")
        XCTAssertTrue(app.buttons["components-primary"].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.buttons["components-primary"].frame.height, 57.9)
        let close = app.buttons["window-close"]
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertLessThan(close.frame.midX, app.staticTexts["طلعاتي"].frame.midX, "✕ on the left, title on the right")
        XCTAssertGreaterThanOrEqual(app.buttons["components-secondary"].frame.height, 44)
        app.buttons["components-primary"].tap()
        XCTAssertTrue(app.staticTexts["taps 1"].waitForExistence(timeout: 3))
    }

    func testEmptyAndErrorStatesHaveOneSentenceAndAButton() {
        let app = launch(page: "states")
        XCTAssertTrue(app.buttons["components-empty-action"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["ما عندك طلعات للحين، سوّ أول طلعة"].exists)
        XCTAssertTrue(app.buttons["components-error-action"].exists)
        app.buttons["components-empty-action"].tap()
        XCTAssertTrue(app.staticTexts["taps 1"].waitForExistence(timeout: 3))
    }

    func testSkeletonListReplacesSpinner() {
        let app = launch(page: "loading")
        XCTAssertTrue(app.otherElements["skeleton-list"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.activityIndicators.count, 0)
    }

    func testListRowsAreEqualHeightAndTappable() {
        let app = launch(page: "list")
        let r1 = app.buttons["components-row-1"], r3 = app.buttons["components-row-3"]
        XCTAssertTrue(r1.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(r1.frame.height, 55.9)
        XCTAssertGreaterThanOrEqual(r3.frame.height, 55.9)
        r1.tap()
        XCTAssertTrue(app.staticTexts["taps 1"].waitForExistence(timeout: 3))
        // The long name stays on one line (shrinks) and the row stays on screen.
        let r2 = app.buttons["components-row-2"]
        XCTAssertTrue(r2.exists)
        XCTAssertLessThanOrEqual(r2.frame.maxX, app.frame.maxX + 1)
    }

    func testChipSelectionAndAvatarStack() {
        let app = launch(page: "chips")
        let c2 = app.buttons["components-chip-2"]
        XCTAssertTrue(c2.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(c2.frame.height, 44)
        c2.tap()
        XCTAssertTrue(c2.isSelected)
        XCTAssertTrue(app.otherElements["avatar-stack"].exists)
    }

    func testLargestTextStillShowsEverything() {
        let app = launch(page: "states", extra: ["-SaryComponentsType", "AX3"])
        XCTAssertTrue(app.buttons["components-empty-action"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["components-primary"].exists)
    }
}
