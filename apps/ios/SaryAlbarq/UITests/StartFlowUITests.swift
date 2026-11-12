import CoreLocation
import XCTest

/// Owner's Build 46 report: starting a trip repeats itself («إنشاء طلعة» → destination → weather → invite → «ابدأ الطلعة»,
/// then guidance asks again). Rule: creating the outing IS starting it: destination → (optional friends) → the trip and its
/// guidance begin at once, with no second «ابدأ» and no repeated question. Each test counts the taps from the home map.
/// Set SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) to also write PNGs.
final class StartFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("start-\(name).png"))
        }
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "home", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryNavDemo"]
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    /// The full wizard, the way the owner does it: pick the destination, and the trip starts.
    func testFullWizardToGuidance() {
        let app = launch()
        var taps = 0
        app.openHomeOutings()
        let create = app.buttons["list.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        shot("0-home")
        create.tap(); taps += 1
        let field = app.textFields["create.dest.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("1-destination")
        field.tap(); field.typeText("24.7590, 46.7491")
        let coordinate = app.buttons["create.dest.coordinate"]
        XCTAssertTrue(coordinate.waitForExistence(timeout: 5))
        coordinate.tap(); taps += 1
        shot("2-after-destination")
        /* One screen after the destination: name, time and the weather there, with «ابدأ الطلعة» / «ادعُ أصدقاءك وابدأ» pinned. */
        let solo = app.buttons["start.solo"]
        XCTAssertTrue(solo.waitForExistence(timeout: 8), "«ابدأ الطلعة» is on the same screen as the weather")
        XCTAssertTrue(app.buttons["start.withFriends"].exists)
        XCTAssertTrue(app.textFields["create.name"].exists, "the name and the time are still there")
        XCTAssertTrue(app.buttons["create.changeTime"].exists)
        XCTAssertFalse(app.buttons["create.start"].exists, "no second «ابدأ الطلعة» later")
        shot("3-start")
        solo.tap(); taps += 1
        app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "nav.end").waitForExistence(timeout: 75), "guidance starts by itself, no second start")
        XCTAssertFalse(el(app, "nav.startChoice").exists, "and nothing asks again")
        shot("4-guiding")
        XCTContext.runActivity(named: "taps from home to guidance: \(taps)") { _ in }
        XCTAssertLessThanOrEqual(taps, 4)
    }

    /// With friends: the same one tap starts the trip and its guidance; the invite opens over the live map.
    func testWithFriendsStartsAtOnce() {
        let app = launch()
        app.openHomeOutings()
        app.buttons["list.create"].tap()
        let field = app.textFields["create.dest.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("24.7590, 46.7491")
        app.buttons["create.dest.coordinate"].tap()
        let friends = app.buttons["start.withFriends"]
        XCTAssertTrue(friends.waitForExistence(timeout: 8))
        friends.tap()
        app.allowLocationIfAsked()
        XCTAssertFalse(el(app, "create.start").waitForExistence(timeout: 2), "no invite step holding the start back")
        XCTAssertTrue(el(app, "nav.end").waitForExistence(timeout: 75), "the trip and its guidance started")
        shot("5-friends-live")
    }
}
