import CoreLocation
import XCTest

/// Before / after screenshots of the satellite colour grade (sand that reads warm, cities that
/// stay normal) at fixed spots and a fixed sun. Only runs when SARY_SHOTS is set
/// (TEST_RUNNER_SARY_SHOTS for xcodebuild); SARY_SHOT_PREFIX names the set (before / after).
final class DesertGradeShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
    }

    /// 11:00 and 22:30 in Riyadh (+03).
    private let day = "2026-11-05T08:00:00Z"
    private let night = "2026-11-05T19:30:00Z"
    /// The demo group's own spot (`AppModel`'s demo positions), for `-SaryDemoShift`.
    private let demoBase = (lat: 24.7105, lng: 46.6748)

    /// SARY_GRADE=mild|strong: the variant under review (`SandGrade`, DEBUG only).
    private var grade: [String] { ProcessInfo.processInfo.environment["SARY_GRADE"].flatMap { $0.isEmpty ? nil : ["-SarySandGrade", $0] } ?? [] }

    /// SARY_NIGHT_ARGS="-SaryNightMapDark": extra launch arguments for the no-night before / after (DEBUG switch).
    private var extraArgs: [String] { (ProcessInfo.processInfo.environment["SARY_NIGHT_ARGS"] ?? "").split(separator: " ").map(String.init) }

    private func launch(at lat: Double, _ lng: Double, clock: String, forcedNight: Bool = false, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        let shift = String(format: "%.4f,%.4f", lat - demoBase.lat, lng - demoBase.lng)
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryNight", forcedNight ? "1" : "0",
                               "-SaryDrive", "0", "-SaryVisualsClock", clock, "-SaryDemoShift", shift] + grade + extraArgs + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), altitude: 600,
                                                                     horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        if app.buttons["ابدأ"].waitForExistence(timeout: 3) {
            app.terminate()
            app.launch()
            app.allowLocationIfAsked()
        }
        let ids = ["outing-sheet-summary", "nav.banner", "nav.offroad"]
        let ready = NSPredicate { _, _ in ids.contains { app.descendants(matching: .any)[$0].exists } }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 40)
        return app
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SARY_SHOTS"] {
            let prefix = env["SARY_SHOT_PREFIX"].map { "\($0)-" } ?? ""
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png"))
        }
    }

    /// The camera alone (stopped): "lat,lng,zoom,pitch,bearing".
    private func view(_ name: String, _ lat: Double, _ lng: Double, zoom: Double, pitch: Double, bearing: Double = 250, clock: String? = nil) {
        let app = launch(at: lat, lng, clock: clock ?? day, ["-SaryContext", "stopped", "-SaryVisualsCamera", "\(lat),\(lng),\(zoom),\(pitch),\(bearing)"])
        sleep(12)
        shot(name)
        app.terminate()
    }

    /// The map at night (real sunset clock, or the night theme forced on): the no-night shots.
    private func nightView(_ name: String, _ lat: Double, _ lng: Double, zoom: Double, pitch: Double, forced: Bool) {
        let app = launch(at: lat, lng, clock: forced ? day : night, forcedNight: forced,
                         ["-SaryContext", "stopped", "-SaryVisualsCamera", "\(lat),\(lng),\(zoom),\(pitch),250"])
        sleep(12)
        shot(name)
        app.terminate()
    }

    func testN1NightRiyadh() { nightView("night-riyadh", 24.7113, 46.6744, zoom: 15, pitch: 60, forced: false) }
    func testN2NightDesert() { nightView("night-desert", 28.30, 41.40, zoom: 13, pitch: 60, forced: false) }
    func testN3ForcedNightThemeAtNoonRiyadh() { nightView("forced-night-riyadh", 24.7113, 46.6744, zoom: 15, pitch: 60, forced: true) }

    private func driving(_ name: String, _ lat: Double, _ lng: Double, clock: String) {
        let app = launch(at: lat, lng, clock: clock, ["-SaryContext", "driving", "-SaryNavDemo", "-SaryNavDelay", "3", "-SaryRadioRemote",
                                                    "-SaryNavTo", "\(lat + 0.0485),\(lng + 0.0743),مخيم", "-SaryNavState", "offroad", "-SaryNavOffRoad"])
        sleep(14)
        shot(name)
        app.terminate()
    }

    func test1NafudDriving() { driving("nafud-driving", 28.30, 41.40, clock: day) }
    func test2NafudTop() { view("nafud-top", 28.30, 41.40, zoom: 14, pitch: 0, bearing: 0) }
    func test3NafudPitch() { view("nafud-pitch", 28.30, 41.40, zoom: 13, pitch: 70) }
    func test4NafudNight() { driving("nafud-night-driving", 28.30, 41.40, clock: night) }
    func test5DahnaTop() { view("dahna-top", 24.2, 47.6, zoom: 13.5, pitch: 0, bearing: 0) }
    func test6RubPitch() { view("rub-pitch", 21.5, 49.0, zoom: 12.5, pitch: 65) }
    func test7RiyadhTop() { view("riyadh-top", 24.7113, 46.6744, zoom: 15.5, pitch: 0, bearing: 0) }
    func test9NafudClose() { view("nafud-close", 28.30, 41.40, zoom: 16.5, pitch: 0, bearing: 0) }
    func testANafudClosePitch() { view("nafud-close-pitch", 28.30, 41.40, zoom: 16, pitch: 60) }
    /// Owner's Build 44 frame: the Nafud west of Zulfi, 26.3 N 44.6 E (SARY_GRADE=natural|naturalwarm|legacy|mild|strong).
    func testZ1ZulfiNavZ14() { view("zulfi-nav-z14", 26.30, 44.60, zoom: 14, pitch: 60) }
    func testZ2ZulfiNavZ13() { view("zulfi-nav-z13", 26.30, 44.60, zoom: 13, pitch: 60) }
    func testZ3ZulfiClose() { view("zulfi-close-z16", 26.30, 44.60, zoom: 16.5, pitch: 45) }
    func testZ4ZulfiFar() { view("zulfi-far-z10", 26.30, 44.60, zoom: 10.5, pitch: 0, bearing: 0) }
    func test8RiyadhPitch() { view("riyadh-pitch", 24.7113, 46.6744, zoom: 15, pitch: 60) }
}
