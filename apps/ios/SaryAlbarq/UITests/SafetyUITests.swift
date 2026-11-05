import XCTest

/// The safety pack on the demo outing (no server): «غرّزت» with confirm → my strip →
/// «طلعت»; a friend's stuck card with the reply buttons; the return-timer editor.
final class SafetyUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0"] + extra
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func testStuckConfirmStripAndClear() {
        let app = launch([])
        let more = any(app, "outing-more")
        XCTAssertTrue(more.waitForExistence(timeout: 20), "«المزيد» is in the control cluster")
        more.tap()
        let stuck = any(app, "outing-stuck")
        XCTAssertTrue(stuck.waitForExistence(timeout: 5), "«غرّزت» is behind «المزيد»")
        stuck.tap()
        let yes = app.buttons["إيه، غرّزت"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "a confirm, not a hold")
        XCTAssertFalse(any(app, "my-stuck-strip").exists, "nothing is sent before the confirm")
        yes.tap()
        XCTAssertTrue(any(app, "my-stuck-strip").waitForExistence(timeout: 5))
        let clear = any(app, "stuck-clear")
        XCTAssertTrue(clear.exists)
        clear.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: any(app, "my-stuck-strip"))
        waitForExpectations(timeout: 5)
    }

    func testFriendStuckCardReplies() {
        let app = launch(["-SarySafety", "stuck-friend"])
        let card = any(app, "safety-stuck-card")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let coming = any(app, "stuck-reply-coming")
        XCTAssertTrue(coming.exists)
        XCTAssertTrue(any(app, "stuck-reply-have_rope").exists)
        XCTAssertTrue(any(app, "stuck-reply-cant").exists)
        coming.tap()
        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: any(app, "stuck-reply-coming"))
        waitForExpectations(timeout: 5)
    }

    func testReturnTimerEditorNeedsAContact() {
        let app = launch(["-SarySafety", "editor"])
        let save = any(app, "timer-save")
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        XCTAssertFalse(save.isEnabled, "no contact name yet")
        let field = app.textFields["timer-contact"].exists ? app.textFields["timer-contact"] : any(app, "timer-contact")
        field.tap()
        field.typeText("أم فهد")
        XCTAssertTrue(save.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "timer-editor"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
