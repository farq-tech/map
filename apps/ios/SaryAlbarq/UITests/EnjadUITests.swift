import XCTest

/// «اطلب إنجاد» is at most two taps from «غرّزت» and from a sent SOS (demo outing, no server).
final class EnjadUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryDrive", "0"]
        app.launch()
        /* The launch intro covers the map while the controls under it are already in the tree: a tap on
           «+» then lands on the intro (or, as it fades, on the map, which opens «نبذة المكان»). Wait it out. */
        let intro = app.descendants(matching: .any)["intro"]
        if intro.waitForExistence(timeout: 3) { XCTAssertTrue(intro.waitForNonExistence(timeout: 20), "the intro ends") }
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func assertSheet(_ app: XCUIApplication) {
        XCTAssertTrue(any(app, "enjad.sheet").waitForExistence(timeout: 5), "the Enjad sheet")
        XCTAssertTrue(any(app, "enjad.whatsapp").exists)
        XCTAssertTrue(any(app, "enjad.call").exists)
        XCTAssertTrue(any(app, "enjad.sms").exists)
    }

    func testFromTheStuckConfirm() {
        let app = launch()
        let more = any(app, "outing-actions")
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let stuck = any(app, "outing-stuck")
        XCTAssertTrue(stuck.waitForExistence(timeout: 5))
        stuck.tap()
        /* Tap 1: «غرّزت» → the confirm; tap 2: «اطلب إنجاد (واتساب)». */
        let enjad = app.buttons["اطلب إنجاد (واتساب)"]
        XCTAssertTrue(enjad.waitForExistence(timeout: 5))
        enjad.tap()
        assertSheet(app)
    }

    func testFromMyStuckStrip() {
        let app = launch()
        let more = any(app, "outing-actions")
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        XCTAssertTrue(any(app, "outing-stuck").waitForExistence(timeout: 5))
        any(app, "outing-stuck").tap()
        app.buttons["إيه، غرّزت"].tap()
        let b = any(app, "stuck-enjad")
        XCTAssertTrue(b.waitForExistence(timeout: 5), "«إنجاد» on the stuck strip")
        b.tap()
        assertSheet(app)
    }

    func testFromASentSOS() {
        let app = launch()
        let sos = any(app, "outing-sos")
        XCTAssertTrue(sos.waitForExistence(timeout: 20))
        sos.press(forDuration: 1.6)
        let b = any(app, "sos-enjad")
        XCTAssertTrue(b.waitForExistence(timeout: 8), "«إنجاد» on the sent-SOS strip")
        b.tap()
        assertSheet(app)
    }
}
