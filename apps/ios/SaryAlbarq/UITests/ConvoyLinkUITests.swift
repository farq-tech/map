import XCTest

/// The thin thread between the convoy's lead and tail: present with the convoy on, labelled only when far.
final class ConvoyLinkUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-demoConvoy"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for l in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // answers the location prompt
        sleep(3)
        return app
    }

    /// Close together the cars sit under each other on screen: no thread (and no label) — never a stub.
    func testCloseCarsGetNoThreadAndNoLabel() {
        let app = launch([])
        XCTAssertFalse(app.descendants(matching: .any)["convoy.link"].exists)
        shot(app, "convoy-link-near")
    }

    func testFarApartTheThreadStaysAndShowsTheDistance() {
        let app = launch(["-demoConvoyFar"])
        let link = app.descendants(matching: .any)["convoy.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        XCTAssertTrue(link.label.contains("كم") || link.label.contains("م"), link.label)
        shot(app, "convoy-link-far")
    }

    func testNoConvoyNoThread() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm"]
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 20))
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["convoy.link"].exists)
    }
}
