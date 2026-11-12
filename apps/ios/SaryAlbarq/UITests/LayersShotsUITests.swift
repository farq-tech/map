import XCTest

/// Screenshots for the layers PRs (S3/S5/S6 of docs/ONE-MAP-UNIFICATION.md). Only runs when SARY_SHOTS is set
/// (TEST_RUNNER_SARY_SHOTS for xcodebuild); SARY_SHOT_PREFIX names the set. One variable per comparison.
final class LayersShotsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var dir: String? { ProcessInfo.processInfo.environment["SARY_SHOTS"] }
    private var prefix: String { ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "s3" }

    private func save(_ name: String) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = XCUIScreen.main.screenshot()
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(_ extra: [String] = [], scheme: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", scheme,
                               "-SaryDrive", "0", "-SaryContext", "stopped", "-SaryExplore"] + extra
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    /// New sheet vs the legacy one (the only variable: `-SaryLegacyLayersSheet`), at the top and scrolled to the data layers.
    func testSheetNewVsLegacy() throws {
        try XCTSkipIf(dir == nil)
        for (tag, extra) in [("new", [String]()), ("legacy", ["-SaryLegacyLayersSheet"])] {
            let app = launch(extra + ["-SaryLiveModal", "layers"])
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 20))
            sleep(4)
            save("sheet-\(tag)-0-top")
            let page = app.scrollViews.firstMatch
            for i in 1...4 {
                page.swipeUp(velocity: .slow)
                sleep(1)
                save("sheet-\(tag)-\(i)")
            }
            app.terminate()
        }
    }

    /// For each data layer: the map with it off, then on (the only variable: the switch in the sheet).
    func testMapOffOnPerLayer() throws {
        try XCTSkipIf(dir == nil)
        let cases: [(String, String, Bool)] = [("camp", "explore-camp-sites", true), ("qibla", "explore-qibla", true),
                                               ("terrain", "explore-terrain3d", false), ("rain", "weather.layer.rain", false)]
        for (name, id, isSwitch) in cases {
            let app = launch(["-SaryCampFrom", "24.7113,46.6744"])
            sleep(8)
            save("map-\(name)-0-before")
            el(app, "map.layers").tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10))
            let page = app.scrollViews.firstMatch
            let target = isSwitch ? app.switches[id].firstMatch : app.buttons[id].firstMatch
            for _ in 0..<10 where !(target.exists && target.isHittable) { page.swipeUp(velocity: .slow) }
            XCTAssertTrue(target.isHittable, id)
            target.tap()
            sleep(1)
            save("map-\(name)-1-sheet-after-tap")
            el(app, "page-close").tap()
            sleep(10)
            save("map-\(name)-2-after")
            app.terminate()
        }
    }
}
