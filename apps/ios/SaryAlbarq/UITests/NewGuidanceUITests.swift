import CoreLocation
import XCTest

/// The new guidance screen (`-SaryNewUI`, «الطلعة وقت القيادة»): the navBlue maneuver card, the compact
/// «طوارئ», the one bottom bar with the friends and the walkie-talkie, and the end controls with the new wording.
/// The flag-off screen is covered by `NavigationUITests`.
/// SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) also writes PNGs; SARY_SHOT_TAG names the device in the file.
final class NewGuidanceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let target = "-SaryNavTo"
    private static let hittin = "24.7220,46.6650,حطين"

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryNewUI", "-SaryScheme", "dark", "-SaryDrive", "0", "-SaryNight", "0",
                               "-SaryNavDemo", Self.target, Self.hittin, "-SaryNavDelay", "3", "-SaryNavState", "guiding"] + extra
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 60), "the maneuver card")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let tag = ProcessInfo.processInfo.environment["SARY_SHOT_TAG"] ?? ""
        let full = "guidance-\(name)\(tag.isEmpty ? "" : "-\(tag)")"
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = full
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(full).png"))
        }
    }

    func testCardAndOneBar() {
        let app = launch()
        XCTAssertTrue(el(app, "nav.distance").exists, "the distance, big")
        let title = el(app, "nav.instruction")
        XCTAssertTrue(title.label.contains("طريق مكة المكرمة"), title.label)
        XCTAssertLessThan(title.frame.height, 100, "the instruction on two lines at most")
        XCTAssertTrue(el(app, "nav.remainingTime").waitForExistence(timeout: 5), "the time left")
        XCTAssertTrue(el(app, "nav.eta").label.contains("كم"), el(app, "nav.eta").label)
        let end = app.buttons["nav.end"]
        XCTAssertTrue(end.exists && end.isHittable, "the stop button")
        XCTAssertTrue(end.label.contains("أوقف التوجيه"), end.label)
        XCTAssertGreaterThan(end.frame.minY, app.frame.height * 0.7, "in the bottom bar")
        XCTAssertTrue(app.buttons["nav.more"].isHittable, "«المزيد»")
        let bar = el(app, "nav.bottomBar").frame
        XCTAssertTrue(el(app, "nav.friends").exists, "«… معك»")
        let ptt = el(app, "outing-ptt")
        XCTAssertTrue(ptt.exists)
        XCTAssertTrue(bar.contains(CGPoint(x: ptt.frame.midX, y: ptt.frame.midY)), "the mic is in the bar")
        XCTAssertTrue(el(app, "nav.progress").exists || el(app, "nav.surfaceAhead").exists, "progress or surfaces")
        let sos = el(app, "outing-sos")
        XCTAssertTrue(sos.exists)
        XCTAssertGreaterThanOrEqual(sos.frame.width, 44)
        XCTAssertLessThan(sos.frame.width, 72, "compact (48 pt disc + padding) under the card, not the 60 pt one")
        XCTAssertGreaterThan(sos.frame.minY, el(app, "nav.banner").frame.minY)
        XCTAssertTrue(el(app, "map.layers").exists || app.buttons["map.layers"].exists, "the shared layers button")
        sleep(2)
        shot(app, "normal")
        app.terminate()
    }

    func testLargestTextStillFits() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 10))
        let bar = el(app, "nav.bottomBar").frame
        XCTAssertLessThanOrEqual(bar.maxX, app.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(bar.minX, app.frame.minX - 1)
        XCTAssertTrue(app.buttons["nav.end"].exists)
        sleep(2)
        shot(app, "axxl")
        app.terminate()
    }

    /// The Build 45 end sheet stays reachable, with the new wording; nothing ends until a row is chosen.
    func testEndSheetNewWording() {
        let app = launch()
        let end = app.buttons["nav.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        end.tap()
        let trip = el(app, "end.action.endTrip")
        let solo = el(app, "end.action.endSolo")
        XCTAssertTrue(trip.waitForExistence(timeout: 5) || solo.waitForExistence(timeout: 2), "the end sheet")
        let all = (trip.exists ? trip.label : "") + (solo.exists ? solo.label : "") + (el(app, "end.action.endOutingForAll").exists ? el(app, "end.action.endOutingForAll").label : "")
        XCTAssertFalse(all.contains("رحلة"), "«طلعة» / «مشوار», not «رحلة»: \(all)")
        XCTAssertTrue(all.contains("أوقف التوجيه") || all.contains("أنهِ المشوار"), all)
        /* One «طوارئ», the map's own: no floating copy over the end sheet (owner review). */
        XCTAssertFalse(el(app, "sos.overlay").exists, "no second «طوارئ» floating over the end sheet")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "outing-sos").count, 1, "a single «طوارئ»")
        shot(app, "end-sheet")
        app.terminate()
    }

    /// The compass closed (in every shot above) and open: the five options, the chosen one marked.
    func testCompassMenuOpens() throws {
        let app = launch()
        let compass = el(app, "live.compass")
        guard compass.waitForExistence(timeout: 25) else { throw XCTSkip("no recent GPS fix: the compass is hidden by design") }
        XCTAssertTrue(compass.isHittable)
        compass.tap()
        sleep(1)
        shot(app, "compass-menu")
        for id in ["destination", "back", "qibla", "rain", "spring"] {
            XCTAssertTrue(el(app, "live.compass.\(id)").waitForExistence(timeout: 5), id)
        }
        XCTAssertTrue(el(app, "live.compass.qibla").isEnabled)
        app.terminate()
    }

    /// A route with dirt on it (`-SaryNavSurfaces`): the bar shows the coloured strip of the surfaces in driving order and the
    /// line under it («زفلت … ← ترابي … ← بر مفتوح …»). The old shots had an all-asphalt route, so no strip was drawn.
    func testSurfaceStripShowsOnARouteWithDirt() {
        let app = launch(["-SaryNavSurfaces"])
        let strip = el(app, "nav.surfaceAhead")
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "the surface strip on a route with dirt")
        let bar = el(app, "nav.bottomBar").frame
        XCTAssertTrue(bar.contains(CGPoint(x: strip.frame.midX, y: strip.frame.midY)), "inside the one bar")
        XCTAssertFalse(el(app, "nav.progress").exists, "the thin progress bar gives way to the surfaces")
        let words = strip.label + " " + strip.value.debugDescription
        XCTAssertTrue(words.contains("أسفلت") || words.contains("زفلت") || strip.frame.width > 150, "the legend line: \(words)")
        sleep(2)
        shot(app, "surfaces")
        app.terminate()
    }

    /// The open compass list stays under the maneuver card (and its chips): never over its edge.
    func testCompassMenuStaysUnderTheCard() throws {
        let app = launch(["-SaryNavSurfaces"])
        let compass = el(app, "live.compass")
        guard compass.waitForExistence(timeout: 25) else { throw XCTSkip("no recent GPS fix: the compass is hidden by design") }
        compass.tap()
        sleep(1)
        let first = el(app, "live.compass.destination")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let card = el(app, "nav.banner").frame
        XCTAssertGreaterThanOrEqual(first.frame.minY, card.maxY + 4, "the list starts under the card: \(first.frame) vs \(card)")
        XCTAssertLessThanOrEqual(first.frame.maxX, app.frame.maxX + 1)
        let sos = el(app, "outing-sos")
        if sos.exists { XCTAssertGreaterThanOrEqual(first.frame.minY, sos.frame.maxY, "«طوارئ» stays uncovered by the list") }
        shot(app, "compass-menu-surfaces")
        app.terminate()
    }
}
