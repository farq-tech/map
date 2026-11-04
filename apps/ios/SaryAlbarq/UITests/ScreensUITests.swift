import XCTest

/// The pages around the live map, with demo data (no server).
final class ScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    func testHomeListsOutingsByStateAndOpensSheets() {
        let app = launch(["-demo", "-SaryScreen", "home"])
        XCTAssertTrue(app.buttons["list.create"].waitForExistence(timeout: 10))
        for name in ["طلعة الثمامة (عرض تجريبي)", "مشوار العارض", "كشتة الخميس", "كشتة نفود الثويرات"] {
            XCTAssertTrue(app.staticTexts[name].exists, name)
        }
        XCTAssertTrue(app.staticTexts["جارية"].exists)
        XCTAssertTrue(app.staticTexts["متوقفة مؤقتًا"].exists)
        XCTAssertTrue(app.staticTexts["لم تبدأ"].exists)
        app.buttons["list.create"].tap()
        XCTAssertTrue(app.textFields["create.name"].waitForExistence(timeout: 5))
        app.buttons["page-close"].tap()
        app.buttons["list.join"].tap()
        XCTAssertTrue(app.textFields["paste.field"].waitForExistence(timeout: 5))
    }

    func testSettingsReachEveryPage() {
        let app = launch(["-demo", "-SaryScreen", "settings"])
        for (row, title) in [("settings.appearance", "المظهر"), ("settings.privacy", "الخصوصية"), ("settings.notifications", "التنبيهات"), ("settings.about", "حول سَرى البارق")] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 10), row)
            app.buttons[row].tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
            app.buttons["page-back"].firstMatch.tap()
        }
    }

    func testEndedOutingOpensItsSummary() {
        let app = launch(["-demo", "-SaryScreen", "home"])
        let ended = app.staticTexts["كشتة نفود الثويرات"]
        XCTAssertTrue(ended.waitForExistence(timeout: 10))
        ended.tap()
        XCTAssertTrue(app.descendants(matching: .any)["summary.stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["أبو فهد"].exists, "shared totals are listed")
    }

    func testInviteStates() {
        let expired = launch(["-demo", "-SaryScreen", "invite-expired"])
        XCTAssertTrue(expired.staticTexts["انتهت صلاحية الدعوة"].waitForExistence(timeout: 10))
        let valid = launch(["-demo", "-SaryScreen", "invite-valid"])
        XCTAssertTrue(valid.buttons["invite.join"].waitForExistence(timeout: 10))
        XCTAssertTrue(valid.staticTexts["كشتة نفود الثويرات"].exists)
    }

    func testRecoveryCodeNeedsAllCharacters() {
        let app = launch(["-demo", "-SaryScreen", "recovery-restore"])
        let field = app.textFields["recovery.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["recovery.submit"].isEnabled)
        field.tap()
        field.typeText("7K3Q-M9XD-2HPA-VR6T-WC4N-8B1F-ZJ5E")
        XCTAssertTrue(app.buttons["recovery.submit"].isEnabled)
    }

    func testOfflineHomeSaysSo() {
        let app = launch(["-demo", "-SaryScreen", "home", "-SaryOffline"])
        XCTAssertTrue(app.descendants(matching: .any)["offline-banner"].waitForExistence(timeout: 10))
    }
}
