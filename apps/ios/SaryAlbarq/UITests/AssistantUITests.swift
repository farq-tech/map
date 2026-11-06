import XCTest

/// «اسأل سرى» in the `-demo` trip with the keyword rules only (no model downloaded on the
/// simulator): open from «أدوات», ask by text, get answers from the trip's own state, SOS is
/// explained and never sent, and driving shows the voice-only layout.
final class AssistantUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(context: String = "stopped", drive: String = "0") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", drive, "-SaryContext", context]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح", "OK", "حسنًا"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 30), "the live screen")
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

    private func open(_ app: XCUIApplication) {
        app.buttons["outing-actions"].tap()
        let tile = any(app, "outing-assistant")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "«أدوات» → «اسأل سرى»")
        tile.tap()
        XCTAssertTrue(any(app, "assistant.sheet").waitForExistence(timeout: 5))
    }

    private func ask(_ app: XCUIApplication, _ q: String) -> String {
        let field = any(app, "assistant.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(q + "\n")
        let answer = any(app, "assistant.answer")
        let asked = NSPredicate { _, _ in self.any(app, "assistant.question").label == q && answer.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: asked, object: nil)], timeout: 10), .completed, q)
        return answer.label
    }

    func testAskByTextWithTheKeywordRules() {
        let app = launch()
        open(app)
        XCTAssertTrue(any(app, "assistant.mic").exists, "the mic")
        XCTAssertTrue(any(app, "assistant.suggestion").exists, "suggestions")
        shot(app, "assistant-01-open")

        let where_ = ask(app, "وين ابو فهد")
        XCTAssertTrue(where_.contains("أبو فهد"), where_)
        XCTAssertTrue(where_.contains("مباشر") || where_.contains("قديم") || where_.contains("آخر موقع"), "live or stale, said: \(where_)")
        shot(app, "assistant-02-where-member")

        let all = ask(app, "وين الربع")
        XCTAssertTrue(all.contains("نورة") || all.contains("سلطان"), all)
        shot(app, "assistant-03-where-everyone")

        let left = ask(app, "كم باقي")
        XCTAssertTrue(left.contains("باقي") || left.contains("وجهة") || left.contains("وصلت") || left.contains("موقعك"), left)
        shot(app, "assistant-04-remaining")

        let sun = ask(app, "متى المغرب")
        XCTAssertTrue(sun.contains("المغرب") || sun.contains("الشمس") || sun.contains("موقعك"), sun)

        let unclear = ask(app, "احكي لي نكتة")
        XCTAssertTrue(unclear.contains("ما فهمت"), unclear)
        shot(app, "assistant-05-unclear-suggestions")
    }

    func testSOSIsExplainedNeverSent() {
        let app = launch()
        open(app)
        let a = ask(app, "ارسل استغاثة للربع")
        XCTAssertTrue(a.contains("ما أرسل"), a)
        XCTAssertTrue(any(app, "assistant.sos").waitForExistence(timeout: 3), "the SOS button is shown")
        shot(app, "assistant-06-sos-explained")
        sleep(2)
        XCTAssertFalse(app.staticTexts["أُرسلت"].exists, "nothing was sent")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "أرسلت طوارئ")).firstMatch.exists)
    }

    func testDrivingIsVoiceOnly() {
        let app = launch(context: "driving", drive: "1")
        app.buttons["outing-actions"].tap()
        let tile = any(app, "outing-assistant")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        XCTAssertTrue(any(app, "assistant.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "assistant.mic").exists)
        XCTAssertFalse(any(app, "assistant.field").exists, "no typing while driving")
        XCTAssertGreaterThanOrEqual(any(app, "assistant.mic").frame.width, 88, "a big mic")
        shot(app, "assistant-07-driving-voice-only")
        /* A suggestion chip asks by one tap. */
        any(app, "assistant.suggestion").tap()
        XCTAssertTrue(any(app, "assistant.answer").waitForExistence(timeout: 8))
        shot(app, "assistant-08-driving-answer")
    }
}
