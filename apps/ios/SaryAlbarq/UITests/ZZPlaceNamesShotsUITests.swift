import XCTest

/// TEMPORARY (not committed): «أماكن سابقة» screenshots for the PR.
final class ZZPlaceNamesShotsUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/Users/m4pro/code/map-wt/simplify-shots/\(name).png"))
    }

    func testPreviousPlacesShots() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", "home", "-SaryScheme", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["list.create"].waitForExistence(timeout: 10))
        app.buttons["list.create"].tap()
        XCTAssertTrue(app.textFields["create.dest.field"].waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "places-1-before-bare-names")
        app.buttons["page-close"].tap()
        sleep(6)
        app.buttons["list.create"].tap()
        XCTAssertTrue(app.textFields["create.dest.field"].waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "places-2-after-real-names")
        XCTAssertFalse(app.staticTexts["نقطة على الخريطة"].exists, "no bare «نقطة على الخريطة» left")
    }
}
