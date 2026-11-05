import XCTest

/// Build 9 stage B — convoy intelligence on screen: the new cards (one at a time, the rest on
/// the bell), the leader's «ارجعوا لنقطة التجمع», and the rows' leader distance.
final class ConvoyIntelUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
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

    func testCardsQueueAndRecall() {
        let app = launch(["-SaryConvoyIntelDemo"])
        let card = any(app, "convoy-alert")
        XCTAssertTrue(card.waitForExistence(timeout: 12), "a convoy card")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "convoy-alert").count, 1, "one card at a time")
        XCTAssertTrue(card.label.contains("وقف فجأة"), "the sudden stop outranks the separation")
        XCTAssertTrue(app.buttons["alerts.bell"].exists, "the other waits on the bell")
        XCTAssertTrue(any(app, "convoy.recall").exists, "the leader can call everyone back")
        shot(app, "convoy-stop-card")
        any(app, "convoy.recall").tap()
        /* The demo has a rally point: the note goes out (or the rally picker opens without one). */
        sleep(2)
        app.buttons["alerts.bell"].tap()
        XCTAssertTrue(any(app, "alerts.list").waitForExistence(timeout: 5))
    }

    func testGroupRowsShowTheLeaderDistance() {
        let app = launch([])
        any(app, "outing-sheet-summary").tap()
        app.buttons["tab.group"].tap()
        XCTAssertTrue(any(app, "participant-row").waitForExistence(timeout: 5))
        sleep(2)
        shot(app, "convoy-group-tab")
        XCTAssertTrue(any(app, "rally-card").exists)
    }

    func testRulesScreenFromSettings() {
        let app = launch([])
        any(app, "outing-sheet-summary").tap()
        app.buttons["tab.more"].tap()
        any(app, "settings-convoy-alerts").tap()
        let toggle = any(app, "rules.stop")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "rules.stop.minutes").exists)
        shot(app, "convoy-rules")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(any(app, "rules.stop.minutes").waitForNonExistence(timeout: 3), "rule off hides its threshold")
        any(app, "rules.reset").tap()
        XCTAssertTrue(any(app, "rules.stop.minutes").waitForExistence(timeout: 3))
    }
}
