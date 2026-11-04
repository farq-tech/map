import XCTest

/// The side control cluster keeps four buttons + «المزيد»; the rest sit in its menu.
final class MoreMenuUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"] + extra
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func testClusterHasFourPlusMoreAndMenuOpens() {
        let app = launch(["-SaryDrive", "0"])
        let more = any(app, "outing-more")
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        for id in ["outing-locate", "outing-fit", "outing-note-open", "outing-backtrack"] {
            XCTAssertTrue(any(app, id).exists, "\(id) stays on the map")
        }
        for id in ["outing-nearest-open", "outing-stuck", "outing-waypoint-add"] {
            XCTAssertFalse(any(app, id).exists, "\(id) is behind «المزيد»")
        }
        more.tap()
        XCTAssertTrue(any(app, "outing-more-menu").waitForExistence(timeout: 5))
        for id in ["outing-nearest-open", "outing-stuck", "outing-waypoint-add"] {
            XCTAssertTrue(any(app, id).exists, "\(id) in the menu")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "more-menu"
        shot.lifetime = .keepAlways
        add(shot)
        more.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: any(app, "outing-more-menu"))
        waitForExpectations(timeout: 5)
    }

    func testDriveModeKeepsThree() {
        let app = launch(["-SaryDrive", "1"])
        XCTAssertTrue(any(app, "outing-locate").waitForExistence(timeout: 20))
        XCTAssertTrue(any(app, "outing-fit").exists)
        XCTAssertTrue(any(app, "outing-backtrack").exists)
        XCTAssertFalse(any(app, "outing-more").exists)
        XCTAssertFalse(any(app, "outing-note-open").exists)
    }
}
