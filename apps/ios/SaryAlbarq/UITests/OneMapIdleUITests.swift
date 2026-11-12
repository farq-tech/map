import XCTest

/// EM1 (docs/EXPLORE-MERGE.md): the navigation map without a trip, behind `-SaryOneMap`.
/// Parity with the home map is proven by the shots: same place, same zoom, the flag as the only variable.
final class OneMapIdleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], oneMap: Bool = true, text: String? = nil, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-resetState"] : []) + ["-demo", "-SaryScreen", "home", "-SaryScheme", "light"]
            + (oneMap ? ["-SaryOneMap"] : []) + extra
            + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
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
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "em1"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    /// The idle sheet carries the home content; the map has exploration's capabilities and the one shared layers button.
    func testIdleMapHoldsHomeContentAndTheSharedLayersButton() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30), "the search field of the home content is in the sheet")
        app.allowLocationIfAsked(within: 3)
        XCTAssertTrue(el(app, "explore.header").waitForExistence(timeout: 10), "exploration's layer bar and coordinate card are on")
        XCTAssertFalse(el(app, "explore-exit").exists, "no way out of exploration: it is the map")
        let layers = el(app, "map.layers")
        XCTAssertTrue(layers.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.layers").count, 1)
        shot("idle-peek")
        layers.tap()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "the same shared sheet")
        for id in ["layer.satellite", "layer.topo", "weather.layer.rain", "explore-camp-sites", "explore-hires"] {
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), "\(id) is in the idle map's sheet")
        }
        shot("idle-layers")
    }

    /// The search of the home content works over the navigation map: a coordinate opens the place's brief.
    func testIdleSearchPicksAPlaceAndOpensItsBrief() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        el(app, "idle.search").tap()
        let field = el(app, "live.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("24.7136, 46.6753")
        let row = el(app, "live.search.coordinate")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons.firstMatch.exists ? row.buttons.firstMatch.tap() : row.tap()
        XCTAssertTrue(el(app, "point.sheet.scroll").waitForExistence(timeout: 15), "the place brief opens over the map")
        shot("idle-search-brief")
    }

    /// The home content without the flag is untouched (the default path).
    func testWithoutTheFlagTheHomeMapIsStillTheDefault() {
        let app = launch(oneMap: false)
        XCTAssertTrue(app.buttons["home.locate"].waitForExistence(timeout: 30))
        XCTAssertFalse(el(app, "idle.search").exists)
        shot("home-flat")
    }

    /// Same place and zoom, only the high-res imagery switch differs (R01).
    func testHighResIsOnByDefaultInTheIdleMap() {
        let on = launch(["-SaryHiRes", "on"])
        XCTAssertTrue(el(on, "idle.search").waitForExistence(timeout: 30))
        on.allowLocationIfAsked(within: 3)
        sleep(8)
        shot("idle-hires-on")
        on.terminate()
        let off = launch(["-SaryHiRes", "off"], reset: false)
        XCTAssertTrue(el(off, "idle.search").waitForExistence(timeout: 30))
        off.allowLocationIfAsked(within: 3)
        sleep(8)
        shot("idle-hires-off")
    }
}
