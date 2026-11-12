import XCTest

/// EM1 (docs/EXPLORE-MERGE.md): the navigation map without a trip, behind `-SaryOneMap`.
/// Parity with the home map is proven by the shots: same place, same zoom, the flag as the only variable.
final class OneMapIdleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], oneMap: Bool = true, text: String? = nil, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-resetState"] : []) + ["-demo", "-SaryScreen", "home", "-SaryScheme", "light"]
            + (oneMap ? ["-SaryOneMap"] : []) + extra
            + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Drag the idle sheet up to its half height (the outings, «طلعة جديدة» and «انضم برابط» live there).
    private func pullSheetUp(_ app: XCUIApplication) {
        let h = app.windows.firstMatch.frame.height
        let sheet = el(app, "idle.sheet").frame
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.02, (sheet.minY - 14) / h)))
        start.press(forDuration: 0.15, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        shot("idle-half")
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "em1"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    /// The idle sheet carries the home content; the map has exploration's capabilities and the one shared layers button.
    func testIdleMapHoldsHomeContentAndTheSharedLayersButton() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30), "the search field of the home content is in the sheet")
        app.allowLocationIfAsked(within: 3)
        XCTAssertTrue(el(app, "explore.header").waitForExistence(timeout: 10), "exploration's layer bar and coordinate card are on")
        XCTAssertFalse(el(app, "explore-exit").exists, "no way out of exploration: it is the map")
        let layers = el(app, "map.layers")
        XCTAssertTrue(layers.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.layers").count, 1)
        shot("idle-peek")
        layers.tap()
        XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10), "the same shared sheet")
        for id in ["layer.satellite", "layer.topo", "weather.layer.rain", "explore-camp-sites", "explore-hires"] {
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), "\(id) is in the idle map's sheet")
        }
        shot("idle-layers")
    }

    /// The search of the home content works over the navigation map: a coordinate opens the place's brief.
    func testIdleSearchPicksAPlaceAndOpensItsBrief() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        el(app, "idle.search").tap()
        let field = el(app, "live.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("24.7136, 46.6753")
        let row = el(app, "live.search.coordinate")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons.firstMatch.exists ? row.buttons.firstMatch.tap() : row.tap()
        XCTAssertTrue(el(app, "point.sheet.scroll").waitForExistence(timeout: 15), "the place brief opens over the map")
        shot("idle-search-brief")
    }

    /// The home content without the flag is untouched (the default path).
    func testWithoutTheFlagTheHomeMapIsStillTheDefault() {
        let app = launch(oneMap: false)
        XCTAssertTrue(app.buttons["home.locate"].waitForExistence(timeout: 30))
        XCTAssertFalse(el(app, "idle.search").exists)
        shot("home-flat")
    }

    /// Same place and zoom, only the high-res imagery switch differs (R01).
    func testHighResIsOnByDefaultInTheIdleMap() {
        let on = launch(["-SaryHiRes", "on"])
        XCTAssertTrue(el(on, "idle.search").waitForExistence(timeout: 30))
        on.allowLocationIfAsked(within: 3)
        sleep(8)
        shot("idle-hires-on")
        on.terminate()
        let off = launch(["-SaryHiRes", "off"], reset: false)
        XCTAssertTrue(el(off, "idle.search").waitForExistence(timeout: 30))
        off.allowLocationIfAsked(within: 3)
        sleep(8)
        shot("idle-hires-off")
    }

    // MARK: EM2: the idle session holds up as a screen of the app

    /// An invite link opened on the idle map is shown once, from the idle map's own sheet (the root has nothing else to present from).
    func testInviteOnTheIdleMapShowsExactlyOnce() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryDemoInvite", "group", "-SaryOneMap", "-SaryScheme", "light"]
        app.launch()
        app.allowLocationIfAsked()
        XCTAssertTrue(app.buttons["invite.join"].waitForExistence(timeout: 30), "the invite shows over the idle map")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "invite.join").count, 1, "never twice")
        shot("idle-invite")
    }

    /// «طلعاتي» in the idle sheet opens the outing; the idle map is gone (the outing's own screen replaces it).
    func testOpeningAnOutingFromTheIdleSheetLeavesTheIdleMap() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        app.allowLocationIfAsked(within: 3)
        pullSheetUp(app)
        let row = app.buttons["outing-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the active outing is on the idle sheet at half height")
        row.tap()
        XCTAssertTrue(el(app, "idle.search").waitForNonExistence(timeout: 20), "the outing's screen replaced the idle map")
        shot("idle-opened-outing")
    }

    /// «ملاحة إلى هنا» on a place brief opened from the idle map starts a real solo outing, not a plan on the carrier session.
    func testNavigateFromTheIdleBriefOpensASoloOuting() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        app.allowLocationIfAsked(within: 3)
        el(app, "idle.search").tap()
        let field = el(app, "live.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("24.7590, 46.7491")
        let row = el(app, "live.search.coordinate")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons.firstMatch.exists ? row.buttons.firstMatch.tap() : row.tap()
        XCTAssertTrue(el(app, "point.sheet.scroll").waitForExistence(timeout: 15))
        let go = el(app, "point.navigate")
        for _ in 0..<4 where !go.exists || !go.isHittable { app.swipeUp() }
        XCTAssertTrue(go.waitForExistence(timeout: 5), "«ملاحة إلى هنا» is on the brief")
        go.tap()
        XCTAssertTrue(el(app, "idle.search").waitForNonExistence(timeout: 25), "the solo outing replaced the idle map")
        shot("idle-navigate-solo")
    }

    // MARK: EM3: the home's overlays on the idle map

    /// The chips are the home's: «البر» + the everyday and desert categories. A chip opens the search already asking for it.
    func testCategoryChipsOpenTheSearchAndTheToolsHandleOpensTheTools() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        app.allowLocationIfAsked(within: 3)
        for id in ["idle.tools.open", "idle.category.restaurants", "idle.category.cafes", "idle.category.mosques", "idle.category.fuel"] {
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 10), "\(id) is a chip on the idle sheet")
        }
        shot("idle-chips")
        el(app, "idle.category.cafes").tap()
        let field = el(app, "live.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "مقهى", "the chip's query is already in the field")
        el(app, "live.search.close").tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        el(app, "idle.tools.open").tap()
        XCTAssertTrue(el(app, "home.tools").waitForExistence(timeout: 10), "«البر» opens the desert tools")
        for id in ["home.tools.weather", "home.tools.qibla", "home.tools.camp"] { XCTAssertTrue(el(app, id).exists, id) }
        shot("idle-tools")
    }

    /// «موقعي», the compass and «المزيد» sit with the one layers button, and no overlap with each other or the sheet.
    func testSideColumnHasLocateCompassMoreAndNeverOverlaps() {
        for (tag, size) in [("normal", nil), ("axxl", "UICTContentSizeCategoryAccessibilityXXL")] as [(String, String?)] {
            let app = launch(text: size)
            XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30), tag)
            app.allowLocationIfAsked(within: 3)
            let ids = ["map.layers", "outing-locate", "idle-more"]
            for id in ids { XCTAssertTrue(el(app, id).waitForExistence(timeout: 15), "\(tag): \(id)") }
            let compact = app.windows.firstMatch.frame.height < 760
            XCTAssertEqual(el(app, "explore-places").exists, !compact, "\(tag): «أماكني» is in the column only when it fits, else under «المزيد»")
            let frames = (ids + (compact ? [] : ["explore-places"])).map { (id: $0, f: el(app, $0).frame) }
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) {
                    XCTAssertTrue(a.f.intersection(b.f).isEmpty, "\(tag): \(a.id) and \(b.id) do not overlap")
                }
            }
            let sheet = el(app, "idle.sheet").frame
            for a in frames { XCTAssertLessThanOrEqual(a.f.maxY, sheet.minY + 1, "\(tag): \(a.id) is above the sheet") }
            if size == nil { shot("idle-side") }
            el(app, "idle-more").tap()
            XCTAssertTrue(app.buttons["درون"].waitForExistence(timeout: 5), "\(tag): «المزيد» holds the drone")
            XCTAssertTrue(app.buttons["الوضع الواقعي"].exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
            app.terminate()
        }
    }

    /// «انضم برابط» (the paste sheet) and the profile with the home's pages behind it.
    func testJoinByLinkAndTheProfileFlowWork() {
        let app = launch()
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        app.allowLocationIfAsked(within: 3)
        pullSheetUp(app)
        XCTAssertTrue(el(app, "idle.join").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "idle.new").exists)
        el(app, "idle.join").tap()
        XCTAssertTrue(el(app, "paste.paste").waitForExistence(timeout: 10), "the paste-a-link sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(el(app, "paste.paste").waitForNonExistence(timeout: 10), "the sheet is dismissed")
        el(app, "idle.profile").tap()
        XCTAssertTrue(el(app, "profile.sheet.settings").waitForExistence(timeout: 10), "the profile sheet")
        shot("idle-profile")
        el(app, "profile.sheet.settings").tap()
        XCTAssertTrue(app.staticTexts["الإعدادات"].firstMatch.waitForExistence(timeout: 10), "the settings page is pushed")
    }

    // MARK: idle polish: queued explainer, opening zoom, «قرّب لصور أوضح»

    /// A sheet never stacks over the idle sheet: the explainer waits behind the search and shows once it is closed.
    func testTheNotificationExplainerWaitsBehindAnOpenIdleSheet() {
        let app = launch(["-SaryOfferNotify", "40"])
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        app.allowLocationIfAsked(within: 3)
        el(app, "idle.search").tap()
        XCTAssertTrue(el(app, "live.search.field").waitForExistence(timeout: 10))
        sleep(45)   // the offer arrived 40 s after launch
        let explainer = app.staticTexts["نبّهك إذا احتاجك أحد؟"]
        XCTAssertFalse(explainer.exists, "queued behind the open search")
        shot("idle-notify-queued")
        el(app, "live.search.close").tap()
        XCTAssertTrue(explainer.waitForExistence(timeout: 15), "shown once the search is closed")
        shot("idle-notify-shown")
    }

    /// In a city the idle map opens at 15, below the enhancement gate (18, not lowered): the chip says so and takes you there.
    func testTheHiResHintAppearsInACityAndTakesYouToTheGate() {
        let on = launch(["-SaryHiRes", "on", "-SaryHiResRemote", "on"])
        let chip = el(on, "idle.hires.hint")
        XCTAssertTrue(chip.waitForExistence(timeout: 40), "«قرّب لصور أوضح» at the opening zoom in Riyadh")
        shot("idle-hires-hint")
        chip.tap()
        sleep(6)
        shot("idle-hires-hint-after-tap")
        XCTAssertTrue(chip.waitForNonExistence(timeout: 20), "at the gate the chip is gone")
        on.terminate()
        let off = launch(["-SaryHiRes", "off"], reset: false)
        XCTAssertTrue(el(off, "idle.search").waitForExistence(timeout: 30))
        sleep(10)
        XCTAssertFalse(el(off, "idle.hires.hint").exists, "switched off: nothing to promise")
    }

    /// Opt-in (`TEST_RUNNER_SARY_OPEN_LAND=1`, with `xcrun simctl location <udid> set 25.12,46.10`): on open land the idle
    /// map opens at 16, inside the gate, so no hint and the «مُحسّنة» badge comes by itself.
    func testOpenLandOpensInsideTheEnhancementGate() throws {
        guard ProcessInfo.processInfo.environment["SARY_OPEN_LAND"] != nil else { throw XCTSkip("set TEST_RUNNER_SARY_OPEN_LAND=1 and put the simulator on open land") }
        let app = launch(["-SaryHiRes", "on", "-SaryHiResRemote", "on"])
        XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
        app.allowLocationIfAsked(within: 3)
        XCTAssertTrue(el(app, "hires.badge").waitForExistence(timeout: 150), "«مُحسّنة» at the opening zoom on open land")
        XCTAssertFalse(el(app, "idle.hires.hint").exists)
        sleep(60)
        shot("openland-opening")
    }

    // MARK: R01: high-res imagery where it exists

    /// The enhancement draws only from z16 in the desert and z18 in a city (`HiResZoom`); the home map's z15 never reached it.
    /// Opt-in (slow: network tiles + the on-device model): `TEST_RUNNER_SARY_R01=1`. Shots: `r01-<spot>-on|off`.
    func testHighResAtTheZoomWhereItExistsShowsTheBadgeAndChangesThePixels() throws {
        guard ProcessInfo.processInfo.environment["SARY_R01"] != nil else { throw XCTSkip("set TEST_RUNNER_SARY_R01=1 (slow, needs the network)") }
        let spots = [("huraymila-z18", "25.12,46.10,18.0"), ("riyadh-z19", "24.80,46.68,19.0")]
        for (name, cam) in spots {
            for on in [true, false] {
                let app = launch(["-SaryHiResCam", cam, "-SaryHiRes", on ? "on" : "off", "-SaryHiResRemote", "on"], reset: on)
                XCTAssertTrue(el(app, "idle.search").waitForExistence(timeout: 30))
                app.allowLocationIfAsked(within: 3)
                let badge = el(app, "hires.badge")
                if on {
                    XCTAssertTrue(badge.waitForExistence(timeout: 150), "\(name): «مُحسّنة» once enhanced tiles are on screen")
                    Thread.sleep(forTimeInterval: 90)
                } else {
                    Thread.sleep(forTimeInterval: 40)
                    XCTAssertFalse(badge.exists, "\(name): switched off, no badge")
                }
                shot("r01-\(name)-\(on ? "on" : "off")")
                app.terminate()
            }
        }
    }

    /// «متقدم» holds the switch, off by default; turning it on is what `OneMapFlag` reads.
    func testAdvancedSettingsHasTheOneMapSwitchOffByDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "advanced", "-SaryScheme", "light"]
        app.launch()
        app.allowLocationIfAsked()
        let sw = app.switches["dev.oneMap"]
        XCTAssertTrue(sw.waitForExistence(timeout: 30), "the switch is in «متقدم»")
        XCTAssertEqual(sw.value as? String, "0", "off by default")
        XCTAssertTrue(app.staticTexts[OneMapSwitchText.title].exists)
        shot("advanced-switch-off")
        sw.tap()
        XCTAssertEqual(sw.value as? String, "1")
        shot("advanced-switch-on")
        sw.tap()   // leave it off
    }
}

private enum OneMapSwitchText { static let title = "الخريطة الواحدة (تجريبي)" }

/// EM4: the live outing map (no exploration mode) gets exploration's capabilities with the flag, and only with it.
final class OutingCapabilitiesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(oneMap: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped"]
            + (oneMap ? ["-SaryOneMap"] : []) + extra
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
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("em4-\(name).png"))
        }
    }

    func testTheOutingLayersSheetHasTheExplorationRowsOnlyWithTheFlag() {
        for flag in [false, true] {
            let app = launch(oneMap: flag)
            let layers = el(app, "map.layers")
            XCTAssertTrue(layers.waitForExistence(timeout: 40), "flag=\(flag): the outing map's layers button")
            layers.tap()
            XCTAssertTrue(el(app, "explore.layers.sheet").waitForExistence(timeout: 10))
            XCTAssertTrue(el(app, "layer.topo").waitForExistence(timeout: 5))
            XCTAssertEqual(el(app, "weather.layer.rain").waitForExistence(timeout: flag ? 5 : 2), flag, "flag=\(flag): weather layers in the outing's sheet")
            XCTAssertTrue(el(app, "explore-camp-sites").exists, "flag=\(flag): camp sites are in the outing's sheet either way (S3)")
            shot("outing-sheet-flag-\(flag ? "on" : "off")")
            app.terminate()
        }
    }

    /// Same trip, same place and zoom: the chosen topographic base shows on the outing map only with the flag.
    func testTheChosenBaseLayerShowsOnTheOutingMapOnlyWithTheFlag() {
        for flag in [false, true] {
            let app = launch(oneMap: flag, extra: ["-SaryLayer", "topo"])
            XCTAssertTrue(el(app, "map.layers").waitForExistence(timeout: 40))
            sleep(10)
            shot("outing-topo-flag-\(flag ? "on" : "off")")
            app.terminate()
        }
    }
}

