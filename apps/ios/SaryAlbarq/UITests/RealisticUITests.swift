import XCTest

/// «الوضع الواقعي» (Apple MapKit realistic 3D imagery): in and out from exploration and the
/// point card, «طيران درون» stops on touch, and «يحتاج إنترنت» offline.
final class RealisticUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], live: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        let base = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0"]
        app.launchArguments = base + (live ? ["-SaryContext", "stopped"] : []) + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        if live {
            XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 20))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        }
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

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

    private func openFromExploration(_ app: XCUIApplication) {
        let enter = app.buttons["trip.explore"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.tap()
        let entry = app.buttons["explore-realistic"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "«الوضع الواقعي» in exploration's controls")
        entry.tap()
        XCTAssertTrue(any(app, "realistic.screen").waitForExistence(timeout: 8))
    }

    func testEnterAndExitFromExploration() {
        let app = launch()
        openFromExploration(app)
        XCTAssertTrue(any(app, "realistic.header").exists)
        XCTAssertTrue(app.buttons["realistic-drone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["realistic-tilt"].exists)
        XCTAssertTrue(app.buttons["realistic-labels"].exists)
        /* Apple's attribution is MapKit's own and must be on screen. */
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Legal' OR label CONTAINS 'قانوني' OR label CONTAINS[c] 'Apple Maps' OR identifier CONTAINS[c] 'legal'")).firstMatch.waitForExistence(timeout: 10),
                      "MapKit «Legal» visible")
        sleep(6)
        shot(app, "realistic-explore")
        app.buttons["realistic-close"].tap()
        XCTAssertTrue(any(app, "explore.header").waitForExistence(timeout: 5), "back in exploration, where it started")
        XCTAssertFalse(any(app, "realistic.screen").exists)
    }

    func testDroneStopsOnTouch() {
        let app = launch()
        openFromExploration(app)
        let drone = app.buttons["realistic-drone"]
        XCTAssertTrue(drone.waitForExistence(timeout: 5))
        XCTAssertEqual(drone.value as? String, "متوقف")
        drone.tap()
        XCTAssertTrue(NSPredicate(format: "value == 'يطير'").evaluate(with: drone), "flying")
        sleep(4)
        shot(app, "realistic-drone-flying")
        /* A touch on the map ends the flight. */
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.62)).tap()
        let stopped = expectation(for: NSPredicate(format: "value == 'متوقف'"), evaluatedWith: drone)
        wait(for: [stopped], timeout: 5)
        /* And «طيران درون» again, stopped by its own button. */
        drone.tap()
        XCTAssertEqual(drone.value as? String, "يطير")
        drone.tap()
        XCTAssertEqual(drone.value as? String, "متوقف")
    }

    func testOfflineSaysItNeedsInternet() {
        let app = launch(["-SaryOffline"])
        openFromExploration(app)
        let blocked = any(app, "realistic.blocked")
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        XCTAssertTrue(blocked.label.contains("يحتاج إنترنت"))
        XCTAssertFalse(app.buttons["realistic-drone"].exists, "no map, no drone, offline")
        shot(app, "realistic-offline")
        app.buttons["realistic-back"].tap()
        XCTAssertTrue(any(app, "explore.header").waitForExistence(timeout: 5))
    }

    func testFromThePointCard() {
        let app = launch(["-demoPlanEmpty", "-SaryScreen", "plan-editor"], live: false)
        let search = app.buttons["plan.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("26.6625, 37.9545")
        let row = app.buttons["search.coordinate"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let entry = app.buttons["point.realistic"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "«الوضع الواقعي» on the point card")
        entry.tap()
        XCTAssertTrue(any(app, "realistic.screen").waitForExistence(timeout: 8))
        sleep(8)
        shot(app, "realistic-point-alula")
        app.buttons["realistic-close"].tap()
        XCTAssertTrue(app.buttons["point.realistic"].waitForExistence(timeout: 5), "back on the card")
    }

    func testFromTrackDetail() {
        let app = launch(["-SaryScreen", "track-detail"], live: false)
        let entry = app.buttons["track.realistic"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "«الوضع الواقعي» on the track detail (trip summary)")
        entry.tap()
        XCTAssertTrue(any(app, "realistic.screen").waitForExistence(timeout: 8))
        sleep(9)
        shot(app, "realistic-track-dunes")
        app.buttons["realistic-close"].tap()
        XCTAssertTrue(any(app, "track.detail").waitForExistence(timeout: 5))
    }

    func testFromSavedPlaces() {
        let app = launch(["-SaryExplore"])
        let save = app.buttons["explore-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let name = any(app, "placeEdit.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("المخيم")
        any(app, "placeEdit.save").tap()
        app.buttons["explore-places"].tap()
        let entry = app.buttons["places.realistic"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "«الوضع الواقعي» on a saved place")
        entry.tap()
        XCTAssertTrue(any(app, "realistic.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(any(app, "realistic.header").label.contains("المخيم"))
        app.buttons["realistic-close"].tap()
        XCTAssertTrue(any(app, "places.sheet").waitForExistence(timeout: 5), "back on the list")
    }
}
