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
        let entry = any(app, "chat.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "«المحادثات» first in the Group tab")
        XCTAssertTrue(any(app, "tab.badge").waitForExistence(timeout: 5), "unread badge on «المجموعة»")
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

    /// App Store 1.2: the message context menu offers «بلّغ عن الرسالة» and «احظر فلان», and
    /// blocking removes that sender's bubbles from the chat. (The reason picker is a submenu that
    /// XCUITest cannot open; it is covered in ChatModerationTests. Settings → «المحظورين» → «إلغاء
    /// الحظر» restoring messages is covered there too.)
    func testReportAndBlockFromAMessage() {
        let app = launch(["-SaryLiveSheet", "half", "-SaryLiveTab", "group"])
        let entry = any(app, "chat.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(any(app, "chat.row.group").waitForExistence(timeout: 5))
        any(app, "chat.row.group").tap()
        /* «أبو فهد» greets the group at the top of the demo chat: his bubble is the one we act on. */
        let his = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "هلا بالشباب")).firstMatch
        XCTAssertTrue(his.waitForExistence(timeout: 5), "a friend's message")
        let before = app.descendants(matching: .any).matching(identifier: "chat.bubble").count

        his.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["chat.menu.report"].waitForExistence(timeout: 4) || app.buttons["بلّغ عن الرسالة"].waitForExistence(timeout: 1), "«بلّغ عن الرسالة» in the menu")
        let block = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'احظر'")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 4), "«احظر فلان» in the menu")
        shot(app, "chat-10-message-menu")

        /* Block him: his bubbles leave the chat (the server also filters; the phone hides at once). */
        block.tap()
        let fewer = NSPredicate { _, _ in app.descendants(matching: .any).matching(identifier: "chat.bubble").count < before }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: nil)], timeout: 6), .completed, "his messages are gone")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "هلا بالشباب")).firstMatch.exists, "his greeting is gone")
        shot(app, "chat-11-after-block")
    }

    func testPlusOpensChatsInTwoTaps() {
        let app = launch()
        app.buttons["outing-actions"].tap()
        let item = any(app, "outing-chat")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "«+» → المحادثات")
        item.tap()
        XCTAssertTrue(any(app, "chat.home").waitForExistence(timeout: 5), "two taps from the map")
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
