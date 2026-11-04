import XCTest

/// Joins a REAL outing on the production API from an invite link and opens the
/// live screen. Skipped unless `SARY_JOIN_LINK` is set (pass it as
/// `TEST_RUNNER_SARY_JOIN_LINK=saryalbarq://join#…` to xcodebuild), so a normal
/// test run never touches production.
final class LiveProductionTests: XCTestCase {
    func testJoinFromLinkAndOpenLiveScreen() throws {
        guard let link = ProcessInfo.processInfo.environment["SARY_JOIN_LINK"], let url = URL(string: link) else {
            throw XCTSkip("SARY_JOIN_LINK not set")
        }
        let name = ProcessInfo.processInfo.environment["SARY_NAME"] ?? "عبدالله"
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.begin"].waitForExistence(timeout: 10))
        app.buttons["onboarding.begin"].tap()
        let onboarding = app.textFields["onboarding.name"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        onboarding.tap()
        onboarding.typeText(name)
        app.buttons["onboarding.start"].tap()
        if app.buttons["onboarding.skipLocation"].waitForExistence(timeout: 15) { app.buttons["onboarding.skipLocation"].tap() }
        XCTAssertTrue(app.buttons["list.create"].waitForExistence(timeout: 20))
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Open", "فتح"] where springboard.buttons[label].waitForExistence(timeout: 3) {
            springboard.buttons[label].tap()
            break
        }
        let join = app.buttons["invite.join"].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 15))
        join.tap()
        XCTAssertTrue(app.buttons["outing-sheet-summary"].waitForExistence(timeout: 20), "the live screen opens")
        sleep(3)
    }
}
