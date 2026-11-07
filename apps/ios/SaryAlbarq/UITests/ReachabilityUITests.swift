import XCTest

/// Nothing was lost in the UX simplification (docs/ux-simplify-inventory.md): every feature of the
/// live screen is reachable from the sheet's quick row, «المزيد» (every group, every entry), its
/// panels and «الإعدادات»; exact duplicates are gone.
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

    /// The map itself: one top bar, SOS and the walkie-talkie; the sheet's quick row under the people.
    func testMapKeepsOnlyTheEssentials() {
        let app = launch()
        for id in ["outing-back", "trip.header", "outing-link-state", "weather.chip", "outing-locate", "outing-sos", "outing-ptt",
                   "sheet.quickRow", "outing-actions", "sheet.chat", "sheet.rally", "trail.backtrack"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 10), "\(id) on the map / quick row")
        }
        XCTAssertTrue(any(app, "outing-navigate").exists || any(app, "outing-guide-all").exists, "the primary: «ملاحة» or «وجّه الكل»")
        /* UX simplification: one way into each thing. */
        for id in ["outing-more", "outing-note-open", "outing-search", "outing-nearest-open", "outing-stuck", "plan.follow", "plan.openSearch",
                   "trip.explore", "outing-fit", "tab.trip", "tab.group", "tab.map", "sheet.settings", "live.leave"] {
            XCTAssertFalse(any(app, id).exists, "\(id) is not on the map / sheet any more")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "outing-actions").count, 1, "«المزيد» once (no «+» on the map)")
        /* The status dot opens the details; the header opens «الوجهة والخطة». */
        any(app, "outing-link-state").tap()
        XCTAssertTrue(any(app, "status.details").waitForExistence(timeout: 5), "status details under the header")
        any(app, "outing-link-state").tap()
        any(app, "trip.header").tap()
        XCTAssertTrue(any(app, "panel.route").waitForExistence(timeout: 5), "the header opens the trip's details")
    }

    /// «المزيد»: five short sections and «الطلعة»; each entry once.
    func testActionSheetHoldsEveryAction() {
        let app = launch()
        let more = app.buttons["outing-actions"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(any(app, "outing-actions-sheet").waitForExistence(timeout: 5))
        for group in ["الطريق", "الجماعة", "السلامة", "المكان", "الخريطة", "الطلعة"] {
            XCTAssertTrue(app.staticTexts[group].exists, "group «\(group)»")
        }
        XCTAssertFalse(app.staticTexts["الترفيه"].exists, "radio / YouTube are in the settings")
        for id in ["outing-route", "outing-search", "outing-invite", "outing-convoy", "outing-note-open", "outing-stuck", "outing-enjad",
                   "outing-timer", "outing-location-tools", "outing-weather-tools", "outing-nearest-open",
                   "outing-explore", "outing-fit", "outing-settings", "settings-leave"] {
            XCTAssertTrue(any(app, id).exists, "\(id) in «المزيد»")
        }
        for id in ["outing-brief", "outing-save-place", "outing-weather", "outing-qibla", "outing-waypoint-add"] {
            XCTAssertFalse(any(app, id).exists, "\(id) is revealed when its related tool group is opened")
        }
        for id in ["outing-backtrack", "outing-chat", "outing-rally", "outing-hires", "outing-realistic", "outing-effects", "outing-radio", "outing-youtube"] {
            XCTAssertFalse(any(app, id).exists, "\(id): a duplicate, gone from «المزيد»")
        }
        shot(app, "actions-sheet")
        any(app, "outing-weather-tools").tap()
        XCTAssertTrue(any(app, "outing-weather").waitForExistence(timeout: 3))
        XCTAssertTrue(any(app, "outing-qibla").exists)
        any(app, "outing-weather").tap()
        XCTAssertTrue(any(app, "weather.sheet").waitForExistence(timeout: 5), "«الطقس» opens the weather")
    }

    /// The raised sheet and the panels hold what the three tabs held.
    func testSheetAndPanelsHoldEverything() {
        let app = launch()
        any(app, "outing-sheet-summary").tap()
        for id in ["participant-row", "sheet.invite"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in the raised sheet")
        }
        let panels: [(String, [String])] = [
            ("outing-route", ["plan.destination", "plan.openEditor"]),
            ("outing-timer", ["safety-section", "timer-card", "sheet-stuck"]),
            ("outing-invite", ["invite-section"]),
        ]
        for (tile, ids) in panels {
            XCTAssertTrue(app.openTool(tile), tile)
            for id in ids { XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) behind «\(tile)»") }
            shot(app, "panel-\(tile)")
            any(app, "panel.close").tap()
            sleep(2)
        }
        any(app, "sheet.rally").tap()
        XCTAssertTrue(any(app, "rally-card").waitForExistence(timeout: 6))
        any(app, "panel.close").tap()
        sleep(2)
        /* «الإعدادات» (the header's gear): five groups, one-line rows; the phone and the trail there. */
        app.buttons["tab.more"].tap()
        for id in ["settings.sharing", "settings.phone", "settings.lateAlert", "settings.defaultLayer", "settings.mapDirection", "settings.units",
                   "settings.driving", "settings.trail", "settings.defaultChannel", "settings.voiceAutoplay", "settings.volume", "settings.media",
                   "settings.clearHistory", "settings.gpsPrecise", "settings-offline", "settings.diagnostics"] {
            let el = any(app, id)
            if !el.waitForExistence(timeout: 2) { app.swipeUp() }
            XCTAssertTrue(el.waitForExistence(timeout: 3), "\(id) in «الإعدادات»")
        }
        XCTAssertFalse(any(app, "settings.tripType").exists, "«نوع الطلعة» (قريبًا) is gone")
        XCTAssertFalse(any(app, "settings.whoSees").exists, "merged into «موقعي ومن يشوفه»")
    }

    /// Exploration (build 9): every tool one tap from its map, two from the trip map.
    func testExplorationToolsWithinTwoTaps() {
        let app = launch()
        XCTAssertTrue(app.openTool("outing-explore"))
        for id in ["explore-layers", "explore-places", "explore-save", "explore-copy", "explore-coord-format", "explore-exit"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id): two taps from the trip map")
        }
        app.buttons["explore-layers"].tap()
        for id in ["layer.satellite", "layer.standard", "layer.topo", "explore-terrain3d", "explore-realistic", "explore-offline",
                   "explore-desert-route", "explore-camp-suggest"] {
            XCTAssertTrue(any(app, id).waitForExistence(timeout: 5), "\(id) in «الطبقات»")
        }
    }

    /// «انسخ موقعي» on «أنت» (my row), «رسالة فوق سيارتي» there too.
    func testMovedActionsStayWithinTwoTaps() {
        let app = launch()
        any(app, "outing-sheet-summary").tap()
        let mine = app.descendants(matching: .any).matching(identifier: "participant-row").matching(NSPredicate(format: "label CONTAINS %@", "أنت")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.tap()
        XCTAssertTrue(app.buttons["انسخ أو شارك موقعي"].waitForExistence(timeout: 5), "«انسخ موقعي» on «أنت»")
        XCTAssertTrue(app.buttons["رسالة فوق سيارتي"].exists)
    }

    /// «تنبيهات القافلة»: from the live sheet («المزيد») and from Settings; every rule there.
    func testConvoyAlertRulesReachable() {
        let app = launch()
        /* «أدوات» → «القافلة» (Lovable's settings keep only «تنبيه لما أحد يتأخر»). */
        XCTAssertTrue(app.openTool("outing-convoy"))
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
        XCTAssertFalse(any(app, "sheet.quickRow").exists, "no quick row while driving")
        /* Raising the sheet means reading: the screen goes back to «stopped» and «المزيد» is there. */
        any(app, "outing-sheet-summary").tap()
        XCTAssertTrue(app.buttons["outing-actions"].waitForExistence(timeout: 5), "«المزيد» once the sheet is up")
    }
}
