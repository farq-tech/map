import XCTest

/// «صور عالية الوضوح»: the «مُحسّنة» badge appears in exploration once over-zoomed past the
/// imagery's real detail (Huraymila's shuaib, z18.6), then the same map enters active navigation
/// with the enhancement badge absent. Needs the network (Mapbox tiles), the bundled model and a
/// simulated GPS fix and location permission: `xcrun simctl privacy <udid> grant location sa.sary.albarq`
/// and `xcrun simctl location <udid> set 25.121,46.101`.
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

    func testBadgeInExplorationThenActiveNavigation() {
        let app = launch(["-SaryExplore", "-SaryHiResCam", "25.12,46.10,18.6",
                          "-SaryNavDemo", "-SaryNavTo", "25.10,46.12,الشعيب", "-SaryNavDelay", "45", "-SaryNavState", "guiding"])
        XCTAssertTrue(app.descendants(matching: .any)["explore.header"].waitForExistence(timeout: 20), "exploration map is open")
        /* Start polling immediately: the badge is intentionally transient after the first enhanced tile. */
        XCTAssertTrue(badge(app).waitForExistence(timeout: 110), "«مُحسّنة» once enhanced tiles are on screen (network tiles + on-device model; slow under a loaded simulator)")
        attach(app, "hires-exploration-badge")
        /* «تخفيف الزحمة» ٧: it says so for 3 s, then steps aside. */
        XCTAssertTrue(badge(app).waitForNonExistence(timeout: 8), "the badge hides after a few seconds")
        app.buttons["explore-exit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["explore.header"].waitForNonExistence(timeout: 8), "leave exploration before guidance starts")
        /* Do not mistake the badge's 3 s timeout for navigation: assert that guidance really began. */
        let banner = app.descendants(matching: .any)["nav.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "active guidance began")
        XCTAssertTrue(banner.isHittable, "the active maneuver banner is visible, not just in the accessibility tree")
        XCTAssertFalse(badge(app).exists, "the navigation screen has no enhancement badge")
        attach(app, "hires-navigation-original")
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
