import XCTest

/// Build 46 «الرئيسية الجديدة» behind `-SaryNewUI` (dark first). With the flag off the legacy home is untouched:
/// `HomeFlowUITests` / `OneMapIdleUITests` prove that. Shots: `SARY_SHOTS` dir, prefix `SARY_SHOT_PREFIX` (default `home`).
final class NewHomeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(text: String? = nil, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-resetState"] : []) + ["-demo", "-SaryScreen", "home", "-SaryScheme", "dark", "-SaryNewUI"]
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
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "home"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    func testNewHomeElementsExistAndDoNotOverlap() {
        let app = launch()
        XCTAssertTrue(el(app, "home.card.start").waitForExistence(timeout: 20))
        for id in ["home.pill", "home.pill.search", "home.pill.mic", "home.pill.profile", "home.capsule", "map.layers", "map.tilt",
                   "home.locate", "home.card", "home.card.handle", "home.tile.camp", "home.tile.routes", "home.tile.weather", "home.tile.qibla"] {
            XCTAssertTrue(el(app, id).exists, id)
        }
        XCTAssertFalse(el(app, "home.search").exists, "the legacy sheet's search bar is not shown")
        let pill = el(app, "home.pill").frame, cap = el(app, "home.capsule").frame, card = el(app, "home.card").frame
        XCTAssertGreaterThanOrEqual(pill.height, 55)
        XCTAssertGreaterThanOrEqual(el(app, "home.card.start").frame.height, 57)
        XCTAssertFalse(pill.intersects(cap), "pill and capsule do not overlap")
        XCTAssertFalse(cap.intersects(card), "capsule and card do not overlap")
        XCTAssertLessThan(cap.midX, app.windows.firstMatch.frame.midX, "the capsule is on the left")
        for id in ["map.layers", "map.tilt", "home.locate", "home.pill.mic", "home.pill.profile"] {
            let f = el(app, id).frame
            XCTAssertGreaterThanOrEqual(f.width, 43.5, id); XCTAssertGreaterThanOrEqual(f.height, 43.5, id)
        }
        shot("pro-dark")
    }

    func testPrimaryButtonStartsANewOutingFlow() {
        let app = launch()
        XCTAssertTrue(el(app, "home.card.start").waitForExistence(timeout: 20))
        el(app, "home.card.start").tap()
        XCTAssertTrue(el(app, "create.bar").waitForExistence(timeout: 10) || el(app, "create.progress").waitForExistence(timeout: 5))
    }

    func testTilesOpenTheirScreens() {
        let app = launch()
        XCTAssertTrue(el(app, "home.tile.camp").waitForExistence(timeout: 20))
        el(app, "home.tile.camp").tap()
        XCTAssertTrue(el(app, "camp.sheet").waitForExistence(timeout: 10))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(el(app, "home.tile.weather").waitForExistence(timeout: 10))
        el(app, "home.tile.weather").tap()
        XCTAssertTrue(waitGone(el(app, "home.card.start"), 10), "the weather screen covers the home")
    }

    func testSearchPillOpensTheSearchSheet() {
        let app = launch()
        XCTAssertTrue(el(app, "home.pill.search").waitForExistence(timeout: 20))
        el(app, "home.pill.search").tap()
        XCTAssertTrue(el(app, "home.search").waitForExistence(timeout: 10))
    }

    func testLayersButtonStillOpensTheSharedLayersSheet() {
        let app = launch()
        XCTAssertTrue(el(app, "map.layers").waitForExistence(timeout: 20))
        el(app, "map.layers").tap()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10))
    }

    func testLargestTextKeepsTheEssentials() {
        let app = launch(text: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(el(app, "home.card.start").waitForExistence(timeout: 20))
        XCTAssertTrue(el(app, "home.card.start").isHittable)
        XCTAssertTrue(el(app, "home.pill.search").isHittable)
        XCTAssertTrue(el(app, "home.tile.qibla").exists)
        shot("pro-axxl-dark")
    }

    /// A long press on the map: the picked spot's card with the coordinates (Arabic digits, «٫») and the elevation line.
    func testPickedPointCardShowsCoordinatesAndElevation() {
        let app = launch()
        XCTAssertTrue(el(app, "home.card.start").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).press(forDuration: 1.2)
        let elev = el(app, "home.place.elevation")
        XCTAssertTrue(elev.waitForExistence(timeout: 15), "the picked spot's card")
        XCTAssertTrue(waitLabel(elev, containing: "الارتفاع", timeout: 12), elev.label)
        /* The coordinates are the card's subtitle (Arabic digits, «٫»), once; the elevation line adds only the elevation then. */
        let coords = el(app, "home.place").staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "٫")).firstMatch
        XCTAssertTrue(coords.waitForExistence(timeout: 5), "the coordinates with «٫» on the card")
        XCTAssertFalse(coords.label.contains(",") || coords.label.contains("."), coords.label)
        shot("point-card")
    }

    /// Small phones (iPhone SE, height < 700): the «آخر طلعة» row is gone first, the primary stays and nothing overlaps;
    /// on a big phone (Pro Max) the whole card is up. The same test runs on both devices.
    func testSmallPhoneDropsSecondaryRowsFirst() {
        let app = launch()
        XCTAssertTrue(el(app, "home.card.start").waitForExistence(timeout: 20))
        let h = app.windows.firstMatch.frame.height
        let start = el(app, "home.card.start"), card = el(app, "home.card").frame
        let pill = el(app, "home.pill").frame, cap = el(app, "home.capsule").frame
        XCTAssertTrue(start.isHittable, "the primary is always reachable")
        XCTAssertFalse(pill.intersects(card), "pill and card do not overlap")
        XCTAssertFalse(cap.intersects(card), "capsule and card do not overlap")
        XCTAssertFalse(pill.intersects(cap), "pill and capsule do not overlap")
        XCTAssertLessThanOrEqual(card.height, h * 0.62 + 1)
        if h < 700 {
            XCTAssertFalse(el(app, "home.card.last").exists, "compact: the last-outing row is dropped first")
            for id in ["home.tile.camp", "home.tile.routes", "home.tile.weather", "home.tile.qibla"] { XCTAssertTrue(el(app, id).exists, id) }
        }
        shot(h < 700 ? "se-dark" : "max-dark")
    }

    private func waitLabel(_ e: XCUIElement, containing s: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if e.label.contains(s) { return true }; usleep(300_000) }
        return false
    }

    private func waitGone(_ e: XCUIElement, _ t: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { if !e.isHittable { return true }; usleep(200_000) }
        return false
    }
}
