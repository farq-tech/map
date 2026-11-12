import XCTest

/// «الطبقات»: «صور عالية الوضوح» and «مسارات البر» flip with a real tap, once on screen
/// (build 18 QA: a tap on a switch still below the half-height sheet's edge does nothing — that
/// was the test, not the app).
final class LayersToggleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testWeatherLayersToggleAndRainPeriodAreReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none",
                               "-SaryScheme", "dark", "-SaryDrive", "0", "-SaryContext", "stopped",
                               "-SaryExplore", "-SaryLiveModal", "layers"]
        app.launch()
        app.allowLocationIfAsked()

        let sheet = app.descendants(matching: .any)["explore.layers.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))

        let rain = app.descendants(matching: .any)["weather.layer.rain"]
        XCTAssertTrue(rain.waitForExistence(timeout: 8))
        /* Short, deliberate steps: a fling goes past the weather rows (same as ExploreUITests). */
        let layerList = app.scrollViews.firstMatch
        for _ in 0..<8 where !rain.isHittable { layerList.swipeUp(velocity: .slow) }
        XCTAssertTrue(rain.isHittable, "the rainfall layer is within the scrollable layers sheet")
        rain.tap()
        XCTAssertTrue(rain.isSelected, "rainfall becomes the active weather layer")

        let sevenDays = app.buttons["weather.rain.days.7"]
        XCTAssertTrue(sevenDays.waitForExistence(timeout: 5), "the 1/3/7-day period picker appears only for rainfall")
        /* The picker opens below the weather rows: bring it fully on screen with short steps before tapping. */
        for _ in 0..<8 where !sevenDays.isHittable { layerList.swipeUp(velocity: .slow) }
        XCTAssertTrue(sevenDays.isHittable)
        sevenDays.tap()
        XCTAssertTrue(sevenDays.isSelected, "the selected accumulation period is visible")

        let clouds = app.descendants(matching: .any)["weather.layer.clouds"]
        for _ in 0..<8 where !clouds.isHittable { layerList.swipeDown(velocity: .slow) }
        for _ in 0..<8 where !clouds.isHittable { layerList.swipeUp(velocity: .slow) }
        XCTAssertTrue(clouds.isHittable, "the cloud layer is reachable")
        clouds.tap()
        XCTAssertTrue(clouds.isSelected, "switching to clouds selects one overlay at a time")
        XCTAssertFalse(rain.isSelected, "the map never selects two weather overlays at once")
        XCTAssertFalse(sevenDays.exists, "the rain-period picker closes when rainfall is not active")
    }

    /// S1 (docs/ONE-MAP-UNIFICATION.md): the base-layer switch behaves exactly as before and the choice
    /// survives a relaunch through the same stored key (`sary.map.layer.v1`).
    func testBaseLayerSwitchStillWorksAndPersists() {
        let app = XCUIApplication()
        let args = ["-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryDrive", "0",
                    "-SaryContext", "stopped", "-SaryExplore", "-SaryLiveModal", "layers"]
        app.launchArguments = ["-resetState"] + args
        app.launch()
        app.allowLocationIfAsked()
        let sheet = app.descendants(matching: .any)["explore.layers.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        let satellite = app.descendants(matching: .any)["layer.satellite"]
        let topo = app.descendants(matching: .any)["layer.topo"]
        let standard = app.descendants(matching: .any)["layer.standard"]
        XCTAssertTrue(topo.waitForExistence(timeout: 5))
        XCTAssertTrue(satellite.isSelected, "satellite is the default")
        standard.tap()
        XCTAssertTrue(standard.isSelected && !satellite.isSelected, "one base layer at a time")
        topo.tap()
        XCTAssertTrue(topo.isSelected && !standard.isSelected)
        app.terminate()

        app.launchArguments = args // no -resetState: the stored choice is read back
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(app.descendants(matching: .any)["explore.layers.sheet"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["layer.topo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["layer.topo"].isSelected, "the choice persisted")
    }

    func testLayersSheetSwitchesFlip() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryDrive", "0",
                               "-SaryContext", "stopped", "-SaryExplore", "-SaryLiveModal", "layers"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        let sheet = app.descendants(matching: .any)["explore.layers.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        sleep(2)
        // The sheet scroll helper moves downward only; visit top-to-bottom in the sheet's order (data layers «مسارات البر», then imagery «صور عالية الوضوح»).
        for id in ["explore-osm-tracks", "explore-hires"] {
            let sw = app.switches[id].firstMatch
            XCTAssertTrue(sw.waitForExistence(timeout: 5), id)
            sw.scrollIntoView(in: app, margin: 120)
            XCTAssertTrue(sw.isHittable, "\(id) on screen")
            let before = sw.value as? String
            sw.tap()
            sleep(1)
            XCTAssertNotEqual(sw.value as? String, before, "\(id) flips with a tap")
            sw.tap()
            sleep(1)
            XCTAssertEqual(sw.value as? String, before, "\(id) flips back")
        }
    }
}
