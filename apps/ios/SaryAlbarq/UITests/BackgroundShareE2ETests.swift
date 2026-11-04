import XCTest

/// End to end against a LOCAL API (never production): joins an outing from an invite
/// link, shares with «دائمًا» (pre-granted with `xcrun simctl privacy … grant location-always`),
/// sends the app to the background for a while (positions must keep arriving at the
/// server), comes back and presses stop (positions must stop). The shell side drives
/// `xcrun simctl location … start` and watches the server. Skipped unless both
/// `TEST_RUNNER_SARY_API_BASE` and `TEST_RUNNER_SARY_JOIN_LINK` are set.
final class BackgroundShareE2ETests: XCTestCase {
    func testSharingContinuesInTheBackgroundAndStopsOnStop() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SARY_API_BASE"], let link = env["SARY_JOIN_LINK"], let url = URL(string: link) else {
            throw XCTSkip("SARY_API_BASE / SARY_JOIN_LINK not set")
        }
        let backgroundSeconds = UInt32(env["SARY_BG_SECONDS"] ?? "90") ?? 90
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-SaryAPIBase", base]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.begin"].waitForExistence(timeout: 15))
        app.buttons["onboarding.begin"].tap()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("سائق")
        app.buttons["onboarding.start"].tap()
        if app.buttons["onboarding.skipLocation"].waitForExistence(timeout: 15) { app.buttons["onboarding.skipLocation"].tap() }
        XCTAssertTrue(app.buttons["list.create"].waitForExistence(timeout: 60))
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Open", "فتح"] where springboard.buttons[label].waitForExistence(timeout: 3) {
            springboard.buttons[label].tap()
            break
        }
        let join = app.buttons["invite.join"].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 15))
        join.tap()
        /* After a first join the app offers notifications with its own explainer: not now. */
        if app.buttons["notify.later"].waitForExistence(timeout: 8) { app.buttons["notify.later"].tap() }
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        sleep(2)
        summary.tap()
        XCTAssertTrue(app.buttons["live.share"].waitForExistence(timeout: 10))
        app.buttons["live.share"].tap()
        XCTAssertTrue(app.buttons["consent.accept"].waitForExistence(timeout: 5))
        app.buttons["consent.accept"].tap()
        XCTAssertTrue(app.buttons["live.stopSharing"].waitForExistence(timeout: 15), "sharing")
        XCTAssertTrue(app.descendants(matching: .any)["live.shareHint"].waitForExistence(timeout: 5), "«دائمًا»: the don't-force-quit note")
        print("SARY-E2E: sharing-started")
        sleep(10)
        XCUIDevice.shared.press(.home)
        print("SARY-E2E: background-start")
        sleep(backgroundSeconds)
        print("SARY-E2E: background-end")
        app.activate()
        XCTAssertTrue(app.buttons["live.stopSharing"].waitForExistence(timeout: 15), "still sharing after the background stretch")
        app.buttons["live.stopSharing"].tap()
        print("SARY-E2E: stopped")
        XCTAssertTrue(app.buttons["live.share"].waitForExistence(timeout: 10))
        /* Background again after stop: nothing must arrive now. */
        XCUIDevice.shared.press(.home)
        sleep(40)
        print("SARY-E2E: done")
    }
}
