import XCTest

/// Launches the real app on the simulator. `-demo` loads a fixed, clearly
/// labelled outing so the map can be checked without a server; `-resetState`
/// wipes identity and consent first.
final class SaryAlbarqUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOnboardingAppearsWithoutIdentity() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.begin"].waitForExistence(timeout: 10), "the one-line idea first")
        XCTAssertTrue(app.buttons["onboarding.restore"].exists, "restore with a recovery code, no passwords")
        app.buttons["onboarding.begin"].tap()
        XCTAssertTrue(app.textFields["onboarding.name"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.start"].isEnabled, "no name, no start")
        app.textFields["onboarding.name"].tap()
        app.textFields["onboarding.name"].typeText("سعد")
        XCTAssertTrue(app.buttons["onboarding.start"].isEnabled)
        attach(app, "onboarding")
    }

    private func allowLocation() {
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// The new live screen over the map: status capsule, control cluster, SOS dock,
    /// and the native sheet with the participants (honest presence for each).
    func testLiveScreenShowsChromeAndParticipants() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm"]
        allowLocation()
        app.launch()
        XCTAssertTrue(app.otherElements["outing.map"].waitForExistence(timeout: 15) || app.maps.firstMatch.waitForExistence(timeout: 5))
        // Tap the status bar, not the map centre: a demo car sits there and would open its card.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap() // lets the interruption monitor answer a permission prompt
        XCTAssertTrue(app.buttons["outing-back"].waitForExistence(timeout: 10), "trip header")
        XCTAssertTrue(app.buttons["outing-fit"].exists, "control cluster")
        XCTAssertTrue(app.buttons["outing-locate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["outing-sos"].exists, "SOS dock")
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        XCTAssertTrue(app.buttons["tab.trip"].waitForExistence(timeout: 5) || app.staticTexts["الرحلة"].exists, "tabs at half height")
        app.buttons["tab.group"].tap()
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "participant-row").count, 4)
        XCTAssertTrue(app.staticTexts["أبو فهد"].exists)
        sleep(1)
        attach(app, "live-half")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: - The one-step invitee join (owner decision, build 14)

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// `TEST_RUNNER_SARY_ONBOARD_SHOTS=1` also writes PNGs to `<worktree>-shots/` (e.g. onboard-shots).
    private func shot(_ name: String, _ app: XCUIApplication? = nil) {
        let png = (app?.screenshot() ?? XCUIScreen.main.screenshot())
        let a = XCTAttachment(screenshot: png)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard ProcessInfo.processInfo.environment["SARY_ONBOARD_SHOTS"] == "1" else { return }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = URL(fileURLWithPath: root.path + "-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// The iOS location alert, answered through springboard (not an interruption monitor:
    /// the test must SEE that the system prompt came right after the one tap).
    @discardableResult
    private func answerLocationAlert(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for l in labels where springboard.buttons[l].exists {
                shot("2-system-location-alert")
                springboard.buttons[l].tap()
                return true
            }
            usleep(250_000)
        }
        XCTFail("no iOS location alert after «انضم للطلعة»", file: file, line: line)
        return false
    }

    private func launchInvite(_ kind: String, noIdentity: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        /* A fresh permission state: the system prompt must come from the join tap itself. */
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-resetState", "-demo", "-SaryDemoInvite", kind, "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped"]
            + (noIdentity ? ["-SaryNoIdentity"] : [])
        app.launch()
        if !app.buttons["invite.join"].waitForExistence(timeout: 20) {
            print("LAUNCH-TREE:\n" + app.debugDescription)
            shot("debug-launch")
        }
        return app
    }

    private func labelled(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// The deep link opens the app's page in Settings; on a simulator whose Settings app starts
    /// cold it can land on the root instead: then Privacy & Security → Location Services → the app.
    private func openAppLocationPage(_ settings: XCUIApplication) {
        let whileUsing = labelled(settings, ["While Using the App", "أثناء استخدام التطبيق"])
        let location = labelled(settings, ["Location", "الموقع"])
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "سَرى البارق")).firstMatch
        let privacy = settings.buttons["com.apple.settings.privacyAndSecurity"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !(whileUsing.exists || location.exists || row.exists || privacy.exists) { usleep(300_000) }
        if whileUsing.exists { return }
        if location.exists {
            shot("7-settings-app-page")
            location.tap()
            return
        }
        if !row.exists {
            var n = 0
            while !(privacy.exists && privacy.isHittable) && n < 8 { settings.swipeUp(); n += 1 }
            privacy.tap()
            let services = labelled(settings, ["Location Services", "خدمات الموقع"])
            XCTAssertTrue(services.waitForExistence(timeout: 10))
            services.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 10))
        }
        var n = 0
        while !row.isHittable && n < 8 { settings.swipeUp(); n += 1 }
        shot("7-settings-location-services")
        row.tap()
    }

    /// Invite link → ONE screen → one tap → the iOS location alert → in the live trip, sharing ON.
    /// No name screen (the inviter's name), no consent sheet, no notification prompt, no toggle.
    func testInviteOneTapJoinsAndSharesAtOnce() {
        let app = launchInvite("personal", noIdentity: true)
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20), "the invite opens straight on the join screen")
        XCTAssertFalse(app.buttons["onboarding.begin"].isHittable, "no onboarding in front of an invite")
        XCTAssertTrue(app.staticTexts["invite.inviter"].label.contains("راشد"), "who invited you")
        XCTAssertTrue(app.staticTexts["invite.name"].exists, "the trip")
        XCTAssertTrue(any(app, "invite.personal").label.contains("فهد أخوي"), "the name the inviter gave")
        XCTAssertFalse(app.textFields["invite.myName"].exists, "no name to type: the identity is made silently")
        XCTAssertEqual(app.staticTexts["join.shareStatement"].label, "بانضمامك يشوف أعضاء الطلعة موقعك المباشر لين تنتهي الطلعة أو تغادرها")
        XCTAssertTrue(join.label.contains("انضم للطلعة"))
        sleep(1)
        shot("1-invite-one-screen", app)

        join.tap()
        answerLocationAlert(["Allow While Using App", "السماح أثناء استخدام التطبيق"])

        let summary = any(app, "outing-sheet-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "in the live trip")
        XCTAssertFalse(app.buttons["notify.allow"].exists, "notifications are not asked at join")
        XCTAssertFalse(app.buttons["share.always.allow"].exists, "«دائمًا» is not asked at join")
        summary.tap()
        let sharing = app.staticTexts["live.sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 10))
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "موقعك مُشارَك").evaluate(with: sharing) || sharing.label.contains("موقعك"), sharing.label)
        let deadline = Date().addingTimeInterval(10)
        while !sharing.label.contains("مُشارَك") && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(sharing.label.contains("مُشارَك"), "sharing ON by itself: \(sharing.label)")
        XCTAssertFalse(app.buttons["live.share"].exists, "no «شارك موقعي»")
        XCTAssertFalse(app.buttons["live.stopSharing"].exists, "no «أوقف»")
        XCTAssertTrue(app.buttons["live.leave"].exists, "«غادر الطلعة» is the way out, right there")
        sleep(1)
        shot("3-in-trip-sharing-on", app)

        app.buttons["tab.more"].tap()
        XCTAssertTrue(any(app, "settings-battery").waitForExistence(timeout: 5))
        XCTAssertFalse(any(app, "settings-pause-sharing").exists, "no stop switch in «المزيد» either")
        shot("4-more-no-toggle", app)

        /* «غادر الطلعة» asks first. */
        app.buttons["tab.trip"].tap()
        XCTAssertTrue(app.buttons["live.leave"].waitForExistence(timeout: 5))
        app.buttons["live.leave"].tap()
        XCTAssertTrue(app.staticTexts["تغادر الطلعة؟"].waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 2), "confirmation first")
        shot("5-leave-confirm", app)
        XCTAssertTrue(app.buttons["غادر الطلعة"].firstMatch.exists)
        /* iOS 26+ shows the dialog as a popover without «إلغاء»: tapping outside cancels. */
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.42)).tap()
        let title = app.staticTexts["تغادر الطلعة؟"]
        let gone = Date().addingTimeInterval(5)
        while title.exists && Date() < gone { usleep(250_000) }
        XCTAssertFalse(title.exists, "dismissed")
        XCTAssertTrue(sharing.exists, "cancel keeps the trip and the share")
    }

    /// Refused: not joined. One calm screen; «افتح الإعدادات» → allow → back: joins and enters by itself.
    func testDeniedLocationThenSettingsJoinsByItself() {
        let app = launchInvite("group", noIdentity: false)
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["invite.myName"].exists, "already has a name on this phone")
        join.tap()
        answerLocationAlert(["Don’t Allow", "Don't Allow", "عدم السماح"])

        let needs = app.staticTexts["join.needsLocation"]
        XCTAssertTrue(needs.waitForExistence(timeout: 10), "the calm screen")
        XCTAssertEqual(needs.label, "الطلعة تحتاج موقعك عشان أصحابك يشوفونك")
        XCTAssertTrue(app.buttons["join.openSettings"].exists)
        XCTAssertTrue(app.buttons["join.cancel"].exists)
        XCTAssertFalse(any(app, "outing-sheet-summary").exists, "not joined: no live map")
        sleep(1)
        shot("6-denied-needs-location", app)

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate() // a known starting page
        app.buttons["join.openSettings"].tap()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "«افتح الإعدادات» opens the app's settings")
        openAppLocationPage(settings)
        let whileUsing = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["While Using the App", "أثناء استخدام التطبيق"])).firstMatch
        XCTAssertTrue(whileUsing.waitForExistence(timeout: 10))
        whileUsing.tap()
        let precise = settings.switches.matching(NSPredicate(format: "label IN %@", ["Precise Location", "الموقع الدقيق"])).firstMatch
        if precise.waitForExistence(timeout: 3), (precise.value as? String) == "0" { precise.tap() }
        shot("8-settings-allowed")

        app.activate()
        let summary = any(app, "outing-sheet-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "back with permission: joined and in the trip, no extra tap")
        summary.tap()
        let sharing = app.staticTexts["live.sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while !sharing.label.contains("مُشارَك") && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(sharing.label.contains("مُشارَك"), sharing.label)
        sleep(1)
        shot("9-auto-joined-sharing", app)
    }
}
