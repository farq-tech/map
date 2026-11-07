import CoreLocation
import XCTest

/// «دليل البر» on the home map: a desert chip lists real places nearest first (offline, from the
/// bundled gazetteer), draws them on the map, and a result opens the place card → «ابدأ» →
/// «مين معك؟». With SARY_SHOTS (TEST_RUNNER_SARY_SHOTS) it also saves the list and the map for
/// «نفود»، «روضة» and «مخيمات» near Riyadh.
final class DesertGazetteerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0",
                               "-SaryScreen", "home", "-SaryRainGreenOff"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح", "OK", "حسنًا"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753), altitude: 600,
                                                                     horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(any(app, "home.search").waitForExistence(timeout: 20))
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

    func testNufudChipListsRealPlacesAndStartsATrip() {
        let app = launch()
        any(app, "home.category.nufud").tap()
        XCTAssertTrue(any(app, "home.desert.result").waitForExistence(timeout: 10), "places from «دليل البر», no network needed")
        XCTAssertEqual(any(app, "home.results.heading").label, "النفود القريبة منك")
        XCTAssertTrue(any(app, "home.desert.attribution").exists, "OSM / GeoNames attribution under the list")
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(identifier: "home.desert.result").count, 3)
        any(app, "home.desert.result").tap()
        XCTAssertTrue(any(app, "home.place.name").waitForExistence(timeout: 8))
        any(app, "home.place.start").tap()
        XCTAssertTrue(any(app, "start.withFriends").waitForExistence(timeout: 8), "«ابدأ» → «مين معك؟»")
    }

    func testRainChipSaysSoonWithoutTheServer() {
        let app = launch()
        let rain = any(app, "home.category.rain")
        for _ in 0..<4 where !rain.isHittable { any(app, "home.categories").swipeLeft() }
        rain.tap()
        XCTAssertTrue(any(app, "home.desert.soon").waitForExistence(timeout: 10))
    }

    /// Visual proof (SARY_SHOTS only): list + map for «نفود»، «روضة»، «مخيمات».
    func testShotsNearRiyadh() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
        continueAfterFailure = true
        let app = launch()
        sleep(4)
        for (chip, name) in [("nufud", "nufud"), ("rawda", "rawda"), ("camps", "camps")] {
            let c = any(app, "home.category.\(chip)")
            for _ in 0..<4 where !c.isHittable { any(app, "home.categories").swipeLeft() }
            c.tap()
            XCTAssertTrue(any(app, "home.desert.result").waitForExistence(timeout: 10), chip)
            sleep(3)
            shot("\(name)-1-list")
            /* Collapse the sheet: the map with the outlines and numbered markers. */
            any(app, "home.sheet.handle").tap()
            sleep(5)
            shot("\(name)-2-map")
            any(app, "home.desert.result").tap()
            sleep(4)
            shot("\(name)-3-place")
            any(app, "home.place.close").tap()
            sleep(1)
            /* Off again (a second tap clears it) for the next chip. */
            let again = any(app, "home.category.\(chip)")
            if again.waitForExistence(timeout: 3) {
                for _ in 0..<4 where !again.isHittable { any(app, "home.categories").swipeRight() }
                again.tap()
            }
            sleep(1)
        }
    }
}
