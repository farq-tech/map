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
            // The Qibla button and ray were removed (owner, 2026-11-13); «موقعي» sits beside it and they do not overlap.
            XCTAssertFalse(app.buttons["home.qibla.toggle"].exists, "\(tag): no Qibla button on the home map")
            for other in [app.buttons["home.locate"]] {
                let x = layers.frame.intersection(other.frame)
                XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag): map.layers overlaps \(other.identifier)")
            }
            sleep(3)
            shot("home-button-\(tag)")
            layers.tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "\(tag): the shared sheet opens")
            for id in ["layer.satellite", "layer.standard", "layer.topo"] { XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), "\(tag): \(id)") }
            XCTAssertFalse(el(app, "explore-qibla").exists, "\(tag): no Qibla row in the sheet")
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
}
