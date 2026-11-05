import XCTest

/// Build 8 «ترتيب الشاشة»: nothing was removed. Every feature of the live screen is still
/// reachable in at most two taps from the map — the floating group, the «+» actions sheet
/// (every group, every entry) and the three sheet tabs. docs/IA-REDESIGN.md.
/// Build 9 adds exploration (header «استكشاف» / «+» → الخريطة) and «تنبيهات القافلة».
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
        for id in ["outing-back", "trip.header", "outing-link-state", "weather.chip", "outing-locate", "outing-actions", "outing-sos", "outing-ptt"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 10), "\(id) on the map")
        }
        /* «تخفيف الزحمة»: the binoculars and «المجموعة» moved into «أدوات». */
        for id in ["outing-more", "outing-note-open", "outing-navigate", "outing-search", "outing-nearest-open", "outing-stuck", "plan.follow", "plan.openSearch",
                   "trip.explore", "outing-fit"] {
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
        for group in ["الطريق", "الجماعة", "السلامة", "المكان", "الترفيه", "الخريطة"] {
            XCTAssertTrue(app.staticTexts[group].exists, "group «\(group)»")
        }
        /* «اتبع الخطة» is in «الرحلة», «انسخ موقعي» on «أنت» (testMovedActionsStayWithinTwoTaps). */
        let entries = ["outing-navigate", "outing-search", "outing-backtrack",
                       "outing-note-open", "outing-stuck", "outing-enjad", "outing-waypoint-add",
                       "outing-nearest-open", "outing-weather", "outing-radio", "outing-youtube", "outing-explore", "outing-fit"]
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
            ("tab.trip", ["plan.destination", "plan.openEditor", "plan.openSearch", "plan.follow", "safety-section", "timer-card", "sheet-stuck", "trail.backtrack", "trail.friends"]),
            ("tab.group", ["participant-row", "convoy.section", "rally-card", "invite-section"]),
            ("tab.map", ["map.layers", "map.realistic", "map.offline"]),
            ("tab.more", ["settings-battery", "settings-notify", "settings-ptt-mute", "media.entry",
                        "settings-context", "settings-drive", "settings-night", "speed.alert", "settings-convoy-alerts", "trail.friends.settings", "settings-offline", "settings-phone", "settings-leave"]),
        ]
        for (tab, ids) in tabs {
            let b = app.buttons[tab]
            XCTAssertTrue(b.waitForExistence(timeout: 5), "tab «\(tab)»")
            b.tap()
            sleep(1)
            if tab == "tab.more" { app.openAdvancedSettings() }
            for id in ids {
                XCTAssertTrue(any(app, id).waitForExistence(timeout: 3), "\(id) in «\(tab)»")
            }
            shot(app, "tab-\(tab)")
        }
    }

    /// Exploration (build 9): every tool one tap from its map, two from the trip map.
    func testExplorationToolsWithinTwoTaps() {
        let app = launch()
        XCTAssertTrue(app.openTool("outing-explore"))
        for id in ["explore-layers", "explore-places", "explore-save", "explore-copy", "explore-coord-format", "explore-exit"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id): two taps from the trip map")
        }
        app.buttons["explore-layers"].tap()
        for id in ["layer.satellite", "layer.standard", "layer.topo", "explore-terrain3d", "explore-realistic", "explore-offline"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in «الطبقات»")
        }
    }

    /// What left «+» is still within two taps: «اتبع الخطة» in «الرحلة», «انسخ موقعي» on «أنت»,
    /// «الترددات» under «اضغط وتكلم».
    func testMovedActionsStayWithinTwoTaps() {
        let app = launch()
        any(app, "outing-sheet-summary").tap()
        app.buttons["tab.trip"].tap()
        let follow = any(app, "plan.follow")
        follow.scrollIntoView(in: app)
        XCTAssertTrue(follow.exists, "«اتبع الخطة» in «الرحلة»")
        app.buttons["tab.group"].tap()
        let mine = app.descendants(matching: .any).matching(identifier: "participant-row").matching(NSPredicate(format: "label CONTAINS %@", "أنت")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.tap()
        XCTAssertTrue(app.buttons["انسخ أو شارك موقعي"].waitForExistence(timeout: 5), "«انسخ موقعي» on «أنت»")
        XCTAssertTrue(app.buttons["رسالة فوق سيارتي"].exists)
    }

    /// «تنبيهات القافلة»: from the live sheet («المزيد») and from Settings; every rule there.
    func testConvoyAlertRulesReachable() {
        let app = launch()
        any(app, "outing-sheet-summary").tap()
        app.buttons["tab.more"].tap()
        let row = any(app, "settings-convoy-alerts")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        for id in ["rules.separation", "rules.separation.km", "rules.separation.grace", "rules.stop", "rules.stop.minutes",
                   "rules.silent", "rules.silent.minutes", "rules.tail", "rules.tail.grace"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in «تنبيهات القافلة»")
        }
    }

    /// Driving («تخفيف الزحمة» ١): no side column at all; SOS and «اضغط وتكلم» stay; the speed only
    /// once a real speed was read (never an empty «—»).
    func testDrivingContextIsMinimal() {
        let app = launch(context: "driving")
        XCTAssertTrue(any(app, "outing-ptt").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "outing-sos").exists, "SOS never hidden")
        XCTAssertFalse(app.buttons["outing-locate"].exists, "no side column while driving")
        XCTAssertFalse(app.buttons["outing-actions"].exists, "no «+» while driving")
        XCTAssertFalse(app.buttons["trip.explore"].exists)
        let speedo = any(app, "speedometer").firstMatch
        if speedo.exists { XCTAssertFalse(speedo.label.contains("غير معروفة"), "never an empty speedometer: \(speedo.label)") }
        /* Raising the sheet means reading: the screen goes back to «stopped» and «+» is there. */
        any(app, "outing-sheet-summary").tap()
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 5), "«+» once the sheet is up")
    }
}
