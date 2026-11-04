import XCTest

/// Offline maps on the simulator: download a small area for real (Mapbox
/// OfflineManager + TileStore), see it listed as complete, then cut the Mapbox
/// stack off the network (OfflineSwitch) and check the live map still draws.
final class OfflineMapsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func test1DownloadSmallAreaReportsComplete() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", "offline-flow"]
        app.launch()
        XCTAssertTrue(app.buttons["offline.add"].waitForExistence(timeout: 10))
        app.buttons["offline.add"].tap()
        let estimate = app.staticTexts["offline.estimate"]
        XCTAssertTrue(estimate.waitForExistence(timeout: 60), "Mapbox estimated the size")
        shot(app, "offline-picker")
        app.buttons["offline.download"].tap()
        let done = app.descendants(matching: .any)["offline.finished"]
        XCTAssertTrue(done.waitForExistence(timeout: 600), "the tile region finished downloading")
        sleep(2)
        shot(app, "offline-saved")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "جاهزة بلا إنترنت")).firstMatch.exists, "listed as complete")
    }

    func test2LiveMapDrawsWithMapboxCutOff() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryWeatherDemo", "calm", "-SaryMapboxOffline", "-SaryClearAmbient", "-SaryScheme", "light"]
        addUIInterruptionMonitor(withDescription: "location") { alert in
            for l in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 20))
        sleep(3)
        app.tap()
        sleep(10)
        shot(app, "offline-live-map")
    }
}
