import XCTest

/// S5 (docs/ONE-MAP-UNIFICATION.md §8.2): ONE layers button (`map.layers`) on the live map in every mode, opening the
/// same `MapLayersSheet`; nothing on the map chrome overlaps it; the floating SOS disc never covers the sheet's rows.
final class LayersButtonUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private enum Mode: String {
        case stopped, driving, exploring
        var args: [String] {
            switch self {
            case .stopped: return ["-SaryDrive", "0", "-SaryContext", "stopped"]
            case .driving: return ["-SaryDrive", "1", "-SaryContext", "driving"]
            case .exploring: return ["-SaryDrive", "0", "-SaryContext", "stopped", "-SaryExplore"]
            }
        }
    }

    private func launch(_ mode: Mode, text: String? = nil, scheme: String = "light", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", scheme] + mode.args + extra
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
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "s5"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    // MARK: Visible and working in every mode

    func testVisibleInStoppedDrivingExploring() {
        for mode in [Mode.stopped, .driving, .exploring] {
            let app = launch(mode)
            let button = el(app, "map.layers")
            XCTAssertTrue(button.waitForExistence(timeout: 25), "\(mode): the layers button is on the map")
            XCTAssertTrue(button.isHittable, "\(mode): and can be tapped")
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.layers").count, 1, "\(mode): exactly one")
            XCTAssertFalse(el(app, "explore-layers").exists, "\(mode): the old explore-only button is gone")
            sleep(2)
            shot("button-\(mode.rawValue)")
            button.tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "\(mode): the shared layers sheet opens")
            for id in ["layer.satellite", "layer.standard", "layer.topo"] { XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), "\(mode): \(id)") }
            // The mode decides the data rows: weather only where its overlay is drawn (exploration).
            let rain = el(app, "weather.layer.rain")
            var found = rain.exists
            let page = app.scrollViews.firstMatch
            for _ in 0..<4 where !found { page.swipeUp(velocity: .slow); found = rain.exists }
            XCTAssertEqual(found, mode == .exploring, "\(mode): weather rows only in exploration")
            app.terminate()
        }
    }

    /// A base layer chosen from the outing map's sheet is kept (same stored key) and the sheet marks it.
    func testBaseLayerChoiceInTheOutingSheet() {
        let app = launch(.stopped)
        el(app, "map.layers").tap()
        XCTAssertTrue(el(app, "layer.topo").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "layer.satellite").isSelected)
        el(app, "layer.topo").tap()
        XCTAssertTrue(el(app, "layer.topo").isSelected)
        XCTAssertFalse(el(app, "layer.satellite").isSelected)
    }

    // MARK: Overlap (chrome frames)

    /// Small and large text: the layers button stays on screen and shares no area with the SOS button, the walkie-talkie /
    /// bottom bar, the camera button or the sheet's summary row. (Member chips are drawn by the map itself, anchored to the
    /// cars; they are in the screenshots, not in the frame checks.)
    func testNoOverlapSmallAndLargeText() {
        for (tag, size) in [("small", "UICTContentSizeCategoryXS"), ("large", "UICTContentSizeCategoryAccessibilityXXL")] {
            for mode in [Mode.stopped, .driving, .exploring] {
                let app = launch(mode, text: size)
                let button = el(app, "map.layers")
                XCTAssertTrue(button.waitForExistence(timeout: 25), "\(tag)/\(mode)")
                sleep(2)
                let f = button.frame
                let screen = app.frame
                XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(f), "\(tag)/\(mode): inside the screen \(f) in \(screen)")
                XCTAssertGreaterThanOrEqual(f.width, 44, "\(tag)/\(mode): a real touch target")
                for other in ["outing-sos", "outing-ptt", "outing-locate", "outing-backtrack", "explore-places", "explore-drone", "explore-realistic",
                              "outing-sheet-summary", "outing-speed"] {
                    let o = el(app, other)
                    guard o.exists, !o.frame.isEmpty else { continue }
                    let x = f.intersection(o.frame)
                    XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag)/\(mode): map.layers \(f) overlaps \(other) \(o.frame)")
                }
                shot("overlap-\(tag)-\(mode.rawValue)")
                app.terminate()
            }
        }
    }

    // MARK: The SOS disc and the sheet

    /// The scroll area of the layers sheet ends above the floating SOS disc, at small and large text, so scrolling to the end
    /// leaves every row clear of it.
    func testSheetRowsNeverUnderTheSOSButton() {
        for (tag, size) in [("small", "UICTContentSizeCategoryXS"), ("large", "UICTContentSizeCategoryAccessibilityXXL")] {
            let app = launch(.exploring, text: size)
            el(app, "map.layers").tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10))
            let sos = el(app, "sos.overlay")
            XCTAssertTrue(sos.waitForExistence(timeout: 8), "\(tag): the floating SOS is over the sheet")
            let page = app.scrollViews.firstMatch
            for _ in 0..<12 { page.swipeUp(velocity: .slow) }
            sleep(1)
            XCTAssertLessThanOrEqual(page.frame.maxY, sos.frame.minY + 1, "\(tag): the scroll area ends above the SOS disc (\(page.frame) vs \(sos.frame))")
            let last = el(app, "explore-offline")
            XCTAssertTrue(last.isHittable, "\(tag): the last row is reachable")
            let x = last.frame.intersection(sos.frame)
            XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag): the last row is clear of the SOS disc")
            shot("sheet-sos-\(tag)")
            app.terminate()
        }
    }
}
