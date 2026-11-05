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

    func testEnterFromToolsAndExitInOneTap() {
        let app = launch()
        /* «تخفيف الزحمة» ٤: «أدوات» → «استكشاف وطبقات» (the binoculars left the header). */
        XCTAssertTrue(app.openTool("outing-explore"), "«استكشاف» two taps from the trip map")
        for id in ["explore.header", "explore-exit", "explore-layers", "explore-places", "outing-locate",
                   "explore.readout", "explore-copy", "explore-save", "outing-sos", "outing-ptt"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in exploration")
        }
        XCTAssertFalse(app.buttons["outing-actions"].exists, "the trip's «أدوات» waits behind the back button")
        XCTAssertFalse(app.buttons["explore-terrain"].exists, "three buttons only: 3D terrain is in «الطبقات»")
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
        let name = any(app, "placeEdit.name")
        /* Exploration may still be settling (the camera, the layers sheet): tap again if the editor did not come up. */
        for _ in 0..<3 where !name.exists {
            save.tap()
            _ = name.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(name.exists, "«حفظ المكان» opens the editor")
        name.focusAndType("مخيم الشتاء")
        any(app, "placeEdit.icon.camp").tap()
        any(app, "placeEdit.save").tap()
        app.buttons["explore-places"].tap()
        XCTAssertTrue(any(app, "places.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["مخيم الشتاء"].waitForExistence(timeout: 5), "the saved place is listed")
        for id in ["places.addCenter", "places.row", "places.menu"] { XCTAssertTrue(any(app, id).exists, id) }
        shot(app, "explore-places")
        /* Delete via the row's menu. */
        any(app, "places.menu").tap()
        /* The menu animates in: wait until «احذف» can take a tap, then the confirmation. */
        /* «احذف» shows twice in the tree (the menu item, then the confirmation): tap the one that can take it. */
        func tapHittableDelete(within seconds: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let b = app.buttons.matching(NSPredicate(format: "label == 'احذف'")).allElementsBoundByIndex.first(where: { $0.isHittable }) {
                    b.tap()
                    return true
                }
                usleep(300_000)
            }
            return false
        }
        XCTAssertTrue(tapHittableDelete(within: 6), "«احذف» in the row's menu")
        _ = tapHittableDelete(within: 3) // the confirmation, if asked
        XCTAssertTrue(app.staticTexts["مخيم الشتاء"].waitForNonExistence(timeout: 5), "deleted")
    }

    func testTracksSheetAndTerrain() {
        let app = launch(["-SaryExplore"])
        /* «أماكني ومساراتي»: one button, the tracks are its second tab. */
        XCTAssertTrue(app.buttons["explore-places"].waitForExistence(timeout: 25))
        app.buttons["explore-places"].tap()
        XCTAssertTrue(app.buttons["explore-tracks"].waitForExistence(timeout: 5))
        app.buttons["explore-tracks"].tap()
        XCTAssertTrue(any(app, "tracks.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "tracks.import").exists, "import a GPX / KML")
        any(app, "page-close").tap()
        /* «تخفيف الزحمة» ١٠: 3D terrain is a switch in «الطبقات»; the layers button lights up. */
        let layers = app.buttons["explore-layers"]
        XCTAssertTrue(layers.waitForExistence(timeout: 5))
        layers.tap()
        let t = app.buttons["explore-terrain3d"].firstMatch
        XCTAssertTrue(t.waitForExistence(timeout: 5))
        t.scrollIntoView(in: app)
        t.tap()
        XCTAssertTrue(t.isSelected, "3D terrain on")
        any(app, "page-close").tap()
        XCTAssertTrue(layers.waitForExistence(timeout: 5))
        XCTAssertTrue(layers.isSelected, "3D terrain on: «الطبقات» shows it")
        sleep(2)
        shot(app, "explore-terrain3d")
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
