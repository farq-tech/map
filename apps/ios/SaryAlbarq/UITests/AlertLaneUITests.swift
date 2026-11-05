import XCTest

/// A burst (stuck + convoy + silence + weather) shows ONE card (the highest priority);
/// the rest wait on the header's bell, which opens the whole queue and folds it back.
/// Set SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS for xcodebuild) to also write PNGs there.
final class AlertLaneUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

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

    func testBurstShowsOneCardAndTheBellOpensTheQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoConvoy", "-demoSilent", "-SarySafety", "stuck-friend",
                               "-SaryWeatherDemo", "rain", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0", "-SaryContext", "stopped"]
        app.launch()
        app.allowLocationIfAsked()
        let bell = app.buttons["alerts.bell"]
        XCTAssertTrue(bell.waitForExistence(timeout: 45), "the bell counts the queued alerts")
        XCTAssertTrue(bell.label.contains("تنبيه"), bell.label)
        /* One card on screen: the stuck friend outranks silence, convoy and weather. */
        XCTAssertTrue(app.buttons["جاي"].waitForExistence(timeout: 5), "the stuck card (highest priority) is the one shown")
        XCTAssertFalse(app.descendants(matching: .any)["convoy-alert"].exists, "convoy waits on the bell")
        shot(app, "alerts-burst-folded")
        bell.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alerts.list"].waitForExistence(timeout: 5), "the queue opens under the header")
        sleep(1)
        shot(app, "alerts-burst-expanded")
        app.buttons["alerts.bell"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.descendants(matching: .any)["alerts.list"])
        waitForExpectations(timeout: 5)
    }

    func testDrivingKeepsLowPriorityOnTheBell() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "rain", "-SaryContext", "driving", "-SaryScheme", "light"]
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(app.descendants(matching: .any)["outing-ptt"].waitForExistence(timeout: 20))
        sleep(4)
        /* Weather is low priority: while driving it never takes the card. */
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'alert.weather.'")).firstMatch.exists, "no weather card while driving")
        XCTAssertFalse(app.buttons["outing-actions"].exists, "driving: no «+» on the map")
        XCTAssertFalse(app.buttons["outing-locate"].exists, "driving: no side column («تخفيف الزحمة» ١)")
    }
}
