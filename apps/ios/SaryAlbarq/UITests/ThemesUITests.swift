import CoreLocation
import XCTest

/// Build 47 themes for the new UI (dark default, daylight, dim night driving). The gallery shows the three side by side;
/// Home and Guidance are rendered once per theme (`-SaryNewUITheme`). SARY_SHOTS=<dir> also writes PNGs.
final class ThemesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let themes = ["dark", "light", "dim"]

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testGalleryRendersAllThreeThemes() {
        let app = XCUIApplication()
        app.launchArguments = ["-SaryThemesGallery", "-AppleLanguages", "(ar)"]
        app.launch()
        XCTAssertTrue(el(app, "themes-gallery-root").waitForExistence(timeout: 20))
        for t in themes {
            XCTAssertTrue(el(app, "themes-panel-\(t)").exists, t)
            let primary = el(app, "themes-primary-\(t)")
            if !primary.isHittable { app.swipeUp() }
            XCTAssertTrue(primary.exists, t)
            XCTAssertGreaterThanOrEqual(primary.frame.height, 57.9, "\(t) primary stays 58 pt")
        }
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        shot(app, "themes-gallery-top")
        app.swipeUp()
        shot(app, "themes-gallery-mid")
        app.swipeUp(); app.swipeUp()
        shot(app, "themes-gallery-bottom")
    }

    func testHomeInEveryTheme() {
        for t in themes {
            let app = XCUIApplication()
            app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "home", "-SaryNewUI", "-SaryNewUITheme", t]
            app.launch()
            app.allowLocationIfAsked()
            XCTAssertTrue(el(app, "home.card.start").waitForExistence(timeout: 20), t)
            XCTAssertTrue(el(app, "home.pill").exists && el(app, "home.card").exists, t)
            XCTAssertGreaterThanOrEqual(el(app, "home.card.start").frame.height, 57, "\(t) start button")
            shot(app, "home-\(t)")
            app.terminate()
        }
    }

    func testGuidanceInEveryTheme() {
        for t in themes {
            let app = XCUIApplication()
            app.launchArguments = ["-resetState", "-demo", "-SaryNewUI", "-SaryNewUITheme", t, "-SaryDrive", "0",
                                   "-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavState", "guiding"]
            XCUIDevice.shared.location = XCUILocation(location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
                horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
            app.launch()
            app.allowLocationIfAsked()
            XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 60), "\(t) maneuver card")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            XCTAssertTrue(el(app, "nav.bottomBar").waitForExistence(timeout: 10), "\(t) the bar")
            shot(app, "guidance-\(t)")
            app.terminate()
        }
    }

    func testThemePickerInAdvancedSettingsChangesTheTheme() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "advanced", "-SaryNewUI", "-SaryNewUITheme", "dark"]
        app.launch()
        app.allowLocationIfAsked()
        let light = el(app, "dev.newUI.theme.light")
        XCTAssertTrue(light.waitForExistence(timeout: 20), "the picker is shown while the new UI is on")
        shot(app, "settings-theme-dark")
        light.tap()
        XCTAssertTrue(el(app, "dev.newUI.theme.dim").exists)
        shot(app, "settings-theme-light")
        el(app, "dev.newUI.theme.dim").tap()
        shot(app, "settings-theme-dim")
    }
}
