import XCTest

/// «ابدأ الطلعة» ⇒ turn-by-turn by itself until «وصلتوا», over the `-demo` outing (no server,
/// no production outing) with the offline demo router (`-SaryNavDemo`). `-SaryAutoNav` opts the
/// demo into the trip's automatic guidance (real outings always have it).
///
/// The simulator's location is set from outside (`xcrun simctl location <udid> set 24.7113,46.6744`,
/// Olaya, where the demo group is). SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) also writes PNGs.
final class TripAutoNavUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String], sheet: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryAutoNav", "-SaryNavDemo",
                               "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0", "-SaryWeatherDemo", "calm"]
            + (sheet.map { ["-SaryLiveSheet", $0] } ?? []) + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        /* The reinstall resets the location permission: answer iOS's prompt directly, whenever it shows. */
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(45)
        while !el(app, "outing-sheet-summary").exists && !el(app, "nav.bottomBar").exists && Date() < deadline {
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
            }
            usleep(250_000)
        }
        for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] where springboard.buttons[label].waitForExistence(timeout: 1.5) {
            springboard.buttons[label].tap()
        }
        if !(el(app, "outing-sheet-summary").exists || el(app, "nav.bottomBar").exists) { shot(app, "debug-launch") }
        XCTAssertTrue(el(app, "outing-sheet-summary").exists || el(app, "nav.bottomBar").exists, "the live screen")
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The leader presses «ابدأ الطلعة»: guidance starts with no other tap.
    func testStartTripStartsNavigation() {
        let app = launch(["-demoNotStarted"], sheet: "half")
        XCTAssertFalse(el(app, "nav.banner").exists, "nothing before the start")
        let start = el(app, "live.start")
        XCTAssertTrue(start.waitForExistence(timeout: 10), "«ابدأ الطلعة»")
        shot(app, "autonav-0-before-start")
        start.tap()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15), "turn-by-turn starts by itself")
        XCTAssertTrue(el(app, "nav.distance").exists, "the next manoeuvre's distance")
        XCTAssertTrue(el(app, "nav.instruction").exists, "the next manoeuvre")
        XCTAssertTrue(el(app, "nav.banner.eta").exists, "where to and the ETA, in the header")
        XCTAssertTrue(el(app, "nav.banner.eta").label.contains("روضة الثمامة"))
        XCTAssertFalse(el(app, "nav.options").exists, "no options sheet to tap through")
        XCTAssertTrue(el(app, "nav.auto.pause").waitForExistence(timeout: 5), "«أوقف التوجيه»")
        sleep(2)
        shot(app, "autonav-1-started")
    }

    /// An active trip opened (a member joining, or the app relaunched): guidance resumes by itself.
    func testOpeningAnActiveTripResumesNavigation() {
        let app = launch(["-SaryDrive", "1"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15))
        sleep(2)
        shot(app, "autonav-2-resumed-drive")
    }

    func testArrivalSaysWasaltuAndStops() {
        let app = launch(["-SaryAutoNavArrive", "6"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15))
        let title = el(app, "nav.arrived.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the arrival card")
        XCTAssertEqual(title.label, "وصلتوا")
        XCTAssertFalse(el(app, "nav.banner").exists, "guidance stopped")
        sleep(1)
        shot(app, "autonav-5-arrived")
        el(app, "nav.arrived.end").tap()
        sleep(6)
        XCTAssertFalse(el(app, "nav.banner").exists, "never restarts after arrival")
    }

    func testStopAdvancesToTheDestination() {
        let app = launch(["-demoPlanStops", "-SaryAutoNavArrive", "14"])
        let eta = el(app, "nav.banner.eta")
        XCTAssertTrue(eta.waitForExistence(timeout: 15))
        XCTAssertTrue(eta.label.contains("محطة الوقود"), "the next planned stop first: \(eta.label)")
        shot(app, "autonav-3-to-stop")
        XCTAssertTrue(el(app, "nav.arrived.title").waitForExistence(timeout: 20), "«وصلتوا» at the stop")
        shot(app, "autonav-4-at-stop")
        let next = NSPredicate(format: "label CONTAINS %@", "روضة الثمامة")
        expectation(for: next, evaluatedWith: eta)
        waitForExpectations(timeout: 25)
        XCTAssertTrue(el(app, "nav.banner").exists, "on to the destination by itself")
        XCTAssertTrue(el(app, "nav.arrived.title").waitForExistence(timeout: 25))
    }

    func testPauseAndResumeOnThisPhone() {
        let app = launch([])
        XCTAssertTrue(el(app, "nav.auto.pause").waitForExistence(timeout: 15))
        el(app, "nav.auto.pause").tap()
        let resume = el(app, "nav.auto.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "«استأنف التوجيه»")
        XCTAssertFalse(el(app, "nav.banner").exists)
        sleep(6)
        XCTAssertFalse(el(app, "nav.banner").exists, "paused stays paused")
        shot(app, "autonav-6-paused")
        resume.tap()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15), "back on")
    }

    func testOfflineFallsBackToTheArrowThenTheRoad() {
        let app = launch(["-SaryNavOfflineFor", "12", "-SaryNavRetry", "4"])
        let panel = el(app, "nav.offroad")
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "bearing guidance at once")
        XCTAssertTrue(panel.label.contains("بلا إنترنت · اتجاه مباشر"), panel.label)
        XCTAssertFalse(el(app, "nav.banner").exists, "no made-up route")
        sleep(1)
        shot(app, "autonav-7-offline-arrow")
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 30), "the road route once routing works again")
        shot(app, "autonav-8-online-again")
    }

    func testOffRoadLegAfterTheRoad() {
        let app = launch(["-SaryNavOffRoad", "-SaryAutoNavRouteEnd", "12", "-SaryDrive", "1"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 12), "the road part first")
        /* The plan's drawn route reaches the camp: the leg follows it («اسلك هذا المسار»). */
        let follow = el(app, "follow.title")
        let arrow = el(app, "nav.offroad")
        let deadline = Date().addingTimeInterval(20)
        while !follow.exists && !arrow.exists && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(follow.exists || arrow.exists, "switches to off-road guidance by itself")
        sleep(2)
        shot(app, "autonav-9-offroad")
    }
}
