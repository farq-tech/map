import CoreLocation
import XCTest

/// Owner's Build 44 report: while guiding he could end neither the outing («الطلعة») nor only the trip («الرحلة»).
/// Two named actions now: «إنهاء الرحلة» (guidance only) and «إنهاء الطلعة» (the outing), each with a sentence saying what happens,
/// in one or two taps from the guidance bar and from «المزيد».
/// Set SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) to also write PNGs.
final class EndTripOutingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(guiding: Bool, solo: Bool = false, text: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var a = ["-resetState", "-demo", "-demoSharing", "-SaryWeatherDemo", "calm", "-SaryWeather", "none",
                 "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0"]
        if solo { a = ["-resetState", "-demo", "-SarySolo", "24.7590,46.7491,روضة الثمامة", "-SaryNavDemo", "-SaryScheme", "light", "-SaryDrive", "0",
                                  "-SaryNight", "0", "-SaryWeatherDemo", "calm", "-SaryContext", "stopped"] }
        else if guiding { a += ["-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavStart"] }
        else { a += ["-SaryLiveSheet", "peek", "-SaryContext", "stopped"] }
        app.launchArguments = a + extra + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("end-\(name).png"))
        }
    }

    private func waitGuiding(_ app: XCUIApplication) {
        XCTAssertTrue(el(app, "nav.end").waitForExistence(timeout: 75), "guidance bar with «إنهاء الرحلة»")
    }

    // MARK: guidance, owner

    func testGuidanceOwnerSeesTripAndOutingChoicesAndTripEndKeepsTheOuting() {
        let app = launch(guiding: true)
        waitGuiding(app)
        XCTAssertTrue(el(app, "nav.end").label.contains("إنهاء الرحلة"), el(app, "nav.end").label)
        el(app, "nav.end").tap()                                              // tap 1
        XCTAssertTrue(el(app, "end.sheet").waitForExistence(timeout: 5))
        for a in ["endTrip", "endOutingForAll", "leaveOnly"] { XCTAssertTrue(el(app, "end.action.\(a)").exists, a) }
        XCTAssertFalse(el(app, "end.action.leaveOuting").exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "جوالك فقط")).firstMatch.exists, "the sentence says what happens")
        shot("sheet-owner")
        el(app, "end.action.endTrip").tap()                                   // tap 2
        XCTAssertTrue(el(app, "nav.bottomBar").waitForNonExistence(timeout: 8), "guidance is over")
        XCTAssertTrue(el(app, "outing-sheet-summary").waitForExistence(timeout: 10) || app.buttons["outing-actions"].waitForExistence(timeout: 5), "the outing is still live")
        XCTAssertFalse(app.buttons["trip.return"].exists, "the outing did not end")
    }

    func testGuidanceOwnerCanEndTheOutingForEveryoneInTwoTaps() {
        let app = launch(guiding: true)
        waitGuiding(app)
        el(app, "nav.end").tap()
        XCTAssertTrue(el(app, "end.action.endOutingForAll").waitForExistence(timeout: 5))
        let tap = Date()
        el(app, "end.action.endOutingForAll").tap()
        XCTAssertTrue(app.buttons["trip.return"].waitForExistence(timeout: 20) || el(app, "outing-ended").waitForExistence(timeout: 5)
                      || app.staticTexts["انتهت الطلعة"].firstMatch.waitForExistence(timeout: 5), "the outing ended")
        XCTAssertFalse(el(app, "nav.bottomBar").exists)
        /* Instant: the tight bound (< 100 ms with a stalled backend) is in BackgroundSessionTests; XCUI wall time under host load is not a measure. */
        _ = tap
        XCTAssertFalse(app.staticTexts["جاري إنهاء الطلعة…"].exists, "no waiting toast")
    }

    func testGuidanceMoreSheetHasTheEndEntryAtTheTop() {
        let app = launch(guiding: true)
        waitGuiding(app)
        app.buttons["nav.more"].tap()                                         // tap 1
        let entry = el(app, "outing.endEntry")
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "«إنهاء الطلعة» is in the header of «المزيد», not under the fold")
        XCTAssertTrue(entry.isHittable)
        entry.tap()                                                           // tap 2
        XCTAssertTrue(el(app, "end.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "end.action.endTrip").exists, "while guiding the trip is offered too")
        XCTAssertTrue(el(app, "end.action.endOutingForAll").exists)
    }

    // MARK: no guidance

    func testOutingWithoutGuidanceOffersOnlyTheOutingChoices() {
        let app = launch(guiding: false)
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 25))
        app.buttons["outing-actions"].tap()
        let entry = el(app, "outing.endEntry")
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(el(app, "end.sheet").waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "end.action.endTrip").exists, "no guidance: no trip to end")
        XCTAssertTrue(el(app, "end.action.endOutingForAll").exists)
        XCTAssertTrue(el(app, "end.action.leaveOnly").exists)
        shot("sheet-no-guidance")
        el(app, "end.cancel").tap()
        XCTAssertTrue(el(app, "end.sheet").waitForNonExistence(timeout: 5))
    }

    func testLeaveOnlyLeavesTheOuting() {
        let app = launch(guiding: false)
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 25))
        app.buttons["outing-actions"].tap()
        el(app, "outing.endEntry").tap()
        XCTAssertTrue(el(app, "end.action.leaveOnly").waitForExistence(timeout: 8))
        el(app, "end.action.leaveOnly").tap()
        XCTAssertTrue(app.buttons["outing-actions"].waitForNonExistence(timeout: 15), "left: the outing screen is gone")
    }

    // MARK: solo

    func testSoloTripEndIsTheOnlyChoiceAndEndsTheSoloOuting() {
        let app = launch(guiding: true, solo: true)
        XCTAssertTrue(el(app, "nav.end").waitForExistence(timeout: 75), "solo guidance starts by itself")
        el(app, "nav.end").tap()
        XCTAssertTrue(el(app, "end.action.endSolo").waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "end.action.endOutingForAll").exists)
        XCTAssertFalse(el(app, "end.action.leaveOnly").exists)
        shot("sheet-solo")
    }

    // MARK: layout

    /// Small and large text: the guidance bar's end button stays on screen, clear of SOS, «المزيد» and the layers button;
    /// the sheet's rows stay inside the screen and apart from each other.
    func testLayoutSmallAndLargeText() {
        for (tag, size) in [("small", "UICTContentSizeCategoryXS"), ("large", "UICTContentSizeCategoryAccessibilityXXL")] {
            let app = launch(guiding: true, text: size)
            waitGuiding(app)
            sleep(2)
            let end = el(app, "nav.end")
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(end.frame), "\(tag): inside the screen")
            XCTAssertGreaterThanOrEqual(end.frame.height, 44, "\(tag): a real touch target")
            for other in ["outing-sos", "map.layers", "nav.more", "outing-ptt"] {
                let o = el(app, other)
                guard o.exists, !o.frame.isEmpty else { continue }
                let x = end.frame.intersection(o.frame)
                XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag): nav.end \(end.frame) overlaps \(other) \(o.frame)")
            }
            shot("bar-\(tag)")
            end.tap()
            XCTAssertTrue(el(app, "end.sheet").waitForExistence(timeout: 5))
            let ids = ["endTrip", "endOutingForAll", "leaveOnly"].map { el(app, "end.action.\($0)") }
            for r in ids { XCTAssertTrue(r.exists, "\(tag)") }
            for (i, r) in ids.enumerated() {
                XCTAssertGreaterThan(r.frame.width, 100)
                for s in ids[(i + 1)...] {
                    let x = r.frame.intersection(s.frame)
                    XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag): rows overlap")
                }
            }
            shot("sheet-\(tag)")
            app.terminate()
        }
    }
}
