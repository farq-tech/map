import XCTest

/// «اقترح لي مكان كشتة» from «أدوات الطلعة», and the «أماكن مقترحة للكشتة» layer toggle.
/// Tonight's wind is injected (`-SaryCampNight`) and the position is Riyadh (`-SaryCampFrom`),
/// so the test does not depend on the network or the simulator's GPS.
final class CampSitesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0", "-SaryContext", "stopped",
                               "-SaryCampFrom", "24.7113,46.6744"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    func testSuggestTopFiveWithWindReasonsAndGo() {
        let app = launch(["-SaryCampNight", "0,40"])
        XCTAssertTrue(app.openTool("outing-camp-suggest", timeout: 20), "the tile is in «أدوات»")
        let sheet = app.descendants(matching: .any)["camp.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        /* 40 km/h gusts: the sheltered places first, with the warning. */
        XCTAssertTrue(app.descendants(matching: .any)["camp.windWarning"].waitForExistence(timeout: 5))
        let first = app.descendants(matching: .any)["camp.card.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "a first suggestion within 100 km of Riyadh")
        XCTAssertTrue(app.descendants(matching: .any)["camp.card.5"].waitForExistence(timeout: 5), "five suggestions")
        let wind = app.staticTexts["camp.wind.1"]
        XCTAssertTrue(wind.exists)
        XCTAssertTrue(wind.label.contains("الريح الليلة: شمالية"), wind.label)
        XCTAssertFalse(app.staticTexts["camp.reasons.1"].label.isEmpty)
        /* A smaller radius: nothing that close to the city. */
        app.buttons["camp.radius.25"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["camp.empty"].waitForExistence(timeout: 5))
        app.buttons["camp.radius.100"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let note = app.descendants(matching: .any)["camp.estimateNote"]
        note.scrollIntoView(in: app)
        XCTAssertTrue(note.label.contains("تقدير من صور الأقمار، تأكد بعينك"), note.label)
        /* «اتجه»: our own guidance opens (route options or the GPS wait), the sheet closes. */
        app.swipeDown()
        let go = app.buttons["camp.go.1"]
        go.scrollIntoView(in: app)
        if !go.isHittable { app.swipeDown(); app.swipeDown() }
        go.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 6), "the suggestions close for the guidance")
    }

    func testMissingForecastShowsTheSafetyFallback() {
        let app = launch(["-SaryLiveModal", "camp", "-SaryCampWeatherOff"])
        let sheet = app.descendants(matching: .any)["camp.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        let warning = app.descendants(matching: .any)["camp.noWeather"]
        XCTAssertTrue(warning.waitForExistence(timeout: 8))
        XCTAssertTrue(warning.label.contains("الأودية"), warning.label)
        XCTAssertTrue(app.descendants(matching: .any)["camp.card.1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["camp.wind.1"].exists, "no guessed wind direction or speed")
    }

    func testLayerToggleInLayers() {
        let app = launch(["-SaryExplore", "-SaryLiveModal", "layers"])
        let layers = app.descendants(matching: .any)["explore.layers.sheet"]
        XCTAssertTrue(layers.waitForExistence(timeout: 20))
        sleep(2)
        let sw = app.switches["explore-camp-sites"].firstMatch
        XCTAssertTrue(sw.waitForExistence(timeout: 5))
        sw.scrollIntoView(in: app, margin: 120)
        let before = sw.value as? String
        XCTAssertTrue(sw.flipSwitch(), "«أماكن مقترحة للكشتة» flips")
        XCTAssertNotEqual(sw.value as? String, before)
        XCTAssertTrue(sw.flipSwitch(), "and back")
    }
}
