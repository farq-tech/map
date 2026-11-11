import XCTest

/// «مين معك؟» (quick start from a place on the map): the cards and buttons are laid out one under
/// the other, never on top of each other (Build 41 regression: siblings overlaid in a ZStack).
final class QuickStartLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func open(largeText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "create-quick", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func check(largeText: Bool) {
        let app = open(largeText: largeText)
        let solo = app.buttons["start.solo"]
        XCTAssertTrue(solo.waitForExistence(timeout: 20), "«لحالي، ابدأ الآن»")
        let ids = ["start.destination", "start.withFriends", "start.solo", "start.changePlace", "start.statement"]
        for id in ids { XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), id) }
        shot(largeText ? "quickstart-large" : "quickstart-normal")
        let frames = ids.map { ($0, el(app, $0).frame) }
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let (a, fa) = frames[i], (b, fb) = frames[j]
                XCTAssertFalse(fa.intersection(fb).height > 1 && fa.intersection(fb).width > 1, "\(a) \(fa) overlaps \(b) \(fb)")
            }
        }
        for id in ["start.solo", "start.changePlace"] {
            XCTAssertTrue(el(app, id).isHittable, "\(id) must be tappable")
        }
    }

    func testQuickStartDoesNotOverlap() { check(largeText: false) }
    func testQuickStartDoesNotOverlapAtLargeText() { check(largeText: true) }
}
