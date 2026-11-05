import XCTest

/// «رسالة صوتية» on the demo outing (no server, `-SaryPTTTone`: a generated tone instead of the
/// microphone): tap the talk button → the recording bar with its timer and waveform → «أرسل» →
/// a second member («أبو فهد» in the demo) answers with the same clip a moment later and it plays
/// by itself on «فلان يتكلم…» → it is listed in «الرسائل الصوتية» in the channels sheet. Also
/// «احذف». Screenshots go to `SARY_SHOT_DIR` when set.
final class VoiceNotesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryPTTTone"]
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

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOT_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testRecordSendAndASecondMemberHearsIt() {
        let app = launch()
        let ptt = any(app, "outing-ptt")
        XCTAssertTrue(ptt.waitForExistence(timeout: 10))
        ptt.tap()

        /* Recording: the bar with «أرسل», «احذف», the timer and the waveform. */
        XCTAssertTrue(any(app, "voice-note-recording").waitForExistence(timeout: 5), "the recording bar")
        let send = app.buttons["voice-note-send"]
        XCTAssertTrue(send.exists)
        XCTAssertTrue(app.buttons["voice-note-cancel"].exists)
        let timer = any(app, "voice-note-timer")
        let t0 = timer.label
        sleep(3)
        XCTAssertNotEqual(timer.label, t0, "the timer runs: \(t0) → \(timer.label)")
        XCTAssertTrue(timer.label.contains("١:٠٠") || timer.label.contains("1:00"), "out of a minute: \(timer.label)")
        shot("vn-01-recording")
        send.tap()
        XCTAssertFalse(any(app, "voice-note-recording").waitForExistence(timeout: 1), "the bar goes once it is sent")

        /* The demo's second member answers with the same clip: it plays by itself. */
        let card = any(app, "voice-note-playing")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "«فلان يتكلم…» while it plays")
        let speaker = any(app, "voice-note-speaker")
        XCTAssertTrue(speaker.label.contains("يتكلم"), speaker.label)
        shot("vn-02-playing")
        /* ≈3 s of voice plus the cues, then it is over. */
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: card)
        waitForExpectations(timeout: 15)

        /* «الرسائل الصوتية» in the channels sheet lists it. */
        let chip = any(app, "ptt-channel-chip")
        if chip.waitForExistence(timeout: 5) {
            chip.tap()
            XCTAssertTrue(any(app, "ptt-channels-sheet").waitForExistence(timeout: 5))
            let row = any(app, "voice-note-row")
            let list = app.collectionViews.firstMatch
            for _ in 0..<6 where !row.exists { list.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "listed with a play button")
            shot("vn-03-list")
            app.buttons["ptt-channels-done"].tap()
        }
    }

    func testDeleteThrowsTheRecordingAway() {
        let app = launch()
        let ptt = any(app, "outing-ptt")
        XCTAssertTrue(ptt.waitForExistence(timeout: 10))
        ptt.tap()
        XCTAssertTrue(any(app, "voice-note-recording").waitForExistence(timeout: 5))
        sleep(1)
        app.buttons["voice-note-cancel"].tap()
        XCTAssertFalse(any(app, "voice-note-recording").waitForExistence(timeout: 1))
        /* Nothing was sent: nobody answers. */
        XCTAssertFalse(any(app, "voice-note-playing").waitForExistence(timeout: 4))
    }
}
