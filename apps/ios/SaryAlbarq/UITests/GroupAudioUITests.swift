import XCTest

/// «إذاعة الطلعة» on the demo outing with a stubbed player (`-SaryStubAudio`):
/// no network, no sound. Screenshots: TEST_RUNNER_SARY_SHOTS=<dir>.
final class GroupAudioUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryStubAudio", "-SaryStubPlayer"] + extra
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
        let ready = any(app, "outing-sheet-summary").waitForExistence(timeout: 15) || any(app, "radio.sheet").exists || any(app, "media.sheet").exists
        XCTAssertTrue(ready)
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

    /// The leader picks إذاعة القرآن الكريم: it plays, and the map shows «يشغّل الآن».
    func testLeaderStartsAStation() {
        let app = launch(["-SaryOpenRadio"])
        XCTAssertTrue(any(app, "radio.sheet").waitForExistence(timeout: 8), "the «إذاعة الطلعة» sheet")
        XCTAssertTrue(any(app, "radio.idle").exists, "nothing plays yet")
        XCTAssertTrue(any(app, "radio.allowAll").exists, "the leader's «الكل يقدر يشغّل»")
        shot(app, "radio-1-leader-pick")
        let station = any(app, "radio.station.sba-quran")
        XCTAssertTrue(station.waitForExistence(timeout: 5))
        station.tap()
        let now = any(app, "radio.nowPlaying")
        XCTAssertTrue(now.waitForExistence(timeout: 5))
        XCTAssertTrue(now.label.contains("إذاعة القرآن الكريم"), now.label)
        XCTAssertTrue(app.buttons["radio.toggle"].exists, "the leader controls it for everyone")
        shot(app, "radio-2-leader-playing")
        any(app, "radio.close").tap()
        XCTAssertTrue(any(app, "radio.sheet").waitForNonExistence(timeout: 5))
        /* «تخفيف الزحمة» ٢: a ♪ in the header; its small control opens from it. */
        let note = any(app, "radio.header")
        XCTAssertTrue(note.waitForExistence(timeout: 5), "♪ in the header")
        let bar = any(app, "radio.bar.title")
        if !bar.exists { note.tap() }
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "«يشغّل الآن» on the map")
        XCTAssertTrue(bar.label.contains("إذاعة القرآن الكريم"))
        XCTAssertTrue(any(app, "radio.bar.toggle").exists)
        shot(app, "radio-3-map-now-playing")
    }

    /// A member: the leader started a station → «يشغّل الآن» appears by itself; «اسكت عندي» is local.
    func testMemberSeesNowPlayingAndMutes() {
        let app = launch(["-SaryRadioMember", "-SaryRadioRemote"])
        let note = any(app, "radio.header")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the leader's pick reaches the member: ♪ in the header")
        let bar = any(app, "radio.bar.title")
        /* The bar shows by itself for a few seconds when the track changes; the ♪ keeps it open. */
        sleep(6)
        XCTAssertFalse(bar.exists, "the bar folds back into the ♪")
        note.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.contains("إذاعة القرآن الكريم"))
        XCTAssertFalse(any(app, "radio.bar.toggle").exists, "a member does not control the trip")
        shot(app, "radio-4-member-now-playing")
        let mute = any(app, "radio.bar.mute")
        XCTAssertEqual(mute.label, "اسكت عندي")
        mute.tap()
        XCTAssertTrue(app.buttons["رجّع الصوت"].waitForExistence(timeout: 3), "muted here")
        XCTAssertTrue(app.staticTexts["ساكت عندك"].exists)
        shot(app, "radio-5-member-muted")
        any(app, "radio.bar.open").tap()
        XCTAssertTrue(any(app, "radio.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "radio.memberNote").exists, "only the leader picks")
        XCTAssertFalse(any(app, "radio.allowAll").exists)
        XCTAssertTrue(any(app, "radio.status").label.contains("ساكت عندك"))
        XCTAssertTrue(any(app, "radio.leave").exists)
        shot(app, "radio-6-member-sheet")
        any(app, "radio.mute").tap()
        XCTAssertTrue(app.buttons["radio.mute"].label.contains("اسكت عندي"), "unmuted again")
    }

    /// The «يوتيوب» sheet puts «إذاعة الطلعة» first, with YouTube's foreground-only note.
    func testYouTubeSheetPointsToRadio() {
        let app = launch(["-SaryOpenMedia", "mine"])
        XCTAssertTrue(any(app, "media.sheet").waitForExistence(timeout: 8))
        let note = any(app, "media.radio.note")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("للسيارة استخدم إذاعة الطلعة"))
        shot(app, "radio-7-youtube-sheet")
        any(app, "media.radio").tap()
        XCTAssertTrue(any(app, "radio.sheet").waitForExistence(timeout: 6), "opens «إذاعة الطلعة»")
    }
}
