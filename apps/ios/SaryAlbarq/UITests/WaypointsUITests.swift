import XCTest

/// Shared waypoints on the live map (demo outing, in-memory demo server).
final class WaypointsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-demoNoWaypoints"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for l in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // answers the location prompt
        sleep(2)
        return app
    }

    /// Long-press the map → pick «ماء», name it, add → the pin is on the map and in the
    /// sheet's list; its card offers «اتجه» and (mine) delete, which removes it.
    func testAddWaypointByLongPressThenDeleteIt() {
        let app = launch()
        let map = app.otherElements["outing.map"]
        /* An empty stretch of map (right of the demo cars; their chips and note bubbles open the member card). */
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.56)).press(forDuration: 1.3)
        /* The single long-press opens the point card; its «أضف نقطة» opens the composer. */
        let add = app.buttons["point.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the long-press point card")
        add.tap()
        let title = app.textFields["waypoint.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "the composer opens at the pressed spot")
        app.buttons["waypoint.kind.water"].tap()
        XCTAssertEqual(title.value as? String, "ماء", "the title follows the kind until edited")
        let note = app.textFields["waypoint.note"]
        note.tap()
        if !(note.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { sleep(1); note.tap() }
        note.typeText("للغسيل فقط")
        shot(app, "waypoint-compose")
        let save = app.buttons["waypoint.save"]
        if !save.isHittable { app.swipeUp() }
        save.tap()
        let pin = app.buttons.matching(identifier: "map.waypoint").firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 8), "the pin is drawn on the map")
        XCTAssertFalse(title.exists, "the composer closed")
        shot(app, "waypoint-on-map")

        /* Listed in the sheet. */
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let row = app.buttons.matching(identifier: "waypoint-row").firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "أنت")).firstMatch.exists, "who added it")
        row.tap()
        XCTAssertTrue(app.buttons["waypoint.go"].waitForExistence(timeout: 5), "«اتجه»")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "للغسيل فقط")).firstMatch.exists, "the note")
        shot(app, "waypoint-card")
        app.buttons["waypoint.delete"].tap()
        let confirm = app.buttons["احذفها للجميع"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["waypoint.go"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(identifier: "map.waypoint").firstMatch.exists, "gone from the map")
    }

    /// Without the server routes the app says «غير متاح بعد» instead of pretending.
    func testNotDeployedServerIsSaidHonestly() {
        let app = launch(["-demoFeaturesMissing"])
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let banner = app.descendants(matching: .any)["waypoints.unavailable"]
        for _ in 0..<4 where !banner.exists { app.swipeUp() }
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["waypoints.add"].exists, "no add button for a feature the server lacks")
    }

    /// Convoy: badges on «المقدمة» / «المؤخرة», an alert for the car that fell behind the
    /// tail (live fixes only), and the honest status in the sheet. Also the screenshots.
    private func convoyFlow(_ look: [String], _ name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryWeatherDemo", "calm", "-demoConvoy"] + look
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for l in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        let alert = app.descendants(matching: .any)["convoy-alert"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "ماجد is behind the tail by more than the gap")
        XCTAssertTrue(alert.label.contains("ماجد"), alert.label)
        let badges = app.descendants(matching: .any).matching(identifier: "car.convoy.badge").count
        let folded = app.descendants(matching: .any).matching(identifier: "car.group").count
        XCTAssertTrue(badges >= 1 || folded >= 1, "a badge, or (drive mode, crowded) the group chip holding those cars")
        sleep(3)
        shot(app, "convoy-map-\(name)")
        app.descendants(matching: .any)["outing-sheet-summary"].tap()
        let section = app.descendants(matching: .any)["convoy.section"]
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "convoy-sheet-\(name)")
        let rows = app.buttons.matching(identifier: "waypoint-row").firstMatch
        for _ in 0..<5 where !rows.isHittable { app.swipeUp() }
        sleep(1)
        shot(app, "waypoints-sheet-\(name)")
        if name == "light" {
            app.swipeDown(); app.swipeDown()
            let edit = app.buttons["convoy.edit"]
            for _ in 0..<4 where !edit.isHittable { app.swipeDown() }
            if edit.isHittable {
                edit.tap()
                XCTAssertTrue(app.buttons["convoy.save"].waitForExistence(timeout: 5))
                sleep(1)
                shot(app, "convoy-editor-light")
            }
        }
    }

    func testConvoyLight() { convoyFlow(["-SaryScheme", "light", "-SaryDrive", "0"], "light") }
    func testConvoyDark() { convoyFlow(["-SaryScheme", "dark", "-SaryDrive", "0"], "dark") }
    func testConvoyDrive() { convoyFlow(["-SaryScheme", "dark", "-SaryDrive", "1"], "drive") }
}
