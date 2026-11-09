import XCTest

/// «دعوة شخصية» with demo data (no server). The system contact picker runs out of
/// process, so `-SaryStubContact` hands back a contact as if one was tapped.
/// `TEST_RUNNER_SARY_INVITE_SHOTS=1` also writes PNGs next to the worktree
/// (`<worktree>-shots/`).
final class PersonalInvitesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard ProcessInfo.processInfo.environment["SARY_INVITE_SHOTS"] == "1" else { return }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = URL(fileURLWithPath: root.path + "-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func launchLive(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryDemoInvites", "-SaryStubContact", "فهد أخوي|+966 50 123 4567",
                               "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped"] + extra
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

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement, max: Int = 10) {
        var n = 0
        while !el.isHittable && n < max { app.swipeUp(); n += 1 }
    }

    /// The leader: the group list shows the invited member under the leader's name, and
    /// «ما شارك موقعه»; a contact becomes a personal invite ready to send.
    func testLeaderInvitesAContactAndSeesStatuses() {
        let app = launchLive()
        any(app, "outing-sheet-summary").tap()
        XCTAssertTrue(app.staticTexts["فهد أخوي"].waitForExistence(timeout: 5), "the inviter's name in the group list")
        XCTAssertTrue(any(app, "participant.nickname").exists, "their own name beside it")
        XCTAssertTrue(app.staticTexts["جوس"].exists)
        XCTAssertTrue(any(app, "participant.neverShared").exists, "«ما شارك موقعه» for a member without a location")
        shot(app, "1-group-list")
        /* «ادعُ ربعك» under the people opens the invites. */
        let invite = any(app, "sheet.invite")
        scrollTo(app, invite)
        invite.tap()

        let pick = app.buttons["invite.pickContact"]
        scrollTo(app, pick)
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "invite.list").exists, "per-person list")
        for s in ["joined", "opened", "sent", "expired"] {
            XCTAssertTrue(any(app, "invite.status.\(s)").exists, "status \(s)")
        }
        XCTAssertTrue(app.staticTexts["لم يفتحها"].exists)
        XCTAssertTrue(app.staticTexts["انضم"].exists)
        let open = app.switches["invite.openLinks"]
        XCTAssertTrue(open.exists)
        XCTAssertEqual(open.value as? String, "0", "the open link is off: personal invites only")
        XCTAssertFalse(any(app, "invite-qr").exists, "no open-link QR while it is off")
        shot(app, "2-invite-list")

        pick.tap()
        let name = app.textFields["invite.add.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "فهد أخوي", "the name as saved in contacts")
        XCTAssertEqual(app.textFields["invite.add.phone"].value as? String, "050 123 4567")
        shot(app, "3-confirm-contact")
        app.buttons["invite.add.create"].tap()

        let wa = app.buttons["invite.send.whatsapp"]
        XCTAssertTrue(wa.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["invite.send.sms"].exists)
        XCTAssertTrue(app.buttons["invite.send.share"].exists)
        let msg = app.staticTexts["invite.send.message"]
        XCTAssertTrue(msg.label.contains("فهد أخوي"), msg.label)
        XCTAssertTrue(msg.label.contains("https://"), "the link is in the message")
        shot(app, "4-send")
        app.buttons["invite.send.done"].tap()
        XCTAssertTrue(app.buttons["invite.pickContact"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "invite.status.sent").count, 2, "the new invite is «أُرسلت»")
    }

    /// Typing a person by hand: bad numbers are refused, and a name-only invite can still be created.
    func testManualInviteValidatesOptionalNumberAndAllowsNameOnly() {
        let app = launchLive()
        any(app, "outing-sheet-summary").tap()
        let invite = any(app, "sheet.invite")
        scrollTo(app, invite)
        invite.tap()
        let manual = app.buttons["invite.manual"]
        scrollTo(app, manual)
        manual.tap()
        let name = app.textFields["invite.add.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("ناصر")
        let phone = app.textFields["invite.add.phone"]
        phone.tap()
        phone.typeText("123")
        XCTAssertFalse(app.buttons["invite.add.create"].isEnabled, "not a number")
        phone.typeText("4567890")
        XCTAssertFalse(app.buttons["invite.add.create"].isEnabled, "1234567890 is not a Saudi mobile")
        phone.clearAndType("0551234567")
        XCTAssertTrue(app.buttons["invite.add.create"].isEnabled)

        /* Contacts are optional. A name-only single-use link can be shared directly. */
        phone.clearAndType("")
        XCTAssertTrue(app.buttons["invite.add.create"].isEnabled, "a phone number is optional for a person outside Contacts")
        app.buttons["invite.add.create"].tap()
        let send = app.buttons["invite.send.share"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the name-only invite should open its send options")
        XCTAssertFalse(app.buttons["invite.send.sms"].exists, "SMS needs a phone number")
        XCTAssertTrue(app.buttons["invite.send.whatsapp"].exists, "WhatsApp can open its recipient picker")
        XCTAssertTrue(app.buttons["invite.send.copy"].exists, "copy or share the one-time link manually")
        let message = app.staticTexts["invite.send.message"]
        XCTAssertTrue(message.label.contains("ناصر"), message.label)
        XCTAssertTrue(message.label.contains("https://"), message.label)
    }

    private func launchScreen(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", screen, "-SaryScheme", "light"]
        app.launch()
        return app
    }

    /// The person invited: told it is their personal invite and joins under that name;
    /// someone else with a used link is told «هذه الدعوة لشخص آخر».
    func testJoinScreens() {
        let mine = launchScreen("invite-personal")
        XCTAssertTrue(mine.descendants(matching: .any)["invite.personal"].waitForExistence(timeout: 10))
        XCTAssertTrue(mine.descendants(matching: .any)["invite.personal"].label.contains("فهد أخوي"), "joins under the inviter's name, no name field")
        XCTAssertFalse(mine.textFields["invite.myName"].exists)
        XCTAssertTrue(mine.buttons["invite.join"].label.contains("انضم للطلعة"), mine.buttons["invite.join"].label)
        shot(mine, "5-join-personal")
        let other = launchScreen("invite-taken")
        XCTAssertTrue(other.staticTexts["هذه الدعوة لشخص آخر"].waitForExistence(timeout: 10))
        shot(other, "6-join-taken")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let v = value as? String, !v.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count))
        }
        typeText(text)
    }
}

/// An invite link opened while a trip is on screen (QA build 15): the live sheet is always
/// presented, so the invite must come from inside it — even over another open sheet.
final class InviteDuringTripUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testInviteLinkOpenedDuringATripShowsTheJoinScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0",
                               "-SaryContext", "stopped", "-SaryDemoInviteDuringTrip", "25"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        let summary = app.descendants(matching: .any)["outing-sheet-summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        /* Another sheet is up when the link arrives: «+» (the actions). */
        app.buttons["outing-actions"].tap()
        XCTAssertTrue(app.buttons["invite.join"].waitForExistence(timeout: 40), "the join screen shows over the trip")
        XCTAssertTrue(app.staticTexts["invite.name"].exists)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "invite-during-trip"
        a.lifetime = .keepAlways
        add(a)
    }
}
