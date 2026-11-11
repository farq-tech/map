import AVKit
import CoreLocation
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
        /* Keep this suite self-contained: the demo route starts by Kingdom Centre, so do not
         * rely on whoever launched xcodebuild having set the simulator's location beforehand. */
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        /* The live screen — or, with `-SaryNavDelay` short and a slow launch, the navigation UI
         * already over it (a presented sheet hides the live sheet's summary). */
        let ids = ["outing-sheet-summary", "nav.options", "nav.banner", "nav.rerouting", "nav.offroad", "nav.arrived", "nav.offroad.note"]
        let ready = NSPredicate { _, _ in ids.contains { app.descendants(matching: .any)[$0].exists } }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30), .completed, "the live screen")
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
            XCTAssertTrue(el(app, "map.navLabel.selected").waitForExistence(timeout: 20), "time/distance on the map")
            XCTAssertTrue(el(app, "map.navLabel").exists, "the alternative too")
            sleep(2)
            shot(app, "nav-options-\(m)")
            app.terminate()
        }
    }

    func testActiveGuidance() {
        for m in ["light", "dark", "drive"] {
            let app = launch(["-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3", "-SaryNavState", "guiding"] + mode(m))
            /* The debug route may wait 40 seconds for its first GPS fix and another 20 for
             * planning; the previous 15-second assertion expired before that supported path. */
            XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 75), "active guidance after the demo GPS and route setup")
            XCTAssertTrue(el(app, "nav.pip").exists, "live guidance can be opened as a floating PiP window")
            XCTAssertTrue(el(app, "nav.lanes").exists, "lanes")
            /* v2: «ثم …» only when the next turn is within 400 m (the demo's next turn is ~1 km away). */
            XCTAssertFalse(el(app, "nav.next").exists, "no «ثم» for a far next turn")
            XCTAssertTrue(el(app, "nav.speedLimit").waitForExistence(timeout: 5), "speed limit")
            XCTAssertTrue(el(app, "nav.bottomBar").exists)
            XCTAssertTrue(el(app, "nav.eta").exists)
            XCTAssertTrue(app.buttons["nav.end"].exists)
            sleep(2)
            shot(app, "nav-guidance-\(m)")
            if m == "light" {
                openTripOptions(app)
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

    func testGuidancePiPStartsAndRemainsOnHomeScreen() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw XCTSkip("The iOS Simulator does not provide system PiP; run this assertion on an iPhone.")
        }
        let app = launch(["-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3", "-SaryNavState", "guiding"] + mode("light"))
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 75), "active route guidance")
        let pipButton = el(app, "nav.pip")
        XCTAssertTrue(pipButton.waitForExistence(timeout: 5))
        pipButton.tap()
        let opened = NSPredicate(format: "value == %@", "مفتوحة")
        expectation(for: opened, evaluatedWith: pipButton)
        waitForExpectations(timeout: 12)

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 8), "PiP remains while the app is backgrounded")
        let attachment = XCTAttachment(screenshot: springboard.screenshot())
        attachment.name = "navigation-pip-on-home-screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pull the guidance sheet up from its grabber: «المسارات»، «مشاركة الوصول»، «الصوت»، «الخطوات»، «نظرة عامة».
    private func openTripOptions(_ app: XCUIApplication) {
        dragSheetUp(app)
        XCTAssertTrue(el(app, "nav.options.trip").waitForExistence(timeout: 5), "the trip options under the bar")
    }

    /// Drag the native sheet up by its grabber (just above the guidance bar) to «نصف».
    func dragSheetUp(_ app: XCUIApplication) {
        let bar = el(app, "nav.bottomBar")
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let end = start.withOffset(CGVector(dx: 0, dy: -360))
        start.press(forDuration: 0.08, thenDragTo: end)
    }

    /// The v2 HUD (Google-like clarity, Sary's colours): one big banner, the time left in the bottom bar,
    /// a red «إنهاء», four round buttons at most on the right, SOS kept, and the speed bottom-left.
    func testGuidanceHUDv2() {
        for m in ["drive", "dark"] {
            let app = launch(["-SaryNavDemo", "-SaryNavTraffic", Self.target, Self.hittin, "-SaryNavDelay", "3", "-SaryNavState", "guiding"] + mode(m))
            XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15), "the maneuver banner")
            XCTAssertTrue(el(app, "nav.distance").exists, "the distance, big")
            let title = el(app, "nav.instruction")
            XCTAssertTrue(title.label.contains("طريق مكة المكرمة"), title.label)
            XCTAssertLessThan(title.frame.height, 60, "the road on one line")
            XCTAssertFalse(el(app, "nav.banner.eta").frame.intersects(el(app, "nav.banner").frame), "the ETA left the banner")
            let remaining = el(app, "nav.remainingTime")
            XCTAssertTrue(remaining.waitForExistence(timeout: 5), "the time left")
            XCTAssertTrue(el(app, "nav.eta").label.contains("كم"), "«١٩ كم · ١٢:٥٦ ص»: \(el(app, "nav.eta").label)")
            let end = app.buttons["nav.end"]
            XCTAssertTrue(end.exists && end.isHittable, "a clear «إنهاء»")
            XCTAssertGreaterThan(end.frame.minY, app.frame.height * 0.75, "«إنهاء» is in the bottom bar")
            XCTAssertTrue(el(app, "outing-sos").exists, "SOS is never hidden while guiding")
            let round = ["outing-locate", "nav.search", "nav.mute", "nav.routes"].filter { el(app, $0).exists }
            XCTAssertGreaterThanOrEqual(round.count, 3, "the round buttons: \(round)")
            XCTAssertLessThanOrEqual(round.count, 4, "four at most")
            for id in round {
                XCTAssertGreaterThan(el(app, id).frame.midX, app.frame.width / 2, "\(id) on the right")
            }
            sleep(2)
            shot(app, "nav-hud-v2-\(m)")
            openTripOptions(app)
            for id in ["nav.opt.routes", "nav.opt.share", "nav.opt.voice"] {
                XCTAssertTrue(el(app, id).exists, id)
            }
            shot(app, "nav-hud-v2-options-\(m)")
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
        /* «ملاحة» lives in the «+» actions sheet (الطريق). */
        app.buttons["outing-actions"].tap()
        XCTAssertTrue(app.buttons["outing-navigate"].waitForExistence(timeout: 5), "«ملاحة» in «+»")
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

    /// The owner's build-20 report: «اتجه» on «انقطع إرسال …» opened Apple Maps. Now it asks while
    /// guiding («نغيّر الوجهة إلى آخر موقع نورة؟»), then plans in OUR map, labelled «آخر موقع معروف».
    func testSilentMemberDirectionsStayInApp() {
        let app = launch(["-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3", "-SaryNavState", "guiding", "-demoSilent",
                          "-SaryContext", "stopped"] + mode("light"))
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 20), "guidance is on")
        /* The card's own identifier covers its pills: find «اتجه» inside «silent-card». */
        let go = app.buttons.matching(NSPredicate(format: "(identifier == 'silent-go' OR identifier == 'silent-card') AND label == 'اتجه'")).firstMatch
        if !go.waitForExistence(timeout: 15), app.buttons["alerts.bell"].exists {
            app.buttons["alerts.bell"].tap()
        }
        XCTAssertTrue(go.waitForExistence(timeout: 10), "the silent card's «اتجه»")
        go.tap()
        let change = app.buttons["غيّر"]
        XCTAssertTrue(change.waitForExistence(timeout: 5), "guidance is on: ask before changing the destination")
        /* (SwiftUI wraps the interpolated name in bidi isolates.) */
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'نغيّر الوجهة إلى' AND label CONTAINS 'آخر موقع نورة'"))
            .firstMatch.exists, "the question names the target")
        shot(app, "nav-silent-retarget-confirm")
        change.tap()
        XCTAssertTrue(el(app, "nav.options").waitForExistence(timeout: 10), "planned in our own map, not Apple Maps")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.Maps").state, .notRunning, "Apple Maps never opened")
        /* (The sheet's own identifier covers its texts: match by label.) */
        let texts = app.staticTexts
        XCTAssertTrue(texts.matching(NSPredicate(format: "label == 'آخر موقع نورة'")).firstMatch.waitForExistence(timeout: 5), "the target's name")
        XCTAssertTrue(texts.matching(NSPredicate(format: "label BEGINSWITH 'آخر موقع معروف · قبل'")).firstMatch.exists, "labelled «آخر موقع معروف», never live")
        sleep(1)
        shot(app, "nav-silent-lastknown-options")
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
