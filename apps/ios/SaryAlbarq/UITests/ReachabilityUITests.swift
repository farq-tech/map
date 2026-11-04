import XCTest

/// Build 8 «ترتيب الشاشة»: nothing was removed. Every feature of the live screen is still
/// reachable in at most two taps from the map — the floating group, the «+» actions sheet
/// (every group, every entry) and the three sheet tabs. docs/IA-REDESIGN.md.
final class ReachabilityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(context: String = "stopped") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", context]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(any(app, "outing-sheet-summary").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The map itself: one top bar, one floating group, SOS and the walkie-talkie.
    func testMapKeepsOnlyTheEssentials() {
        let app = launch()
        for id in ["outing-back", "trip.header", "outing-link-state", "weather.chip", "outing-locate", "outing-fit", "outing-actions", "outing-sos", "outing-ptt"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 10), "\(id) on the map")
        }
        for id in ["outing-more", "outing-note-open", "outing-navigate", "outing-search", "outing-nearest-open", "outing-stuck", "plan.follow", "plan.openSearch"] {
            XCTAssertFalse(any(app, id).exists, "\(id) is not on the map any more (one tap away)")
        }
        /* The status dot opens the details; the header opens «الرحلة». */
        any(app, "outing-link-state").tap()
        XCTAssertTrue(any(app, "status.details").waitForExistence(timeout: 5), "status details under the header")
        any(app, "outing-link-state").tap()
        any(app, "trip.header").tap()
        XCTAssertTrue(app.buttons["tab.trip"].waitForExistence(timeout: 5), "the header opens the trip's details")
    }

    /// «+»: four groups, every entry present (identifiers kept from the old cluster and «المزيد»).
    func testActionSheetHoldsEveryAction() {
        let app = launch()
        let plus = app.buttons["outing-actions"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        XCTAssertTrue(any(app, "outing-actions-sheet").waitForExistence(timeout: 5))
        for group in ["الطريق", "المجموعة", "الخدمات", "الترفيه"] {
            XCTAssertTrue(app.staticTexts[group].exists, "group «\(group)»")
        }
        let entries = ["outing-navigate", "outing-search", "outing-backtrack", "plan.follow",
                       "outing-note-open", "outing-stuck", "outing-waypoint-add", "outing-copyme",
                       "outing-nearest-open", "outing-weather", "outing-youtube"]
        for id in entries {
            XCTAssertTrue(any(app, id).exists, "\(id) in the actions sheet")
        }
        shot(app, "actions-sheet")
        /* Each entry does something: «الطقس» opens the weather sheet. */
        any(app, "outing-weather").tap()
        XCTAssertTrue(any(app, "weather.sheet").waitForExistence(timeout: 5), "«الطقس» opens the weather")
    }

    /// The three tabs and what each holds.
    func testSheetTabsHoldEverything() {
        let app = launch()
        any(app, "outing-sheet-summary").tap()
        let tabs: [(String, [String])] = [
            ("tab.trip", ["plan.destination", "plan.openEditor", "plan.openSearch", "safety-section", "timer-card", "sheet-stuck", "trail.backtrack", "trail.friends"]),
            ("tab.group", ["participant-row", "convoy.section", "rally-card", "invite-section"]),
            ("tab.more", ["settings-pause-sharing", "settings-battery", "settings-notify", "settings-ptt-mute", "media.entry",
                        "settings-context", "settings-drive", "settings-night", "speed.alert", "trail.friends.settings", "settings-offline", "settings-phone", "settings-leave"]),
        ]
        for (tab, ids) in tabs {
            let b = app.buttons[tab]
            XCTAssertTrue(b.waitForExistence(timeout: 5), "tab «\(tab)»")
            b.tap()
            sleep(1)
            for id in ids {
                XCTAssertTrue(any(app, id).waitForExistence(timeout: 3), "\(id) in «\(tab)»")
            }
            shot(app, "tab-\(tab)")
        }
    }

    /// Driving: the map keeps «موقعي» and «المجموعة» only; the speed shows.
    func testDrivingContextIsMinimal() {
        let app = launch(context: "driving")
        XCTAssertTrue(app.buttons["outing-locate"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["outing-fit"].exists)
        XCTAssertFalse(app.buttons["outing-actions"].exists, "no «+» while driving")
        XCTAssertTrue(any(app, "speedometer").firstMatch.exists, "the speed while driving")
        /* Raising the sheet means reading: the screen goes back to «stopped» and «+» is there. */
        any(app, "outing-sheet-summary").tap()
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 5), "«+» once the sheet is up")
    }
}
