import XCTest

/// «الطبقات»: «صور عالية الوضوح» and «مسارات البر» flip with a real tap, once on screen
/// (build 18 QA: a tap on a switch still below the half-height sheet's edge does nothing — that
/// was the test, not the app).
final class LayersToggleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

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
        // The sheet scroll helper moves downward only; visit top-to-bottom.
        for id in ["explore-hires", "explore-osm-tracks"] {
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
