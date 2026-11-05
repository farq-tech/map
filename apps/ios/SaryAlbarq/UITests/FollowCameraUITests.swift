import XCTest

/// «تتبعني» / «باتجاهي»: the camera button cycles; starting guidance turns «باتجاهي» on by
/// itself; a pan drops it and offers «رجّعني للتوجيه», whose tap brings it back.
/// The simulator's location is set from outside (`xcrun simctl location <udid> set 24.7113,46.6744`).
/// SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) also writes PNGs there.
final class FollowCameraUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScheme", "dark", "-SaryNight", "0"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func mode(_ app: XCUIApplication) -> String { (el(app, "outing-locate").value as? String) ?? "" }

    private func waitMode(_ app: XCUIApplication, _ m: String, timeout: TimeInterval = 8) -> Bool {
        let p = NSPredicate(format: "value == %@", m)
        return XCTWaiter.wait(for: [expectation(for: p, evaluatedWith: el(app, "outing-locate"))], timeout: timeout) == .completed
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func pan(_ app: XCUIApplication) {
        let map = el(app, "outing.map")
        let a = map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let b = map.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.62))
        a.press(forDuration: 0.05, thenDragTo: b)
    }

    func testButtonCyclesFollowHeadingFree() {
        let app = launch(["-SaryDrive", "1"])
        let b = el(app, "outing-locate")
        XCTAssertTrue(b.waitForExistence(timeout: 10))
        XCTAssertEqual(mode(app), "free")
        XCTAssertGreaterThanOrEqual(b.frame.width, 54, "big enough to hit while driving")
        b.tap()
        XCTAssertTrue(waitMode(app, "north"), "«تتبعني»")
        XCTAssertEqual(b.label, "تتبعني")
        sleep(2)
        shot(app, "follow-1-north")
        b.tap()
        XCTAssertTrue(waitMode(app, "heading"), "«باتجاهي»")
        XCTAssertEqual(b.label, "باتجاهي")
        sleep(2)
        shot(app, "follow-2-heading")
        b.tap()
        XCTAssertTrue(waitMode(app, "free"))
        XCTAssertEqual(b.label, "موقعي")
    }

    func testGuidanceStartsHeadingUpAndPanOffersRecenter() {
        let app = launch(["-SaryDrive", "1", "-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavStart"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 20), "guidance on")
        XCTAssertTrue(waitMode(app, "heading"), "«باتجاهي» by itself when guidance starts")
        sleep(2)
        shot(app, "follow-3-guidance-heading")

        pan(app)
        let pill = el(app, "camera.recenter")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "«رجّعني للتوجيه» after a pan")
        XCTAssertEqual(pill.label, "رجّعني للتوجيه")
        XCTAssertEqual(mode(app), "free")
        XCTAssertGreaterThanOrEqual(pill.frame.height, 54)
        sleep(1)
        shot(app, "follow-4-recenter-pill")

        pill.tap()
        XCTAssertTrue(waitMode(app, "heading"), "back to «باتجاهي»")
        XCTAssertFalse(pill.waitForExistence(timeout: 1.5) && pill.isHittable, "the pill goes away")
        sleep(2)
        shot(app, "follow-5-recentered")
    }

    func testOverviewThenBackToHeading() {
        let app = launch(["-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavStart"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 20))
        XCTAssertTrue(waitMode(app, "heading"))
        el(app, "nav.overview").tap()
        XCTAssertTrue(waitMode(app, "free"))
        XCTAssertTrue(el(app, "camera.recenter").waitForExistence(timeout: 5), "the pill brings guidance back from the overview too")
        sleep(2)
        shot(app, "follow-6-overview")
        el(app, "outing-locate").tap()
        XCTAssertTrue(waitMode(app, "heading"))
    }
}
