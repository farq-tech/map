import CoreLocation
import XCTest

/// «رحلة كاملة» end to end on the demo outing: a simulated drive from 2 km out to the
/// destination («روضة الثمامة») → the progress grows → parked inside 150 m for 30 s →
/// «وصلت 🎉» → the leader «أنهِ الرحلة» → «ملخص الرحلة» with the trip section.
/// (The screenshots in the PR were taken with `xcrun simctl location … start` over the same path.)
final class TripUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let dest = CLLocationCoordinate2D(latitude: 24.7590, longitude: 46.7491)

    /// `m` metres south-west of the destination along a straight approach.
    private func approach(_ m: Double) -> CLLocation {
        let d = m / 111_195 / 2.squareRoot()
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: dest.latitude - d, longitude: dest.longitude - d / cos(dest.latitude * .pi / 180)),
                          altitude: 600, horizontalAccuracy: 5, verticalAccuracy: 5, course: 45, speed: 25, timestamp: Date())
    }

    private func move(to l: CLLocation) {
        XCUIDevice.shared.location = XCUILocation(location: l)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testSimulatedDriveFromStartToArrivalToSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        move(to: approach(2200))
        app.launch()

        let peek = app.descendants(matching: .any)["trip.header"]
        XCTAssertTrue(peek.waitForExistence(timeout: 20), "the trip header sits at the top of the map")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        /* On a clean simulator iOS asks for the location a moment later; the permission monitor
         * only answers on an interaction: keep nudging until the first fix is in. */
        for _ in 0..<15 where peek.label.contains("ننتظر موقعك") {
            move(to: approach(2200))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            sleep(2)
        }
        XCTAssertFalse(peek.label.contains("ننتظر موقعك"), "the first fix is in: \(peek.label)")

        /* Drive in: 100 m every 4 s (25 m/s), with the GPS ticking each second in between. */
        var first: String?
        for m in stride(from: 2100.0, through: 100, by: -100) {
            for k in 0..<4 { move(to: approach(m + 100 - Double(k + 1) * 25)); usleep(1_000_000) }
            if first == nil, peek.label.contains("باقي") { first = peek.label }
        }
        let progressed = peek.label
        attach(app, "drive")
        XCTAssertNotNil(first, "progress shows while driving: \(peek.label)")
        XCTAssertNotEqual(first, progressed, "and it moves as we drive")
        XCTAssertTrue(progressed.contains("باقي"), progressed)

        /* Parked inside 150 m: the GPS wobbles a few metres; after 30 s we have arrived. */
        for k in 0..<40 {
            move(to: approach(60 + Double(k % 3) * 6))
            usleep(1_000_000)
            if peek.label.contains("واقفين عند") { break }
        }
        /* The arrival is said once: the header («واقفين عند …») and a 4 s toast; the trip's card with its
         * numbers is in the «الرحلة» sheet, which no longer opens by itself (the owner's «زحمة» review). */
        XCTAssertTrue(peek.label.contains("واقفين عند"), "the header says we are there: \(peek.label)")
        peek.tap()
        XCTAssertTrue(app.staticTexts["وصلت 🎉"].waitForExistence(timeout: 15), "the arrival card")
        XCTAssertTrue(app.descendants(matching: .any)["trip.arrivalOrder"].exists, "who arrived first")
        attach(app, "arrived")

        /* The demo me leads: «أنهِ الرحلة» → confirm. */
        let end = app.buttons["trip.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.tap()
        let confirm = app.buttons["أنهِ الطلعة للجميع"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let summary = app.buttons["trip.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "«ملخص الرحلة» once it ended")
        XCTAssertTrue(app.buttons["trip.return"].exists, "«طريق الرجعة» as a new trip")
        summary.tap()
        let trip = app.descendants(matching: .any)["summary.trip"]
        XCTAssertTrue(trip.waitForExistence(timeout: 15), "the trip section in the summary")
        attach(app, "summary")
    }

    func testLeaderCanEndOutingWhileItIsStillUnderway() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm",
                               "-SaryScheme", "light", "-SaryDrive", "0", "-SaryLiveSheet", "half"]
        app.launch()

        let end = app.buttons["trip.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 20), "the owner can end the outing before arrival")
        XCTAssertTrue(end.isHittable, "the end-outing action is reachable while the route is underway")
        end.tap()

        let confirm = app.buttons["أنهِ الطلعة للجميع"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "ending the outing asks for confirmation")
    }
}
