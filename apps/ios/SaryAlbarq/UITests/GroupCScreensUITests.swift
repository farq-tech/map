import XCTest

/// Build 47, screens group C (communication and safety) in the new interface (`-SaryNewUI`), one debug
/// screen at a time (`-demo -SaryScreen <name>`). With the flag off the legacy screens are untouched
/// (`-SaryLegacyUI`). Shots: `SARY_SHOTS` dir, prefix `SARY_SHOT_PREFIX` (default `c`).
final class GroupCScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ screen: String, legacy: Bool = false, text: String? = nil, scheme: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", screen, "-SaryScheme", scheme, legacy ? "-SaryLegacyUI" : "-SaryNewUI"]
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
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "c"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    /// The unified window title: a ✕ of at least 44 pt on the left half of the screen.
    private func assertWindowTitle(_ app: XCUIApplication, close: String, file: StaticString = #filePath, line: UInt = #line) {
        let c = el(app, close)
        XCTAssertTrue(c.waitForExistence(timeout: 10), "the ✕ (\(close))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.frame.height, 44, file: file, line: line)
        XCTAssertLessThan(c.frame.midX, app.windows.firstMatch.frame.midX, "✕ on the left (RTL)", file: file, line: line)
    }

    // MARK: QR scanner

    func testQRScannerWithoutCameraOffersTypingByHand() {
        let app = launch("qr-scan")
        XCTAssertTrue(el(app, "qr.sheet").waitForExistence(timeout: 20))
        assertWindowTitle(app, close: "qr.close")
        let type = el(app, "qr.type")
        XCTAssertTrue(type.exists, "«اكتب الرمز بيدك»")
        XCTAssertGreaterThanOrEqual(type.frame.height, 57, "the one primary button is 58 pt")
        XCTAssertTrue(app.staticTexts["ما فيه كاميرا"].exists)
        shot("qr-no-camera")
    }

    func testQRScannerLegacyIsUntouched() {
        let app = launch("qr-scan", legacy: true)
        XCTAssertTrue(app.staticTexts["ما فيه كاميرا"].waitForExistence(timeout: 20))
        XCTAssertFalse(el(app, "qr.type").exists)
        XCTAssertFalse(el(app, "qr.sheet").exists)
    }

    // MARK: Enjad and emergency

    func testEnjadNewSheet() {
        let app = launch("enjad")
        XCTAssertTrue(el(app, "enjad.sheet").waitForExistence(timeout: 20))
        assertWindowTitle(app, close: "enjad.close")
        for id in ["enjad.whatsapp", "enjad.call", "enjad.sms", "enjad.message", "enjad.note"] { XCTAssertTrue(el(app, id).exists, id) }
        XCTAssertFalse(el(app, "solo.sos.call911").exists, "911 first only on a solo outing")
        XCTAssertGreaterThanOrEqual(el(app, "enjad.whatsapp").frame.height, 57)
        shot("enjad")
    }

    func testEnjadSoloPutsCall911First() {
        let app = launch("enjad-solo")
        XCTAssertTrue(el(app, "enjad.sheet").waitForExistence(timeout: 20))
        let call = el(app, "solo.sos.call911"), wa = el(app, "enjad.whatsapp")
        XCTAssertTrue(call.exists)
        XCTAssertLessThan(call.frame.minY, wa.frame.minY, "«اتصل ٩١١» is the first option")
        XCTAssertTrue(app.staticTexts["طوارئ"].exists, "«طوارئ», not «SOS»")
        XCTAssertFalse(app.staticTexts["SOS"].exists)
        shot("enjad-solo")
    }

    func testEnjadWithoutPhoneAndLargeText() {
        let app = launch("enjad-nophone", text: "UICTContentSizeCategoryAccessibilityXL")
        XCTAssertTrue(el(app, "enjad.addPhone").waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(el(app, "enjad.addPhone").frame.height, 44)
        shot("enjad-large")
    }

    func testEnjadLegacyIsUntouched() {
        let app = launch("enjad", legacy: true)
        XCTAssertTrue(el(app, "enjad.sheet").waitForExistence(timeout: 20))
        XCTAssertFalse(el(app, "enjad.close").exists)
    }

    // MARK: Offline maps

    func testOfflineMapsNewKeepsEveryPieceAndPinsTheOnePrimary() {
        let app = launch("offline-flow")
        XCTAssertTrue(el(app, "offline.usage").waitForExistence(timeout: 20), "the space used")
        assertWindowTitle(app, close: "offline.close")
        let add = el(app, "offline.add")
        XCTAssertTrue(add.exists, "«حمّل منطقة»")
        XCTAssertGreaterThanOrEqual(add.frame.height, 57, "the one primary button is 58 pt")
        XCTAssertGreaterThan(add.frame.midY, app.windows.firstMatch.frame.midY, "pinned at the bottom")
        XCTAssertTrue(app.staticTexts["الخرائط بلا إنترنت"].exists)
        shot("offline")
    }

    func testOfflineMapsLegacyIsUntouched() {
        let app = launch("offline-flow", legacy: true)
        XCTAssertTrue(el(app, "offline.add").waitForExistence(timeout: 20))
        XCTAssertFalse(el(app, "offline.close").exists)
    }

    // MARK: Live-screen sheets (the demo outing)

    private func launchLive(_ extra: [String], legacy: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryDrive", "0", "-SaryContext", "stopped",
                               legacy ? "-SaryLegacyUI" : "-SaryNewUI"] + extra
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    func testReturnTimerEditorNewHasTheOnePrimaryAndKeepsEveryControl() {
        let app = launchLive(["-SaryLiveModal", "timer"])
        XCTAssertTrue(el(app, "timer-save").waitForExistence(timeout: 30), "«اضبط…» is the primary")
        assertWindowTitle(app, close: "timer-close")
        XCTAssertGreaterThanOrEqual(el(app, "timer-save").frame.height, 57)
        for id in ["timer-due", "timer-quick-2", "timer-quick-3", "timer-quick-5", "timer-note"] { XCTAssertTrue(el(app, id).exists, id) }
        shot("timer-editor")
    }

    func testReturnTimerEditorSoloSaysPhoneOnly() {
        let app = launchLive(["-SarySolo", "24.7590,46.7491,روضة الثمامة", "-SaryNavDemo", "-SaryLiveModal", "timer"])
        let note = el(app, "timer-note")
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        XCTAssertTrue(note.label.contains("منبّه على جوالك فقط"), "solo: «منبّه على جوالك فقط»: \(note.label)")
        XCTAssertFalse(el(app, "timer-contact").exists, "nobody follows a solo outing")
        shot("timer-editor-solo")
    }

    func testReturnTimerEditorLegacyIsUntouched() {
        let app = launchLive(["-SaryLiveModal", "timer"], legacy: true)
        XCTAssertTrue(el(app, "timer-save").waitForExistence(timeout: 30))
        XCTAssertFalse(el(app, "timer-close").exists)
    }

    func testChatHomeAndThreadNewShowTheCountAndKeepTheirControls() {
        let app = launchLive(["-SaryChat", "home"])
        XCTAssertTrue(el(app, "chat.home").waitForExistence(timeout: 30))
        assertWindowTitle(app, close: "chat.home.close")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'في الطلعة'")).firstMatch.exists, "«N في الطلعة»")
        XCTAssertTrue(el(app, "chat.row.group").exists)
        shot("chat-home")
        el(app, "chat.row.group").tap()
        XCTAssertTrue(el(app, "chat.thread").waitForExistence(timeout: 10))
        for id in ["chat.back", "chat.close", "chat.input", "chat.send"] { XCTAssertTrue(el(app, id).exists, id) }
        shot("chat-thread")
    }

    func testWalkieTalkieChannelsNewHasTheWindowTitle() {
        let app = launchLive(["-SaryLiveModal", "ptt"])
        XCTAssertTrue(el(app, "ptt-channels-sheet").waitForExistence(timeout: 30))
        assertWindowTitle(app, close: "ptt-channels-done")
        XCTAssertTrue(el(app, "ptt-channel-knob").exists, "the channel knob stays")
        shot("ptt-channels")
    }

    func testEnjadFromTheLiveScreenNew() {
        let app = launchLive(["-SaryLiveModal", "enjad"])
        XCTAssertTrue(el(app, "enjad.sheet").waitForExistence(timeout: 30))
        assertWindowTitle(app, close: "enjad.close")
        shot("enjad-live")
    }
}
