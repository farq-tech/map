import XCTest

/// «يوتيوب ← قناتي» on the demo outing with a stubbed player (`-SaryStubPlayer`),
/// so the test never needs YouTube or the network.
final class MediaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryStubPlayer"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح", "Allow Paste", "السماح باللصق"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        /* A fresh simulator asks for location first: an interaction lets the monitor answer it
         * (with «-SaryOpenMedia» the media sheet is already up and the prompt would hide the map). */
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        /* «-SaryOpenMedia» may already cover the live sheet with the media sheet. */
        let ready = app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 15)
            || app.descendants(matching: .any)["media.sheet"].exists
        XCTAssertTrue(ready)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testOpenPrivateChannelAndPlayALink() {
        let app = launch()
        any(app, "outing-sheet-summary").tap()
        /* «يوتيوب» (قناتي / قناة الطلعة) lives in the sheet's «المزيد» tab; also in «+» → الترفيه. */
        let moreTab = app.buttons["tab.more"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 5))
        moreTab.tap()
        let entry = any(app, "media.entry")
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "«يوتيوب» in the live sheet")
        entry.tap()
        XCTAssertTrue(any(app, "media.sheet").waitForExistence(timeout: 5), "the «يوتيوب» sheet")
        XCTAssertTrue(app.buttons["قناتي"].exists && app.buttons["قناة الطلعة"].exists, "two channels")
        XCTAssertTrue(any(app, "media.policy").exists, "says it stops in the background")

        let field = app.textFields["media.mine.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("not a link")
        app.buttons["media.mine.go"].tap()
        XCTAssertTrue(app.staticTexts["هذا مو رابط فيديو يوتيوب."].waitForExistence(timeout: 3), "invalid link")

        field.tap()
        field.press(forDuration: 0.1)
        field.clearAndType("https://youtu.be/dQw4w9WgXcQ?t=30")
        app.buttons["media.mine.go"].tap()
        XCTAssertTrue(any(app, "media.player.full").waitForExistence(timeout: 5), "the player, full size when parked")
        XCTAssertTrue(app.staticTexts["media.stub"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["media.stub"].label.contains("dQw4w9WgXcQ"), "the stub got the video id")
        XCTAssertTrue(app.buttons["media.mine.toggle"].exists)
        XCTAssertGreaterThanOrEqual(any(app, "media.player.full").frame.height, 200, "≥ 200 pt")

        /* «قناة الطلعة» is independent: idle in the demo. */
        app.buttons["قناة الطلعة"].tap()
        XCTAssertTrue(any(app, "media.outing.idle").waitForExistence(timeout: 5))
        app.buttons["قناتي"].tap()
        XCTAssertTrue(any(app, "media.close").exists, "STEP1 sheet still up after tab switch")
        app.buttons["media.mine.stop"].tap()
        XCTAssertTrue(any(app, "media.close").waitForExistence(timeout: 2), "STEP2 sheet still up after stop")
        XCTAssertTrue(any(app, "media.player.full").waitForNonExistence(timeout: 5))
        any(app, "media.close").tap()
        XCTAssertTrue(any(app, "media.sheet").waitForNonExistence(timeout: 5))
    }

    func testDrivingShowsTheCompactPassengerPlayer() {
        let app = launch(["-SaryMediaMoving", "-SaryOpenMedia", "mine", "-SaryMediaVideo", "dQw4w9WgXcQ"])
        XCTAssertTrue(any(app, "media.passengerNotice").waitForExistence(timeout: 8), "«للركّاب»")
        let compact = any(app, "media.player.compact")
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(compact.frame.width, 200, accuracy: 1)
        XCTAssertEqual(compact.frame.height, 200, accuracy: 1)
        app.buttons["media.passenger"].tap()
        XCTAssertTrue(any(app, "media.player.full").waitForExistence(timeout: 5), "«أنا راكب» → full size")
    }

    func testSharedChannelJoinFromTheAlertLane() {
        let app = launch(["-SaryMediaShared"])
        let join = app.buttons["media.notice.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 10), "«أبو فهد شغّل: … في قناة الطلعة»")
        XCTAssertTrue(app.staticTexts["media.notice.text"].label.contains("في قناة الطلعة"))
        join.tap()
        XCTAssertTrue(any(app, "media.player.full").waitForExistence(timeout: 8), "joined: the player follows")
        XCTAssertTrue(app.staticTexts["media.controller"].label.contains("أبو فهد"))
        XCTAssertTrue(app.buttons["media.takeover"].exists, "I lead the demo outing: «خذ التحكم»")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "media.queue.item").count, 2)
        app.buttons["media.takeover"].tap()
        XCTAssertTrue(app.buttons["media.toggle"].waitForExistence(timeout: 5), "controls after takeover")
        app.buttons["media.leave"].tap()
        XCTAssertTrue(app.buttons["media.join"].waitForExistence(timeout: 5))
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        if let v = value as? String, !v.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count))
        }
        typeText(text)
    }
}
