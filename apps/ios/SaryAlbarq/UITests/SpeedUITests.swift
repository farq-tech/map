import XCTest

/// «سرعة المركبة» on the demo outing: my speedometer over the map, a friend's
/// speed on their row and card (only while their position is fresh), and the
/// optional over-speed nudge in the sheet's settings (off by default).
/// Run with a simulated route (`xcrun simctl location <udid> start …`) to see a number;
/// without one the speedometer must read «—».
final class SpeedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        /* The speedometer shows while driving only (build 8): pin the driving context. */
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryContext", "driving", "-SaryDemoKeepLive"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 15))
        // Tap the status bar, not the map centre: a demo car sits there and would open its card.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testSpeedometerAndFriendSpeed() {
        let app = launch()
        let speedo = app.descendants(matching: .any)["speedometer"].firstMatch
        /* «تخفيف الزحمة» ٨: the speedometer shows from the first real speed only (a simulated route);
         * without one it stays off the map rather than showing an empty «— كم/س». */
        _ = speedo.waitForExistence(timeout: 10)
        let label = speedo.exists ? speedo.label : ""
        if speedo.exists { XCTAssertTrue(label.contains("كم/س"), "a real speed: \(label)") }
        /* Clear of the dock and the control cluster (measured, not guessed). */
        if speedo.exists {
            let ptt = app.descendants(matching: .any)["outing-ptt"]
            if ptt.exists { XCTAssertFalse(speedo.frame.intersects(ptt.frame), "not over «اضغط وتكلم»") }
            let sos = app.descendants(matching: .any)["outing-sos"]
            if sos.exists { XCTAssertFalse(speedo.frame.intersects(sos.frame), "not over SOS") }
        }

        /* The demo's «أبو فهد» sent a moving fix moments ago (22 m/s): his speed shows while it is
         * fresh. «نورة»'s last fix is 5 minutes old: no speed, just «آخر موقع». */
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let groupTab = app.buttons["tab.group"]
        XCTAssertTrue(groupTab.waitForExistence(timeout: 5))
        groupTab.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "participant-row")
        let fahd = rows.containing(NSPredicate(format: "label CONTAINS %@", "أبو فهد")).firstMatch
        let fahdRow = fahd.exists ? fahd : rows.matching(NSPredicate(format: "label CONTAINS %@", "أبو فهد")).firstMatch
        XCTAssertTrue(fahdRow.waitForExistence(timeout: 5))
        /* Read the row before scrolling to it: the integrated sheet has more sections above the
         * rows (safety, weather, convoy, trail), and the demo fix stops being live ~15 s in. */
        XCTAssertTrue(fahdRow.label.contains("السرعة ٧٩ كم/س"), "a live friend's speed on the row: \(fahdRow.label)")
        for _ in 0..<3 where !fahdRow.isHittable { app.swipeUp() }
        let noura = rows.matching(NSPredicate(format: "label CONTAINS %@", "نورة")).firstMatch
        XCTAssertTrue(noura.exists)
        XCTAssertFalse(noura.label.contains("السرعة"), "a stale friend shows no speed: \(noura.label)")
        attach(app, "speed-rows")
        fahdRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["participant-card"].waitForExistence(timeout: 5))
        sleep(1)
        /* The demo fix ages out ~15 s after launch: then the card must drop the speed, never keep an old one. */
        let stale = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "قد يكون مكانه تغيّر")).firstMatch.exists
        if stale {
            XCTAssertFalse(app.staticTexts["السرعة"].exists, "a stale card shows no speed")
        } else {
            XCTAssertTrue(app.staticTexts["السرعة"].exists, "the card's speed tile while the fix is fresh")
        }
        attach(app, "speed-card")

        /* Back to the map. */
        app.swipeDown()
        app.swipeDown()
        /* Driving (a simulated route): a tap shows the trip's top and average speed for a few seconds. */
        if label.contains("كم/س"), ProcessInfo.processInfo.environment["SARY_SIM_ROUTE"] != nil {
            sleep(7)
            speedo.tap()
            let trip = NSPredicate(format: "label CONTAINS %@", "أعلى سرعة")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "speedometer").matching(trip).firstMatch.waitForExistence(timeout: 3), "trip view on tap")
            attach(app, "speed-trip")
        }
    }

    func testOverSpeedNudgeIsOffByDefaultAndAdjustable() {
        let app = launch()
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let tab = app.buttons["tab.more"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        /* «الإعدادات» → «القيادة والعرض». */
        let driving = app.descendants(matching: .any)["settings.driving"]
        XCTAssertTrue(driving.waitForExistence(timeout: 5))
        driving.tap()
        let toggle = app.switches["speed.alert"]
        /* The «المزيد» list grew (auto-guidance, driving realism): bring the switch clear of the
         * bottom edge, not just barely on screen, before tapping it. */
        for _ in 0..<10 where !toggle.isHittable || toggle.frame.maxY > app.frame.maxY - 160 { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        XCTAssertFalse(app.staticTexts["speed.limit"].exists)
        /* Tap the switch itself (on the left in RTL), not the row's middle (its label). */
        XCTAssertTrue(toggle.flipSwitch(), "the over-speed switch flips")
        let limit = app.staticTexts["speed.limit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        XCTAssertEqual(limit.label, "١٢٠ كم/س")
        app.buttons["speed.limit.up"].tap()
        XCTAssertEqual(limit.label, "١٣٠ كم/س")
        attach(app, "speed-settings")
    }
}
