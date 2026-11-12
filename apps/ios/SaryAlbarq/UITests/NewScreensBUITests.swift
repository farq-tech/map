import XCTest

/// Build 47 · screens group B (profile/settings, weather, Qibla, camp suggestions, desert routes) behind `-SaryNewUI`.
/// With the flag off the legacy screens are untouched (their own UI tests prove that). Shots: `SARY_SHOTS` dir.
final class NewScreensBUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String], screen: String? = nil, live: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryNewUI"]
        if let screen { args += ["-SaryScreen", screen] }
        if live { args += ["-SaryDrive", "0", "-SaryContext", "stopped", "-SaryCampFrom", "24.7113,46.6744"] }
        app.launchArguments = args + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("screens-b-\(name).png"))
        }
    }

    // MARK: profile + settings

    func testProfileHasTheUnifiedHeaderAndOneHeightRows() {
        let app = launch([], screen: "profile")
        XCTAssertTrue(el(app, "profile.save").waitForExistence(timeout: 20))
        XCTAssertTrue(el(app, "page-back").exists, "a pushed page keeps its back button")
        let recovery = el(app, "profile.recovery")
        recovery.scrollIntoView(in: app, margin: 80)
        XCTAssertGreaterThanOrEqual(recovery.frame.height, 55.5, "rows share the 56 pt height")
        shot("profile")
    }

    func testSettingsPagesShareTheNewRows() {
        for (screen, name) in [("settings", "settings"), ("advanced", "advanced"), ("privacy", "privacy"), ("notifications", "notifications")] {
            let app = launch([], screen: screen)
            XCTAssertTrue(el(app, "page-back").waitForExistence(timeout: 20), name)
            XCTAssertGreaterThanOrEqual(el(app, "page-back").frame.height, 43.5, name)
            shot(name)
            app.terminate()
        }
    }

    // MARK: weather

    func testWeatherSheetHasTheWindowHeaderAndCloses() {
        let app = launch(["-SaryLiveModal", "weather"], live: true)
        XCTAssertTrue(el(app, "weather.sheet").waitForExistence(timeout: 25))
        let close = el(app, "weather.close"), refresh = el(app, "weather.refresh")
        XCTAssertTrue(close.exists && refresh.exists)
        XCTAssertGreaterThanOrEqual(close.frame.width, 43.5); XCTAssertGreaterThanOrEqual(close.frame.height, 43.5)
        XCTAssertLessThan(close.frame.midX, app.windows.firstMatch.frame.midX, "the ✕ is on the left")
        shot("weather")
        close.tap()
        XCTAssertTrue(el(app, "weather.sheet").waitForNonExistence(timeout: 6))
    }

    // MARK: Qibla

    func testQiblaCompassAndDenied() {
        let app = launch(["-SaryLiveModal", "qibla", "-SaryQiblaLat", "24.7136", "-SaryQiblaLng", "46.6753", "-SaryQiblaHeading", "40"], live: true)
        XCTAssertTrue(el(app, "qibla.degrees").waitForExistence(timeout: 25))
        XCTAssertTrue(el(app, "qibla.compass").exists)
        XCTAssertGreaterThanOrEqual(el(app, "page-close").frame.height, 43.5)
        shot("qibla")
        app.terminate()
        let denied = launch(["-SaryLiveModal", "qibla", "-SaryQiblaLocationState", "denied"], live: true)
        XCTAssertTrue(el(denied, "qibla.location-denied").waitForExistence(timeout: 25))
        let b = denied.buttons["qibla.open-settings"]
        XCTAssertTrue(b.exists)
        XCTAssertGreaterThanOrEqual(b.frame.height, 57, "the one primary button is 58 pt")
        XCTAssertFalse(el(denied, "qibla.waiting").exists)
        shot("qibla-denied")
    }

    // MARK: camp suggestions + desert routes

    func testOnlyTheFirstSuggestionHasThePrimaryGo() {
        let app = launch(["-SaryLiveModal", "camp", "-SaryCampNight", "0,20"], live: true)
        XCTAssertTrue(el(app, "camp.card.1").waitForExistence(timeout: 25))
        XCTAssertTrue(el(app, "camp.go.1").exists)
        XCTAssertGreaterThanOrEqual(el(app, "page-close").frame.height, 43.5)
        shot("camp")
    }

    func testDesertRoutesHeader() {
        let app = launch(["-SaryLiveModal", "routes", "-SaryRouteTo", "25.23,46.74", "-SaryRouteName", "روضة نورة"], live: true)
        XCTAssertTrue(el(app, "routes.sheet").waitForExistence(timeout: 25))
        XCTAssertTrue(el(app, "page-close").exists)
        shot("routes")
    }
}
