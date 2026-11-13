import CoreLocation
import XCTest

/// Build 49, «بالسيارة» / «مشي» in the route options sheet (the same sheet in the old and the new design):
/// car is the default, picking «مشي» asks for the routes again (a walking time, no car options) and the choice
/// is remembered for the next launch. SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) also writes PNGs.
final class TravelModeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let target = "-SaryNavTo"
    private static let hittin = "24.7220,46.6650,حطين"

    private func launch(newUI: Bool, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-resetState"] : []) + ["-demo", "-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3",
                                                                 "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0"] + (newUI ? ["-SaryNewUI"] : [])
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
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

    private func openSheet(_ app: XCUIApplication) {
        XCTAssertTrue(el(app, "nav.options").waitForExistence(timeout: 45), "the route options sheet")
        XCTAssertTrue(el(app, "nav.route.selected").waitForExistence(timeout: 15), "routes listed")
    }

    private func changeAndRemember(newUI: Bool) {
        let tag = newUI ? "new" : "old"
        let app = launch(newUI: newUI)
        openSheet(app)
        /* Default: car. Both segments are there, the car options are shown. */
        XCTAssertTrue(el(app, "nav.mode.car").exists && el(app, "nav.mode.walk").exists, "the two-segment control")
        XCTAssertTrue(el(app, "nav.opt.fastest").exists, "car: the traffic option")
        XCTAssertFalse(el(app, "nav.mode.walkNote").exists)
        let carRoute = el(app, "nav.route.selected").label
        shot(app, "travelmode-car-\(tag)")

        el(app, "nav.mode.walk").tap()
        let note = el(app, "nav.mode.walkNote")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "walking note")
        XCTAssertFalse(el(app, "nav.opt.fastest").exists, "the car options are hidden on foot")
        XCTAssertFalse(el(app, "nav.opt.unpaved").exists)
        XCTAssertTrue(el(app, "nav.route.selected").waitForExistence(timeout: 15), "walking route listed")
        /* The routes were asked for again: the time changed (the demo road is ~6 min by car, an hour on foot). */
        let changed = NSPredicate { _, _ in self.el(app, "nav.route.selected").label != carRoute }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 15), .completed,
                       "walking time differs from \(carRoute)")
        XCTAssertTrue(app.staticTexts["ابدأ المشي"].waitForExistence(timeout: 5) || app.buttons["ابدأ المشي"].exists, "the start button says «ابدأ المشي»")
        shot(app, "travelmode-walk-\(tag)")
        app.terminate()

        /* Remembered: a new launch (state kept) opens on foot. */
        let again = launch(newUI: newUI, reset: false)
        openSheet(again)
        XCTAssertTrue(el(again, "nav.mode.walkNote").waitForExistence(timeout: 10), "walking is remembered")
        XCTAssertFalse(el(again, "nav.opt.fastest").exists)
        /* And back to the car. */
        el(again, "nav.mode.car").tap()
        XCTAssertTrue(el(again, "nav.opt.fastest").waitForExistence(timeout: 10), "car again")
        XCTAssertFalse(el(again, "nav.mode.walkNote").exists)
        again.terminate()
    }

    func testPickerChangesRoutesAndIsRememberedOldDesign() { changeAndRemember(newUI: false) }
    func testPickerChangesRoutesAndIsRememberedNewDesign() { changeAndRemember(newUI: true) }
}
