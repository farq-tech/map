import XCTest

/// «السحاب الآن» card: a one-line strip by default; it can be expanded, hidden with a small restore
/// button, and brought back, and hiding it does not turn the layer off.
final class WeatherCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0",
                               "-SaryContext", "stopped", "-SaryExplore", "-SaryWeather", "clouds",
                               /* The timeline (scrubber) needs the frame list: fixed here, not fetched from the live API. */
                               "-SaryCloudFramesStub"] + extra
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

    func testStripByDefaultThenExpandHideAndRestore() {
        let app = launch()
        let strip = any(app, "weather.legend.strip")
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "the default is the thin strip")
        XCTAssertTrue(any(app, "weather.clouds.playpause").exists, "play/pause lives on the strip")
        XCTAssertFalse(any(app, "weather.clouds.scrubber").exists, "no big card by default")
        XCTAssertLessThan(strip.frame.height, 80, "one line, not a third of the screen")
        shot(app, "card-strip")

        any(app, "weather.legend.expand").tap()
        XCTAssertTrue(any(app, "weather.clouds.scrubber").waitForExistence(timeout: 5), "the full card has the timeline (frames are stubbed: no network needed)")
        XCTAssertTrue(any(app, "weather.legend.off").exists, "turning the layer off is its own, named button")
        shot(app, "card-expanded")

        any(app, "weather.legend.hide").tap()
        let restore = any(app, "weather.legend.restore")
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "hidden card leaves a small restore button")
        XCTAssertFalse(any(app, "weather.clouds.scrubber").exists)
        XCTAssertFalse(any(app, "weather.legend.strip").exists)
        XCTAssertTrue(restore.label.contains("الطبقة ما زالت فعّالة"), "the button says the layer is still on")
        shot(app, "card-hidden")

        restore.tap()
        XCTAssertTrue(any(app, "weather.legend.strip").waitForExistence(timeout: 5), "the card comes back as the strip")
        XCTAssertTrue(any(app, "weather.clouds.playpause").exists, "and the layer is still the clouds")
    }

    func testTurningTheLayerOffIsSeparateFromHidingTheCard() {
        let app = launch(["-SaryWeatherCard", "expanded"])
        XCTAssertTrue(any(app, "weather.legend.off").waitForExistence(timeout: 15))
        any(app, "weather.legend.off").tap()
        XCTAssertFalse(any(app, "weather.legend.restore").waitForExistence(timeout: 3), "layer off: no card, no restore button")
        XCTAssertFalse(any(app, "weather.legend.strip").exists)
    }
}
