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
            // Weather is offered in every outing state, not only exploration (owner's Build 44 report, PR #239): the quick chips and the section.
            for k in ["clouds", "rain", "wind"] { XCTAssertTrue(el(app, "weather.quick.\(k)").waitForExistence(timeout: 5), "\(mode): quick weather chip \(k)") }
            let rain = el(app, "weather.layer.rain")
            var found = rain.exists
            let page = app.scrollViews.firstMatch
            for _ in 0..<4 where !found { page.swipeUp(velocity: .slow); found = rain.exists }
            XCTAssertTrue(found, "\(mode): weather rows are offered in every outing state")
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
            // Pull the sheet to its large detent first (at large text on a short phone the medium one has little room).
            let top = el(app, "layer.satellite").frame.minY
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.05, (top - 62) / app.frame.height)))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
            sleep(1)
            let sos = el(app, "sos.overlay")
            XCTAssertTrue(sos.waitForExistence(timeout: 8), "\(tag): the floating SOS is over the sheet")
            let page = app.scrollViews.firstMatch
            let last = el(app, "explore-offline")
            // Scroll until the last row is wholly inside the scroll area (a tall row at large text takes many slow swipes).
            for _ in 0..<40 where !(last.exists && last.frame.maxY <= page.frame.maxY + 1) { page.swipeUp(velocity: .slow) }
            sleep(1)
            XCTAssertLessThanOrEqual(page.frame.maxY, sos.frame.minY + 1, "\(tag): the scroll area ends above the SOS disc (\(page.frame) vs \(sos.frame))")
            XCTAssertTrue(last.isHittable, "\(tag): the last row is reachable")
            let x = last.frame.intersection(sos.frame)
            XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag): the last row is clear of the SOS disc")
            shot("sheet-sos-\(tag)")
            app.terminate()
        }
    }

    // MARK: Owner's Build 44 report: «خلال الطلعة لا يمكنني الضغط على الطبقات»

    private func tapOpensSheet(_ app: XCUIApplication, _ label: String) {
        let button = el(app, "map.layers")
        XCTAssertTrue(button.waitForExistence(timeout: 30), "\(label): the layers button is on the map")
        sleep(2)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(label): hit area width")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(label): hit area height")
        XCTAssertTrue(button.isHittable, "\(label): nothing covers it")
        button.tap()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "\(label): the tap opened the layers sheet")
        shot("tap-\(label)")
    }

    func testTapOpensTheSheetStanding() { tapOpensSheet(launch(.stopped), "standing") }

    func testTapOpensTheSheetDriving() { tapOpensSheet(launch(.driving), "driving") }

    func testTapOpensTheSheetWhileGuiding() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavStart",
                               "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", "light", "-SaryDrive", "0"]
        app.launch(); app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 75), "guiding")
        tapOpensSheet(app, "guiding")
        // Weather is one tap away here: the quick chip turns the clouds on and the legend card appears.
        XCTAssertTrue(el(app, "weather.quick.clouds").waitForExistence(timeout: 5), "quick weather chips lead the sheet")
        XCTAssertTrue(el(app, "weather.layer.clouds").exists || el(app, "weather.quick.clouds").exists)
        el(app, "weather.quick.clouds").tap()
        XCTAssertTrue(el(app, "weather.quick.clouds").isSelected, "the chip shows the layer is on")
    }

    private func guidingApp(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavStart",
                               "-SaryWeatherDemo", "rain", "-SaryScheme", "light", "-SaryDrive", "0"] + extra
        app.launch(); app.allowLocationIfAsked()
        return app
    }

    /// Owner's Build 46 report: in guidance, with rain on, «الطبقات» did nothing and the rain layer could not be turned off.
    func testGuidingWithRainLayersOpenAndRainTurnsOff() {
        let app = guidingApp()
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 75), "guiding")
        tapOpensSheet(app, "guiding-rain")
        let rain = el(app, "weather.quick.rain")
        XCTAssertTrue(rain.waitForExistence(timeout: 5))
        if !rain.isSelected { rain.tap() }
        XCTAssertTrue(rain.isSelected, "rain is on")
        rain.tap()
        XCTAssertFalse(rain.isSelected, "rain turns off")
        shot("guiding-rain-off")
    }



    func testGuidingDockComesBackAndLayersWork() {
        let app = guidingApp(["-SaryDockDrop", "35"])
        XCTAssertTrue(el(app, "dock.fallback.end").waitForExistence(timeout: 60))
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 30), "the dock is presented again")
        XCTAssertTrue(el(app, "dock.fallback.end").waitForNonExistence(timeout: 10))
        tapOpensSheet(app, "after-dock-return")
    }

    func testTapOpensTheSheetAfterTheEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", "light", "-SaryDrive", "0",
                               "-SaryContext", "stopped", "-SaryTrip", "arrived", "-SarySheetHalf"]
        app.launch(); app.allowLocationIfAsked()
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.endOutingFromMore(), "ended by the owner")
        XCTAssertTrue(app.buttons["trip.return"].waitForExistence(timeout: 15))
        let summary = el(app, "outing-sheet-summary")
        if summary.waitForExistence(timeout: 5) { summary.tap() }
        tapOpensSheet(app, "after-end")
    }

    /// The second tap, and the tap after another sheet was opened and closed, must work as well as the first.
    func testTapWorksAgainAfterASheetWasOpenedAndClosed() {
        let app = launch(.stopped)
        let button = el(app, "map.layers")
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        for round in 1...2 {
            button.tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "round \(round): layers sheet opens")
            el(app, "explore.layers.sheet").swipeDown(velocity: .fast)
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForNonExistence(timeout: 10), "round \(round): closed")
        }
        app.buttons["outing-actions"].tap()
        XCTAssertTrue(el(app, "outing-actions-sheet").waitForExistence(timeout: 10))
        el(app, "outing-actions-close").tap()
        XCTAssertTrue(el(app, "outing-actions-sheet").waitForNonExistence(timeout: 10))
        sleep(1)
        button.tap()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "layers opens after «المزيد» was closed")
        shot("tap-after-more")
    }

    /// Owner's Build 44 report: with the sheet raised to half (members, «المزيد» row) the button was gone.
    func testTapOpensTheSheetWithTheSheetHalfOpen() {
        let app = launch(.stopped, extra: ["-SaryLiveSheet", "half"])
        tapOpensSheet(app, "half-sheet")
    }
}
