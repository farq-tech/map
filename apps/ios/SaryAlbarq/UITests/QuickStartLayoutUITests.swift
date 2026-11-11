import XCTest

/// «مين معك؟» (quick start from a place on the map): the cards and buttons are laid out one under
/// the other, never on top of each other (Build 41 regression: siblings overlaid in a ZStack).
final class QuickStartLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func open(largeText: Bool, screen: String = "create-quick") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", screen, "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0"]
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

    /// No two of these elements share any area, and the buttons among them can be tapped.
    private func assertLaidOut(_ app: XCUIApplication, ids: [String], tappable: [String], step: String) {
        for id in ids { XCTAssertTrue(el(app, id).waitForExistence(timeout: 8), "\(step): \(id)") }
        let frames = ids.map { ($0, el(app, $0).frame) }
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let (a, fa) = frames[i], (b, fb) = frames[j]
                let x = fa.intersection(fb)
                XCTAssertFalse(x.width > 1 && x.height > 1, "\(step): \(a) \(fa) overlaps \(b) \(fb)")
            }
        }
        for id in tappable { XCTAssertTrue(el(app, id).isHittable, "\(step): \(id) must be tappable") }
    }

    /// The full wizard: ١ وين رايحين؟ → ٢ الجو هناك → ٣ ادعُ أصدقاءك, with a shot of each step.
    private func checkWizard(largeText: Bool) {
        let tag = largeText ? "large" : "normal"
        let app = open(largeText: largeText, screen: "create")
        let field = app.textFields["create.dest.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        assertLaidOut(app, ids: ["create.dest.field", "create.dest.map", "create.dest.required"],
                      tappable: ["create.dest.field", "create.dest.map"], step: "destination")
        shot("wizard-1-destination-\(tag)")
        field.tap()
        field.typeText("24.7590, 46.7491")
        let coordinate = app.buttons["create.dest.coordinate"]
        XCTAssertTrue(coordinate.waitForExistence(timeout: 8))
        coordinate.tap()

        XCTAssertTrue(app.textFields["create.name"].waitForExistence(timeout: 8))
        shot("wizard-2-weather-\(tag)")
        let approve = app.buttons["create.approve"]
        if !approve.isHittable { app.swipeUp() }
        approve.tap()

        XCTAssertTrue(app.buttons["create.whatsapp"].waitForExistence(timeout: 15))
        assertLaidOut(app, ids: ["create.created", "create.whatsapp", "create.more", "create.start", "create.later", "create.shareStatement"],
                      tappable: ["create.whatsapp", "create.more", "create.start", "create.later"], step: "invite")
        shot("wizard-3-invite-\(tag)")
    }

    func testWizardStepsDoNotOverlap() { checkWizard(largeText: false) }
    func testWizardStepsDoNotOverlapAtLargeText() { checkWizard(largeText: true) }

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
