import CoreLocation
import XCTest

/// Visual proof that «ستاربكس» and "Starbucks" give the same list on the home search (live Apple and
/// Mapbox, from Riyadh). Screenshots only run with SARY_SHOTS (TEST_RUNNER_SARY_SHOTS for xcodebuild).
final class BilingualSearchShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String, rows: [String]) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            let url = URL(fileURLWithPath: dir)
            try? s.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
            try? rows.joined(separator: "\n").write(to: url.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

    /// The result rows' labels, top to bottom.
    private func rows(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "home.result").allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { $0.label }
    }

    private func search(_ app: XCUIApplication, _ text: String) -> [String] {
        let field = any(app, "home.search")
        if any(app, "home.search.clear").exists { any(app, "home.search.clear").tap() }
        field.focusAndType(text + "\n") // return: search now
        _ = any(app, "home.result").waitForExistence(timeout: 20)
        sleep(4) // every source answered
        return rows(app)
    }

    func testStarbucksInArabicAndEnglish() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryScreen", "home"]
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
        XCTAssertTrue(any(app, "home.search").waitForExistence(timeout: 20))
        sleep(3)

        let ar = search(app, "ستاربكس")
        shot("search-ar-starbucks", rows: ar)
        let en = search(app, "Starbucks")
        shot("search-en-starbucks", rows: en)
        XCTAssertFalse(ar.isEmpty)
        XCTAssertEqual(ar, en, "«ستاربكس» and Starbucks: the same rows in the same order")

        let arN = search(app, "صيدلية النهدي")
        shot("search-ar-nahdi", rows: arN)
        let enN = search(app, "Nahdi pharmacy")
        shot("search-en-nahdi", rows: enN)
        XCTAssertEqual(arN, enN, "«صيدلية النهدي» and Nahdi pharmacy")
    }
}
