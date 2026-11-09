import XCTest

/// «بريف المكان»: one tap on an empty map spot opens the point card with the spot's
/// weather, sun, terrain and the camping line; the long press still opens the same card;
/// the driving layout shows the compact version.
final class PlaceBriefUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(context: String = "stopped") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "dust", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", context]
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
        sleep(2) // style + interactions ready
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

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

    /// An empty spot: off the cars (the group sits in the middle) and clear of the chrome.
    private func emptySpot(_ app: XCUIApplication) -> XCUICoordinate {
        let map = any(app, "outing.map")
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        /* Upper right, under the weather pill: (0.22, 0.36) now lands on a hazard pin by
         * «أبو فهد»'s note bubble. */
        return map.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.30))
    }

    func testOneTapOnTheMapOpensTheBrief() {
        let app = launch()
        emptySpot(app).tap()
        XCTAssertTrue(any(app, "brief.section").waitForExistence(timeout: 6), "one tap ⇒ the brief")
        for id in ["point.title", "brief.temp", "brief.wind", "brief.dust", "brief.visibility", "brief.rain",
                   "brief.assessment", "brief.source", "brief.more"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 3), "\(id) in the brief")
        }
        XCTAssertFalse(any(app, "brief.hours").exists, "the short summary does not lead with the forecast strip")
        XCTAssertTrue(any(app, "brief.source").label.hasPrefix("المصدر: Open-Meteo"), any(app, "brief.source").label)
        /* The demo «dust» forecast: heavy dust ⇒ not suitable, with the reason shown. */
        XCTAssertTrue(any(app, "brief.assessment").label.contains("غير مناسب للتخييم الآن"), any(app, "brief.assessment").label)
        XCTAssertTrue(any(app, "brief.dust").label.contains("غبار كثيف"), any(app, "brief.dust").label)
        shot(app, "place-brief-tap")
        any(app, "brief.more").tap()
        XCTAssertEqual(any(app, "brief.more").value as? String, "مفتوحة", "the details control changes state")
        let briefScroll = any(app, "point.sheet.scroll")
        XCTAssertTrue(briefScroll.exists, "the point brief is in a scrollable sheet")
        for _ in 0..<5 where !any(app, "brief.humidity").exists { briefScroll.swipeUp() }
        for id in ["brief.humidity", "brief.uv", "brief.sun", "brief.elevation", "brief.hours"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 3), "expanded details show \(id)")
        }
        XCTAssertTrue(any(app, "brief.elevation").label.contains("الارتفاع"), "elevation, a value or «غير متاح»")
        XCTAssertTrue(any(app, "brief.assessment").label.contains("غبار كثيف"))
        shot(app, "place-brief-expanded")
        /* The card's actions stay, under the brief. */
        /* On a smaller phone the sheet first grows to full height, then scrolls. */
        for _ in 0..<4 where !any(app, "point.save").waitForExistence(timeout: 2) { any(app, "brief.section").swipeUp() }
        for id in ["point.copy", "point.share", "point.navigate", "point.save"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 3), "\(id) on the card")
        }
    }

    func testLongPressStillOpensTheCardWithTheBrief() {
        let app = launch()
        emptySpot(app).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["point.copy"].waitForExistence(timeout: 6), "the long-press card")
        XCTAssertTrue(any(app, "brief.section").waitForExistence(timeout: 3))
    }

    func testDrivingLayoutShowsTheCompactBrief() {
        let app = launch(context: "driving")
        emptySpot(app).press(forDuration: 1.2)
        XCTAssertTrue(any(app, "brief.section").waitForExistence(timeout: 6))
        XCTAssertTrue(any(app, "brief.assessment").exists)
        XCTAssertFalse(any(app, "brief.hours").exists, "no timeline to read while driving")
        XCTAssertFalse(any(app, "brief.sun").exists)
    }
}
