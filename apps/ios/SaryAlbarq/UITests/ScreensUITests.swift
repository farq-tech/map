import XCTest

/// The pages around the live map, with demo data (no server).
final class ScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    func testHomeListsOutingsByStateAndOpensSheets() {
        let app = launch(["-demo", "-SaryScreen", "home"])
        /* The map-first home: «طلعاتي» is in the raised sheet; the running outing is its card on top. */
        XCTAssertTrue(app.descendants(matching: .any)["home.search"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["home.active"].exists, "the running outing on the collapsed sheet")
        app.openHomeOutings()
        for name in ["طلعة الثمامة (عرض تجريبي)", "مشوار العارض", "كشتة الخميس", "كشتة نفود الثويرات"] {
            XCTAssertTrue(app.staticTexts[name].exists, name)
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "جارية")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["متوقفة مؤقتًا"].exists)
        XCTAssertTrue(app.staticTexts["لم تبدأ"].exists)
        app.buttons["list.create"].tap()
        XCTAssertTrue(app.textFields["create.dest.field"].waitForExistence(timeout: 5), "«طلعة جديدة» starts with «وين رايحين؟»")
        app.buttons["page-close"].tap()
        let join = app.buttons["list.join"]
        _ = join.waitForExistence(timeout: 5)
        join.tap()
        XCTAssertTrue(app.textFields["paste.field"].waitForExistence(timeout: 5))
    }

    func testHomeSheetContentScrollDoesNotCollapseSheet() {
        let app = launch(["-demo", "-SaryScreen", "home"])
        let handle = app.descendants(matching: .any)["home.sheet.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        let availableWidth = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(handle.frame.width, min(availableWidth, 560) + 1,
                                  "the map sheet stays comfortably narrow on iPad and fits iPhone")
        handle.tap()

        let expanded = app.descendants(matching: .any)["home.sheet.expanded"]
        let content = app.scrollViews["home.sheet.content"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.swipeUp()
        XCTAssertTrue(expanded.exists, "scrolling the categories and recent places must not resize the sheet")
        content.swipeDown()
        XCTAssertTrue(expanded.exists, "scrolling back to the top must leave the sheet expanded")

        handle.swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["home.sheet"].waitForExistence(timeout: 5),
                      "the dedicated handle still collapses the sheet")
    }

    func testSettingsReachEveryPage() {
        let app = launch(["-demo", "-SaryScreen", "settings"])
        for (row, title) in [("settings.appearance", "المظهر"), ("settings.privacy", "الخصوصية"), ("settings.notifications", "التنبيهات"), ("settings.about", "حول سَرى البارق")] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 10), row)
            app.buttons[row].tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
            app.buttons["page-back"].firstMatch.tap()
        }
    }

    func testEndedOutingOpensItsSummary() {
        let app = launch(["-demo", "-SaryScreen", "home"])
        // Ended outings live in the expanded «طلعاتي» sheet, not the collapsed home map.
        app.openHomeOutings()
        let ended = app.staticTexts["كشتة نفود الثويرات"]
        XCTAssertTrue(ended.waitForExistence(timeout: 10))
        ended.tap()
        XCTAssertTrue(app.descendants(matching: .any)["summary.stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["أبو فهد"].exists, "shared totals are listed")
    }

    func testInviteStates() {
        let expired = launch(["-demo", "-SaryScreen", "invite-expired"])
        XCTAssertTrue(expired.staticTexts["انتهت صلاحية الدعوة"].waitForExistence(timeout: 10))
        let valid = launch(["-demo", "-SaryScreen", "invite-valid"])
        XCTAssertTrue(valid.buttons["invite.join"].waitForExistence(timeout: 10))
        XCTAssertTrue(valid.staticTexts["كشتة نفود الثويرات"].exists)
    }

    func testRecoveryCodeNeedsAllCharacters() {
        let app = launch(["-demo", "-SaryScreen", "recovery-restore"])
        let field = app.textFields["recovery.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["recovery.submit"].isEnabled)
        field.tap()
        field.typeText("7K3Q-M9XD-2HPA-VR6T-WC4N-8B1F-ZJ5E")
        XCTAssertTrue(app.buttons["recovery.submit"].isEnabled)
    }

    /// «احذف حسابي»: explained, needs the typed word, then back to onboarding with a notice (demo: no server).
    func testDeleteAccountNeedsTypedConfirmationAndReturnsToOnboarding() {
        let app = launch(["-demo", "-SaryScreen", "privacy"])
        let open = app.buttons["privacy.deleteAccount"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let submit = app.buttons["deleteAccount.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["يُحذف من الخادم"].exists)
        XCTAssertTrue(app.staticTexts["يبقى"].exists)
        XCTAssertFalse(submit.isEnabled, "nothing happens without the typed word")
        let field = app.textFields["deleteAccount.confirm"]
        field.tap()
        field.typeText("حذف")
        XCTAssertFalse(submit.isEnabled, "a near miss is not enough")
        field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "احذف")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let notice = app.alerts["حُذف حسابك"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "باقية على جوالك")).firstMatch.exists, "says the offline areas stay")
        notice.buttons["حسنًا"].tap()
        XCTAssertFalse(app.buttons["privacy.deleteAccount"].exists, "the settings are gone: back at onboarding")
    }

    func testOfflineHomeSaysSo() {
        let app = launch(["-demo", "-SaryScreen", "home", "-SaryOffline"])
        XCTAssertTrue(app.descendants(matching: .any)["offline-banner"].waitForExistence(timeout: 10))
    }

    /// UI-AUDIT 0.1 + 0.5: a friend's SOS shows even with a sheet (or the settings) up, offers
    /// «اتصل ٩١١», and «أظهره على الخريطة» acknowledges it.
    func testFriendSOSShowsOverAnOpenSheet() {
        for extra in [["-SaryLiveModal", "layers"], ["-SaryLiveTab", "more"]] {
            let app = launch(["-resetState", "-demo", "-SaryDrive", "0", "-SaryContext", "stopped", "-SaryFriendSOS", "6"] + extra)
            let show = app.buttons["sos-alert-show"]
            XCTAssertTrue(show.waitForExistence(timeout: 30), "the friend's SOS over \(extra)")
            XCTAssertTrue(app.buttons["sos-alert-911"].exists, "«اتصل ٩١١» on the friend's SOS")
            show.tap()
            XCTAssertTrue(show.waitForNonExistence(timeout: 5), "acknowledged")
            app.terminate()
        }
    }
}

/// «اتجه» without an outing on a phone lying still: iOS sends nothing new, my only fix is 5 minutes
/// old. Guidance must ask for a fresh fix and start, never hang on «ننتظر موقعك» (owner, Build 38).
final class StandaloneNavStaleFixUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testGoOnAParkedPhoneAsksForAFixAndStarts() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryScreen", "home",
                               "-SaryParkedPhone", "-SaryNavDemo"]
        app.launch()
        let any = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        XCTAssertTrue(any("home.search").waitForExistence(timeout: 30))
        sleep(2)
        /* A place away from me (the top of the map), not my own spot. */
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.3)
        let go = any("home.place.go")
        XCTAssertTrue(go.waitForExistence(timeout: 10), "«اتجه» on the place card")
        go.tap()
        XCTAssertTrue(any("standaloneNav.screen").waitForExistence(timeout: 5))
        let started = any("nav.banner").waitForExistence(timeout: 15) || any("nav.instruction").exists || any("nav.offRoad").exists
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "standalone-parked-phone"; a.lifetime = .keepAlways; add(a)
        let status = any("standaloneNav.status")
        XCTAssertTrue(started, "guidance never started: «\(status.exists ? status.label : "-")»")
    }
}

/// Issue #161: a category chip (or a search) lists places; they must show on the map too.
final class CategoryPinsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testCityCategoryResultsShowOnTheMap() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryScreen", "home"]
        app.launch()
        let any = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        XCTAssertTrue(any("home.search").waitForExistence(timeout: 30))
        sleep(2)
        any("home.category.restaurants").tap()
        XCTAssertTrue(any("home.result").waitForExistence(timeout: 20), "the list has places")
        sleep(2)
        /* Lower the sheet: the map with its markers. */
        let handle = any("home.sheet.handle")
        if handle.exists { handle.swipeDown() }
        sleep(4)
        shot("category-restaurants")
    }
}

/// «اتجه» while driving (temporary until #157): my car (not a dot), my speed and the posted limit.
final class StandaloneNavDriveShotsUITests: XCTestCase {
    func testCarAndSpeedWhileGuiding() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryScreen", "home", "-SaryNavDemo"]
        app.launch()
        let any = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        XCTAssertTrue(any("home.search").waitForExistence(timeout: 30))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 1.3)
        XCTAssertTrue(any("home.place.go").waitForExistence(timeout: 10))
        any("home.place.go").tap()
        XCTAssertTrue(any("nav.banner").waitForExistence(timeout: 20), "guiding")
        sleep(12)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "standalone-drive"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(any("map.user-car").exists, "my car, not the dot")
        XCTAssertTrue(any("standaloneNav.speed").exists || any("standaloneNav.speedLimit").exists, "speed or the posted limit")
    }
}

/// Owner, Build 39: «اتجه» stuck on «ننتظر موقعك… · الدقة ±٨ م» with a good fix — guidance had started
/// and was brought back to idle. It must start again by itself.
final class StandaloneNavRestartUITests: XCTestCase {
    func testGuidanceBackToIdleStartsAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryScreen", "home",
                               "-SaryNavDemo", "-SaryNavResetOnce", "3"]
        app.launch()
        let any = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        XCTAssertTrue(any("home.search").waitForExistence(timeout: 30))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.3)
        XCTAssertTrue(any("home.place.go").waitForExistence(timeout: 10))
        any("home.place.go").tap()
        XCTAssertTrue(any("nav.banner").waitForExistence(timeout: 20), "guiding first")
        sleep(6)   /* reset at +3 s, then the 1 s re-check */
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "standalone-after-reset"; a.lifetime = .keepAlways; add(a)
        let status = any("standaloneNav.status")
        XCTAssertTrue(any("nav.banner").waitForExistence(timeout: 8), "guiding again, not «\(status.exists ? status.label : "-")»")
    }
}
