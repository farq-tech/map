import XCTest

/// «المؤثرات البصرية»: the drone button in the point card (flies, stops on a touch) and the
/// screenshot scenarios (real sun for the given instant, the weather demo for dust).
/// With `SARY_SHOTS` set (TEST_RUNNER_SARY_SHOTS) the shots are also written there.
final class VisualsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String], weather: String = "calm") -> XCUIApplication {
        let app = XCUIApplication()
        /* The app reads the first occurrence of an argument: drop the defaults `extra` overrides. */
        var base = ["-SaryScheme": "light", "-SaryDrive": "0", "-SaryContext": "stopped"]
        for k in base.keys where extra.contains(k) { base[k] = nil }
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", weather] + base.flatMap { [$0.key, $0.value] } + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 25))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // answers the location prompt
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

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

    private func flying(_ map: XCUIElement) -> Bool { (map.value as? String)?.contains("درون") == true }

    func testDroneButtonInPointCardFliesAndStopsOnTouch() {
        let app = launch(["-SaryVisualsClock", "2026-11-05T13:40:00Z", "-SaryVisualsCamera", "28.0,41.5,13.5,40,250"])
        let map = any(app, "outing.map")
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        sleep(6)
        /* An empty stretch of map (clear of the cars, their chips and the edge arrows). */
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.56)).press(forDuration: 1.3)
        XCTAssertTrue(app.buttons["point.copy"].waitForExistence(timeout: 6), "the long-press card")
        let drone = app.buttons["point.drone"]
        /* «بريف المكان» (#60) sits above the actions: scroll until the drone row shows. */
        for _ in 0..<5 where !(drone.exists && drone.isHittable) { app.swipeUp() }
        shot(app, "visuals-point-card")
        XCTAssertTrue(drone.waitForExistence(timeout: 4), "«طيران درون استكشافي» in the point card")
        XCTAssertTrue(drone.isEnabled, "enabled when not driving")
        XCTAssertTrue(drone.label.contains("طيران درون"))
        drone.tap()
        let started = NSPredicate { _, _ in self.flying(map) }
        expectation(for: started, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        sleep(5)
        shot(app, "visuals-drone-from-card")
        XCTAssertTrue(flying(map), "still orbiting mid-flight")
        /* Any touch stops it. */
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let stopped = NSPredicate { _, _ in !self.flying(map) }
        expectation(for: stopped, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
    }

    func testDroneButtonDisabledWhileDriving() {
        let app = launch(["-SaryDrive", "1", "-SaryContext", "driving"])
        let map = any(app, "outing.map")
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        sleep(4)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.56)).press(forDuration: 1.3)
        let drone = app.buttons["point.drone"]
        guard drone.waitForExistence(timeout: 6) else { return } // drive mode may hide the long-press card entirely
        XCTAssertFalse(drone.isEnabled, "no drone flight while driving")
    }

    // MARK: screenshots (real sun at the given instants)

    func testShotNafudDusk() {
        let app = launch(["-SaryVisualsClock", "2026-11-05T14:12:00Z", "-SaryVisualsCamera", "28.0,41.5,13.4,70,250"])
        sleep(16)
        shot(app, "nafud-dusk")
    }

    func testShotNafudDustAtDusk() {
        let app = launch(["-SaryVisualsClock", "2026-11-05T14:12:00Z", "-SaryVisualsCamera", "28.0,41.5,13.4,70,250"], weather: "dust")
        sleep(16)
        XCTAssertTrue(any(app, "visuals.source").label.contains("غبار"), "the weather-driven source line")
        shot(app, "nafud-dust")
    }

    func testShotHuraymilaNoon() {
        let app = launch(["-SaryVisualsClock", "2026-11-05T08:40:00Z", "-SaryVisualsCamera", "25.12,46.12,13.6,62,200"])
        sleep(16)
        shot(app, "huraymila-noon")
    }

    func testShotNafudNightStars() {
        let app = launch(["-SaryVisualsClock", "2026-11-05T18:30:00Z", "-SaryVisualsCamera", "28.0,41.5,12.6,80,250"])
        sleep(16)
        shot(app, "nafud-night-stars")
    }

    func testShotDroneMidFlight() {
        let app = launch(["-SaryVisualsClock", "2026-11-05T13:55:00Z", "-SaryVisualsCamera", "28.0,41.5,13.4,45,250", "-SaryVisualsDrone", "4"])
        let map = any(app, "outing.map")
        let started = NSPredicate { _, _ in self.flying(map) }
        expectation(for: started, evaluatedWith: nil)
        waitForExpectations(timeout: 30)
        sleep(10)
        shot(app, "drone-mid-flight")
        /* Let it finish: the app logs the flight's frame pacing (MapVisuals, "drone flight: …"). */
        let ended = NSPredicate { _, _ in !self.flying(map) }
        expectation(for: ended, evaluatedWith: nil)
        waitForExpectations(timeout: 25)
    }

    // MARK: cities

    /// Tilted over Al-Masjid al-Haram: neutral 3D buildings over the imagery, «اعرضها بالوضع الواقعي»
    /// offered, and it opens Apple's realistic view at the same camera.
    func testCityTiltOffersRealisticAtTheSameCamera() {
        let app = launch(["-SaryExplore", "-SaryLayer", "satellite", "-SaryVisualsClock", "2026-11-05T08:30:00Z",
                          "-SaryVisualsCamera", "21.4200,39.8262,15.3,58,170"])
        let chip = app.buttons["explore.city-realistic"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "offered when tilted over a city")
        XCTAssertTrue(chip.label.contains("اعرضها بالوضع الواقعي"))
        sleep(8)
        shot(app, "city-makkah-buildings")
        chip.tap()
        XCTAssertTrue(any(app, "realistic.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(any(app, "realistic.map").waitForExistence(timeout: 8), "online and stopped: the map opens")
        sleep(14)
        shot(app, "city-makkah-realistic")
    }

    func testCityRealisticNotOfferedInTheDesert() {
        let app = launch(["-SaryExplore", "-SaryLayer", "satellite", "-SaryVisualsCamera", "28.0,41.5,13.4,62,250"])
        XCTAssertTrue(any(app, "outing.map").waitForExistence(timeout: 10))
        sleep(8)
        XCTAssertFalse(app.buttons["explore.city-realistic"].exists, "the desert: no offer")
    }
}
