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
        let overlay = any(app, "sos.overlay")
        /* Drag the sheet by its top row all the way up (full height). */
        for _ in 0..<3 where !overlay.exists {
            let top = any(app, "outing-sheet-summary").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
            _ = overlay.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(overlay.waitForExistence(timeout: 6), "SOS over the full sheet")
        assertOnScreen(app, overlay)

        /* A sheet on top («+» the actions): still there. */
        let summary = any(app, "outing-sheet-summary").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        summary.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        if app.buttons["outing-actions"].waitForExistence(timeout: 5) { app.buttons["outing-actions"].tap() }
        XCTAssertTrue(any(app, "outing-actions-sheet").waitForExistence(timeout: 6))
        XCTAssertTrue(overlay.waitForExistence(timeout: 4), "SOS over a sheet on top")
        assertOnScreen(app, overlay)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "sos-over-sheet"
        a.lifetime = .keepAlways
        add(a)
    }

    /// UX ٢١: a held SOS waits 3 s with «تراجع» (cancel sends nothing); stopping a sent SOS asks first.
    func testSOSCountdownCanBeUndoneAndImOKAsksFirst() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0", "-SaryContext", "stopped"]
        app.launch()
        let intro = app.descendants(matching: .any)["intro"]
        if intro.waitForExistence(timeout: 3) { _ = intro.waitForNonExistence(timeout: 20) }
        let sos = any(app, "outing-sos")
        XCTAssertTrue(sos.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["اضغط مطوّل"].exists, "the caption says hold, not «اضغط ثانية»")

        /* Hold → countdown → «تراجع»: nothing is sent. */
        sos.press(forDuration: 1.6)
        let cancel = any(app, "sos-countdown-cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "«تراجع» after the hold")
        XCTAssertTrue(any(app, "sos-countdown-seconds").exists)
        cancel.tap()
        XCTAssertTrue(any(app, "sos-countdown").waitForNonExistence(timeout: 3))
        XCTAssertFalse(any(app, "outing-sos-ok").waitForExistence(timeout: 4), "undone: no SOS went out")

        /* Hold → let the 3 s run out → sent. */
        sos.press(forDuration: 1.6)
        XCTAssertTrue(any(app, "sos-countdown").waitForExistence(timeout: 3))
        let ok = any(app, "outing-sos-ok")
        XCTAssertTrue(ok.waitForExistence(timeout: 8), "sent after the countdown")

        /* «أنا بخير» asks first; «لا، خلها» keeps it. */
        ok.tap()
        let keep = any(app, "sos-stop-no")
        XCTAssertTrue(keep.waitForExistence(timeout: 3), "a confirmation before stopping the SOS")
        keep.tap()
        XCTAssertTrue(ok.waitForExistence(timeout: 2), "still active")
        ok.tap()
        any(app, "sos-stop-yes").tap()
        XCTAssertTrue(ok.waitForNonExistence(timeout: 5), "stopped after the confirmation")
    }

    /// Big enough and fully on screen, bottom left: over a full sheet it must not cover the sheet's
    /// search field or first rows (QA #111 screenshot).
    /// (Not `isHittable`: XCUITest's hit test does not look into the app's extra overlay window.)
    private func assertOnScreen(_ app: XCUIApplication, _ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let f = e.frame, screen = app.frame
        XCTAssertGreaterThanOrEqual(f.width, 60, "a big target", file: file, line: line)
        XCTAssertTrue(screen.contains(f), "fully on screen: \(f)", file: file, line: line)
        XCTAssertLessThan(f.midX, screen.midX, "on the left, like the map's SOS", file: file, line: line)
        XCTAssertGreaterThan(f.midY, screen.height * 0.75, "in the bottom corner, clear of the sheet's search field", file: file, line: line)
    }
}
