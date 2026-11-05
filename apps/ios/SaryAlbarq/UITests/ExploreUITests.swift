import XCTest

/// Build 9 stage A — exploration: entry from the header and from «+», the layer switcher,
/// the crosshair readout, saving a place, GPX tracks, offline entry, and one-tap exit.
final class ExploreUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped"] + extra
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

    /// Attaches the screenshot; with `SARY_SHOTS` set (TEST_RUNNER_SARY_SHOTS) also writes it there.
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

    func testEnterFromHeaderAndExitInOneTap() {
        let app = launch()
        let enter = app.buttons["trip.explore"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10), "«استكشاف» next to the trip header")
        enter.tap()
        for id in ["explore.header", "explore-exit", "explore-layers", "explore-terrain", "explore-places", "explore-tracks", "outing-locate",
                   "explore.readout", "explore-copy", "explore-save", "outing-sos", "outing-ptt"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in exploration")
        }
        XCTAssertFalse(app.buttons["outing-actions"].exists, "the trip's «+» waits behind «ارجع للرحلة»")
        let elev = any(app, "explore.elevation")
        XCTAssertTrue(elev.label.contains("الارتفاع"), "elevation line, a value or «غير متاح»")
        /* Decimal ↔ DMS. */
        let coord = any(app, "explore.coordinate")
        let before = coord.label
        any(app, "explore-coord-format").tap()
        XCTAssertNotEqual(any(app, "explore.coordinate").label, before, "the format switched")
        app.buttons["explore-exit"].tap()
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 5), "one tap back to the trip")
        XCTAssertFalse(any(app, "explore.header").exists)
    }

    func testEnterFromActionsAndSwitchLayers() {
        let app = launch()
        app.buttons["outing-actions"].tap()
        let entry = any(app, "outing-explore")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "«+» → الخريطة → استكشاف")
        entry.tap()
        XCTAssertTrue(app.buttons["explore-layers"].waitForExistence(timeout: 5))
        app.buttons["explore-layers"].tap()
        for id in ["layer.satellite", "layer.standard", "layer.topo", "explore-terrain3d", "explore-offline"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in «الطبقات»")
        }
        any(app, "layer.topo").tap()
        shot(app, "explore-layers-sheet")
        any(app, "page-close").tap()
        XCTAssertTrue(any(app, "explore.layerName").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "explore.layerName").label.contains("طبوغرافي"))
        /* Offline entry from the layer sheet. */
        app.buttons["explore-layers"].tap()
        any(app, "explore-offline").tap()
        XCTAssertTrue(any(app, "offline.add").waitForExistence(timeout: 6), "«الخرائط بلا إنترنت» opens")
        any(app, "page-back").tap()
    }

    func testSavePlaceAndListIt() {
        let app = launch(["-SaryExplore"])
        let save = app.buttons["explore-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let name = any(app, "placeEdit.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("مخيم الشتاء")
        any(app, "placeEdit.icon.camp").tap()
        any(app, "placeEdit.save").tap()
        app.buttons["explore-places"].tap()
        XCTAssertTrue(any(app, "places.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["مخيم الشتاء"].waitForExistence(timeout: 5), "the saved place is listed")
        for id in ["places.addCenter", "places.row", "places.menu"] { XCTAssertTrue(any(app, id).exists, id) }
        shot(app, "explore-places")
        /* Delete via the row's menu. */
        any(app, "places.menu").tap()
        app.buttons["احذف"].firstMatch.tap()
        let confirm = app.buttons["احذف"].firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertTrue(app.staticTexts["مخيم الشتاء"].waitForNonExistence(timeout: 5), "deleted")
    }

    func testTracksSheetAndTerrain() {
        let app = launch(["-SaryExplore"])
        XCTAssertTrue(app.buttons["explore-tracks"].waitForExistence(timeout: 10))
        app.buttons["explore-tracks"].tap()
        XCTAssertTrue(any(app, "tracks.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "tracks.import").exists, "import a GPX / KML")
        any(app, "page-close").tap()
        let t = app.buttons["explore-terrain"]
        t.tap()
        XCTAssertTrue(t.isSelected, "3D terrain on")
        sleep(2)
        shot(app, "explore-terrain3d")
        t.tap()
        XCTAssertFalse(t.isSelected)
    }

    /// Screenshots of the topographic layer over relief (Abha), for review.
    func testTopoScreenshot() {
        let app = launch(["-SaryExplore", "-SaryLayer", "topo", "-SaryExploreAt", "18.2465,42.5117"])
        XCTAssertTrue(any(app, "explore.readout").waitForExistence(timeout: 10))
        sleep(9)
        shot(app, "explore-topo")
        XCTAssertTrue(any(app, "explore.elevation").label.contains("الارتفاع"))
    }
}
