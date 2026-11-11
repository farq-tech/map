import XCTest

/// «طريق الرجعة»: entering it from «المزيد» → «الطريق» and leaving it from its panel's «إنهاء»
/// (UI-AUDIT م3: one stop, no duplicate on the map or the quick row). Demo outing with a seeded trail.
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

    func testEnterFromMoreAndLeaveFromThePanelOnly() {
        let app = launch()
        /* «طريق الرجعة»: «المزيد» → «الطريق» (and by itself on the map after arrival / off the route). */
        XCTAssertFalse(app.buttons["trail.backtrack"].exists, "not in the quick row any more")
        XCTAssertTrue(app.openTool("trail.backtrack"), "«طريق الرجعة» in «المزيد»")
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5), "back-track panel")
        XCTAssertTrue(app.staticTexts["backtrack.title"].exists)
        XCTAssertTrue(app.buttons["backtrack.exit"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["map.trailStart"].waitForExistence(timeout: 5), "«نقطة البداية» on the map")
        /* While it runs its panel's «إنهاء» is the only stop: no map shortcut, no tile. */
        XCTAssertFalse(app.buttons["outing-backtrack"].exists, "no second stop on the map")
        sleep(2)
        attach(app, "backtrack")
        app.buttons["backtrack.exit"].tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5), "«أنهِ الرجعة» leaves back-track mode")
    }

    func testEnterFromTheRaisedSheet() {
        let app = launch()
        sleep(1)
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        /* The raised sheet keeps the quick row: «المزيد» → «طريق الرجعة». */
        XCTAssertTrue(app.openTool("trail.backtrack"), "«طريق الرجعة» from the raised sheet's «المزيد»")
        /* «أظهر مسارات العيال» moved to «الإعدادات» → «مساري» (UX simplification). */
        XCTAssertFalse(app.descendants(matching: .any)["trail.friends"].exists, "not stacked in the sheet any more")
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5), "back-track from the sheet")
        attach(app, "trail-card")
        app.buttons["backtrack.exit"].tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    }
}
