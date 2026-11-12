import XCTest

/// W-1: the map has ONE weather chip; the layer controls (play, scrubber, direction, rain period, off) are
/// in the weather page it opens. The old floating card is still covered behind `-SaryLegacyWeatherCard`.
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

    /// The page is one long scroll: bring a control into reach in short steps.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let el = any(app, id)
        _ = el.waitForExistence(timeout: 10)
        let page = any(app, "weather.sheet").scrollViews.firstMatch
        for _ in 0..<10 where !el.isHittable { page.swipeUp(velocity: .slow) }
        return el
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

    func testLegacyStripByDefaultThenExpandHideAndRestore() {
        let app = launch(["-SaryLegacyWeatherCard"])
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

    func testLegacyTurningTheLayerOffIsSeparateFromHidingTheCard() {
        let app = launch(["-SaryLegacyWeatherCard", "-SaryWeatherCard", "expanded"])
        XCTAssertTrue(any(app, "weather.legend.off").waitForExistence(timeout: 15))
        any(app, "weather.legend.off").tap()
        XCTAssertFalse(any(app, "weather.legend.restore").waitForExistence(timeout: 3), "layer off: no card, no restore button")
        XCTAssertFalse(any(app, "weather.legend.strip").exists)
    }

    func testOneChipOnTheMapAndNoFloatingCard() {
        let app = launch()
        let chip = any(app, "weather.status.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the one weather chip")
        XCTAssertLessThan(chip.frame.height, 80)
        for id in ["weather.legend.strip", "weather.legend.expand", "weather.legend.hide", "weather.legend.restore", "weather.clouds.playpause", "weather.clouds.scrubber"] {
            XCTAssertFalse(any(app, id).exists, "\(id) is no longer on the map")
        }
        shot(app, "page-chip-only")
    }

    func testChipOpensThePageWithEverythingWeather() {
        let app = launch()
        any(app, "weather.status.chip").tap()
        XCTAssertTrue(any(app, "weather.sheet").waitForExistence(timeout: 10), "the chip opens the weather page")
        shot(app, "page-open-top")
        XCTAssertTrue(any(app, "weather.page.map").waitForExistence(timeout: 5), "the layers live in the page")
        XCTAssertTrue(reveal(app, "weather.layer.clouds").exists)
        XCTAssertTrue(any(app, "weather.layer.rain").exists)
        XCTAssertTrue(reveal(app, "weather.clouds.playpause").exists, "play / pause is in the page")
        XCTAssertTrue(reveal(app, "weather.clouds.scrubber").exists, "the time scrubber is in the page (frames are stubbed)")
        shot(app, "page-open-map")
    }

    func testRainPeriodAndLayerOffFromThePage() {
        let app = launch()
        any(app, "weather.status.chip").tap()
        let rain = reveal(app, "weather.layer.rain")
        XCTAssertTrue(rain.isHittable, "rain is reachable in the page")
        rain.tap()
        let week = app.buttons["weather.rain.days.7"].firstMatch
        XCTAssertTrue(week.waitForExistence(timeout: 5), "the rain period picker is in the page")
        week.tap()
        XCTAssertTrue(week.isSelected)
        reveal(app, "weather.layer.none").tap()
        let close = any(app, "weather.close")
        for _ in 0..<6 where !close.isHittable { any(app, "weather.sheet").scrollViews.firstMatch.swipeDown() }
        close.tap()
        XCTAssertFalse(any(app, "weather.status.chip").waitForExistence(timeout: 3), "layer off: the chip goes away")
    }
}
