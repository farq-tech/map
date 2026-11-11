import CoreLocation
import XCTest

/// Build 11 bug (TestFlight recording 2026-11-05): on a trip that had ended («انتهت الطلعة»),
/// «أدوات الطلعة» closed by itself about a second after opening, and the screen kept every live
/// control as if the trip were still on. Demo outing: the leader ends the trip, then the screen
/// must say so clearly and every sheet must stay until the person closes it.
final class LiveEndedUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let here = CLLocationCoordinate2D(latitude: 24.7062, longitude: 46.6611)

    /// A GPS tick a few metres away: each one used to re-run the session-changed path.
    private func wobble(_ k: Int) {
        let d = Double(k % 4) * 0.00002
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: here.latitude + d, longitude: here.longitude + d),
            altitude: 600, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The demo outing, arrived, ended by me (the leader) from the sheet's «الرحلة» card.
    private func launchEnded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0",
                               "-SaryContext", "stopped", "-SaryTrip", "arrived", "-SarySheetHalf"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        wobble(0)
        app.launch()
        /* The sheet opens at «نصف» (-SarySheetHalf). UI-AUDIT م3: ending is «المزيد» → «الطلعة» → «أنهِها». */
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 45), "«المزيد» in the quick row")
        XCTAssertTrue(app.endOutingFromMore(), "«تنهي الطلعة للكل؟» → «أنهِها»")
        XCTAssertTrue(app.buttons["trip.return"].waitForExistence(timeout: 10), "the trip has ended: «طلعة الرجعة» in the sheet")
        /* Back to the map with the sheet at its peek (where the floating «+» is). */
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        return app
    }

    func testEndedTripShowsAClearEndedState() {
        let app = launchEnded()
        let banner = app.descendants(matching: .any)["live.ended"]
        XCTAssertTrue(banner.waitForExistence(timeout: 8), "«الرحلة انتهت» over the map")
        XCTAssertTrue(app.buttons["live.ended.summary"].exists, "«اعرض الملخص»")
        XCTAssertTrue(app.buttons["live.ended.home"].exists, "«ارجع لطلعاتي»")
        /* Nothing that needs a running trip: no walkie-talkie, no SOS to an ended group. */
        XCTAssertFalse(app.buttons["outing-ptt"].exists, "«اضغط وتكلم» is gone once the trip ended")
        XCTAssertFalse(app.buttons["outing-sos"].exists, "SOS is gone once the trip ended")
        /* Lovable: the end card takes the header's place; no «إلى …» target after the end. */
        XCTAssertFalse(app.descendants(matching: .any)["trip.header"].exists, "the end card replaces the trip header")
        let title = app.descendants(matching: .any)["live.ended.title"]
        XCTAssertTrue(title.label.contains("انتهت"), title.label)
        XCTAssertFalse(title.label.contains("إلى "), "no «إلى …» target after the end: \(title.label)")
        /* The peek line says the trip ended rather than «٠ مباشر» next to my own moving car. */
        XCTAssertTrue(app.descendants(matching: .any)["outing-sheet-summary"].label.contains("انتهت"))
        attach(app, "ended-state")
    }

    func testToolsSheetStaysOpenUntilAChoiceAndNeverTurnsIntoTheNoteSheet() {
        let app = launchEnded()
        let plus = app.buttons["outing-actions"]
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "«+» in the floating group")
        plus.tap()
        let sheet = app.descendants(matching: .any)["outing-actions-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "«أدوات الطلعة» opens")
        attach(app, "tools-open")
        /* Six seconds of GPS ticks and live updates: it must still be there, and alone. */
        for k in 1...6 {
            wobble(k)
            sleep(1)
            XCTAssertTrue(sheet.exists, "«أدوات الطلعة» closed by itself after \(k) s")
            XCTAssertFalse(app.textFields["note-input"].exists, "the note sheet opened without being chosen")
        }
        /* Actions that need a running trip are not offered on an ended one. */
        XCTAssertFalse(app.buttons["outing-note-open"].exists, "«رسالة فوق سيارتي» on an ended trip")
        XCTAssertFalse(app.buttons["outing-stuck"].exists, "«غرّزت» on an ended trip")
        XCTAssertTrue(app.buttons["outing-search"].exists, "the map tools stay")
        app.buttons["outing-actions-close"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        /* Closing chose nothing: nothing else opens afterwards. */
        for k in 7...10 {
            wobble(k)
            sleep(1)
            XCTAssertFalse(app.textFields["note-input"].exists, "the note sheet opened after closing «أدوات الطلعة»")
            XCTAssertFalse(sheet.exists)
        }
    }

    func testAChosenSheetStaysOpenOnAnEndedTrip() {
        let app = launchEnded()
        let plus = app.buttons["outing-actions"]
        XCTAssertTrue(plus.waitForExistence(timeout: 8))
        plus.tap()
        app.buttons["outing-weather-tools"].tap()
        let weather = app.buttons["outing-weather"]
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        weather.tap()
        /* The chosen sheet arrives and stays (any one: the bug closed every modal). */
        let close = app.buttons["weather.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 6), "the weather sheet opens")
        for k in 1...4 {
            wobble(k)
            sleep(1)
            XCTAssertTrue(close.exists, "the weather sheet closed by itself after \(k) s")
        }
    }
}
