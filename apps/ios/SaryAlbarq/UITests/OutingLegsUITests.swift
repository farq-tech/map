import XCTest

/// «الطلعة» و«المشوار» (ux/الطلعة-والمشوار.md) over the `-demo` outing (no server):
/// the leader starts the outing → «وين رايحين؟» → a destination → «ابدأ المشوار» → «وصلنا»
/// → a second leg → «أنهِ الطلعة» → the summary lists both legs. Members wait for the leader.
///
/// Simulator location: `xcrun simctl location <udid> set 24.7113,46.6744`.
/// SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) also writes the PNGs of each state.
final class OutingLegsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-demoNotStarted", "-demoPlanEmpty", "-SaryLegsDemo",
                               "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0", "-SaryWeatherDemo", "calm"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        /* A fresh install on a small simulator can take a while, and iOS may ask more than once. */
        let deadline = Date().addingTimeInterval(90)
        let cta = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'flow.cta.'")).firstMatch
        while !cta.exists && Date() < deadline {
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
            }
            /* The interruption monitor answers only on an interaction: nudge the app now and then. */
            if Int(Date().timeIntervalSince1970) % 5 == 0 { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap() }
            usleep(250_000)
        }
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "the big button")
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func line(_ app: XCUIApplication) -> String { el(app, "trip.header.line").label }

    private func waitLine(_ app: XCUIApplication, contains s: String, timeout: TimeInterval = 8) -> Bool {
        let p = NSPredicate { _, _ in self.line(app).contains(s) }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: timeout) == .completed
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 8) {
        let e = el(app, id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) shows")
        e.tap()
    }

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

    private func pick(_ app: XCUIApplication, _ name: String) {
        tap(app, "flow.cta.whereTo")
        XCTAssertTrue(el(app, "whereTo.sheet").waitForExistence(timeout: 6), "«وين رايحين؟»")
        let place = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 4), name)
        place.tap()
        XCTAssertTrue(waitLine(app, contains: "الوجهة \(name)"), "picked: \(line(app))")
    }

    func testLeaderTwoLegsThenEndAndSummary() {
        let app = launch([])
        XCTAssertTrue(waitLine(app, contains: "ما بدأت الطلعة"), line(app))
        XCTAssertTrue(el(app, "flow.cta.startOuting").exists)
        shot(app, "01-not-started-leader")

        tap(app, "flow.cta.startOuting")
        XCTAssertTrue(waitLine(app, contains: "الطلعة شغّالة"), line(app))
        XCTAssertTrue(el(app, "flow.cta.whereTo").waitForExistence(timeout: 5))
        shot(app, "03-outing-no-leg")

        /* Leg 1: → محطة الوقود. */
        pick(app, "محطة الوقود")
        shot(app, "04-picked")
        tap(app, "flow.cta.startLeg")
        XCTAssertTrue(waitLine(app, contains: "في الطريق إلى محطة الوقود"), line(app))
        shot(app, "05-on-leg")
        tap(app, "flow.cta.arrived")
        XCTAssertTrue(waitLine(app, contains: "واقفين عند محطة الوقود"), line(app))
        XCTAssertFalse(el(app, "flow.cta.endOuting").exists, "ONE primary button: «وين رايحين؟»")
        shot(app, "06-arrived")

        /* Leg 2: → مخيم النفود; the outing goes on. */
        pick(app, "مخيم النفود")
        tap(app, "flow.cta.startLeg")
        XCTAssertTrue(waitLine(app, contains: "في الطريق إلى مخيم النفود"), line(app))
        tap(app, "flow.cta.arrived")
        XCTAssertTrue(waitLine(app, contains: "واقفين عند مخيم النفود"), line(app))

        /* «أنهِ الطلعة» lives in «المزيد» → «الطلعة» (once) → confirm → the summary lists both legs. */
        shot(app, "07-stopped-second")
        let more = app.buttons["outing-actions"]
        if !more.waitForExistence(timeout: 3) { el(app, "outing-sheet-summary").tap() }
        XCTAssertTrue(more.waitForExistence(timeout: 6))
        more.tap()
        let end = el(app, "settings-end")
        for _ in 0..<8 where !(end.exists && end.isHittable) { app.swipeUp(); usleep(500_000) }
        XCTAssertTrue(end.waitForExistence(timeout: 6), "«أنهِ الطلعة» in the sheet")
        end.tap()
        let confirm = app.buttons["أنهِ الطلعة للجميع"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asked first")
        shot(app, "08-ending")
        confirm.tap()
        /* The ended screen offers «ملخص الطلعة» (some builds open the summary by themselves). */
        let summaryButton = el(app, "live.ended.summary")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !el(app, "summary.legs").exists {
            if summaryButton.exists, summaryButton.isHittable { summaryButton.tap(); break }
            usleep(300_000)
        }
        if !el(app, "summary.legs").waitForExistence(timeout: 8) { shot(app, "debug-after-end") }
        XCTAssertTrue(el(app, "summary.legs").waitForExistence(timeout: 10), "«المشاوير» in the summary")
        let rows = app.descendants(matching: .any).matching(identifier: "legs.row")
        XCTAssertEqual(rows.count, 2, "two legs")
        XCTAssertTrue(app.staticTexts["المشاوير (٢)"].exists || el(app, "summary.legs").label.contains("٢"))
        el(app, "summary.legs").scrollIntoView(in: app)
        shot(app, "09-summary")
    }

    func testInTripSearchOpensTheHomeDestinationSearch() {
        let app = launch([])
        tap(app, "flow.cta.startOuting")
        XCTAssertTrue(waitLine(app, contains: "الطلعة شغّالة"), line(app))
        tap(app, "outing-actions")
        tap(app, "outing-search")

        XCTAssertTrue(el(app, "home.search").waitForExistence(timeout: 8), "in-trip search uses the home search bar")
        XCTAssertFalse(el(app, "search.field").exists, "the old coordinate search screen is no longer used here")
    }

    /// Driving: the walkie-talkie is the big button, «وصلنا» is compact.
    func testOnALegWhileDriving() {
        let app = launch(["-SaryDrive", "1"])
        tap(app, "flow.cta.startOuting")
        XCTAssertTrue(waitLine(app, contains: "الطلعة شغّالة"), line(app))
        pick(app, "مخيم النفود")
        tap(app, "flow.cta.startLeg")
        XCTAssertTrue(waitLine(app, contains: "في الطريق إلى مخيم النفود"), line(app))
        XCTAssertTrue(el(app, "flow.cta.arrived").waitForExistence(timeout: 5))
        sleep(2)
        shot(app, "05b-on-leg-driving")
    }

    func testMemberWaitsForTheLeader() {
        let app = launch(["-SaryDemoMe", "00000000-0000-4000-8000-000000000002"])
        XCTAssertTrue(waitLine(app, contains: "بانتظار أمير الرحلة يبدأ"), line(app))
        XCTAssertTrue(el(app, "flow.cta.waitLeader").exists)
        XCTAssertFalse(el(app, "flow.cta.startOuting").exists, "only the leader starts")
        shot(app, "02-not-started-member")
    }
}
