import XCTest

/// Build 10 «اسلك هذا المسار»: the button on the trip summary and the track detail, follow
/// mode entry / reverse / exit (stand-alone and in the live outing). With SARY_SHOT_DIR set,
/// saves screenshots there.
final class TrackFollowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func allowLocation(_ app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SARY_SHOT_DIR"], !dir.isEmpty else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testSummaryButtonReachableAndFollowEntryExit() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", "summary"]
        allowLocation(app)
        app.launch()
        let follow = app.buttons["track.follow"]
        for _ in 0..<6 where !(follow.exists && follow.isHittable) { app.swipeUp() }
        XCTAssertTrue(follow.waitForExistence(timeout: 15), "«اسلك هذا المسار» on the trip summary")
        XCTAssertTrue(any(app, "track.stat.distance").exists)
        XCTAssertTrue(any(app, "track.stat.maxSpeed").exists)
        XCTAssertTrue(any(app, "track.stat.moving").exists)
        sleep(3)
        shot("summary-card")
        follow.tap()
        XCTAssertTrue(any(app, "follow.panel").waitForExistence(timeout: 8), "follow mode")
        XCTAssertTrue(app.buttons["follow.exit"].exists)
        let reverse = app.buttons["follow.reverse"]
        XCTAssertTrue(reverse.exists, "«اعكس الاتجاه»")
        reverse.tap()
        XCTAssertTrue(any(app, "follow.panel").exists)
        app.buttons["follow.exit"].tap()
        XCTAssertTrue(any(app, "follow.panel").waitForNonExistence(timeout: 5), "«أوقف التتبع» leaves follow mode")
        XCTAssertTrue(follow.waitForExistence(timeout: 5), "back on the summary")
    }

    func testTrackDetailFromSummary() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", "summary"]
        allowLocation(app)
        app.launch()
        let open = app.buttons["summary.trackOpen"]
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        XCTAssertTrue(any(app, "track.detail").waitForExistence(timeout: 8))
        /* The summary's own button is still under the cover: the detail's is the last one. */
        let follow = any(app, "track.detail").buttons["track.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        sleep(4)
        shot("track-detail")
        follow.tap()
        XCTAssertTrue(any(app, "follow.panel").waitForExistence(timeout: 8))
        app.buttons["follow.exit"].tap()
        XCTAssertTrue(any(app, "follow.panel").waitForNonExistence(timeout: 5))
    }

    func testLiveFollowEntryAndExit() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0", "-SaryFollow", "3"]
        allowLocation(app)
        app.launch()
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        let panel = any(app, "follow.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 12), "follow mode on the live map")
        XCTAssertTrue(app.buttons["follow.exit"].waitForExistence(timeout: 5))
        sleep(3)
        shot("live-follow")
        app.buttons["follow.exit"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }
}
