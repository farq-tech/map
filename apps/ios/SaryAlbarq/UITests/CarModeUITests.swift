import XCTest

/// «وضع السيارة»: with `-SaryCarMode` the live screen shows the car layer: «إنهاء» is on the screen and every control is at
/// least 64 pt, also in a 1280×480 preview viewport (`-SaryCarModeSize`). Screenshots are kept for the review.
final class CarModeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(size: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-resetState", "-demo", "-SaryCarMode", "-SaryDrive", "1"] + extra
        if let size { args += ["-SaryCarModeSize", size] }
        app.launchArguments = args
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func assertBigEnough(_ app: XCUIApplication, ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        for id in ids {
            let el = app.descendants(matching: .any)[id]
            XCTAssertTrue(el.waitForExistence(timeout: 8), "\(id) is missing", file: file, line: line)
            guard el.exists else { continue }
            XCTAssertGreaterThanOrEqual(el.frame.width, 64, "\(id) is narrower than 64 pt", file: file, line: line)
            XCTAssertGreaterThanOrEqual(el.frame.height, 64, "\(id) is shorter than 64 pt", file: file, line: line)
        }
    }

    func testCarLayerHasEndAndBigControlsInTheDefaultViewport() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["car.layer"].waitForExistence(timeout: 15))
        assertBigEnough(app, ids: ["car.end", "car.layers", "car.tilt", "car.exit"])
        shot("car-default")
    }

    func testCarLayerOn1280x480KeepsEverythingReachable() {
        let app = launch(size: "1280x480")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["car.layer"].waitForExistence(timeout: 15))
        assertBigEnough(app, ids: ["car.end", "car.layers", "car.tilt", "car.exit"])
        shot("car-1280x480")
    }

    func testCarLayerOn1920x720() {
        let app = launch(size: "1920x720")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["car.layer"].waitForExistence(timeout: 15))
        assertBigEnough(app, ids: ["car.end", "car.layers", "car.exit"])
        shot("car-1920x720")
    }

    func testTheEndButtonOpensTheEndChoice() {
        let app = launch(size: "1280x480")
        XCUIDevice.shared.orientation = .landscapeLeft
        let end = app.descendants(matching: .any)["car.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 15))
        end.tap()
        XCTAssertTrue(app.descendants(matching: .any)["end.choice"].waitForExistence(timeout: 8)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "إنهاء")).count > 1,
                      "the end choice did not open from the car layer")
        shot("car-end-choice")
    }

    func testTheOldPortraitScreenIsUntouchedWithTheModeOff() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryDrive", "0"]
        app.launch()
        XCTAssertFalse(app.descendants(matching: .any)["car.layer"].waitForExistence(timeout: 6), "the car layer must not exist with the mode off")
    }
}
