import XCTest

/// Owner's Build 48 report (real phone): during guidance, ~530 m from a desert destination, with the sheet at
/// peek, NO map control answered (موقعي, الطبقات, الطقس, ٣د) while the screen looked normal. These tests drive
/// the same screen through the states guidance goes through (reroute, off-route, back, the overview camera,
/// background / foreground) and require that a real tap on each control still does its job each time.
final class GuidingTouchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("untappable-\(name).png"))
        }
    }

    /// A desert destination: the demo road ends short of it and the rest is the off-road leg.
    private func guidingApp(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryNavDemo", "-SaryNavTo", "24.7420,46.6850,صحراء النفود", "-SaryNavDelay", "3",
                               "-SaryNavStart", "-SaryNavOffRoad", "-SaryNavSurfaces", "-SaryWeatherDemo", "calm", "-SaryWeather", "none",
                               "-SaryScheme", "light", "-SaryDrive", "0"] + extra
        app.launch(); app.allowLocationIfAsked()
        return app
    }

    /// Taps `map.layers` and requires the sheet to open, then closes it again. Fails with `label` when the tap did nothing.
    private func layersAnswers(_ app: XCUIApplication, _ label: String) {
        let button = el(app, "map.layers")
        XCTAssertTrue(button.waitForExistence(timeout: 20), "\(label): the layers button is on the map")
        XCTAssertTrue(button.isHittable, "\(label): layers is hittable")
        button.tap()
        let sheet = el(app, "explore.layers.sheet")
        if !sheet.waitForExistence(timeout: 6) { shot("\(label)-layers-dead") }
        XCTAssertTrue(sheet.exists, "\(label): a real tap on the layers button opens its sheet")
        sheet.swipeDown(velocity: .fast)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 8), "\(label): and it closes again")
        sleep(1)
    }

    /// Taps the camera button («باتجاهي» / «تتبعني») and requires its state to change.
    private func tiltAnswers(_ app: XCUIApplication, _ label: String) {
        let tilt = el(app, "map.tilt")
        guard tilt.waitForExistence(timeout: 5) else { return }
        let before = tilt.value as? String
        tilt.tap()
        let changed = NSPredicate { _, _ in (tilt.value as? String) != before }
        let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 6) == .completed
        if !ok { shot("\(label)-tilt-dead") }
        XCTAssertTrue(ok, "\(label): a real tap on ٣د changes the camera")
        tilt.tap()
        sleep(1)
    }


    /// «موقعي» / «باتجاهي»: a real tap must change the camera button (its label flips between follow and heading).
    private func locateAnswers(_ app: XCUIApplication, _ label: String) {
        let b = el(app, "outing-locate")
        guard b.waitForExistence(timeout: 5) else { return }
        XCTAssertTrue(b.isHittable, "\(label): locate is hittable")
        let before = b.value as? String
        b.tap()
        let changed = NSPredicate { _, _ in (b.value as? String) != before }
        let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 6) == .completed
        if !ok { shot("\(label)-locate-dead") }
        XCTAssertTrue(ok, "\(label): a real tap on «موقعي» changes the camera mode")
        sleep(1)
    }

    /// The weather chip opens the weather sheet.
    private func weatherAnswers(_ app: XCUIApplication, _ label: String) {
        let chip = el(app, "weather.chip")
        guard chip.waitForExistence(timeout: 5) else { return }
        chip.tap()
        let sheet = el(app, "weather.sheet")
        if !sheet.waitForExistence(timeout: 6) { shot("\(label)-weather-dead") }
        XCTAssertTrue(sheet.exists, "\(label): a real tap on the weather chip opens its sheet")
        sheet.swipeDown(velocity: .fast)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 8), "\(label): and it closes again")
        sleep(1)
    }

    private func allAnswer(_ app: XCUIApplication, _ label: String) {
        layersAnswers(app, label); tiltAnswers(app, label); locateAnswers(app, label); weatherAnswers(app, label)
    }

    /// The whole cycle the owner's phone goes through while driving the last stretch (reroute, off-route, back to guiding).
    func testControlsAnswerThroughRerouteOffRouteAndBack() {
        let app = guidingApp(["-SaryNavCycle"])
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 75), "guiding")
        for round in 1...6 {
            allAnswer(app, "cycle\(round)")
            sleep(2)
        }
    }

    func testControlsAnswerAfterBackgroundAndForeground() {
        let app = guidingApp()
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 75), "guiding")
        layersAnswers(app, "before-bg")
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 20))
        layersAnswers(app, "after-bg")
        tiltAnswers(app, "after-bg")
    }

    func testControlsAnswerInOverviewAndAfterTheArrivalState() {
        let app = guidingApp()
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 75), "guiding")
        let overview = el(app, "nav.overview")
        if overview.waitForExistence(timeout: 5) { overview.tap(); sleep(2) }
        layersAnswers(app, "overview")
        let follow = el(app, "nav.follow")
        if follow.exists, follow.isHittable { follow.tap(); sleep(1) }
        layersAnswers(app, "after-recenter")
    }

    /// Owner's phone: ~500 m left on the desert leg, sheet at peek, speed dropping (drive mode flips, so the sheet's peek shape does).
    func testControlsAnswerNearTheDestinationWithSpeedDropping() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryNavDemo", "-SaryNavTo", "24.7270,46.6900,صحراء النفود", "-SaryNavDelay", "3",
                               "-SaryNavState", "offroad", "-SaryNavSurfaces", "-SaryDriveFlip", "7", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", "light"]
        app.launch(); app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 75), "guiding near the destination")
        for round in 1...8 { allAnswer(app, "near\(round)") }
    }
}
