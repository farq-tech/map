import XCTest

/// Owner's Build 48.1 report: «الأماكن المحفوظة ما تضغط». The favourites page (home «المفضلة») listed the places as
/// plain rows with no action. A tap must now close the page and show the place on the home map with its options.
final class FavoritesTapUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("favorites-\(name).png"))
        }
    }

    func testTappingASavedPlaceShowsItOnTheHomeMap() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "home", "-SaryScheme", "dark", "-SaryNewUI",
                               "-SarySeedPlace", "مخيم الشعيب,26.0352,44.0521"]
        app.launch(); app.allowLocationIfAsked()
        XCTAssertTrue(el(app, "home.pill.profile").waitForExistence(timeout: 20), "new home profile button")
        shot("0-home")
        el(app, "home.pill.profile").tap()
        let fav = el(app, "profile.sheet.favorites")
        XCTAssertTrue(fav.waitForExistence(timeout: 10), "«مفضلتك» row in the profile sheet")
        fav.tap()
        let row = el(app, "favorites.place")
        _ = row.waitForExistence(timeout: 10)
        shot("1-list")
        XCTAssertTrue(row.exists, "the saved place is listed")
        row.tap()
        /* back on the home with the place selected: its name is on screen and the favourites page is gone */
        XCTAssertTrue(app.staticTexts["مخيم الشعيب"].firstMatch.waitForExistence(timeout: 10), "the place is shown on the home map")
        XCTAssertFalse(row.exists, "the favourites page closed")
        shot("2-shown")
        Thread.sleep(forTimeInterval: 12)
        shot("3-after-flight")
    }
}
