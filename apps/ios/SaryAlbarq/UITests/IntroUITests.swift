import XCTest

/// «مقدمة سينمائية»: plays on the first cold launch, a tap skips it, a relaunch within 6 h
/// does not replay it, and a launch for an invite link goes straight to the app.
///
/// The running intro animates every frame, which keeps XCUITest from ever seeing the app
/// idle; the tap test holds one frame with `-SaryIntroFreeze` (DEBUG) so it can query it.
final class IntroUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func intro(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["intro"].firstMatch }

    private func waitGone(_ e: XCUIElement, _ timeout: TimeInterval) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        wait(for: [gone], timeout: timeout)
    }

    func testIntroOnFirstColdLaunchAndTapSkips() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-SaryIntro", "1", "-SaryIntroFreeze", "3.0"]
        app.launch()
        XCTAssertTrue(intro(app).waitForExistence(timeout: 5), "the intro is up on the first cold launch")
        sleep(1)
        XCTAssertTrue(intro(app).exists, "a held frame stays until tapped")
        intro(app).tap()
        waitGone(intro(app), 2)
        XCTAssertTrue(app.buttons["onboarding.begin"].waitForExistence(timeout: 5), "the app is right behind it")
    }

    func testIntroEndsOnItsOwn() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-SaryIntro", "1"]
        app.launch()
        XCTAssertTrue(intro(app).waitForExistence(timeout: 5))
        waitGone(intro(app), 8)
        XCTAssertTrue(app.buttons["onboarding.begin"].exists)
    }

    func testRelaunchWithinSixHoursSkipsTheIntro() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-SaryIntro", "1"]
        app.launch()
        XCTAssertTrue(intro(app).waitForExistence(timeout: 5))
        waitGone(intro(app), 8)
        app.terminate()
        app.launchArguments = ["-SaryIntro", "1"]
        app.launch()
        /* Only the launch's night frame, crossfading out with the boot splash (≈1 s). */
        waitGone(intro(app), 3)
        XCTAssertTrue(app.buttons["onboarding.begin"].waitForExistence(timeout: 5))
    }

    func testInviteLinkLaunchSkipsTheIntro() {
        let app = XCUIApplication()
        /* First: a clean state where the intro WOULD play (a held frame is not counted as shown)… */
        app.launchArguments = ["-resetState", "-SaryIntro", "1", "-SaryIntroFreeze", "3.0"]
        app.launch()
        XCTAssertTrue(intro(app).waitForExistence(timeout: 5), "eligible: the intro plays on a plain launch")
        app.terminate()
        /* …then a cold launch for an invite link (no -resetState: the eligibility above stands). */
        app.launchArguments = ["-SaryIntro", "1"]
        let token = String(repeating: "A", count: 43)
        app.open(URL(string: "saryalbarq://join#\(token)")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitGone(intro(app), 1.5)
        sleep(2)
        XCTAssertFalse(intro(app).exists, "a launch for an invite never plays the intro")
    }
}
