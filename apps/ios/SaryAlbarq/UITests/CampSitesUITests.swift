import XCTest

/// «اقترح لي مكان كشتة» and the «أماكن مقترحة للكشتة» layer toggle in map layers.
/// Tonight's wind is injected (`-SaryCampNight`) and the position is Riyadh (`-SaryCampFrom`),
/// so the test does not depend on the network or the simulator's GPS.
final class CampSitesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String], from: String = "24.7113,46.6744") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0", "-SaryContext", "stopped",
                               "-SaryCampFrom", from] + extra
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
        let app = launch(["-SaryCampNight", "0,40", "-SaryExplore", "-SaryLiveModal", "layers"])
        let layers = app.descendants(matching: .any)["explore.layers.sheet"]
        XCTAssertTrue(layers.waitForExistence(timeout: 20))
        let suggest = app.buttons["explore-camp-suggest"].firstMatch
        suggest.scrollIntoView(in: app, margin: 120)
        XCTAssertTrue(suggest.waitForExistence(timeout: 5), "the action is in map layers")
        suggest.tap()
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
        XCTAssertTrue(app.buttons["explore-desert-route"].firstMatch.waitForExistence(timeout: 5),
                      "route planning is accessible from map layers")
        let suggest = app.buttons["explore-camp-suggest"].firstMatch
        suggest.scrollIntoView(in: app, margin: 120)
        XCTAssertTrue(suggest.waitForExistence(timeout: 5))
        suggest.tap()
        XCTAssertTrue(app.descendants(matching: .any)["camp.sheet"].waitForExistence(timeout: 10))
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Every card carries a geographic name or the plain «موقع كشتة»; never «جلسة N».
    func testCardsAreNamedNotJalsa() {
        let app = launch(["-SaryCampNight", "0,20", "-SaryExplore", "-SaryLiveModal", "camp"])
        XCTAssertTrue(app.descendants(matching: .any)["camp.card.5"].waitForExistence(timeout: 20))
        sleep(2)
        for i in 1...5 {
            let t = app.staticTexts["camp.title.\(i)"]
            XCTAssertTrue(t.exists, "title \(i)")
            XCTAssertFalse(t.label.contains("جلسة"), t.label)
            XCTAssertFalse(app.staticTexts["camp.reasons.\(i)"].label.contains("محمية"))
        }
        attach("camp-names-riyadh")
    }

    /// Nafud: every bundled site is inside a royal reserve, so nothing is suggested and the empty state says why.
    func testOnlyProtectedAreasShowsTheReserveEmptyState() {
        let app = launch(["-SaryCampNight", "0,20", "-SaryExplore", "-SaryLiveModal", "camp"], from: "28.54,41.45")
        let empty = app.descendants(matching: .any)["camp.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["كل الأماكن القريبة داخل محميات"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["camp.card.1"].exists)
        attach("camp-only-protected")
    }

    /// «ما لقينا درب آمن»: the destination keeps its name and no «مسار مقترح» line is shown.
    func testNoSafeRouteHidesTheSatelliteRouteNote() {
        let app = launch(["-SaryLiveModal", "routes", "-SaryRouteTo", "25.23,46.74", "-SaryRouteName", "روضة نورة",
                          "-SaryRouteFrom", "24.7113,46.6744", "-SaryRouteForceNone"])
        XCTAssertTrue(app.descendants(matching: .any)["routes.none"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["إلى روضة نورة"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["routes.note"].exists)
        attach("routes-none")
    }
}
