import CoreLocation
import XCTest

/// «أثري (GPS)»: the followed GPS track is the thin neon-aqua line with chevrons, and its legend line is on the follow panel.
/// With SARY_SHOTS set (TEST_RUNNER_SARY_SHOTS), also saves same-frame screenshots; SARY_SHOT_PREFIX names the set
/// (old / new), SARY_TRACK_* choose the place, zoom, scheme and whether the old look is drawn (`-SaryLegacyTrackStyle`).
final class GPSTrackStyleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = env["SARY_SHOTS"], !dir.isEmpty {
            let prefix = env["SARY_SHOT_PREFIX"].map { "\($0)-" } ?? ""
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png"))
        }
    }

    /// The follow screen shows the legend line «أثري (GPS)».
    func testFollowScreenNamesTheGPSTrack() {
        let app = launch(["-SaryScreen", "follow"])
        let panel = app.descendants(matching: .any)["follow.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let legend = app.descendants(matching: .any)["follow.legend"]
        XCTAssertTrue(legend.waitForExistence(timeout: 5), "legend line")
        XCTAssertEqual(legend.label, "أثري (GPS)")
        sleep(4)
        shot("follow-default")
    }

    /// Screenshots of the follow screen at a given place / zoom (SARY_SHOTS only).
    func testShotsFollowScreen() throws {
        try XCTSkipIf(env["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
        var args = ["-SaryScreen", "follow"]
        if let at = env["SARY_TRACK_AT"] { args += ["-SaryTrackStart", at] }
        if let h = env["SARY_TRACK_HEADING"] { args += ["-SaryTrackHeading", h, "-SaryTrackLenM", env["SARY_TRACK_LEN"] ?? "1600"] }
        args += ["-SaryTrackZoom", env["SARY_TRACK_ZOOM"] ?? "15"]
        if let p = env["SARY_TRACK_PITCH"] { args += ["-SaryTrackPitch", p] }
        if env["SARY_TRACK_LEGACY"] != nil { args += ["-SaryLegacyTrackStyle"] }
        if let scheme = env["SARY_TRACK_SCHEME"] { args += ["-SaryScheme", scheme] }
        let app = launch(args)
        XCTAssertTrue(app.descendants(matching: .any)["follow.panel"].waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: Double(env["SARY_TRACK_WAIT"] ?? "10") ?? 10)
        shot(env["SARY_SHOT_NAME"] ?? "follow")
    }

    /// The live outing map (road lines, OSM dirt tracks, the navigation route) with the followed GPS track over it (SARY_SHOTS only).
    /// SARY_TRACK_AT "lat,lng" (track start and camera), SARY_TRACK_HEADING, SARY_TRACK_LEN, SARY_TRACK_ZOOM, SARY_TRACK_PITCH,
    /// SARY_TRACK_NAV=1 (a navigation route over it), SARY_TRACK_NIGHT=1, SARY_TRACK_OSM=1 (the OSM dirt-track overlay).
    func testShotsOutingMap() throws {
        try XCTSkipIf(env["SARY_SHOTS"] == nil, "screenshots only (SARY_SHOTS)")
        let at = (env["SARY_TRACK_AT"] ?? "24.6938,46.6816").split(separator: ",").compactMap { Double($0) }
        let lat = at[0], lng = at[1]
        let demoBase = (lat: 24.7105, lng: 46.6748)
        let night = env["SARY_TRACK_NIGHT"] != nil
        let clock = night ? "2026-11-05T19:30:00Z" : "2026-11-05T08:00:00Z"
        var args = ["-SaryContext", env["SARY_TRACK_NAV"] != nil ? "driving" : "stopped", "-demoSharing", "-SaryNight", night ? "1" : "0", "-SaryVisualsClock", clock,
                    "-SaryDemoShift", String(format: "%.4f,%.4f", lat - demoBase.lat, lng - demoBase.lng),
                    "-SaryTrackStart", "\(lat),\(lng)", "-SaryTrackHeading", env["SARY_TRACK_HEADING"] ?? "11",
                    "-SaryTrackLenM", env["SARY_TRACK_LEN"] ?? "900", "-SaryFollow", "3",
                    "-SaryVisualsCamera", "\(lat),\(lng),\(env["SARY_TRACK_ZOOM"] ?? "15"),\(env["SARY_TRACK_PITCH"] ?? "0"),0"]
        if env["SARY_TRACK_LEGACY"] != nil { args += ["-SaryLegacyTrackStyle"] }
        if env["SARY_TRACK_OSM"] != nil { args += ["-sary.map.osmTracks.v1", "YES"] }
        if env["SARY_TRACK_NAV"] != nil {
            args += ["-SaryNavDemo", "-SaryNavDelay", "3", "-SaryNavTo", "\(lat + 0.012),\(lng + 0.004),وجهة"]
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), altitude: 600,
                                                                     horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        let app = launch(args)
        _ = app.descendants(matching: .any)["outing-sheet-summary"].waitForExistence(timeout: 40)
        Thread.sleep(forTimeInterval: Double(env["SARY_TRACK_WAIT"] ?? "16") ?? 16)
        shot(env["SARY_SHOT_NAME"] ?? "outing")
    }
}
