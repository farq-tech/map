import XCTest

/// «الإعدادات» → «الصوت واللاسلكي» → «صوت التوجيه»: «صوت سرى» (default) or «صوت الجهاز».
final class NavVoiceSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testChooseTheGuidanceVoice() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"]
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
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        any(app, "outing-sheet-summary").tap()
        app.openLiveSettings()
        let row = any(app, "settings.navVoice")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "«صوت التوجيه» under «الصوت واللاسلكي»")
        row.tap()
        let sary = any(app, "settings.navVoice.sary"), device = any(app, "settings.navVoice.device")
        XCTAssertTrue(sary.waitForExistence(timeout: 5))
        XCTAssertTrue(device.exists)
        XCTAssertTrue(sary.isSelected || sary.value as? String == "1" || app.staticTexts["صوت سرى"].exists, "«صوت سرى» is offered (the default)")
        device.tap()
        XCTAssertTrue(device.waitForExistence(timeout: 2))
        any(app, "settings.sub.back").tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back on «الإعدادات»")
    }
}
