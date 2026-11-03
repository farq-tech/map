import XCTest

/// Launches the real app on the simulator. `-demo` loads a fixed, clearly
/// labelled outing so the map can be checked without a server; `-resetState`
/// wipes identity and consent first.
final class SaryAlbarqUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOnboardingAppearsWithoutIdentity() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"]
        app.launch()
        XCTAssertTrue(app.textFields["onboarding.name"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.start"].isEnabled, "no name, no start")
        app.textFields["onboarding.name"].tap()
        app.textFields["onboarding.name"].typeText("سعد")
        XCTAssertTrue(app.buttons["onboarding.start"].isEnabled)
        attach(app, "onboarding")
    }

    func testLiveMapShowsMembersAndFreshness() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 15) || app.maps.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["أبو فهد"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["مباشر"].exists, "a fresh moving fix is live")
        XCTAssertTrue(app.staticTexts["آخر موقع"].exists, "a 95 s old parked fix is last-known, not live")
        XCTAssertTrue(app.staticTexts["انقطع"].exists, "nothing heard for 4 min is lost")
        app.tap() // lets the interruption monitor run if a prompt is up
        app.buttons["live.fit"].tap()
        sleep(2)
        attach(app, "live-map")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
