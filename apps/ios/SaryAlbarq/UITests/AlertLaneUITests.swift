import XCTest

/// A burst (stuck + convoy + silence + weather) shows at most 2 cards; «+N تنبيهات» expands and folds back.
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

    func testBurstFoldsAndExpands() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoConvoy", "-demoSilent", "-SarySafety", "stuck-friend",
                               "-SaryWeatherDemo", "rain", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0"]
        app.launch()
        let more = app.buttons["alerts.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the overflow pill shows")
        XCTAssertTrue(more.label.contains("تنبيه"), more.label)
        shot(app, "alerts-burst-folded")
        more.tap()
        let hide = app.buttons.matching(NSPredicate(format: "identifier == 'alerts.more' AND label CONTAINS 'إخفاء'")).firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "expanded: «إخفاء»")
        sleep(1)
        shot(app, "alerts-burst-expanded")
        hide.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'alerts.more' AND label CONTAINS 'اعرضها'")).firstMatch.waitForExistence(timeout: 5))
    }
}
