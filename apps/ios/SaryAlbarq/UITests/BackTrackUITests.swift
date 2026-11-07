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
        /* «طريق العودة»: in the sheet's quick row (and by itself on the map after arrival / off the route). */
        let button = app.buttons["trail.backtrack"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "«طريق الرجعة» in the quick row")
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
        /* Again from the row; while it runs, «طريق العودة» sits on the map by itself and toggles it off. */
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        let shortcut = app.buttons["outing-backtrack"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5), "the map shortcut while it runs")
        shortcut.tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    }

    func testEnterFromTheSheetsTrailCard() {
        let app = launch()
        sleep(1)
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let start = app.buttons["trail.backtrack"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "«طريق الرجعة» in the sheet")
        /* «مساري» sits below the trip card in «الرحلة», out of view at the sheet's middle height. Scroll it in
           ourselves and tap only once it stopped moving: XCUITest's own scroll-to-visible taps while the sheet
           is still decelerating, and a tap on a moving scroll view only stops it (the button never fires). */
        for _ in 0..<5 where !start.isHittable {
            /* A drag inside the sheet's lower part (below its middle-height top): grows the sheet, then scrolls it. */
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        var last = start.frame
        for _ in 0..<20 {
            usleep(250_000)
            if start.frame == last { break }
            last = start.frame
        }
        XCTAssertTrue(start.isHittable, "«طريق الرجعة» in the sheet's quick row, in view")
        /* «أظهر مسارات العيال» moved to «الإعدادات» → «مساري» (UX simplification). */
        XCTAssertFalse(app.descendants(matching: .any)["trail.friends"].exists, "not stacked in the sheet any more")
        attach(app, "trail-card")
        start.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5), "back-track from the sheet")
        app.buttons["backtrack.exit"].tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    }
}
