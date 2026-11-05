import XCTest

/// «ترددات» on the demo outing (no server): the channel chip beside «اضغط وتكلم», the sheet with
/// the knob and the five public channels, switching, and the leader's «+ تردد خاص» → pick
/// members → on it → close it → back on ١. Screenshots go to `SARY_SHOT_DIR` when set.
final class PTTChannelsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOT_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testSwitchChannelsAndOpenAPrivateOne() {
        let app = launch()
        let chip = any(app, "ptt-channel-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the channel chip beside the talk button")
        XCTAssertTrue(chip.label.contains("تردد ١"), "everyone starts on ١: \(chip.label)")
        shot(app, "01-chip")

        chip.tap()
        XCTAssertTrue(any(app, "ptt-channels-sheet").waitForExistence(timeout: 5))
        shot(app, "02-sheet")
        for id in ["1", "2", "3", "4", "5"] { XCTAssertTrue(any(app, "ptt-channel-row-\(id)").exists, "row \(id)") }
        XCTAssertTrue(any(app, "ptt-channel-knob").exists)
        XCTAssertTrue(any(app, "ptt-channel-row-1").label.contains("تردد ١"))

        /* The knob: ٣. */
        any(app, "ptt-knob-3").tap()
        let row3 = any(app, "ptt-channel-row-3")
        XCTAssertTrue(((row3.value as? String) ?? "").contains("التردد الحالي"), "٣ is the current channel: \(String(describing: row3.value))")
        shot(app, "03-tuned-3")

        /* The demo's owner is «أمير الرحلة»: «+ تردد خاص». */
        let create = app.buttons["ptt-channel-create"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(create.exists && create.isHittable) { list.swipeUp() }
        XCTAssertTrue(create.waitForExistence(timeout: 3), "«+ تردد خاص» for the leader")
        create.tap()
        let name = app.textFields["ptt-private-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("الأمامية")
        any(app, "ptt-private-member-أبو فهد").tap()
        any(app, "ptt-private-member-سلطان").tap()
        shot(app, "04-create-private")
        app.buttons["ptt-private-save"].tap()

        /* Opened and tuned to it. */
        let row = any(app, "ptt-channel-row-private-الأمامية")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        shot(app, "05-private-listed")
        app.buttons["ptt-channels-done"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.contains("الأمامية"), "the chip says which channel: \(chip.label)")
        shot(app, "06-chip-private")

        /* Manage → close: back on ١. */
        chip.tap()
        let manage = app.buttons["ptt-channel-manage-الأمامية"]
        for _ in 0..<4 where !(manage.exists && manage.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        let close = any(app, "ptt-private-close")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let confirms = app.buttons.matching(identifier: "أغلق التردد")
        XCTAssertTrue(confirms.firstMatch.waitForExistence(timeout: 3))
        sleep(1)
        confirms.allElementsBoundByIndex.last { $0.isHittable }?.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "closed")
        app.buttons["ptt-channels-done"].tap()
        XCTAssertTrue(chip.label.contains("تردد ١"), "back on ١: \(chip.label)")
    }
}
