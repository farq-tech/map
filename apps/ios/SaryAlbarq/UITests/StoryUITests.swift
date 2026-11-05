import XCTest

/// «قصة الطلعة» from the ended outing's summary: the button, the composer, the privacy switches (off by default).
/// With `SARY_STORY_SHOTS=1` it saves screenshots to docs/app-shots/story-*.jpg.
final class StoryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func allowLocationIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); return }
        }
    }

    private func shot(_ name: String) {
        guard ProcessInfo.processInfo.environment["SARY_STORY_SHOTS"] == "1" else { return }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/app-shots")
        let png = XCUIScreen.main.screenshot().pngRepresentation
        guard let img = UIImage(data: png), let jpg = img.jpegData(compressionQuality: 0.82) else { return }
        try? jpg.write(to: dir.appendingPathComponent("story-\(name).jpg"))
    }

    func testStoryFromTripSummary() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", "summary", "-SaryScheme", "dark"]
        app.launch()
        allowLocationIfAsked()
        let open = app.buttons["summary.story"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        shot("summary-entry-dark")
        open.tap()

        let preview = app.descendants(matching: .any)["story.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        /* Privacy first: both switches start off. */
        let start = app.switches["story.showStart"], names = app.switches["story.showNames"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.value as? String, "0")
        XCTAssertEqual(names.value as? String, "0")
        /* Share becomes available once the preview (with the satellite snapshot) is ready. */
        let share = app.buttons["story.share"]
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: share)
        waitForExpectations(timeout: 30)
        sleep(1)
        shot("composer-dark")
        app.swipeUp()
        sleep(1)
        shot("composer-options-dark")
    }
}
