import XCTest

/// «صور عالية الوضوح»: the «مُحسّنة» badge appears in exploration once over-zoomed past the
/// imagery's real detail (Huraymila's shuaib, z18.6), and disappears when navigation starts
/// (original imagery while navigating). Needs the network (Mapbox tiles), the bundled model and a
/// simulated GPS fix for the demo navigation: `xcrun simctl location <udid> set 25.121,46.101`.
final class HiResImageryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0"] + extra
            + (extra.contains("-SaryHiRes") ? [] : ["-SaryHiRes", "on"]) + (extra.contains("-SaryHiResRemote") ? [] : ["-SaryHiResRemote", "on"])
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

    private func badge(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["hires.badge"].firstMatch }

    func testBadgeInExplorationOverZoomGoneInNavigation() {
        let app = launch(["-SaryExplore", "-SaryHiResCam", "25.12,46.10,18.6",
                          "-SaryNavDemo", "-SaryNavTo", "25.10,46.12,الشعيب", "-SaryNavDelay", "120", "-SaryNavState", "guiding"])
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // lets the permission monitor answer
        XCTAssertTrue(badge(app).waitForExistence(timeout: 110), "«مُحسّنة» once enhanced tiles are on screen (network tiles + on-device model; slow under a loaded simulator)")
        attach(app, "hires-exploration-badge")
        /* Round 3 (red line): it stays as long as enhanced tiles are on screen, and sits clear
           of the map's centre marks (bottom left, by the Mapbox logo). */
        sleep(8)
        XCTAssertTrue(badge(app).exists, "the badge stays while enhancement is on screen")
        let f = badge(app).frame, w = app.frame
        XCTAssertLessThan(f.midX, w.width * 0.3, "left side, away from the crosshair")
        XCTAssertGreaterThan(f.midY, w.height * 0.6, "low, away from the centre marks")
        /* Navigation starts at 120 s (demo router): the enhanced layer is removed with its badge. */
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: badge(app))
        waitForExpectations(timeout: 150)
        attach(app, "hires-navigation-original")
    }

    /// Round 3 incident: enhanced tiles were handed to Mapbox (badge on) but never drawn. The
    /// DEBUG tint substitutes cyan pixels in each delivered tile; count them in the rendered map
    /// to prove the custom raster source actually draws. This checks delivery/rendering, not quality.
    func testEnhancedTilesAreReallyDrawn() throws {
        let app = launch(["-SaryExplore", "-SaryHiResCam", "28.30,41.40,18.0", "-SaryHiResTint", "-SaryHiResLevel", "light", "-SarySandDetail", "off"])
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        XCTAssertTrue(badge(app).waitForExistence(timeout: 150), "enhanced tiles arrive")
        sleep(10)
        let shot = XCUIScreen.main.screenshot()
        attach(app, "hires-tint")
        let tinted = try XCTUnwrap(Self.blueShare(shot.image))
        XCTAssertGreaterThan(tinted, 0.15, "the enhanced layer is drawn on screen (tinted share \(tinted))")
    }

    /// Share of the map's middle band (x 10–90 %, y 55–75 %) where blue > red + 10.
    static func blueShare(_ image: UIImage) -> Double? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0, blue = 0
        for y in stride(from: Int(Double(h) * 0.55), to: Int(Double(h) * 0.75), by: 4) {
            for x in stride(from: Int(Double(w) * 0.1), to: Int(Double(w) * 0.9), by: 4) {
                let o = (y * w + x) * 4
                n += 1
                if Int(px[o + 2]) > Int(px[o]) + 10 { blue += 1 }
            }
        }
        return n == 0 ? nil : Double(blue) / Double(n)
    }

    func testNoBadgeWhenTurnedOff() {
        let app = launch(["-SaryExplore", "-SaryHiResCam", "25.12,46.10,18.6", "-SaryHiRes", "off"])
        XCTAssertFalse(badge(app).waitForExistence(timeout: 25), "the toggle off: original imagery, no badge")
    }

    func testRemoteKillSwitchHidesIt() {
        let app = launch(["-SaryExplore", "-SaryHiResCam", "25.12,46.10,18.6", "-SaryHiResRemote", "off"])
        XCTAssertFalse(badge(app).waitForExistence(timeout: 25), "server switch off: original imagery, no badge")
    }

    /// Internal before/after shots (owner review only): runs only with
    /// `TEST_RUNNER_SARY_HIRES_SHOTS=<dir>`; each spot: original, then enhanced once the screen has filled.
    func testBeforeAfterShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["SARY_HIRES_SHOTS"] else { throw XCTSkip("set TEST_RUNNER_SARY_HIRES_SHOTS") }
        let spots = [("shuaib_z18", "25.12,46.10,18.0"), ("shuaib_z19", "25.12,46.10,19.0"),
                     ("nafud_z18", "28.0,41.5,18.0"), ("riyadh_z19", "24.80,46.68,19.0")]
        let fill = Double(ProcessInfo.processInfo.environment["SARY_HIRES_FILL"] ?? "150") ?? 150
        for (name, cam) in spots {
            for on in [false, true] {
                let app = launch(["-SaryExplore", "-SaryHiResCam", cam, "-SaryHiRes", on ? "on" : "off"])
                sleep(3)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // lets the permission monitor answer
                if on {
                    _ = badge(app).waitForExistence(timeout: 90)
                    Thread.sleep(forTimeInterval: fill)
                } else {
                    Thread.sleep(forTimeInterval: 25)
                }
                let png = app.screenshot().pngRepresentation
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)_\(on ? "after" : "before").png"))
                app.terminate()
            }
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
