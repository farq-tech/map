import XCTest

/// «طريق العودة»: entering and leaving back-track mode from the control cluster
/// and from the sheet's «مساري» card (demo outing with a seeded trail).
final class BackTrackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-demoTrail"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 15))
        // Tap the status bar, not the map centre: a demo car sits there and would open its card.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func panel(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["backtrack.panel"] }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testEnterAndLeaveFromTheControlCluster() {
        let app = launch()
        let button = app.buttons["outing-backtrack"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "«طريق العودة» is in the control cluster")
        XCTAssertFalse(panel(app).exists)
        button.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5), "back-track panel")
        XCTAssertTrue(app.staticTexts["backtrack.title"].exists)
        XCTAssertTrue(app.buttons["backtrack.exit"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["map.trailStart"].waitForExistence(timeout: 5), "«نقطة البداية» on the map")
        sleep(2)
        attach(app, "backtrack")
        app.buttons["backtrack.exit"].tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5), "«إنهاء» leaves back-track mode")
        /* The cluster button toggles too. */
        button.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    }

    func testEnterFromTheSheetsTrailCard() {
        let app = launch()
        sleep(1)
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let start = app.buttons["trail.backtrack"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "«مساري» card in the sheet")
        if !start.isHittable { app.descendants(matching: .any)["outing-sheet-summary"].swipeUp() }
        XCTAssertTrue(app.switches["trail.friends"].exists || app.descendants(matching: .any)["trail.friends"].exists, "«أظهر مسارات الأصحاب»")
        attach(app, "trail-card")
        start.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5), "back-track from the sheet")
        app.buttons["backtrack.exit"].tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    }
}
