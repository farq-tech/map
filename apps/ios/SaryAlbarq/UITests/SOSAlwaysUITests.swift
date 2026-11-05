import XCTest

/// QA build 15: SOS never disappears — over the full-height sheet and over any sheet on top.
final class SOSAlwaysUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testSOSStaysReachableOverTheFullSheetAndOverASheetOnTop() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        XCTAssertTrue(any(app, "outing-sos").exists || app.buttons.matching(NSPredicate(format: "label CONTAINS 'طوارئ'")).firstMatch.exists, "SOS on the map")

        /* The sheet full height: the dock is covered, SOS floats above. */
        any(app, "outing-sheet-summary").tap()
        let sheet = any(app, "tab.more")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.swipeUp()
        let overlay = any(app, "sos.overlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 6), "SOS over the full sheet")
        XCTAssertTrue(overlay.isHittable)

        /* A sheet on top («+» the actions): still there. */
        app.swipeDown()
        if app.buttons["outing-actions"].waitForExistence(timeout: 5) { app.buttons["outing-actions"].tap() }
        XCTAssertTrue(any(app, "outing-actions-sheet").waitForExistence(timeout: 6))
        XCTAssertTrue(overlay.waitForExistence(timeout: 4) && overlay.isHittable, "SOS over a sheet on top")
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "sos-over-sheet"
        a.lifetime = .keepAlways
        add(a)
    }
}
