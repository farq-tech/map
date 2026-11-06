import CoreLocation
import XCTest

/// Before / after screenshots of «تفاصيل الرمال» (`SandDetail`) and the line-checked
/// «صور عالية الوضوح». Only runs when SARY_SHOTS is set (TEST_RUNNER_SARY_SHOTS for xcodebuild);
/// SARY_SHOT_PREFIX names the set; SARY_DETAIL=off takes the "before" set (`-SarySandDetail off`,
/// DEBUG only). Writes the DEBUG perf JSON next to the shots (`sand-detail-stats.json`).
final class DesertDetailShotsUITests: XCTestCase {
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
    private var grade: [String] {
        let env = ProcessInfo.processInfo.environment
        var a: [String] = []
        if env["SARY_DETAIL"] == "off" { a += ["-SarySandDetail", "off", "-SaryHiRes", "off"] } else { a += ["-SaryHiRes", "on", "-SaryHiResRemote", "on"] }
        return a
    }

    private func launch(at lat: Double, _ lng: Double, clock: String, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        let shift = String(format: "%.4f,%.4f", lat - demoBase.lat, lng - demoBase.lng)
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm", "-SaryScheme", "dark", "-SaryNight", "0",
                               "-SaryDrive", "0", "-SaryVisualsClock", clock, "-SaryDemoShift", shift] + grade + extra
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

    private func driving(_ name: String, _ lat: Double, _ lng: Double, clock: String) {
        let app = launch(at: lat, lng, clock: clock, ["-SaryContext", "driving", "-SaryNavDemo", "-SaryNavDelay", "3", "-SaryRadioRemote",
                                                    "-SaryNavTo", "\(lat + 0.0485),\(lng + 0.0743),مخيم", "-SaryNavState", "offroad", "-SaryNavOffRoad"])
        sleep(14)
        shot(name)
        app.terminate()
    }

    func test1NafudDriving() { driving("nafud-driving", 28.30, 41.40, clock: day) }
    func test2NafudCloseTop() { view("nafud-z17-top", 28.30, 41.40, zoom: 17, pitch: 0, bearing: 0) }
    func test3NafudCloseZ16Pitch() { view("nafud-z16-pitch", 28.30, 41.40, zoom: 16, pitch: 60) }
    func test4NafudTop() { view("nafud-z14-top", 28.30, 41.40, zoom: 14.5, pitch: 0, bearing: 0) }
    func test5DahnaClose() { view("dahna-z16-top", 24.2, 47.6, zoom: 16.5, pitch: 0, bearing: 0) }
    func test6RiyadhClose() { view("riyadh-z17-top", 24.7113, 46.6744, zoom: 17, pitch: 0, bearing: 0) }
    func test7NafudExploreHiRes() {
        /* Exploration at z18 (the AI layer may draw there), the detail over it. */
        let app = launch(at: 28.30, 41.40, clock: day, ["-SaryExplore", "-SaryHiResCam", "28.30,41.40,18.0"])
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        sleep(UInt32(ProcessInfo.processInfo.environment["SARY_FILL"].flatMap(UInt32.init) ?? 60))
        shot("nafud-z18-explore")
        app.terminate()
    }
}
