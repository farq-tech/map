import XCTest

/// S6 (docs/ONE-MAP-UNIFICATION.md §8.2): the layers button + the shared sheet on the HOME map; the chosen base is applied to
/// the home map, remembered, and is the one the outing map shows too.
final class HomeFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(reset: Bool = true, extra: [String] = [], text: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-resetState"] : []) + ["-demo", "-SaryScreen", "home", "-SaryScheme", "light"] + extra
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
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "s6"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    func testLayersButtonOnHome() {
        for (tag, size) in [("normal", nil), ("axxl", "UICTContentSizeCategoryAccessibilityXXL")] as [(String, String?)] {
            let app = launch(text: size)
            let layers = el(app, "map.layers")
            XCTAssertTrue(layers.waitForExistence(timeout: 20), "\(tag): the layers button is on the home map")
            XCTAssertTrue(layers.isHittable)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.layers").count, 1)
            // Home V2: «موقعي» shares the layers capsule and they do not overlap. The Qibla direction
            // switch is in the layers sheet (`explore-qibla`, checked below) and in the «القبلة» tile's page.
            let locate = app.buttons["home.locate"]
            XCTAssertTrue(locate.exists, "\(tag): «موقعي» beside the layers button")
            let x = layers.frame.intersection(locate.frame)
            XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag): map.layers overlaps home.locate")
            sleep(3)
            shot("home-button-\(tag)")
            layers.tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "\(tag): the shared sheet opens")
            for id in ["layer.satellite", "layer.standard", "layer.topo", "explore-qibla"] { XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), "\(tag): \(id)") }
            XCTAssertTrue(el(app, "layer.satellite").isSelected, "\(tag): satellite on a first launch")
            // Only what the home map draws: no weather, terrain or outing actions.
            for id in ["weather.layer.rain", "explore-terrain3d", "explore-offline", "explore-camp-suggest"] { XCTAssertFalse(el(app, id).exists, "\(tag): \(id) is not offered on home") }
            app.terminate()
        }
    }

    /// Each base layer applied to the home map (shots), remembered across a relaunch, and the same choice in the outing map's sheet.
    func testHomeFollowsChosenBase() {
        var app = launch()
        for layer in ["topo", "standard", "satellite"] {
            el(app, "map.layers").tap()
            XCTAssertTrue(el(app, "layer.\(layer)").waitForExistence(timeout: 10))
            el(app, "layer.\(layer)").tap()
            XCTAssertTrue(el(app, "layer.\(layer)").isSelected)
            el(app, "page-close").tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForNonExistence(timeout: 5))
            sleep(12)
            shot("home-\(layer)")
        }
        // Choose topo last, relaunch with the store kept: still topo.
        el(app, "map.layers").tap()
        el(app, "layer.topo").tap()
        el(app, "page-close").tap()
        sleep(2)
        app.terminate()
        app = launch(reset: false)
        el(app, "map.layers").tap()
        XCTAssertTrue(el(app, "layer.topo").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "layer.topo").isSelected, "the home map remembers the last choice")
        sleep(1)
        el(app, "page-close").tap()
        sleep(12)
        shot("home-topo-after-relaunch")
        app.terminate()
        // The outing/explore map shows the same choice.
        let live = XCUIApplication()
        live.launchArguments = ["-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped", "-SaryExplore"]
        live.launch()
        live.allowLocationIfAsked()
        XCTAssertTrue(el(live, "map.layers").waitForExistence(timeout: 25))
        sleep(8)
        shot("explore-after-home-topo")
        el(live, "map.layers").tap()
        XCTAssertTrue(el(live, "layer.topo").waitForExistence(timeout: 10))
        XCTAssertTrue(el(live, "layer.topo").isSelected, "the layer chosen on the home map stays in the outing")
    }

    /// Home V2 (the owner-approved redesign): one bar on top, two buttons on the map, one card at the bottom;
    /// every old action still reachable (the chips, البيت/الشغل/المفضلة, «طلعاتي» in the raised sheet).
    func testHomeV2OneBarTwoButtonsOneCard() {
        let app = launch()
        let bar = el(app, "home.topbar")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the one bar on top")
        for id in ["home.search", "home.mic", "home.profile"] {
            XCTAssertTrue(el(app, id).exists, id)
            XCTAssertTrue(bar.frame.insetBy(dx: -2, dy: -2).contains(el(app, id).frame), "\(id) inside the top bar")
        }
        // Only the two map buttons float over the map.
        XCTAssertTrue(el(app, "map.layers").exists)
        XCTAssertTrue(el(app, "home.locate").exists)
        XCTAssertFalse(el(app, "home.qibla.toggle").exists, "Qibla: the layers sheet and the «القبلة» tile")
        XCTAssertFalse(el(app, "home.categories").exists, "the chips are in the raised sheet")
        // The card: ONE primary action and the four desert shortcuts (the outing row: ScreensUITests).
        XCTAssertTrue(el(app, "home.start.create").exists)
        for id in ["home.tile.camp", "home.tile.routes", "home.tile.weather", "home.tile.qibla"] { XCTAssertTrue(el(app, id).exists, id) }
        XCTAssertLessThan(el(app, "home.locate").frame.maxY, el(app, "home.start.create").frame.minY, "the map buttons stay above the card")
        sleep(3)
        shot("v2-home")

        // A pressed point: its coordinates are in the point card (no permanent bar on the home map).
        el(app, "home.map").press(forDuration: 1.2)
        XCTAssertTrue(el(app, "home.place.coordinate").waitForExistence(timeout: 8), "coordinates in the point card")
        shot("v2-point-card")
        el(app, "home.place.close").tap()

        // Each tile opens its existing tool.
        XCTAssertTrue(el(app, "home.tile.qibla").waitForExistence(timeout: 5))
        el(app, "home.tile.qibla").tap()
        XCTAssertTrue(el(app, "page-close").waitForExistence(timeout: 5), "«القبلة» opens the Qibla page")
        el(app, "page-close").tap()
        XCTAssertTrue(el(app, "page-close").waitForNonExistence(timeout: 5))
        el(app, "home.tile.routes").tap()
        XCTAssertTrue(el(app, "home.tools").waitForExistence(timeout: 5), "«دروب البر» opens the «البر» sheet that explains it")
        el(app, "page-close").tap()
        XCTAssertTrue(el(app, "home.tools").waitForNonExistence(timeout: 5))
        el(app, "home.tile.camp").tap()
        XCTAssertTrue(app.staticTexts["اقترح لي مكان كشتة"].waitForExistence(timeout: 5), "«كشتة» opens the camp suggestions")
        el(app, "page-close").tap()
        XCTAssertTrue(app.staticTexts["اقترح لي مكان كشتة"].waitForNonExistence(timeout: 5))

        // Raised: البيت/الشغل/المفضلة, the chips with «البر», and «طلعاتي».
        app.showHomeCategories()
        for id in ["home.shortcut.home", "home.shortcut.work", "home.shortcut.favorites", "home.categories", "home.tools.open"] {
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), id)
        }
        app.openHomeOutings()
        XCTAssertTrue(app.buttons["list.create"].exists)
        XCTAssertTrue(app.buttons["list.join"].exists)
    }

    /// `-SaryHomeV1`: the old layout (chips and three buttons over the map, the search in the sheet).
    func testHomeV1FallbackKeepsTheOldChrome() {
        let app = launch(extra: ["-SaryHomeV1"])
        XCTAssertTrue(el(app, "home.search").waitForExistence(timeout: 20))
        XCTAssertFalse(el(app, "home.topbar").exists)
        for id in ["home.categories", "home.tools.open", "home.qibla.toggle", "home.locate", "map.layers", "home.mic", "home.profile"] {
            XCTAssertTrue(el(app, id).exists, id)
        }
        XCTAssertFalse(el(app, "home.tile.camp").exists)
        shot("v1-home")
    }
}
