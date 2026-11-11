import CoreLocation
import XCTest

/// Reference screenshots of the live screen's contexts (driving, stopped, «أدوات الطلعة»,
/// exploring, ended, settings) for the «تخفيف الزحمة» review. Only runs when SARY_SHOTS is set
/// (TEST_RUNNER_SARY_SHOTS for xcodebuild); SARY_SHOT_PREFIX names the set (before / after).
final class DeclutterShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
    }

    /// SARY_SHOT_DESERT=1: the demo group, its plan and the simulator in the Great Nafud
    /// (demo-only launch arguments; the app code is the same).
    private var desert: Bool { ProcessInfo.processInfo.environment["SARY_SHOT_DESERT"] != nil }
    private var here: CLLocationCoordinate2D {
        desert ? CLLocationCoordinate2D(latitude: 28.30, longitude: 41.40) : CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744)
    }
    private var look: [String] {
        ["-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryNight", "0", "-SaryDrive", "0"]
            + (desert ? ["-SaryDemoShift", "3.5895,-5.2748", "-SaryDemoPlanName", "مخيم النفود", "-SaryDemoOutingName", "كشتة النفود الكبير"] : [])
    }
    private var navTarget: [String] {
        desert ? ["-SaryNavTo", "28.3485,41.4743,مخيم النفود", "-SaryNavState", "offroad", "-SaryNavOffRoad"]
            : ["-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavState", "guiding"]
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing"] + look + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: here, altitude: 600, horizontalAccuracy: 5,
                                                                     verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        /* A slow first launch can land on the welcome screen: launch again. */
        if app.buttons["ابدأ"].waitForExistence(timeout: 3) {
            app.terminate()
            app.launch()
            app.allowLocationIfAsked()
        }
        let ids = ["outing-sheet-summary", "nav.banner", "nav.offroad", "outing-actions-sheet"]
        let ready = NSPredicate { _, _ in ids.contains { app.descendants(matching: .any)[$0].exists } }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 40)
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SARY_SHOTS"] {
            let prefix = env["SARY_SHOT_PREFIX"].map { "\($0)-" } ?? ""
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png"))
        }
    }

    func test1Driving() {
        let app = launch(["-SaryContext", "driving", "-SaryNavDemo", "-SaryNavDelay", "3", "-SaryRadioRemote"] + navTarget)
        let ids = ["nav.banner", "nav.offroad"]
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ids.contains { app.descendants(matching: .any)[$0].exists } }, object: nil)], timeout: 20)
        sleep(4)
        shot(app, "1-driving")
    }

    func test2Stopped() {
        let app = launch(["-SaryContext", "stopped", "-SaryRadioRemote"])
        sleep(6)
        shot(app, "2-stopped")
    }

    func test3ToolsSheet() {
        let app = launch(["-SaryContext", "stopped", "-SaryLiveModal", "actions"])
        _ = app.descendants(matching: .any)["outing-actions-sheet"].waitForExistence(timeout: 10)
        sleep(2)
        shot(app, "3-tools-sheet")
    }

    func test4Exploring() {
        let app = launch(["-SaryContext", "stopped", "-SaryExplore", "-SaryHiRes"] + (desert ? ["-SaryExploreAt", "28.30,41.40"] : []))
        sleep(6)
        shot(app, "4-exploring")
    }

    func test5Ended() {
        let app = launch(["-SaryContext", "stopped", "-SaryTrip", "arrived", "-SarySheetHalf"])
        guard app.buttons["outing-actions"].waitForExistence(timeout: 30) else { return XCTFail("outing-actions") }
        guard app.endOutingFromMore() else { return XCTFail("end from «المزيد»") }
        _ = app.buttons["trip.return"].waitForExistence(timeout: 10)
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        if summary.waitForExistence(timeout: 5) { summary.tap() }
        sleep(3)
        shot(app, "5-ended")
    }

    func test6Settings() {
        let app = launch(["-SaryContext", "stopped", "-SaryLiveTab", "more"])
        sleep(3)
        shot(app, "6-settings")
        app.swipeUp()
        sleep(1)
        shot(app, "6-settings-2")
    }
}
