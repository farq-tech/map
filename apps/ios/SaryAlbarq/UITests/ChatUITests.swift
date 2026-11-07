import XCTest

/// «المحادثات» in the `-demo` trip (an in-memory stub of the server: «أبو فهد» answers in the
/// group and reads what you send). Entry from the Group tab and «+», send / receive, ✓✓,
/// the unread badge, and «وقّف عشان تكتب» while driving.
final class ChatUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
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
        /* «-SaryChat» opens a thread over the live sheet, which may hide its summary. */
        let ready = NSPredicate { _, _ in self.any(app, "outing-sheet-summary").exists || self.any(app, "chat.thread").exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30), .completed, "the live screen (or the chat over it)")
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

    func testGroupTabEntryBadgeSendAndReceive() {
        let app = launch(["-SaryLiveSheet", "half", "-SaryLiveTab", "group"])
        let entry = any(app, "sheet.chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "«المحادثة» in the sheet's quick row")
        XCTAssertTrue(entry.label.contains("،"), "the unread count on it: \(entry.label)")
        shot(app, "chat-01-group-tab-badge")
        entry.tap()
        XCTAssertTrue(any(app, "chat.home").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "chat.row.group").exists, "the group conversation first")
        XCTAssertTrue(any(app, "chat.row.direct").exists, "then the members")
        shot(app, "chat-02-conversations")
        any(app, "chat.row.group").tap()
        XCTAssertTrue(any(app, "chat.thread").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "مخيم الشباب")).firstMatch.waitForExistence(timeout: 5), "a shared map point from «أبو فهد»")
        let fields = app.textViews.count > 0 ? app.textViews : app.textFields
        let input = fields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "the composer")
        input.tap()
        input.typeText("وينكم يا شباب؟")
        let send = app.buttons["chat.send"].exists ? app.buttons["chat.send"] : app.buttons["أرسل"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "send")
        send.tap()
        XCTAssertTrue(any(app, "chat.bubble.mine").waitForExistence(timeout: 5), "my bubble")
        XCTAssertTrue(any(app, "chat.receipt.read").waitForExistence(timeout: 6), "✓✓ once the others read it")
        XCTAssertTrue(app.staticTexts["تمام، وصلت 👍"].waitForExistence(timeout: 8), "the reply arrives live")
        shot(app, "chat-03-thread-sent-received")
        /* Back to the list: the group is read now. */
        let back = app.buttons["chat.back"].exists ? app.buttons["chat.back"] : app.buttons["رجوع"].firstMatch
        back.tap()
        XCTAssertTrue(any(app, "chat.home").waitForExistence(timeout: 5))
        shot(app, "chat-04-conversations-after")
    }

    /// App Store 1.2: a chat message's context menu offers «بلّغ عن الرسالة» and «احظر فلان».
    /// (SwiftUI context-menu items are not reliably tappable by XCUITest — see the reasons submenu —
    /// so the block/unblock effects and the report reasons are covered in ChatModerationTests.)
    func testMessageMenuOffersReportAndBlock() {
        let app = launch(["-SaryLiveSheet", "half", "-SaryLiveTab", "group"])
        let entry = any(app, "sheet.chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(any(app, "chat.row.group").waitForExistence(timeout: 5))
        any(app, "chat.row.group").tap()
        let his = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "هلا بالشباب")).firstMatch
        XCTAssertTrue(his.waitForExistence(timeout: 5), "a friend's message")

        his.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["chat.menu.report"].waitForExistence(timeout: 4) || app.buttons["بلّغ عن الرسالة"].exists, "«بلّغ عن الرسالة» in the menu")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'احظر'")).firstMatch.waitForExistence(timeout: 4), "«احظر فلان» in the menu")
        shot(app, "chat-10-message-menu")
    }

    func testQuickRowOpensChatsInOneTap() {
        let app = launch()
        let item = any(app, "sheet.chat")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "«المحادثة» in the quick row")
        item.tap()
        XCTAssertTrue(any(app, "chat.home").waitForExistence(timeout: 5), "one tap from the map")
    }

    func testQuickReplyAndLocationShare() {
        let app = launch(["-SaryChat", "group"])
        XCTAssertTrue(any(app, "chat.thread").waitForExistence(timeout: 10))
        let quick = app.buttons.matching(identifier: "chat.quick").element(boundBy: 0)
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        let before = app.descendants(matching: .any).matching(identifier: "chat.bubble.mine").count
        quick.tap()
        let mine = app.descendants(matching: .any).matching(identifier: "chat.bubble.mine")
        let deadline = Date().addingTimeInterval(5)
        while mine.count <= before && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertGreaterThan(mine.count, before, "a quick reply is one tap")
        XCTAssertTrue(any(app, "chat.shareLocation").exists, "«موقعي» in the same row")
    }

    func testNoTypingWhileDriving() {
        let app = launch(["-SaryChat", "group", "-SaryChatMoving"])
        XCTAssertTrue(any(app, "chat.thread").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["وقّف عشان تكتب"].waitForExistence(timeout: 5), "«وقّف عشان تكتب»")
        XCTAssertFalse(app.textViews.firstMatch.exists || app.textFields.firstMatch.exists, "no keyboard at speed")
        XCTAssertTrue(app.buttons.matching(identifier: "chat.quick").element(boundBy: 0).exists, "quick replies stay")
        XCTAssertTrue(any(app, "chat.ptt").exists, "and the walkie-talkie")
        shot(app, "chat-05-driving-block")
    }
}
