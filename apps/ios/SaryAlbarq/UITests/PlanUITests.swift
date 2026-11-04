import XCTest

/// «تخطيط الطلعة» with demo data (no server): drawing a route, a typed coordinate as
/// the destination, the long-press card and «انسخ موقعي».
final class PlanUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    private func value(_ e: XCUIElement) -> String { (e.value as? String) ?? "" }

    func testDrawRouteTapUndoSave() {
        let app = launch(["-demo", "-demoPlanEmpty", "-SaryScreen", "plan-editor"])
        let draw = app.buttons["plan.draw"]
        XCTAssertTrue(draw.waitForExistence(timeout: 15))
        let points = app.descendants(matching: .any)["plan.points"]
        XCTAssertEqual(value(points), "٠")
        XCTAssertFalse(app.buttons["plan.save"].isEnabled, "nothing to save yet")

        draw.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.drawHint"].waitForExistence(timeout: 5))
        let map = app.descendants(matching: .any)["plan.map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        sleep(2) // style + interactions ready
        for (x, y) in [(0.3, 0.35), (0.55, 0.45), (0.7, 0.6)] {
            map.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
            sleep(1)
        }
        XCTAssertTrue(NSPredicate(format: "value == %@", "٣").evaluate(with: points) || waitValue(points, "٣"), "three points: \(value(points))")
        XCTAssertNotEqual(value(app.descendants(matching: .any)["plan.distance"]), "—", "distance shown")
        XCTAssertTrue(value(app.descendants(matching: .any)["plan.eta"]).hasPrefix("≈"), "estimated time shown")

        app.buttons["plan.undo"].tap()
        XCTAssertTrue(waitValue(points, "٢"))

        app.buttons["plan.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.toast"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["plan.save"].isEnabled, "saved")
        XCTAssertTrue(app.buttons["plan.export"].waitForExistence(timeout: 3), "GPX export once a route is saved")
    }

    func testTypedCoordinateBecomesDestination() {
        let app = launch(["-demo", "-demoPlanEmpty", "-SaryScreen", "plan-editor"])
        let search = app.buttons["plan.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("24.7136, 46.6753")
        let row = app.buttons["search.coordinate"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["point.decimal"].waitForExistence(timeout: 5))
        let dest = app.buttons["point.destination"]
        XCTAssertTrue(dest.waitForExistence(timeout: 5))
        dest.tap()
        XCTAssertTrue(app.staticTexts["plan.destinationName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.save"].isEnabled)
        app.buttons["plan.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.toast"].waitForExistence(timeout: 5))
    }

    func testLongPressCardCopiesWesternDigits() {
        let app = launch(["-demo", "-demoPlanEmpty", "-SaryScreen", "plan-editor"])
        let map = app.descendants(matching: .any)["plan.map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        sleep(2)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).press(forDuration: 1.2)
        let copy = app.buttons["point.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the long-press card")
        XCTAssertTrue(app.buttons["point.share"].exists)
        XCTAssertTrue(app.buttons["point.destination"].exists)
        XCTAssertTrue(app.buttons["point.add"].exists)
        copy.tap()
        let decimal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'عشري'")).firstMatch
        XCTAssertTrue(decimal.waitForExistence(timeout: 3))
        decimal.tap()
        XCTAssertTrue(NSPredicate(format: "value BEGINSWITH 'نُسخ: '").evaluate(with: copy) || waitPrefix(copy, "نُسخ: "), "haptic + «نُسخ»")
        /* The accessibility value wraps the text in bidi isolates (U+2066…2069); the pasteboard holds the bare text. */
        let copied = value(copy).replacingOccurrences(of: "نُسخ: ", with: "").filter { !("\u{2066}"..."\u{2069}").contains($0) }
        XCTAssertNotNil(copied.range(of: #"^-?\d{1,2}\.\d{5}, -?\d{1,3}\.\d{5}$"#, options: .regularExpression), "Western digits: \(copied)")
    }

    func testCopyMyLocationFromTheControlCluster() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        let copyMe = app.buttons["outing-copyme"]
        XCTAssertTrue(copyMe.waitForExistence(timeout: 15))
        copyMe.tap()
        /* With a fix: the card (honest about its age); without one: says so. */
        let card = app.descendants(matching: .any)["point.title"]
        let none = app.staticTexts["ما عندنا موقعك بعد"]
        XCTAssertTrue(card.waitForExistence(timeout: 8) || none.exists)
    }

    private func waitPrefix(_ e: XCUIElement, _ p: String) -> Bool {
        let exp = expectation(for: NSPredicate(format: "value BEGINSWITH %@", p), evaluatedWith: e)
        return XCTWaiter.wait(for: [exp], timeout: 5) == .completed
    }

    private func waitValue(_ e: XCUIElement, _ v: String) -> Bool {
        let exp = expectation(for: NSPredicate(format: "value == %@", v), evaluatedWith: e)
        return XCTWaiter.wait(for: [exp], timeout: 5) == .completed
    }
}
