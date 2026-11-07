import XCTest

/// «طلعة جديدة» end to end with demo data (no server) and a synthetic calm forecast:
/// a typed coordinate → «الجو هناك» → «ادعُ ربعك» → «ابدأ الطلعة» → the live map's weather chip.
/// With `SARY_FLOW_SHOTS=1` it saves docs/app-shots/flow-*-<scheme>.jpg (`SARY_FLOW_SCHEME` light|dark).
final class CreateFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var scheme: String { ProcessInfo.processInfo.environment["SARY_FLOW_SCHEME"] ?? "light" }

    private func shot(_ name: String) {
        guard ProcessInfo.processInfo.environment["SARY_FLOW_SHOTS"] == "1" else { return }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/app-shots")
        let png = XCUIScreen.main.screenshot().pngRepresentation
        guard let img = UIImage(data: png), let jpg = img.jpegData(compressionQuality: 0.82) else { return }
        try? jpg.write(to: dir.appendingPathComponent("flow-\(name)-\(scheme).jpg"))
    }

    private func allowLocationIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 2) { b.tap(); return }
        }
    }

    func testWizardWithTypedCoordinateThroughWeatherToInviteAndLiveChip() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "home", "-SaryWeatherDemo", "calm", "-SaryScheme", scheme]
        app.launch()
        allowLocationIfAsked()

        app.openHomeOutings()
        let create = app.buttons["list.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()

        /* ١ وين رايحين؟ */
        let field = app.textFields["create.dest.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["وين رايحين؟"].exists)
        /* «لا يوجد رحلة من غير نهاية»: no way to go on without a destination. */
        XCTAssertFalse(app.buttons["create.dest.skip"].exists, "no «بدون وجهة الحين»")
        XCTAssertFalse(app.buttons["بدون وجهة الحين"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["create.dest.required"].exists, "the destination is required")
        XCTAssertFalse(app.textFields["create.name"].exists, "step 2 is not reachable without a destination")
        XCTAssertTrue(app.buttons["create.dest.map"].exists)
        shot("1-destination")
        field.tap()
        field.typeText("24.7590, 46.7491")
        let coordinate = app.buttons["create.dest.coordinate"]
        XCTAssertTrue(coordinate.waitForExistence(timeout: 5))
        shot("1-coordinate")
        coordinate.tap()

        /* ٢ الجو هناك */
        let name = app.textFields["create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["الجو هناك"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["create.weather.now"].waitForExistence(timeout: 8), "the destination's weather now")
        XCTAssertTrue(app.descendants(matching: .any)["create.weather.arrival"].exists, "and at arrival")
        let approve = app.buttons["create.approve"]
        approve.tap()
        XCTAssertTrue(app.staticTexts["اكتب اسم الطلعة."].waitForExistence(timeout: 3), "a name is required")
        name.tap()
        name.typeText("كشتة الثمامة\n")
        app.swipeDown()
        shot("2-weather")
        app.swipeUp()
        XCTAssertTrue(app.buttons["create.changeTime"].exists)
        XCTAssertTrue(app.buttons["create.changePlace"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["create.weather.wadi"].exists, "the wadi / flood caveat")
        shot("2-approve")
        app.buttons["create.approve"].tap()

        /* ٣ ادعُ ربعك */
        let whatsapp = app.buttons["create.whatsapp"]
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ادعُ ربعك"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["create.qr"].exists)
        let message = app.staticTexts["create.message"]
        XCTAssertTrue(message.exists)
        XCTAssertTrue(message.label.contains("الجو هناك وقت وصولنا"), message.label)
        XCTAssertTrue(message.label.contains("https://"), "the link is in the message")
        shot("3-invite")
        app.swipeUp()
        shot("3-invite-bottom")
        app.buttons["create.start"].tap()

        /* The live map: the weather chip is always there. */
        allowLocationIfAsked()
        /* The creator shares by default (build 6): once When-In-Use is granted, the «دائمًا» explainer follows. */
        let later = app.buttons["share.always.later"]
        if later.waitForExistence(timeout: 6) { shot("live-always-explainer"); later.tap() }
        let chip = app.buttons["weather.chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        sleep(3)
        shot("live-chip")
        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["weather.sheet"].waitForExistence(timeout: 5))
        shot("live-weather-sheet")
    }

    func testStepOneMapPickerReadsTheCentre() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "create", "-SaryWeatherDemo", "calm", "-SaryScheme", scheme]
        app.launch()
        allowLocationIfAsked()
        let map = app.buttons["create.dest.map"]
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        map.tap()
        let readout = app.staticTexts["create.map.readout"]
        XCTAssertTrue(readout.waitForExistence(timeout: 10))
        sleep(4)
        shot("1-map")
        app.buttons["create.map.confirm"].tap()
        XCTAssertTrue(app.textFields["create.name"].waitForExistence(timeout: 5), "the picked point leads to «الجو هناك»")
        app.swipeUp()
        app.buttons["create.changePlace"].tap()
        XCTAssertTrue(app.textFields["create.dest.field"].waitForExistence(timeout: 5), "«غيّر المكان» goes back to step 1")
    }
}

private extension XCUIElement {
    func tapIfExists() { if exists && isHittable { tap() } }
}
