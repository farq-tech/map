import XCTest

/// «الملاحة»: the route options, active guidance, reroute, the off-road last leg and
/// arrival, over the demo outing. Screens use the offline demo router (`-SaryNavDemo`);
/// `testLiveRiyadhDrive` uses real Mapbox routing and only runs with SARY_NAV_LIVE=1
/// while `xcrun simctl location … start` drives the simulator along a Riyadh route.
///
/// Set SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS for xcodebuild) to also write PNGs there.
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The simulator's location is set from outside (`xcrun simctl location <udid> set 24.7113,46.6744`,
    /// Olaya by Kingdom Centre, where the demo outing is; the live drive uses `simctl location start`).
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
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

    private static let target = "-SaryNavTo"
    private static let hittin = "24.7220,46.6650,حطين"
    private static let desert = "24.7420,46.6420,روضة في الصحراء"

    private func mode(_ m: String) -> [String] {
        switch m {
        case "dark": return ["-SaryScheme", "dark", "-SaryDrive", "0", "-SaryNight", "0"]
        case "drive": return ["-SaryScheme", "light", "-SaryDrive", "1", "-SaryNight", "0"]
        default: return ["-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0"]
        }
    }

    // MARK: screens

    func testRouteOptions() {
        for m in ["light", "dark", "drive"] {
            let app = launch(["-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3"] + mode(m))
            XCTAssertTrue(el(app, "nav.options").waitForExistence(timeout: 15), "the route options sheet")
            XCTAssertTrue(el(app, "nav.route.selected").waitForExistence(timeout: 10), "routes listed")
            XCTAssertTrue(app.switches["nav.opt.fastest"].exists || el(app, "nav.opt.fastest").exists)
            XCTAssertTrue(el(app, "map.navLabel.selected").waitForExistence(timeout: 8), "time/distance on the map")
            XCTAssertTrue(el(app, "map.navLabel").exists, "the alternative too")
            sleep(2)
            shot(app, "nav-options-\(m)")
            app.terminate()
        }
    }

    func testActiveGuidance() {
        for m in ["light", "dark", "drive"] {
            let app = launch(["-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3", "-SaryNavState", "guiding"] + mode(m))
            XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15))
            XCTAssertTrue(el(app, "nav.lanes").exists, "lanes")
            XCTAssertTrue(el(app, "nav.next").exists, "next maneuver")
            XCTAssertTrue(el(app, "nav.speedLimit").waitForExistence(timeout: 5), "speed limit")
            XCTAssertTrue(el(app, "nav.bottomBar").exists)
            XCTAssertTrue(el(app, "nav.eta").exists)
            XCTAssertTrue(app.buttons["nav.end"].exists)
            sleep(2)
            shot(app, "nav-guidance-\(m)")
            if m == "light" {
                app.buttons["nav.stepsButton"].tap()
                XCTAssertTrue(el(app, "nav.steps").waitForExistence(timeout: 5))
                sleep(1)
                shot(app, "nav-steps-light")
                app.buttons["nav.steps.close"].tap()
                app.buttons["nav.end"].tap()
                XCTAssertTrue(el(app, "nav.banner").waitForNonExistence(timeout: 5), "«إنهاء» ends guidance")
            }
            app.terminate()
        }
    }

    func testRerouteOffRoadArrival() {
        let cases: [(String, String, String, String)] = [
            ("reroute", Self.hittin, "nav.rerouting", "drive"),
            ("reroute", Self.hittin, "nav.rerouting", "light"),
            ("offroad", Self.desert, "nav.offroad", "light"),
            ("offroad", Self.desert, "nav.offroad", "drive"),
            ("arrived", Self.hittin, "nav.arrived", "light"),
            ("arrived", Self.hittin, "nav.arrived", "dark"),
        ]
        for (state, to, id, m) in cases {
            var extra = ["-SaryNavDemo", Self.target, to, "-SaryNavDelay", "3", "-SaryNavState", state] + mode(m)
            if state == "offroad" { extra.append("-SaryNavOffRoad") }
            let app = launch(extra)
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 15), id)
            sleep(2)
            shot(app, "nav-\(state)-\(m)")
            app.terminate()
        }
    }

    func testOffRoadNoteInOptions() {
        let app = launch(["-SaryNavDemo", "-SaryNavOffRoad", Self.target, Self.desert, "-SaryNavDelay", "3"] + mode("light"))
        XCTAssertTrue(el(app, "nav.offroad.note").waitForExistence(timeout: 15), "«آخر جزء بدون طريق» before starting")
        sleep(2)
        shot(app, "nav-options-offroad-light")
    }

    func testStaleMemberIsRefused() {
        let app = launch(["-SaryNavDemo", "-SaryNavDelay", "3"] + mode("light"))
        /* «ملاحة» lives in «المزيد» (four cluster buttons stay on the map). */
        app.buttons["outing-more"].tap()
        XCTAssertTrue(app.buttons["outing-navigate"].waitForExistence(timeout: 5), "«ملاحة» in «المزيد»")
        app.buttons["outing-navigate"].tap()
        XCTAssertTrue(el(app, "nav.picker").waitForExistence(timeout: 5))
        /* The demo has members whose last fix is minutes old: they explain instead of guiding. */
        let stale = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'nav.pick.member.' AND label CONTAINS 'قديم'")).firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 5), "a member with an old position is listed: \(app.buttons.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("nav.pick") }.map { $0.identifier + "=" + $0.label })")
        stale.tap()
        let reason = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ما نوجّهك'")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "a stale member is refused with the reason")
        XCTAssertFalse(el(app, "nav.options").exists, "no route is planned to an old position")
        shot(app, "nav-picker-light")
    }

    // MARK: live (real Mapbox routing + simulated drive)

    func testLiveRiyadhDrive() throws {
        guard ProcessInfo.processInfo.environment["SARY_NAV_LIVE"] == "1" else { throw XCTSkip("SARY_NAV_LIVE=1 only") }
        let app = launch(["-SaryNavTo", "24.7465,46.6386,حطين", "-SaryNavStart", "-SaryNavDelay", "4", "-SaryDrive", "1"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 40), "guidance started on a real route")
        shot(app, "live-1-start")
        var sawReroute = false
        var n = 2
        let deadline = Date().addingTimeInterval(9 * 60)
        while Date() < deadline {
            if el(app, "nav.arrived").exists { break }
            if !sawReroute, el(app, "nav.rerouting").exists {
                sawReroute = true
                shot(app, "live-\(n)-reroute"); n += 1
            }
            if Int(Date().timeIntervalSince1970) % 45 == 0 { shot(app, "live-\(n)"); n += 1 }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(el(app, "nav.arrived").waitForExistence(timeout: 5), "arrived")
        shot(app, "live-\(n)-arrived")
        /* The reroute banner can be up for under a second; the app log ("[NAV] event offRoute / rerouted") is the proof. */
        print("[NAV-UITEST] reroute banner seen: \(sawReroute)")
    }
}
