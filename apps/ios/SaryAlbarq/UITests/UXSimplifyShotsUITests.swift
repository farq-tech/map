import CoreLocation
import XCTest

/// Visual proof for the UX simplification (docs/ux-simplify-inventory.md): the home map and its
/// sheet (collapsed / raised), search → place → «أنشئ طلعة» → «مين معك؟» → invite → the trip, the
/// profile sheet, settings, and the simplified outing sheet with «المزيد». Screenshots only run
/// with SARY_SHOTS (TEST_RUNNER_SARY_SHOTS for xcodebuild); they are written there.
final class UXSimplifyShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0"] + args
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح", "OK", "حسنًا"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
                                                                     horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func test1HomeAndTripStart() {
        let app = launch(["-SaryScreen", "home"])
        XCTAssertTrue(any(app, "home.search").waitForExistence(timeout: 45))
        sleep(5)
        shot("01-home-collapsed")
        any(app, "home.sheet.handle").tap()
        sleep(2)
        shot("02-home-expanded")
        app.swipeUp()
        sleep(1)
        shot("03-home-expanded-outings")
        any(app, "home.sheet.handle").tap()
        sleep(1)
        any(app, "home.category.restaurants").tap()
        _ = any(app, "home.result").waitForExistence(timeout: 15)
        sleep(2)
        shot("04-home-category-results")
        let first = any(app, "home.result")
        if first.exists { first.tap() } else {
            any(app, "home.search.clear").tap()
            any(app, "home.map").press(forDuration: 1.2)
        }
        let placeStart = any(app, "home.place.start")
        let placeSave = any(app, "home.place.save")
        XCTAssertTrue(placeStart.waitForExistence(timeout: 8))
        XCTAssertTrue(placeStart.isHittable, "Place start action should be reachable at the current Dynamic Type size")
        XCTAssertTrue(placeSave.isHittable, "Place save action should be reachable at the current Dynamic Type size")
        sleep(3)
        shot("05-home-place-card")
        any(app, "home.place.start").tap()
        XCTAssertTrue(any(app, "start.withFriends").waitForExistence(timeout: 8))
        sleep(2)
        shot("06-start-who-is-with-you")
        any(app, "start.withFriends").tap()
        /* Build 47: «ادعُ أصدقاءك» starts the trip at once (no second «ابدأ الطلعة»); the invite opens over the live map. */
        XCTAssertFalse(any(app, "create.start").waitForExistence(timeout: 2), "no invite step holding the start back")
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 25))
        shot("07-start-invite-over-live")
        let later = any(app, "share.always.later")
        if later.waitForExistence(timeout: 10) { later.tap() }
        sleep(5)
        shot("08-trip-started")
    }

    /// A manually selected map coordinate must stay the destination through the quick-start flow.
    /// This covers the exact «نقطة على الخريطة» card, independently of place-search results.
    func testMapPointCardSaveAndStartActions() {
        let app = launch(["-SaryScreen", "home"])
        let map = any(app, "home.map")
        XCTAssertTrue(map.waitForExistence(timeout: 20))

        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.2)
        let pointName = any(app, "home.place.name")
        XCTAssertTrue(pointName.waitForExistence(timeout: 8), "long-pressing the map should open the selected coordinate")
        XCTAssertEqual(pointName.label, "نقطة على الخريطة")

        let save = any(app, "home.place.save")
        XCTAssertTrue(save.isHittable, "the point-card save action must be tappable over the map")
        save.tap()
        XCTAssertEqual(save.label, "محفوظ", "saving the selected point should persist and update its state")

        let start = any(app, "home.place.start")
        XCTAssertTrue(start.isHittable, "the point-card start button must be tappable over the map")
        XCTAssertEqual(start.label, "أنشئ طلعة", "make clear that this creates a new outing; it is not immediate turn-by-turn navigation")
        start.tap()

        let chosenDestination = any(app, "start.destination")
        XCTAssertTrue(chosenDestination.waitForExistence(timeout: 8), "quick start must carry the selected point into the outing")
        XCTAssertTrue(chosenDestination.label.contains("نقطة على الخريطة"), chosenDestination.label)
    }

    func test2ProfileAndSettings() {
        let app = launch(["-SaryScreen", "home"])
        XCTAssertTrue(any(app, "home.profile").waitForExistence(timeout: 20))
        sleep(2)
        any(app, "home.profile").tap()
        XCTAssertTrue(any(app, "profile.sheet.settings").waitForExistence(timeout: 5))
        sleep(1)
        shot("09-profile-sheet")
        any(app, "profile.sheet.settings").tap()
        sleep(2)
        shot("10-home-settings")
        app.terminate()
        let app2 = launch(["-SaryScreen", "home"])
        XCTAssertTrue(any(app2, "home.profile").waitForExistence(timeout: 20))
        any(app2, "home.profile").tap()
        XCTAssertTrue(any(app2, "profile.sheet.favorites").waitForExistence(timeout: 5))
        any(app2, "profile.sheet.favorites").tap()
        sleep(2)
        shot("11-favorites")
    }

    func test3OutingSheet() {
        let app = launch(["-demoSharing", "-SaryContext", "stopped"])
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 30))
        sleep(6)
        shot("12-outing-peek-quick-row")
        any(app, "outing-sheet-summary").tap()
        sleep(2)
        shot("13-outing-half")
        any(app, "outing-actions").tap()
        XCTAssertTrue(any(app, "outing-actions-sheet").waitForExistence(timeout: 5))
        sleep(2)
        shot("14-more-sheet")
        app.swipeUp()
        sleep(2)
        shot("15-more-sheet-trip-rows")
        any(app, "outing-route").tap()
        _ = any(app, "panel.route").waitForExistence(timeout: 5)
        sleep(2)
        shot("16-panel-route")
        any(app, "panel.close").tap()
        sleep(3)
        any(app, "sheet.rally").tap()
        XCTAssertTrue(any(app, "panel.rally").waitForExistence(timeout: 8))
        sleep(2)
        shot("17-panel-rally")
        app.terminate()
        let app2 = launch(["-demoSharing", "-SaryContext", "stopped", "-SaryLiveTab", "more"])
        _ = any(app2, "settings.page").waitForExistence(timeout: 30)
        sleep(3)
        shot("18-outing-settings")
        app2.swipeUp()
        sleep(1)
        shot("19-outing-settings-2")
    }

}
