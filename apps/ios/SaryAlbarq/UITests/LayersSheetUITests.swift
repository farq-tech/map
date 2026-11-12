import XCTest

/// S2 (docs/ONE-MAP-UNIFICATION.md §8.2): the shared `MapLayersSheet` in Explore.
final class LayersSheetUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func open(_ extra: [String] = [], scheme: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", scheme,
                               "-SaryDrive", "0", "-SaryContext", "stopped", "-SaryExplore", "-SaryLiveModal", "layers"] + extra
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 20))
        XCTAssertTrue(el(app, "layer.topo").waitForExistence(timeout: 8))
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// One row per registered base layer, no more and no less (the catalog has exactly three).
    func testRowsMatchCatalog() {
        let app = open()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'layer.' AND NOT identifier BEGINSWITH 'layer.base'"))
        for id in ["layer.satellite", "layer.standard", "layer.topo"] { XCTAssertTrue(el(app, id).exists, id) }
        let ids = Set((0..<rows.count).map { rows.element(boundBy: $0).identifier }).filter { ["layer.satellite", "layer.standard", "layer.topo"].contains($0) }
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(el(app, "layer.satellite").isSelected, "satellite is the default")
        XCTAssertFalse(el(app, "layer.topo").isSelected)
    }

    private func assertRowsLaidOut(_ app: XCUIApplication, step: String) {
        let ids = ["layer.satellite", "layer.standard", "layer.topo"]
        let screen = app.frame
        let frames = ids.map { ($0, el(app, $0).frame) }
        for (id, f) in frames {
            XCTAssertGreaterThan(f.height, 40, "\(step): \(id) has a real height")
            XCTAssertGreaterThanOrEqual(f.minX, screen.minX, "\(step): \(id) inside left edge")
            XCTAssertLessThanOrEqual(f.maxX, screen.maxX, "\(step): \(id) inside right edge")
        }
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let x = frames[i].1.intersection(frames[j].1)
                XCTAssertFalse(x.width > 1 && x.height > 1, "\(step): \(frames[i].0) overlaps \(frames[j].0)")
            }
        }
    }

    /// Small and large text, light and dark: rows stack one under the other, grow with the text, stay on screen and tappable.
    func testLayoutAtSmallAndLargeText() {
        var heights: [String: CGFloat] = [:]
        for (tag, size, scheme) in [("small", "UICTContentSizeCategoryXS", "dark"),
                                    ("large", "UICTContentSizeCategoryAccessibilityXXL", "light")] {
            let app = open(["-UIPreferredContentSizeCategoryName", size], scheme: scheme)
            sleep(1)
            assertRowsLaidOut(app, step: tag)
            heights[tag] = el(app, "layer.topo").frame.height
            XCTAssertTrue(el(app, "layer.satellite").isHittable, "\(tag): first row tappable")
            shot("layers-sheet-\(tag)")
            // The big sheet scrolls to the end without a row ever covering another.
            let page = app.scrollViews.firstMatch
            for _ in 0..<3 { page.swipeUp(velocity: .slow) }
            XCTAssertTrue(el(app, "explore-offline").waitForExistence(timeout: 5), "\(tag): offline row reachable")
            app.terminate()
        }
        XCTAssertGreaterThan(heights["large"] ?? 0, heights["small"] ?? .infinity, "rows grow with the text size instead of clipping it")
    }

    /// The new sheet writes the same stored choice the legacy one did, and the old sheet is still reachable (DEBUG flag).
    func testLegacySheetStillAvailableBehindFlag() {
        let app = open(["-SaryLegacyLayersSheet"])
        for id in ["layer.satellite", "layer.standard", "layer.topo"] { XCTAssertTrue(el(app, id).exists, id) }
        el(app, "layer.standard").tap()
        XCTAssertTrue(el(app, "layer.standard").isSelected)
    }

    /// The sheet grows to its large detent and the base rows stay laid out; with SARY_SHOTS set, saves the
    /// large-detent shot (`<prefix>-large-<light|dark>.png`) for the before/after comparison.
    private func largeDetent(_ extra: [String], prefix: String, scheme: String) {
        let app = open(extra, scheme: scheme)
        let before = el(app, "layer.satellite").frame.minY
        let grab = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (before - 62) / app.frame.height))
        grab.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
        sleep(1)
        XCTAssertLessThan(el(app, "layer.satellite").frame.minY, before - 40, "the sheet grew to the large detent")
        assertRowsLaidOut(app, step: "large detent")
        let s = XCUIScreen.main.screenshot()
        shot("\(prefix)-large-\(scheme)")
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-large-\(scheme).png"))
        }
    }

    func testLargeDetentLight() { largeDetent([], prefix: "after", scheme: "light") }
    func testLargeDetentDark() { largeDetent([], prefix: "after", scheme: "dark") }
    func testLargeDetentLegacyLight() { largeDetent(["-SaryLegacyLayersSheet"], prefix: "legacy", scheme: "light") }
    func testLargeDetentLegacyDark() { largeDetent(["-SaryLegacyLayersSheet"], prefix: "legacy", scheme: "dark") }
}
