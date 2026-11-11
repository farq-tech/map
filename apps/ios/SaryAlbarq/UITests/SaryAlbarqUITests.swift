import CoreLocation
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
        XCTAssertTrue(app.buttons["outing-actions"].exists, "«المزيد» at the end of the sheet's quick row")
        XCTAssertTrue(app.buttons["outing-locate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["outing-sos"].exists, "SOS dock")
        let summary = app.descendants(matching: .any)["outing-sheet-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        XCTAssertFalse(app.buttons["tab.trip"].exists, "no tabs any more: one sheet")
        XCTAssertTrue(app.descendants(matching: .any)["participant-row"].firstMatch.waitForExistence(timeout: 5), "the people at half height")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "participant-row").count, 4)
        XCTAssertTrue(app.staticTexts["أبو فهد"].exists)
        sleep(1)
        attach(app, "live-half")
    }

    /// Selecting a point from Home during an existing outing starts a leg in that outing.
    func testMapPointStartsLegInActiveOuting() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "home", "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryDemoPlanName", "وجهة الخطة القديمة"]
        allowLocation()
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744), altitude: 600,
                                                                     horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()

        let map = app.descendants(matching: .any)["home.map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.2)

        let start = app.descendants(matching: .any)["home.place.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "وجّه القافلة إلى هنا")
        let selectedName = app.staticTexts["home.place.name"].label
        XCTAssertFalse(selectedName.isEmpty)
        XCTAssertNotEqual(selectedName, "وجهة الخطة القديمة", "the selected map point must differ from the outing's existing plan destination")
        start.tap()

        let liveMap = app.descendants(matching: .any)["outing-sheet-summary"].firstMatch
        XCTAssertTrue(liveMap.waitForExistence(timeout: 30), "the existing outing should open")
        let line = app.descendants(matching: .any)["trip.header.line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let destination = NSPredicate(format: "label CONTAINS %@", selectedName)
        expectation(for: destination, evaluatedWith: line)
        waitForExpectations(timeout: 15)

        /* The route picker must use the active map-picked leg, not the previous plan target. */
        app.buttons["outing-actions"].tap()
        let navigate = app.buttons["outing-navigate"]
        XCTAssertTrue(navigate.waitForExistence(timeout: 5))
        navigate.tap()
        let pickerDestination = app.buttons["nav.pick.destination"]
        XCTAssertTrue(pickerDestination.waitForExistence(timeout: 5))
        XCTAssertTrue(pickerDestination.label.contains(selectedName), "picker should follow the active leg: \(pickerDestination.label)")
        XCTAssertFalse(pickerDestination.label.contains("وجهة الخطة القديمة"), "picker must not fall back to the previous plan target")
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

    /// Register before the action that triggers Core Location. Otherwise XCTest's
    /// default interruption handler can dismiss the prompt before the test sees it.
    private func tapAndHandleLocationPermission(_ app: XCUIApplication, _ action: XCUIElement, using labels: [String]) -> Bool {
        var handled = false
        let monitor = addUIInterruptionMonitor(withDescription: "location permission") { alert in
            for label in labels where alert.buttons[label].exists {
                handled = true
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        action.tap()
        /* The join flow creates its identity before asking Core Location, so the system
         * alert may arrive after the initiating tap returns. Poll SpringBoard directly;
         * tapping blank app space can dismiss the alert, reach the map, or leave the app. */
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        /* Do not tap the obscured invitation/map while waiting: a system alert can report the
         * underlying title as hittable even though XCTest cannot compute a valid hit point. */
        usleep(600_000)
        let deadline = Date().addingTimeInterval(15)
        let expectsRefusal = labels.contains("Don’t Allow") || labels.contains("Don't Allow") || labels.contains("عدم السماح")
        while !handled && Date() < deadline {
            /* The app can consume the permission result before XCTest's monitor reports it.
             * Accept only the intended post-choice state, never a background map element. */
            if expectsRefusal && app.staticTexts["join.needsLocation"].exists {
                handled = true
                break
            }
            if !expectsRefusal && (app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "نطلب الموقع الدقيق")).firstMatch.exists
                                   || app.descendants(matching: .any)["outing-sheet-summary"].exists) {
                handled = true
                break
            }
            for label in labels {
                /* Core Location's prompt is surfaced as a SpringBoard interruption on some
                 * simulator runtimes and as an app button on others; query both owners. */
                let candidates = [springboard.buttons[label], app.buttons[label]]
                if let button = candidates.first(where: { $0.exists && $0.isHittable }) {
                    button.tap()
                    handled = true
                    break
                }
            }
            usleep(400_000)
        }
        removeUIInterruptionMonitor(monitor)
        /* This helper reports only whether the system permission interaction happened.
         * Each test asserts its own outcome next: allow → joined, deny/reduced → recovery.
         * Requiring `live` here makes expected denial look like a failed prompt; tapping the
         * old join button again can also turn a one-tap test into a different flow. */
        return handled
    }

    private func launchInvite(_ kind: String, noIdentity: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        /* XCTest may launch the app as part of resetting its permission state. Do that first,
         * then terminate that setup launch and set the arguments for the invite under test. */
        if !extra.contains("-SaryLocationAlreadyDenied") && !extra.contains("-SaryLocationFresh") {
            app.resetAuthorizationStatus(for: .location)
        }
        app.terminate()
        var arguments = ["-demo", "-SaryDemoInvite", kind, "-SaryWeatherDemo", "calm", "-SaryScheme", "light", "-SaryDrive", "0", "-SaryContext", "stopped"]
        if !extra.contains("-SaryLocationFresh") { arguments.insert("-resetState", at: 0) }
        app.launchArguments = arguments
            + (noIdentity ? ["-SaryNoIdentity"] : []) + extra
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

    private func setTestLocation() {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
            altitude: 600, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()
        ))
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
        let dest = app.staticTexts["invite.destination"]
        XCTAssertTrue(dest.exists && dest.label.contains("روضة الثمامة"), "the destination under the trip name: \(dest.exists ? dest.label : "-")")
        XCTAssertTrue(any(app, "invite.personal").label.contains("فهد أخوي"), "the name the inviter gave")
        XCTAssertFalse(app.textFields["invite.myName"].exists, "no name to type: the identity is made silently")
        XCTAssertEqual(app.staticTexts["join.shareStatement"].label, "بانضمامك يشوف ربع الطلعة موقعك المباشر لين تنتهي الطلعة أو تغادرها")
        XCTAssertTrue(join.label.contains("انضم للطلعة"))
        /* Build 21: iOS never asked → the Najdi pre-prompt is right above the button (no extra screen). */
        let pre = any(app, "join.prePrompt").firstMatch
        XCTAssertTrue(pre.exists, "the pre-prompt before the system alert")
        XCTAssertTrue(pre.label.contains("عشان الربع يشوفونك وتوصلهم الطوارئ"), pre.label)
        sleep(1)
        shot("1-invite-one-screen", app)

        setTestLocation()
        XCTAssertTrue(tapAndHandleLocationPermission(app, join, using: ["Allow While Using App", "السماح أثناء استخدام التطبيق"]))

        let summary = any(app, "outing-sheet-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "in the live trip")
        /* The trip's atmosphere: the one-time welcome over the map, the SOS dock and the walkie-talkie
         * ready, «نحدد موقعك…» until a good fix (then the camera frames me, the convoy, the destination). */
        let welcome = any(app, "arrival.welcome")
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), "the welcome card")
        XCTAssertTrue(welcome.label.hasPrefix("حياك في"), welcome.label)
        let withDest = Date().addingTimeInterval(5)
        while welcome.exists && !welcome.label.contains("الوجهة") && Date() < withDest { usleep(250_000) }
        XCTAssertTrue(welcome.label.contains("الوجهة روضة الثمامة"), welcome.label)
        XCTAssertTrue(any(app, "outing-sos").exists, "SOS is never hidden")
        XCTAssertFalse(any(app, "arrival.hidden").exists, "allowed: nothing says my location is hidden")
        shot("2b-arrival-welcome", app)
        let locating = any(app, "arrival.locating")
        let located = Date().addingTimeInterval(25)
        while locating.exists && Date() < located { usleep(400_000) }
        XCTAssertFalse(locating.exists, "a good fix arrives (simulator location set) and «نحدد موقعك…» goes")
        shot("2c-arrival-located", app)
        XCTAssertFalse(app.buttons["notify.allow"].exists, "notifications are not asked at join")
        /* Field 2026-11-06: «دائمًا» is now explained right after joining (after the welcome card),
         * so the share keeps going with the phone locked until the trip ends. */
        let later = app.buttons["share.always.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 20), "«دائمًا» explained right after joining")
        XCTAssertTrue(app.staticTexts["خلّ الربع يشوفونك طول الطلعة"].exists, "the after-join explainer")
        shot("2d-always-after-join", app)
        later.tap()
        XCTAssertTrue(later.waitForNonExistence(timeout: 5))
        summary.tap()
        let sharing = app.staticTexts["live.sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 10))
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "موقعك مُشارَك").evaluate(with: sharing) || sharing.label.contains("موقعك"), sharing.label)
        let deadline = Date().addingTimeInterval(10)
        while !sharing.label.contains("مُشارَك") && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(sharing.label.contains("مُشارَك"), "sharing ON by itself: \(sharing.label)")
        XCTAssertFalse(app.buttons["live.share"].exists, "no «شارك موقعي»")
        XCTAssertFalse(app.buttons["live.stopSharing"].exists, "no «أوقف»")
        XCTAssertTrue(app.buttons["outing-actions"].exists, "«غادر الطلعة» is in «المزيد»")
        sleep(1)
        shot("3-in-trip-sharing-on", app)

        app.openLiveSettings()
        let who = any(app, "settings.sharing")
        XCTAssertTrue(who.waitForExistence(timeout: 5))
        who.tap()
        XCTAssertTrue(any(app, "settings-battery").waitForExistence(timeout: 5))
        XCTAssertFalse(any(app, "settings-pause-sharing").exists, "no stop switch in «المزيد» either")
        shot("4-more-no-toggle", app)

        /* «غادر الطلعة» asks first (back from «الإعدادات» to «الرحلة»). */
        app.buttons["settings.sub.back"].tap()
        XCTAssertTrue(app.buttons["settings.back"].waitForExistence(timeout: 3))
        app.buttons["settings.back"].tap()
        let confirmLeave = app.openLeaveConfirmation()
        XCTAssertTrue(app.staticTexts["تغادر الطلعة؟"].waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 2), "confirmation first")
        shot("5-leave-confirm", app)
        XCTAssertTrue(confirmLeave.exists)
        /* iOS 26+ shows the dialog as a popover without «إلغاء»: tapping outside cancels. */
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.42)).tap()
        let title = app.staticTexts["تغادر الطلعة؟"]
        let gone = Date().addingTimeInterval(5)
        while title.exists && Date() < gone { usleep(250_000) }
        XCTAssertFalse(title.exists, "dismissed")
        /* The tap outside may also close «المزيد» and lower the sheet: raise it again to read the state. */
        if app.buttons["outing-actions-close"].exists { app.buttons["outing-actions-close"].tap() }
        if !sharing.waitForExistence(timeout: 2) { summary.tap() }
        XCTAssertTrue(sharing.waitForExistence(timeout: 5), "cancel keeps the trip and the share")
    }

    /// Deterministic local check for an already-denied iOS authorization. The runner revokes TCC first.
    func testPreviouslyDeniedLocationShowsRecoveryWithoutJoining() {
        let app = launchInvite("group", noIdentity: false, extra: ["-SaryLocationAlreadyDenied"])
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        join.tap()

        let needs = app.staticTexts["join.needsLocation"]
        XCTAssertTrue(needs.waitForExistence(timeout: 10), "the recovery screen after a previous refusal")
        XCTAssertEqual(needs.label, "موقعك مقفل، والربع ما راح يشوفونك")
        XCTAssertTrue(app.buttons["join.openSettings"].exists)
        XCTAssertFalse(any(app, "outing-sheet-summary").exists)
    }

    /// Previously refused: «افتح الإعدادات» → allow → back: joins and enters by itself.
    /// Run with simulator location TCC revoked before the test (simctl privacy revoke location).
    func testDeniedLocationThenSettingsJoinsByItself() {
        let app = launchInvite("group", noIdentity: false, extra: ["-SaryLocationAlreadyDenied"])
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        setTestLocation()
        XCTAssertFalse(app.textFields["invite.myName"].exists, "already has a name on this phone")
        join.tap()

        let needs = app.staticTexts["join.needsLocation"]
        XCTAssertTrue(needs.waitForExistence(timeout: 10), "the recovery screen")
        XCTAssertEqual(needs.label, "موقعك مقفل، والربع ما راح يشوفونك")
        XCTAssertTrue(app.buttons["join.openSettings"].exists)
        XCTAssertTrue(app.buttons["join.cancel"].exists)
        XCTAssertFalse(app.buttons["join.enterWithout"].exists, "owner: never in a trip without the location")
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
        let later = app.buttons["share.always.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 20), "the existing after-join background-sharing explainer")
        later.tap()
        summary.tap()
        let sharing = app.staticTexts["live.sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while !sharing.label.contains("مُشارَك") && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(sharing.label.contains("مُشارَك"), sharing.label)
        sleep(1)
        shot("9-auto-joined-sharing", app)
    }

    /// Owner decision (build 21): never in a trip without the location. An invitee refuses → the
    /// recovery screen has only «افتح الإعدادات» and «إلغاء», nothing is joined; allowed in Settings →
    /// back in the app it joins and enters by itself, sharing. Reset TCC before the test run.
    func testDeniedRecoveryOnlySettingsThenJoinsByItself() {
        let app = launchInvite("group", noIdentity: false, extra: ["-SaryLocationFresh", "-SaryJoinDiagnostics"])
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        setTestLocation()
        XCTAssertTrue(tapAndHandleLocationPermission(app, join, using: ["Don’t Allow", "Don't Allow", "عدم السماح"]))
        let needs = app.staticTexts["join.needsLocation"]
        XCTAssertTrue(needs.waitForExistence(timeout: 10), "the recovery screen; join state=\(join.value as? String ?? "nil"), enabled=\(join.isEnabled)")
        XCTAssertTrue((join.value as? String)?.hasPrefix("إذن الموقع مطلوب") == true,
                       "the join action must expose the denied-permission recovery state")
        XCTAssertTrue(app.buttons["join.openSettings"].exists)
        XCTAssertTrue(app.buttons["join.cancel"].exists)
        XCTAssertFalse(app.buttons["join.enterWithout"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "بدون موقعي")).count, 0, "no view-only words anywhere")
        XCTAssertFalse(any(app, "outing-sheet-summary").exists, "not joined: no live map")
        sleep(1)
        shot("6-denied-recovery", app)

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        app.buttons["join.openSettings"].tap()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        openAppLocationPage(settings)
        let whileUsing = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["While Using the App", "أثناء استخدام التطبيق"])).firstMatch
        XCTAssertTrue(whileUsing.waitForExistence(timeout: 10))
        whileUsing.tap()
        let precise = settings.switches.matching(NSPredicate(format: "label IN %@", ["Precise Location", "الموقع الدقيق"])).firstMatch
        if precise.waitForExistence(timeout: 3), (precise.value as? String) == "0" { precise.tap() }

        app.activate()
        let summary = any(app, "outing-sheet-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "allowed: joined and in the trip by itself")
        XCTAssertFalse(any(app, "arrival.hidden").exists, "allowed: nothing says my location is hidden")
        let later = app.buttons["share.always.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 20), "the existing after-join background-sharing explainer")
        later.tap()
        summary.tap()
        let sharing = app.staticTexts["live.sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while !sharing.label.contains("مُشارَك") && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(sharing.label.contains("مُشارَك"), sharing.label)
        shot("6b-denied-then-allowed-joined", app)
    }

    /// Build 21: «الموقع الدقيق» off → iOS's temporary precise prompt (requestPreciseForTrip, key ConvoyTrip) → precise → live.
    /// The simulator cannot turn precise off, so `-SaryJoinReduced` plays the approximate answer.
    func testApproximateAsksPreciseThenJoins() {
        let app = launchInvite("personal", noIdentity: true, extra: ["-SaryJoinReduced", "allow"])
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        XCTAssertTrue(tapAndHandleLocationPermission(app, join, using: ["Allow While Using App", "السماح أثناء استخدام التطبيق"]))
        let asking = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "نطلب الموقع الدقيق")).firstMatch
        XCTAssertTrue(asking.waitForExistence(timeout: 5), "the precise request comes right after the location prompt")
        shot("10-invite-asks-precise", app)
        let summary = any(app, "outing-sheet-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "precise allowed: in the live trip")
        XCTAssertFalse(app.staticTexts["join.needsLocation"].exists)
    }

    /// Still approximate after the precise prompt: the recovery screen says so; not joined.
    func testApproximateRefusedShowsPreciseRecovery() {
        let app = launchInvite("group", noIdentity: false, extra: ["-SaryJoinReduced", "deny"])
        let join = app.buttons["invite.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        XCTAssertTrue(tapAndHandleLocationPermission(app, join, using: ["Allow While Using App", "السماح أثناء استخدام التطبيق"]))
        let needs = app.staticTexts["join.needsLocation"]
        XCTAssertTrue(needs.waitForExistence(timeout: 10))
        XCTAssertEqual(needs.label, "موقعك تقريبي بالكيلومترات")
        XCTAssertTrue(app.buttons["join.openSettings"].exists)
        XCTAssertTrue(app.buttons["join.cancel"].exists)
        XCTAssertFalse(app.buttons["join.enterWithout"].exists, "never in a trip without the (precise) location")
        shot("11-invite-needs-precise", app)
        sleep(2)
        XCTAssertFalse(any(app, "outing-sheet-summary").exists, "not joined")
    }
}
