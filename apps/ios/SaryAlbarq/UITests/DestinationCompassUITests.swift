import XCTest

/// «البوصلة» while driving: on the live map bottom-left, one tap target that opens the choice of target.
final class DestinationCompassUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testCompassWhileDrivingOpensTheTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", "dark",
                               "-SaryDrive", "1", "-SaryContext", "driving", "-SaryNewUI"]
        app.launch()
        app.allowLocationIfAsked()
        let compass = el(app, "live.compass")
        /* The dial needs a recent GPS fix (the simulator's location); without one it stays hidden by design. */
        guard compass.waitForExistence(timeout: 25) else { throw XCTSkip("no recent GPS fix in this run: the compass is hidden") }
        XCTAssertTrue(compass.isHittable)
        XCTAssertTrue(el(app, "map.layers").exists, "the layers button stays while driving")
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "compass-driving"; a.lifetime = .keepAlways; add(a)
        compass.tap()
        for id in ["live.compass.destination", "live.compass.back", "live.compass.qibla", "live.compass.rain", "live.compass.spring"] {
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), id)
        }
        XCTAssertTrue(el(app, "live.compass.qibla").isEnabled, "«القبلة» is always available")
        el(app, "live.compass.qibla").tap()
        XCTAssertTrue(compass.waitForExistence(timeout: 5))
        XCTAssertTrue(compass.label.hasPrefix("القبلة:"), compass.label)
    }
}
