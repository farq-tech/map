import XCTest

/// Build 49 W-2 / W-3 (docs/UNIFIED-SURFACES.md): with the unified weather on (`-SaryUnifiedWeather`), the layers
/// sheet's weather group is one row that opens the weather page; with it off (the default) nothing changes.
final class UnifiedWeatherUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openLayers(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", "light",
                               "-SaryDrive", "0", "-SaryContext", "stopped", "-SaryExplore", "-SaryLiveModal", "layers"] + extra
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 20))
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Flag off (default): the layers sheet keeps its three weather rows and has no page row.
    func testFlagOffKeepsTheWeatherRowsInTheLayersSheet() {
        let app = openLayers()
        XCTAssertTrue(el(app, "weather.layer.clouds").waitForExistence(timeout: 8), "the old weather group is still there")
        XCTAssertFalse(el(app, "weather.layers.openPage").exists, "no page row with the flag off")
    }

    /// Flag on: one row «صفحة الطقس» replaces the group (the quick chips stay), and it opens the page.
    func testFlagOnTheWeatherGroupIsOneRowThatOpensThePage() {
        let app = openLayers(["-SaryUnifiedWeather"])
        let row = el(app, "weather.layers.openPage")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "one row opens the page")
        XCTAssertFalse(el(app, "weather.layer.wind").exists, "the three-row group is gone from the sheet (it lives in the page)")
        XCTAssertTrue(el(app, "weather.quick.clouds").exists || el(app, "weather.quick.rain").exists, "the quick chips stay (one tap, also from guidance)")
        shot("unified-layers-row")
        row.tap()
        XCTAssertTrue(el(app, "weather.sheet").waitForExistence(timeout: 10), "the row opens the weather page")
        XCTAssertTrue(el(app, "weather.page.map").waitForExistence(timeout: 5), "with the layers and their controls")
        shot("unified-page-from-layers")
    }
}
