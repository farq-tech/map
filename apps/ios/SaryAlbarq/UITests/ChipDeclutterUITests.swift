import XCTest

/// The chip declutter on the real map: friends parked together fold into one
/// group chip, «أنت» stays on its own, and tapping the group spreads them out.
final class ChipDeclutterUITests: XCTestCase {
    func testParkedFriendsFoldIntoAGroupThatExpands() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoCrowd"]
        app.launch()
        let group = app.buttons["car.group"].exists ? app.buttons["car.group"] : app.descendants(matching: .any)["car.group"]
        XCTAssertTrue(group.waitForExistence(timeout: 20), "a crowd folds into a group chip")
        /* Let the first group framing settle before tapping. */
        sleep(4)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "declutter-folded"
        shot.lifetime = .keepAlways
        add(shot)
        group.tap()
        sleep(3)
        let open = XCTAttachment(screenshot: app.screenshot())
        open.name = "declutter-expanded"
        open.lifetime = .keepAlways
        add(open)
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "car.chip").count, 3, "the group spread out into chips")
    }
}
