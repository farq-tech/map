import XCTest

/// The outing's Live Activity as iOS draws it: Dynamic Island (compact and
/// expanded) over the Home Screen, and the Lock Screen. Uses the DEBUG
/// fixture `-SaryActivity <name>` (fixed numbers, never live data).
/// Set `SARY_SHOT_DIR` (TEST_RUNNER_SARY_SHOT_DIR) to also write PNGs there.
final class LiveActivityUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOT_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// iOS asks once, on the Lock Screen, whether this app may show Live Activities.
    private func allowActivitiesIfAsked() {
        for l in ["Allow", "Always Allow"] {
            let b = springboard.buttons[l]
            if b.waitForExistence(timeout: 2) { b.tap(); sleep(2) }
        }
    }

    private func lockAndWake() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(3)
    }

    private func run(_ scenario: String, expanded: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", "home", "-SaryActivity", scenario]
        app.launch()
        sleep(4)
        lockAndWake()
        allowActivitiesIfAsked()
        shot("activity-lock-\(scenario)")
        /* Unlock to the Home Screen: the activity moves to the Dynamic Island. */
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("activity-island-\(scenario)")
        if expanded {
            /* Long-press the island to expand it. */
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
            sleep(2)
            shot("activity-island-expanded-\(scenario)")
            XCUIDevice.shared.press(.home)
            sleep(1)
        }
        app.terminate()
    }

    func testActivityNormal() { run("normal", expanded: true) }
    func testActivitySOS() { run("sos", expanded: true) }
    func testActivityStale() { run("stale", expanded: false) }
    func testActivityNoGPS() { run("gps", expanded: false) }
}
