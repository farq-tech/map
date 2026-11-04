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
        XCTAssertTrue(app.buttons["onboarding.begin"].waitForExistence(timeout: 10), "the one-line idea first")
        XCTAssertTrue(app.buttons["onboarding.restore"].exists, "restore with a recovery code, no passwords")
        app.buttons["onboarding.begin"].tap()
        XCTAssertTrue(app.textFields["onboarding.name"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.start"].isEnabled, "no name, no start")
        app.textFields["onboarding.name"].tap()
        app.textFields["onboarding.name"].typeText("سعد")
        XCTAssertTrue(app.buttons["onboarding.start"].isEnabled)
        attach(app, "onboarding")
    }

    private func allowLocation() {
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// The new live screen over the map: status capsule, control cluster, SOS dock,
    /// and the native sheet with the participants (honest presence for each).
    func testLiveScreenShowsChromeAndParticipants() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm"]
        allowLocation()
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 15) || app.maps.firstMatch.waitForExistence(timeout: 5))
        // Tap the status bar, not the map centre: a demo car sits there and would open its card.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // lets the interruption monitor answer a permission prompt
        XCTAssertTrue(app.buttons["outing-back"].waitForExistence(timeout: 10), "status capsule")
        XCTAssertTrue(app.buttons["outing-fit"].exists, "control cluster")
        XCTAssertTrue(app.buttons["outing-locate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["outing-sos"].exists, "SOS dock")
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        XCTAssertTrue(app.buttons["المشاركون"].waitForExistence(timeout: 5) || app.staticTexts["المشاركون"].exists, "tabs at half height")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "participant-row").count, 4)
        XCTAssertTrue(app.staticTexts["أبو فهد"].exists)
        sleep(1)
        attach(app, "live-half")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testConsentComesBeforeSharingAndListIsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm"]
        allowLocation()
        app.launch()
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // answers the When-In-Use prompt; the map centre holds a car
        sleep(1)
        summary.tap()
        XCTAssertTrue(app.buttons["live.share"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["live.sharing"].exists, "nothing is shared before the press")
        app.buttons["live.share"].tap()
        XCTAssertTrue(app.buttons["consent.accept"].waitForExistence(timeout: 5), "no position leaves the phone before the consent sheet")
        sleep(1)
        attach(app, "consent")
        app.buttons["consent.accept"].tap()
        /* The consent sheet explained background sharing; iOS now offers «دائمًا». Keep «أثناء الاستخدام» here. */
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Keep Only While Using", "الإبقاء على أثناء الاستخدام فقط", "Allow While Using App", "السماح أثناء استخدام التطبيق"] where springboard.buttons[label].waitForExistence(timeout: 3) {
            springboard.buttons[label].tap()
            break
        }
        XCTAssertTrue(app.buttons["live.stopSharing"].waitForExistence(timeout: 10), "sharing starts only after consent")
        XCTAssertTrue(app.staticTexts["live.sharing"].exists, "visible sharing indicator")
        /* «أثناء الاستخدام» only: a persistent one-liner links to Settings to choose «دائمًا». */
        XCTAssertTrue(app.buttons["live.shareHint.settings"].waitForExistence(timeout: 5), "When-In-Use hint with a Settings link")
        sleep(1)
        attach(app, "sharing")
        /* Going back while sharing asks first (the back button is on the map, above the sheet). */
        let summaryNow = app.descendants(matching: .any)["outing-sheet-summary"]
        if !app.buttons["outing-back"].isHittable { summaryNow.tap() }
        XCTAssertTrue(app.buttons["outing-back"].waitForExistence(timeout: 5))
        app.buttons["outing-back"].tap()
        XCTAssertTrue(app.buttons["أوقف المشاركة وارجع"].waitForExistence(timeout: 5))
        app.buttons["أوقف المشاركة وارجع"].tap()
        XCTAssertTrue(app.buttons["list.create"].waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "outings-list")
    }
}
