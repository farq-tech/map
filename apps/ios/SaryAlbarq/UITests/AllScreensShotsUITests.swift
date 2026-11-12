import CoreLocation
import XCTest

/// Every screen of the app (docs/SCREENS.md), one named simulator screenshot each, so the owner sees
/// the build exactly as it looks. Names are `NN-area-SS-screen` (area number, then the step inside the
/// area), so a contact sheet sorts in app order. Demo data only (no server): the launch arguments are
/// the same DEBUG switches the other shot tests use.
///
/// Opt-in: only runs with SARY_ALL_SHOTS=1 (TEST_RUNNER_SARY_ALL_SHOTS=1 for xcodebuild); skipped in
/// the normal test run. Screenshots are XCTAttachments (`.keepAlways`); with SARY_SHOTS=<dir> they are
/// also written there as PNGs. A screen that cannot be reached in the simulator (camera, GPS, a server)
/// is still shot as it stands, with a `<name>-NOTE` text attachment saying why: never a failure.
/// See docs/WORKFLOW.md («لقطات كل الشاشات») for the run and export commands.
final class AllScreensShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["SARY_ALL_SHOTS"] != "1", "all-screens screenshots only (SARY_ALL_SHOTS=1)")
    }

    // MARK: - Helpers

    private let riyadh = CLLocationCoordinate2D(latitude: 24.7113, longitude: 46.6744)
    private let largestText = "UICTContentSizeCategoryAccessibilityXXXL"
    private let memberId = "00000000-0000-4000-8000-000000000002"

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// A fresh launch. `demo`: the demo identity and outing. `welcomeIsOK`: the welcome screen is the
    /// point (otherwise a slow first launch that lands on it is launched again, as DeclutterShots does).
    @discardableResult
    private func launch(_ extra: [String], demo: Bool = true, scheme: String = "light", night: Bool = false,
                        textSize: String? = nil, welcomeIsOK: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-resetState"] + (demo ? ["-demo"] : [])
        args += ["-SaryWeatherDemo", "calm", "-SaryScheme", scheme, "-SaryNight", night ? "1" : "0", "-SaryDrive", "0"]
        args += extra
        if let textSize { args += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchArguments = args
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح", "OK", "حسنًا"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: riyadh, altitude: 600, horizontalAccuracy: 5,
                                                                     verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()))
        app.launch()
        app.allowLocationIfAsked()
        waitIntro(app)
        if demo, !welcomeIsOK, app.buttons["onboarding.begin"].exists {
            app.terminate()
            app.launch()
            app.allowLocationIfAsked()
            waitIntro(app)
        }
        return app
    }

    /// The launch intro covers the screen while the controls under it are already in the tree.
    private func waitIntro(_ app: XCUIApplication) {
        let intro = el(app, "intro")
        if intro.waitForExistence(timeout: 2) { _ = intro.waitForNonExistence(timeout: 20) }
    }

    private func waitAny(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval) -> Bool {
        if ids.isEmpty { return true }
        let p = NSPredicate { _, _ in ids.contains { app.descendants(matching: .any)[$0].firstMatch.exists } }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: timeout) == .completed
    }

    /// Waits for any of `ids`; if none comes, says so in a note on `name` (the shot is still taken).
    @discardableResult
    private func expect(_ app: XCUIApplication, _ ids: [String], _ name: String, timeout: TimeInterval = 20) -> Bool {
        if waitAny(app, ids, timeout: timeout) { return true }
        note(name, "Not reached: none of \(ids) appeared within \(Int(timeout)) s. The shot shows whatever was on screen.")
        return false
    }

    private func shot(_ name: String, settle: UInt32 = 2) {
        sleep(settle)
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = "\(name)-NOTE"
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? text.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-NOTE.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Taps the element with `id` once it exists and can be hit; otherwise a note on `name`.
    @discardableResult
    private func tapID(_ app: XCUIApplication, _ id: String, _ name: String, timeout: TimeInterval = 8) -> Bool {
        let e = el(app, id)
        guard e.waitForExistence(timeout: timeout) else {
            note(name, "Could not find «\(id)» to tap.")
            return false
        }
        if !e.isHittable { e.scrollIntoView(in: app) }
        guard e.isHittable else {
            note(name, "«\(id)» exists but cannot be tapped.")
            return false
        }
        e.tap()
        return true
    }

    /// Taps a button whose label contains `text` (rows without an identifier).
    @discardableResult
    private func tapLabel(_ app: XCUIApplication, _ text: String, _ name: String, timeout: TimeInterval = 8) -> Bool {
        let b = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        let t = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        let found = b.waitForExistence(timeout: timeout) || t.exists
        guard found else {
            note(name, "Could not find «\(text)» to tap.")
            return false
        }
        let target = b.exists ? b : t
        if !target.isHittable { target.scrollIntoView(in: app) }
        target.tap()
        return true
    }

    /// Launch, wait for the screen, shoot. Returns the app for further steps.
    @discardableResult
    private func screen(_ name: String, _ extra: [String], ready: [String], scheme: String = "light", night: Bool = false,
                        textSize: String? = nil, demo: Bool = true, welcomeIsOK: Bool = false,
                        timeout: TimeInterval = 40, settle: UInt32 = 3) -> XCUIApplication {
        let app = launch(extra, demo: demo, scheme: scheme, night: night, textSize: textSize, welcomeIsOK: welcomeIsOK)
        expect(app, ready, name, timeout: timeout)
        shot(name, settle: settle)
        return app
    }

    /// The demo outing's live screen (stopped unless `extra` says otherwise), ready for taps.
    @discardableResult
    private func live(_ extra: [String], scheme: String = "light", night: Bool = false, textSize: String? = nil,
                      ready: [String] = ["outing-sheet-summary", "nav.banner", "nav.offroad", "outing-actions-sheet", "settings.page"],
                      name: String) -> XCUIApplication {
        let context: [String] = extra.contains("-SaryContext") ? [] : ["-SaryContext", "stopped"]
        let app = launch(["-demoSharing"] + context + extra, scheme: scheme, night: night, textSize: textSize)
        expect(app, ready, name, timeout: 45)
        return app
    }

    /// «المزيد» → (a group tile) → a tile of «أدوات الطلعة».
    @discardableResult
    private func moreTile(_ app: XCUIApplication, _ id: String, group: String? = nil, _ name: String) -> Bool {
        let more = app.buttons["outing-actions"]
        if !more.waitForExistence(timeout: 5) { tapIfThere(el(app, "outing-sheet-summary")) }
        guard more.waitForExistence(timeout: 10) else {
            note(name, "«المزيد» (outing-actions) did not show.")
            return false
        }
        more.tap()
        _ = el(app, "outing-actions-sheet").waitForExistence(timeout: 5)
        let tile = el(app, id)
        if !tile.waitForExistence(timeout: 2), let group {
            guard tapID(app, group, name, timeout: 5) else { return false }
        }
        return tapID(app, id, name, timeout: 6)
    }

    /// Taps `e` if it shows up and can be hit (no failure when it does not).
    @discardableResult
    private func tapIfThere(_ e: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        guard e.waitForExistence(timeout: timeout), e.isHittable else { return false }
        e.tap()
        return true
    }

    /// Swipes up inside `e` when it exists, else on the whole app.
    private func swipeUp(_ app: XCUIApplication, in e: XCUIElement) {
        if e.exists { e.swipeUp() } else { app.swipeUp() }
    }

    // MARK: - 01 Launch

    func test01Launch() {
        /* «المقدمة السينمائية»: one frame held (-SaryIntroFreeze) so the animated intro can be shot. */
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-SaryIntro", "1", "-SaryIntroFreeze", "3.0"]
        app.launch()
        expect(app, ["intro"], "01-launch-01-intro", timeout: 8)
        shot("01-launch-01-intro", settle: 1)
        app.terminate()

        screen("01-launch-02-splash", ["-SaryScreen", "splash", "-SaryHoldSplash"], ready: [], settle: 2)
    }

    // MARK: - 02 Onboarding

    func test02Onboarding() {
        /* No identity: the real first run. */
        let app = launch([], demo: false, welcomeIsOK: true)
        expect(app, ["onboarding.begin"], "02-onboarding-01-welcome")
        shot("02-onboarding-01-welcome")
        if tapID(app, "onboarding.begin", "02-onboarding-02-profile") {
            expect(app, ["onboarding.name"], "02-onboarding-02-profile", timeout: 10)
        }
        shot("02-onboarding-02-profile")
        let field = app.textFields["onboarding.name"]
        if field.exists {
            field.focusAndType("سعد")
            shot("02-onboarding-03-profile-filled")
        } else {
            note("02-onboarding-03-profile-filled", "The name field was not there.")
            shot("02-onboarding-03-profile-filled")
        }

        /* «نستخدم موقعك أثناء الطلعة فقط»: creating the account needs the server, so the step is opened directly. */
        screen("02-onboarding-04-location", ["-SaryScreen", "onboarding-location"],
               ready: ["onboarding.allowLocation", "onboarding.location.title", "onboarding.skipLocation"], welcomeIsOK: true)
        screen("02-onboarding-05-notify-explainer", ["-SaryScreen", "notify-explainer"], ready: ["notify.enable", "notify.allow", "notify.later"])
        screen("02-onboarding-06-share-always-explainer", ["-SaryScreen", "share-always-explainer"], ready: ["share.always.allow", "share.always.later"])

        let deleted = launch(["-SaryScreen", "account-deleted"], welcomeIsOK: true)
        if !deleted.alerts.firstMatch.waitForExistence(timeout: 10) { note("02-onboarding-07-account-deleted", "The notice alert did not show.") }
        shot("02-onboarding-07-account-deleted")
        let wiped = launch(["-SaryScreen", "account-wiped"], welcomeIsOK: true)
        if !wiped.alerts.firstMatch.waitForExistence(timeout: 10) { note("02-onboarding-08-account-wiped", "The notice alert did not show.") }
        shot("02-onboarding-08-account-wiped")
    }

    // MARK: - 03 Recovery and QR

    func test03Recovery() {
        let app = screen("03-recovery-01-restore", ["-SaryScreen", "recovery-restore"], ready: ["recovery.code"], welcomeIsOK: true)
        let field = app.textFields["recovery.code"]
        if field.exists {
            field.focusAndType("7K3Q-M9XD-2HPA-VR6T-WC4N-8B1F-ZJ5E")
        } else {
            note("03-recovery-02-restore-filled", "The code field was not there.")
        }
        shot("03-recovery-02-restore-filled")

        /* «امسح رمز QR من جوالك القديم»: the simulator has no camera, so the scanner shows its unavailable state. */
        let scan = launch(["-SaryScreen", "recovery-restore"], welcomeIsOK: true)
        if tapID(scan, "recovery.scan", "03-recovery-03-qr-scanner", timeout: 15) { sleep(2) }
        note("03-recovery-03-qr-scanner", "Simulator: no camera. The QR scanner shows its no-camera / permission state, not a live preview.")
        shot("03-recovery-03-qr-scanner")

        screen("03-recovery-04-code-create", ["-SaryScreen", "recovery-code"], ready: ["recovery.make"])
        screen("03-recovery-05-code-shown", ["-SaryScreen", "recovery-code-shown"], ready: ["recovery.shownCode", "recovery.done"])
    }

    // MARK: - 04 Invite join and its states

    func test04InviteJoin() {
        let states: [(String, String, [String])] = [
            ("04-invite-01-valid", "invite-valid", ["invite.join"]),
            ("04-invite-02-personal", "invite-personal", ["invite.join"]),
            ("04-invite-03-expired", "invite-expired", ["invite.expired"]),
            ("04-invite-04-taken", "invite-taken", ["invite.taken"]),
            ("04-invite-05-invalid", "invite-invalid", ["invite.invalid"]),
            ("04-invite-06-error", "invite-error", ["invite.retry"]),
            ("04-invite-07-needs-location", "invite-needs-location", ["join.needsLocation", "join.openSettings"]),
            ("04-invite-08-needs-precise", "invite-needs-precise", ["join.needsLocation", "join.openSettings"]),
        ]
        for (name, debug, ready) in states {
            screen(name, ["-SaryScreen", debug], ready: ready, welcomeIsOK: true)
        }

        /* «انضم برابط» and its QR scanner. */
        let join = screen("04-invite-09-join-by-link", ["-SaryScreen", "join"], ready: ["paste.field"])
        if tapID(join, "paste.scan", "04-invite-10-join-qr-scanner") { sleep(2) }
        note("04-invite-10-join-qr-scanner", "Simulator: no camera. The QR scanner shows its no-camera / permission state.")
        shot("04-invite-10-join-qr-scanner")

        /* An invite link just opened (demo preview and join stand in for the server). */
        screen("04-invite-11-link-opened-no-account", ["-SaryDemoInvite", "personal", "-SaryNoIdentity"], ready: ["invite.join"], welcomeIsOK: true)
        screen("04-invite-12-link-opened-group", ["-SaryDemoInvite", "group"], ready: ["invite.join"])
        let during = launch(["-demoSharing", "-SaryContext", "stopped", "-SaryDemoInviteDuringTrip", "10"])
        expect(during, ["invite.join"], "04-invite-13-link-opened-during-trip", timeout: 40)
        shot("04-invite-13-link-opened-during-trip")
    }

    // MARK: - 05 Home

    func test05Home() {
        var app = launch(["-SaryScreen", "home"])
        expect(app, ["home.search"], "05-home-01-peek", timeout: 45)
        shot("05-home-01-peek", settle: 5)

        if tapID(app, "home.sheet.handle", "05-home-02-raised") { expect(app, ["home.sheet.expanded"], "05-home-02-raised", timeout: 5) }
        shot("05-home-02-raised")
        app.openHomeOutings()
        shot("05-home-03-raised-outings")
        app.swipeUp()
        shot("05-home-04-raised-bottom")

        /* Categories: a desert one (the local gazetteer, offline) and a city one (live search). */
        app = launch(["-SaryScreen", "home"])
        if tapID(app, "home.category.rawda", "05-home-05-category-desert", timeout: 30) {
            expect(app, ["home.result", "home.desert.result"], "05-home-05-category-desert", timeout: 15)
        }
        shot("05-home-05-category-desert", settle: 3)
        app = launch(["-SaryScreen", "home"])
        if tapID(app, "home.category.restaurants", "05-home-06-category-city", timeout: 30) {
            if !waitAny(app, ["home.result"], timeout: 20) {
                note("05-home-06-category-city", "No city results: Apple / Mapbox search needs the network on the Mac.")
            }
        }
        shot("05-home-06-category-city", settle: 3)
        let handle = el(app, "home.sheet.handle")
        if handle.exists { handle.swipeDown() }
        shot("05-home-07-category-pins-on-map", settle: 4)

        /* Search: a name and a coordinate. */
        app = launch(["-SaryScreen", "home"])
        let search = el(app, "home.search")
        if search.waitForExistence(timeout: 30) {
            search.focusAndType("نفود\n")
            if !waitAny(app, ["home.result", "home.desert.result"], timeout: 20) { note("05-home-08-search-results", "No results came.") }
        } else {
            note("05-home-08-search-results", "The search field did not show.")
        }
        shot("05-home-08-search-results", settle: 3)
        if el(app, "home.search.clear").exists { el(app, "home.search.clear").tap() }
        if search.exists { search.focusAndType("24.7590, 46.7491") }
        expect(app, ["home.result.coordinate"], "05-home-09-search-coordinate", timeout: 8)
        shot("05-home-09-search-coordinate")

        /* The point card (a long press on the map). */
        app = launch(["-SaryScreen", "home"])
        if el(app, "home.map").waitForExistence(timeout: 30) {
            sleep(2)
            el(app, "home.map").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 1.2)
        }
        expect(app, ["home.place.start", "home.place.name"], "05-home-10-point-card", timeout: 10)
        shot("05-home-10-point-card", settle: 4)

        /* The layers sheet on the home map. */
        app = launch(["-SaryScreen", "home"])
        if tapID(app, "map.layers", "05-home-11-layers-sheet", timeout: 30) {
            expect(app, ["explore.layers.sheet"], "05-home-11-layers-sheet", timeout: 10)
        }
        shot("05-home-11-layers-sheet")
        swipeUp(app, in: app.scrollViews.firstMatch)
        shot("05-home-12-layers-sheet-scrolled")

        /* «البر»: weather, Qibla, camp, routes. */
        app = launch(["-SaryScreen", "home"])
        if tapID(app, "home.tools.open", "05-home-13-desert-tools", timeout: 30) {
            expect(app, ["home.tools.weather", "home.tools.qibla"], "05-home-13-desert-tools", timeout: 8)
        }
        shot("05-home-13-desert-tools")
        let tools: [(String, String)] = [("05-home-14-tools-weather", "home.tools.weather"), ("05-home-15-tools-qibla", "home.tools.qibla"),
                                         ("05-home-16-tools-camp", "home.tools.camp"), ("05-home-17-tools-routes", "home.tools.routes")]
        for (name, id) in tools {
            let t = launch(["-SaryScreen", "home"])
            if tapID(t, "home.tools.open", name, timeout: 30) { tapID(t, id, name) }
            shot(name, settle: 4)
        }

        screen("05-home-18-offline", ["-SaryScreen", "home", "-SaryOffline"], ready: ["offline-banner"], settle: 4)
        screen("05-home-19-one-map-idle", ["-SaryScreen", "home", "-SaryOneMap"], ready: ["home.search"], settle: 5)
        screen("05-home-20-no-outings", ["-SaryScreen", "home", "-demoEmpty"], ready: ["home.search"], settle: 4)
    }

    // MARK: - 06 Create-outing wizard

    func test06CreateWizard() {
        var app = screen("06-create-01-destination", ["-SaryScreen", "create"], ready: ["create.dest.field"])
        if tapID(app, "create.dest.map", "06-create-02-pick-on-map") { expect(app, ["create.map.confirm"], "06-create-02-pick-on-map", timeout: 8) }
        shot("06-create-02-pick-on-map", settle: 4)

        app = screen("06-create-03-destination-coordinate", ["-SaryScreen", "create-coordinate"], ready: ["create.dest.coordinate"])
        if tapID(app, "create.dest.coordinate", "06-create-04-weather-there") { expect(app, ["create.name"], "06-create-04-weather-there", timeout: 10) }
        shot("06-create-04-weather-there", settle: 3)
        app.swipeUp()
        shot("06-create-05-weather-there-scrolled")
        if tapID(app, "create.approve", "06-create-06-invite-friends") { expect(app, ["create.start", "create.qr"], "06-create-06-invite-friends", timeout: 10) }
        shot("06-create-06-invite-friends", settle: 3)
        app.swipeUp()
        shot("06-create-07-invite-friends-scrolled")

        screen("06-create-08-destination-search", ["-SaryScreen", "create-search"], ready: ["create.dest.field"], settle: 4)

        /* The quick mode (from «أنشئ طلعة» on the home map): «مين معك؟». */
        app = screen("06-create-09-quick-who-is-with-you", ["-SaryScreen", "create-quick"], ready: ["start.withFriends", "start.solo"])
        if tapID(app, "start.withFriends", "06-create-10-quick-invite") { expect(app, ["create.start"], "06-create-10-quick-invite", timeout: 10) }
        shot("06-create-10-quick-invite")
    }

    // MARK: - 07 Invite / QR share

    func test07InviteShare() {
        var app = live(["-SaryDemoInvites", "-SaryStubContact", "فهد أخوي|+966 50 123 4567"], name: "07-share-01-group-list")
        tapIfThere(el(app, "outing-sheet-summary"))
        shot("07-share-01-group-list")
        let invite = el(app, "sheet.invite")
        for _ in 0..<8 where !(invite.exists && invite.isHittable) { app.swipeUp() }
        if tapID(app, "sheet.invite", "07-share-02-personal-invites") { expect(app, ["invite.pickContact", "invite.list"], "07-share-02-personal-invites", timeout: 8) }
        shot("07-share-02-personal-invites")
        if tapID(app, "invite.pickContact", "07-share-03-send-invite") {
            expect(app, ["invite.send.whatsapp", "invite.send.share"], "07-share-03-send-invite", timeout: 8)
        }
        shot("07-share-03-send-invite")

        /* The open link with its QR (no personal invites in this demo). */
        app = live([], name: "07-share-04-open-link-qr")
        if moreTile(app, "outing-invite", "07-share-04-open-link-qr") { expect(app, ["invite-qr", "invite-share", "invite-section"], "07-share-04-open-link-qr", timeout: 8) }
        shot("07-share-04-open-link-qr", settle: 3)
        app.swipeUp()
        shot("07-share-05-open-link-qr-scrolled")

        /* A member: «الدعوات عند أمير الطلعة». */
        app = live(["-SaryDemoMe", memberId], name: "07-share-06-member-view")
        moreTile(app, "outing-invite", "07-share-06-member-view")
        shot("07-share-06-member-view", settle: 3)
    }

    // MARK: - 08 Live outing: states, sheet, «المزيد», panels

    func test08LiveOuting() {
        var app = live(["-demoNotStarted"], name: "08-live-01-not-started")
        expect(app, ["flow.cta.startOuting"], "08-live-01-not-started", timeout: 10)
        shot("08-live-01-not-started", settle: 4)
        app = live(["-demoNotStarted", "-SaryDemoMe", memberId], name: "08-live-02-not-started-member")
        shot("08-live-02-not-started-member", settle: 4)

        app = live(["-SaryRadioRemote"], name: "08-live-03-stopped-peek")
        shot("08-live-03-stopped-peek", settle: 5)
        tapIfThere(el(app, "outing-sheet-summary"))
        shot("08-live-04-sheet-half")
        app = live(["-SaryLiveSheet", "full"], name: "08-live-05-sheet-full")
        shot("08-live-05-sheet-full", settle: 3)
        app.swipeUp()
        shot("08-live-06-sheet-full-scrolled")

        app = live(["-SaryContext", "driving", "-SaryRadioRemote"], name: "08-live-07-driving")
        shot("08-live-07-driving", settle: 5)

        /* «المزيد». */
        app = live(["-SaryLiveModal", "actions"], name: "08-live-08-more")
        expect(app, ["outing-actions-sheet"], "08-live-08-more", timeout: 10)
        shot("08-live-08-more")
        app.swipeUp()
        shot("08-live-09-more-scrolled")
        app = live(["-SaryLiveModal", "actions"], name: "08-live-10-more-location-tools")
        if tapID(app, "outing-location-tools", "08-live-10-more-location-tools", timeout: 10) { sleep(1) }
        shot("08-live-10-more-location-tools")
        app = live(["-SaryLiveModal", "actions"], name: "08-live-11-more-weather-tools")
        if tapID(app, "outing-weather-tools", "08-live-11-more-weather-tools", timeout: 10) { sleep(1) }
        shot("08-live-11-more-weather-tools")

        /* The panels. */
        app = live([], name: "08-live-12-panel-route")
        if moreTile(app, "outing-route", "08-live-12-panel-route") { expect(app, ["panel.route"], "08-live-12-panel-route", timeout: 8) }
        shot("08-live-12-panel-route")
        app = live([], name: "08-live-13-panel-rally")
        if tapID(app, "sheet.rally", "08-live-13-panel-rally", timeout: 10) { expect(app, ["panel.rally"], "08-live-13-panel-rally", timeout: 8) }
        shot("08-live-13-panel-rally")
        if tapID(app, "rally-set", "08-live-14-rally-new") { sleep(1) }
        shot("08-live-14-rally-new")
        app = live([], name: "08-live-15-panel-safety")
        moreTile(app, "outing-timer", "08-live-15-panel-safety")
        shot("08-live-15-panel-safety", settle: 3)

        /* The header: destination and plan, connection details, the alerts log. */
        app = live(["-SaryConvoyIntelDemo"], name: "08-live-16-convoy-alerts")
        shot("08-live-16-convoy-alerts", settle: 6)
        if tapID(app, "alerts.bell", "08-live-17-alerts-log") { sleep(2) }
        shot("08-live-17-alerts-log")
        app = live([], name: "08-live-18-header-destination")
        if tapID(app, "outing-title", "08-live-18-header-destination") { sleep(2) }
        shot("08-live-18-header-destination")
        app = live([], name: "08-live-19-header-connection")
        if tapID(app, "outing-link-state", "08-live-19-header-connection") { sleep(2) }
        shot("08-live-19-header-connection")

        /* A friend's card (tap his car). */
        app = live([], name: "08-live-20-member-card")
        let friend = el(app, "car.chip")
        if friend.waitForExistence(timeout: 15) && friend.isHittable { friend.tap() } else { note("08-live-20-member-card", "No friend's car chip to tap on screen.") }
        shot("08-live-20-member-card", settle: 3)

        /* «تغادر الطلعة؟» and «تنهي الطلعة للكل؟», not confirmed. */
        app = live([], name: "08-live-21-leave-confirm")
        if app.buttons["outing-actions"].waitForExistence(timeout: 10) { _ = app.openLeaveConfirmation() } else { note("08-live-21-leave-confirm", "«المزيد» did not show.") }
        shot("08-live-21-leave-confirm")
        app = live([], name: "08-live-22-end-confirm")
        if moreTile(app, "settings-end", "08-live-22-end-confirm") { _ = app.buttons["أنهِها"].waitForExistence(timeout: 5) }
        shot("08-live-22-end-confirm")

        /* «ننتظر موقعك…»: no fix yet. */
        app = launch(["-demoSharing", "-SaryContext", "stopped", "-SaryParkedPhone"])
        shot("08-live-23-waiting-or-stale-fix", settle: 6)
    }

    // MARK: - 09 Guiding, driving, off-road, back-track, follow

    func test09Navigation() {
        let guide = ["-SaryContext", "driving", "-SaryNavDemo", "-SaryNavDelay", "3", "-SaryRadioRemote", "-SaryNavTo", "24.7220,46.6650,حطين"]
        var app = live(guide + ["-SaryNavState", "guiding"], ready: ["nav.banner"], name: "09-nav-01-guiding")
        shot("09-nav-01-guiding", settle: 5)
        tapIfThere(el(app, "nav.bottomBar"))
        shot("09-nav-02-guiding-sheet-raised")
        live(guide + ["-SaryNavState", "reroute"], ready: ["nav.banner", "nav.rerouting"], name: "09-nav-03-rerouting")
        shot("09-nav-03-rerouting", settle: 4)
        live(guide + ["-SaryNavState", "guiding", "-SaryNavSteps"], ready: ["nav.steps"], name: "09-nav-04-steps")
        shot("09-nav-04-steps", settle: 3)
        live(guide + ["-SaryNavState", "guiding", "-SaryNavOverview"], ready: ["nav.banner"], name: "09-nav-05-overview")
        shot("09-nav-05-overview", settle: 6)
        live(guide + ["-SaryNavState", "arrived"], ready: ["nav.arrived"], name: "09-nav-06-arrived")
        shot("09-nav-06-arrived", settle: 3)
        live(["-SaryContext", "driving", "-SaryNavDemo", "-SaryNavDelay", "3", "-SaryNavTo", "24.80,46.85,روضة خريم",
              "-SaryNavState", "offroad", "-SaryNavOffRoad"], ready: ["nav.offroad"], name: "09-nav-07-off-road")
        shot("09-nav-07-off-road", settle: 5)

        /* Before guiding: the options, the target picker, the leader's choice. */
        live(["-SaryNavDemo", "-SaryNavDelay", "3", "-SaryNavTo", "24.7220,46.6650,حطين"], ready: ["nav.options"], name: "09-nav-08-options")
        shot("09-nav-08-options", settle: 3)
        live(["-SaryNavPicker"], ready: ["nav.picker"], name: "09-nav-09-target-picker")
        shot("09-nav-09-target-picker", settle: 3)
        app = live(["-SaryAutoNav", "-SaryNavDemo", "-demoNotStarted", "-SaryLiveSheet", "half"], name: "09-nav-10-start-choice")
        if tapID(app, "flow.cta.startOuting", "09-nav-10-start-choice", timeout: 10) { expect(app, ["nav.choice"], "09-nav-10-start-choice", timeout: 10) }
        shot("09-nav-10-start-choice")
        app = live([], name: "09-nav-11-live-search")
        if moreTile(app, "outing-search", "09-nav-11-live-search") { expect(app, ["search.field"], "09-nav-11-live-search", timeout: 8) }
        shot("09-nav-11-live-search")
        screen("09-nav-12-route-surfaces", ["-SaryScreen", "route-surfaces"], ready: ["nav.surfaceLegend"])
        screen("09-nav-13-route-km", ["-SaryScreen", "route-km"], ready: ["nav.surfaceKm"])

        /* «طريق الرجعة» and «اسلك هذا المسار». */
        live(["-demoTrail", "-SaryBackTrack", "3"], ready: ["backtrack.panel"], name: "09-nav-14-back-track")
        shot("09-nav-14-back-track", settle: 4)
        live(["-SaryFollow", "3"], ready: ["follow.panel"], name: "09-nav-15-follow-track")
        shot("09-nav-15-follow-track", settle: 4)
    }

    // MARK: - 10 Map tools in the outing: explore, point card, waypoints, convoy, note, nearby, brief

    func test10LiveTools() {
        var app = live(["-SaryExplore"], ready: ["explore.header"], name: "10-tools-01-explore")
        shot("10-tools-01-explore", settle: 5)
        if tapID(app, "explore.layer.topo", "10-tools-02-explore-topo") { sleep(4) }
        shot("10-tools-02-explore-topo")
        app = live(["-SaryExplore"], ready: ["explore.header"], name: "10-tools-03-places-and-tracks")
        if tapID(app, "explore-places", "10-tools-03-places-and-tracks") { expect(app, ["places.sheet", "tracks.sheet"], "10-tools-03-places-and-tracks", timeout: 8) }
        shot("10-tools-03-places-and-tracks")
        app = live(["-SaryExplore"], ready: ["explore.header"], name: "10-tools-04-realistic")
        if tapID(app, "explore-realistic", "10-tools-04-realistic") { sleep(8) }
        note("10-tools-04-realistic", "Apple 3D cities need the network; on a simulator without it the realistic map may stay flat.")
        shot("10-tools-04-realistic")
        app = live(["-SaryExplore", "-SaryHiRes"], ready: ["explore.header"], name: "10-tools-05-explore-hires")
        shot("10-tools-05-explore-hires", settle: 6)

        /* The point card on the outing map (one long press). */
        app = live([], name: "10-tools-06-point-card")
        let map = el(app, "outing.map")
        if map.waitForExistence(timeout: 10) {
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.2)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.2)
        }
        expect(app, ["point.title", "point.add"], "10-tools-06-point-card", timeout: 8)
        shot("10-tools-06-point-card", settle: 3)

        let tiles: [(String, String, String?, [String])] = [
            ("10-tools-07-waypoint-new", "outing-waypoint-add", "outing-location-tools", ["waypoint.save", "waypoint.title"]),
            ("10-tools-08-place-brief", "outing-brief", "outing-location-tools", ["brief.section"]),
            ("10-tools-09-save-place", "outing-save-place", "outing-location-tools", []),
            ("10-tools-10-nearest-station", "outing-nearest-open", "outing-location-tools", []),
            ("10-tools-11-convoy", "outing-convoy", nil, ["convoy.section", "convoy.save", "convoy.lead"]),
            ("10-tools-12-note-above-car", "outing-note-open", nil, ["note-input"]),
            ("10-tools-13-hide-location", "live.hideLocation", nil, []),
            ("10-tools-14-navigate-picker", "outing-navigate", nil, ["nav.picker"]),
            ("10-tools-15-fit-everyone", "outing-fit", nil, []),
        ]
        for (name, id, group, ready) in tiles {
            let t = live([], name: name)
            if moreTile(t, id, group: group, name), !ready.isEmpty { expect(t, ready, name, timeout: 8) }
            shot(name, settle: 3)
        }
        note("10-tools-10-nearest-station", "The station list comes from live search; without the network it may be empty.")

        /* A shared waypoint's card, with demo waypoints on the map. */
        app = live(["-demoConvoy"], name: "10-tools-16-convoy-demo")
        shot("10-tools-16-convoy-demo", settle: 5)
    }

    // MARK: - 11 Ended outing and its summary

    func test11Ended() {
        let app = live(["-SaryTrip", "arrived", "-SarySheetHalf"], name: "11-ended-01-arrived")
        shot("11-ended-01-arrived", settle: 3)
        if app.buttons["outing-actions"].waitForExistence(timeout: 30), app.endOutingFromMore() {
            expect(app, ["trip.return", "live.ended", "live.ended.title"], "11-ended-02-sheet-after-end", timeout: 10)
        } else {
            note("11-ended-02-sheet-after-end", "Ending from «المزيد» did not go through.")
        }
        shot("11-ended-02-sheet-after-end", settle: 3)
        let summary = el(app, "outing-sheet-summary")
        if summary.waitForExistence(timeout: 5) { summary.tap() }
        shot("11-ended-03-ended-card", settle: 3)
        if tapID(app, "live.ended.summary", "11-ended-04-summary") { expect(app, ["summary.stats"], "11-ended-04-summary", timeout: 10) }
        shot("11-ended-04-summary", settle: 3)
        app.swipeUp()
        shot("11-ended-05-summary-scrolled")
        app.swipeUp()
        shot("11-ended-06-summary-bottom")
    }

    // MARK: - 12 SOS (mine and a friend's)

    func test12SOS() {
        var app = live([], name: "12-sos-01-countdown")
        let sos = el(app, "outing-sos")
        if sos.waitForExistence(timeout: 20) {
            sos.press(forDuration: 1.6)
            expect(app, ["sos-countdown"], "12-sos-01-countdown", timeout: 3)
            shot("12-sos-01-countdown", settle: 0)
            expect(app, ["outing-sos-ok"], "12-sos-02-mine-active", timeout: 10)
            shot("12-sos-02-mine-active", settle: 2)
            if tapID(app, "outing-sos-ok", "12-sos-03-stop-confirm") { expect(app, ["sos-stop-yes", "sos-stop-no"], "12-sos-03-stop-confirm", timeout: 4) }
            shot("12-sos-03-stop-confirm", settle: 1)
        } else {
            note("12-sos-01-countdown", "The SOS button did not show.")
            shot("12-sos-01-countdown")
        }

        app = live(["-SaryFriendSOS", "6"], name: "12-sos-04-friend")
        expect(app, ["sos-alert-show"], "12-sos-04-friend", timeout: 30)
        shot("12-sos-04-friend")
        app = live(["-SaryFriendSOS", "6", "-SaryLiveModal", "layers"], name: "12-sos-05-friend-over-sheet")
        expect(app, ["sos-alert-show"], "12-sos-05-friend-over-sheet", timeout: 30)
        shot("12-sos-05-friend-over-sheet")
    }

    // MARK: - 13 Safety: return timer, stuck, Enjad

    func test13Safety() {
        let states: [(String, String, [String])] = [
            ("13-safety-01-timer-armed", "timer", ["timer-card"]),
            ("13-safety-02-timer-overdue", "overdue", ["timer-card", "timer-due"]),
            ("13-safety-03-timer-editor", "editor", ["timer-save"]),
            ("13-safety-04-stuck-me", "stuck-me", ["my-stuck-strip"]),
            ("13-safety-05-stuck-friend", "stuck-friend", ["safety-stuck-card"]),
            ("13-safety-06-stuck-confirm", "confirm-stuck", []),
            ("13-safety-07-sunset", "sunset", []),
            ("13-safety-08-unavailable", "unavailable", ["timer-unavailable"]),
        ]
        for (name, state, ready) in states {
            let app = live(["-SarySafety", state, "-SarySafetySheet", "half"], name: name)
            if !ready.isEmpty { expect(app, ready, name, timeout: 10) }
            shot(name, settle: 4)
        }

        var app = live([], name: "13-safety-09-stuck-from-more")
        if moreTile(app, "outing-stuck", "13-safety-09-stuck-from-more") { _ = app.buttons["إيه، غرّزت"].waitForExistence(timeout: 5) }
        shot("13-safety-09-stuck-from-more")
        app = live([], name: "13-safety-10-enjad")
        if moreTile(app, "outing-enjad", "13-safety-10-enjad") { expect(app, ["enjad.sheet"], "13-safety-10-enjad", timeout: 6) }
        shot("13-safety-10-enjad")
    }

    // MARK: - 14 Chat

    func test14Chat() {
        var app = live(["-SaryChat", "home"], ready: ["chat.home"], name: "14-chat-01-conversations")
        shot("14-chat-01-conversations")
        if tapID(app, "chat.row.direct", "14-chat-02-direct-thread") { expect(app, ["chat.thread"], "14-chat-02-direct-thread", timeout: 6) }
        shot("14-chat-02-direct-thread")

        app = live(["-SaryChat", "group"], ready: ["chat.thread"], name: "14-chat-03-group-thread")
        shot("14-chat-03-group-thread", settle: 3)
        let his = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "هلا بالشباب")).firstMatch
        if his.waitForExistence(timeout: 5) {
            his.press(forDuration: 1.0)
            sleep(1)
        } else {
            note("14-chat-04-message-menu", "The friend's message «هلا بالشباب» was not there to long-press.")
        }
        shot("14-chat-04-message-menu")

        live(["-SaryChat", "group", "-SaryChatMoving"], ready: ["chat.thread"], name: "14-chat-05-driving-block")
        shot("14-chat-05-driving-block")
        live(["-SaryChat", "group", "-SaryChatOffline"], ready: ["chat.thread"], name: "14-chat-06-offline")
        shot("14-chat-06-offline")
        live(["-SaryLiveSheet", "half", "-SaryLiveTab", "group"], ready: ["sheet.chat"], name: "14-chat-07-quick-row-badge")
        shot("14-chat-07-quick-row-badge")
    }

    // MARK: - 15 Voice notes and PTT channels

    func test15VoiceAndPTT() {
        var app = live(["-SaryPTTTone"], name: "15-voice-01-recording")
        if tapID(app, "outing-ptt", "15-voice-01-recording", timeout: 10) { expect(app, ["voice-note-recording"], "15-voice-01-recording", timeout: 5) }
        shot("15-voice-01-recording", settle: 3)
        if tapID(app, "voice-note-send", "15-voice-02-friend-note") {
            expect(app, ["voice-note-playing", "voice-note-pill", "voice-note-offer"], "15-voice-02-friend-note", timeout: 20)
        }
        shot("15-voice-02-friend-note", settle: 1)

        app = live([], name: "15-voice-03-channels")
        if tapID(app, "ptt-channel-chip", "15-voice-03-channels", timeout: 10) { expect(app, ["ptt-channels-sheet"], "15-voice-03-channels", timeout: 5) }
        shot("15-voice-03-channels")
        swipeUp(app, in: app.collectionViews.firstMatch)
        shot("15-voice-04-channels-scrolled")
        let create = app.buttons["ptt-channel-create"]
        for _ in 0..<4 where !(create.exists && create.isHittable) { swipeUp(app, in: app.collectionViews.firstMatch) }
        if tapID(app, "ptt-channel-create", "15-voice-05-private-channel") { expect(app, ["ptt-private-name"], "15-voice-05-private-channel", timeout: 5) }
        shot("15-voice-05-private-channel")

        live(["-SaryPTTDemo", "talking"], name: "15-voice-06-ptt-talking")
        shot("15-voice-06-ptt-talking", settle: 5)
        live(["-SaryPTTDemo", "listening"], name: "15-voice-07-ptt-listening")
        shot("15-voice-07-ptt-listening", settle: 5)
    }

    // MARK: - 16 YouTube and the outing radio

    func test16MediaAndRadio() {
        live(["-SaryOpenMedia", "mine", "-SaryStubPlayer"], ready: ["media.sheet"], name: "16-media-01-youtube-mine")
        shot("16-media-01-youtube-mine", settle: 3)
        live(["-SaryOpenMedia", "outing", "-SaryStubPlayer"], ready: ["media.sheet"], name: "16-media-02-youtube-outing")
        shot("16-media-02-youtube-outing", settle: 3)
        live(["-SaryOpenMedia", "outing", "-SaryStubPlayer", "-SaryMediaMoving"], ready: ["media.sheet"], name: "16-media-03-youtube-moving")
        shot("16-media-03-youtube-moving", settle: 3)
        live(["-SaryOpenRadio", "-SaryStubAudio", "-SaryStubPlayer"], ready: ["radio.sheet"], name: "16-media-04-radio")
        shot("16-media-04-radio", settle: 3)
        live(["-SaryOpenRadio", "-SaryStubAudio", "-SaryStubPlayer", "-SaryRadioMember"], ready: ["radio.sheet"], name: "16-media-05-radio-member")
        shot("16-media-05-radio-member", settle: 3)
    }

    // MARK: - 17 Weather sheet and layers

    func test17Weather() {
        let app = live(["-SaryLiveModal", "weather"], ready: ["weather.sheet"], name: "17-weather-01-sheet")
        shot("17-weather-01-sheet", settle: 3)
        app.swipeUp()
        shot("17-weather-02-sheet-scrolled")
        app.swipeUp()
        shot("17-weather-03-sheet-bottom")
        let layers: [(String, String)] = [("17-weather-04-layer-rain", "rain"), ("17-weather-05-layer-wind", "wind"), ("17-weather-06-layer-clouds", "clouds")]
        for (name, kind) in layers {
            live(["-SaryWeather", kind, "-SaryWeatherCam", "24.71,46.67,6"], name: name)
            shot(name, settle: 8)
        }
        live(["-SaryWeatherCard", "expanded"], ready: ["weather.card"], name: "17-weather-07-card-expanded")
        shot("17-weather-07-card-expanded", settle: 4)
        screen("17-weather-08-weather-here", ["-SaryScreen", "weather-here"], ready: ["weather-here", "weather.close"], settle: 4)
    }

    // MARK: - 18 Qibla

    func test18Qibla() {
        live(["-SaryLiveModal", "qibla", "-SaryQiblaHeading", "250"], ready: ["qibla.compass", "qibla.degrees"], name: "18-qibla-01-compass")
        shot("18-qibla-01-compass", settle: 3)
        live(["-SaryLiveModal", "qibla", "-SaryQiblaHeading", "250", "-SaryQiblaAccuracy", "45"], ready: ["qibla.compass", "qibla.calibrate"],
             name: "18-qibla-02-low-accuracy")
        shot("18-qibla-02-low-accuracy", settle: 3)
        live(["-SaryLiveModal", "qibla", "-SaryQiblaLocationState", "denied"], ready: ["qibla.location-denied"], name: "18-qibla-03-location-denied")
        shot("18-qibla-03-location-denied", settle: 2)
        live(["-SaryLiveModal", "qibla", "-SaryQiblaLocationState", "failed"], ready: ["qibla.location-error"], name: "18-qibla-04-location-error")
        shot("18-qibla-04-location-error", settle: 2)
    }

    // MARK: - 19 Camp suggestions, desert routes, the outing's layers sheet

    func test19DesertTools() {
        live(["-SaryCampFrom", "24.7113,46.6744", "-SaryCampNight", "0,20", "-SaryExplore", "-SaryLiveModal", "camp"], ready: ["camp.sheet"],
             name: "19-desert-01-camp-suggest")
        shot("19-desert-01-camp-suggest", settle: 4)
        live(["-SaryCampFrom", "24.7113,46.6744", "-SaryLiveModal", "camp", "-SaryCampWeatherOff"], ready: ["camp.sheet"], name: "19-desert-02-camp-no-weather")
        shot("19-desert-02-camp-no-weather", settle: 4)

        let route = ["-SaryLiveModal", "routes", "-SaryRouteTo", "25.23,46.74", "-SaryRouteName", "روضة نورة", "-SaryRouteFrom", "24.7113,46.6744"]
        live(route, ready: ["routes.sheet"], name: "19-desert-03-routes")
        shot("19-desert-03-routes", settle: 5)
        live(route + ["-SaryRouteRain"], ready: ["routes.sheet"], name: "19-desert-04-routes-rain")
        shot("19-desert-04-routes-rain", settle: 5)
        live(route + ["-SaryRouteForceNone"], ready: ["routes.none"], name: "19-desert-05-routes-none")
        shot("19-desert-05-routes-none", settle: 3)

        let app = live(["-SaryExplore", "-SaryLiveModal", "layers"], ready: ["explore.layers.sheet"], name: "19-desert-06-layers-sheet")
        shot("19-desert-06-layers-sheet", settle: 3)
        let page = app.scrollViews.firstMatch
        for i in 7...9 {
            swipeUp(app, in: page)
            shot(String(format: "19-desert-%02d-layers-sheet-scrolled", i))
        }
    }

    // MARK: - 20 Plan editor

    func test20Plan() {
        let app = screen("20-plan-01-editor", ["-SaryScreen", "plan-editor"], ready: ["plan.editor", "plan.map"], settle: 4)
        let map = el(app, "plan.map")
        if tapID(app, "plan.draw", "20-plan-02-drawing"), map.exists {
            for (x, y) in [(0.3, 0.35), (0.5, 0.45), (0.7, 0.4)] {
                map.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                usleep(600_000)
            }
        }
        shot("20-plan-02-drawing", settle: 2)
        screen("20-plan-03-coordinate-search", ["-SaryScreen", "plan-search"], ready: ["search.field", "search.coordinate"])
        screen("20-plan-04-point-card", ["-SaryScreen", "plan-point"], ready: ["point.title"])
        screen("20-plan-05-me-stale", ["-SaryScreen", "plan-me-stale"], ready: [])
        screen("20-plan-06-details-not-started", ["-SaryScreen", "plan-details"], ready: ["details.open", "details.leave", "details.planOpen"])
        screen("20-plan-07-empty-plan", ["-SaryScreen", "plan-editor", "-demoPlanEmpty"], ready: ["plan.editor", "plan.map"], settle: 4)
    }

    // MARK: - 21 Outings list, details, summary, history, tracks

    func test21Outings() {
        let list = launch(["-SaryScreen", "home"])
        list.openHomeOutings()
        expect(list, ["list.create"], "21-outings-01-list")
        shot("21-outings-01-list")

        let details = screen("21-outings-02-details", ["-SaryScreen", "details"], ready: ["details.open", "details.leave"])
        details.swipeUp()
        shot("21-outings-03-details-scrolled")
        details.swipeUp()
        shot("21-outings-04-details-bottom")

        let summary = screen("21-outings-05-summary", ["-SaryScreen", "summary"], ready: ["summary.stats"])
        summary.swipeUp()
        shot("21-outings-06-summary-scrolled")
        summary.swipeUp()
        shot("21-outings-07-summary-bottom")

        screen("21-outings-08-history", ["-SaryScreen", "history"], ready: [])
        screen("21-outings-09-track-detail", ["-SaryScreen", "track-detail"], ready: ["track.detail"], settle: 4)
        screen("21-outings-10-track-follow", ["-SaryScreen", "follow"], ready: ["follow.screen", "follow.panel"], settle: 4)
        screen("21-outings-11-leave-dialog", ["-SaryScreen", "dialog-leave"], ready: [])
        let join = launch(["-SaryScreen", "home"])
        join.openHomeOutings()
        if tapID(join, "list.join", "21-outings-12-join-by-link") { expect(join, ["paste.field"], "21-outings-12-join-by-link", timeout: 5) }
        shot("21-outings-12-join-by-link")
    }

    // MARK: - 22 Trip story

    func test22Story() {
        let app = screen("22-story-01-composer", ["-SaryScreen", "story"], ready: ["story.preview"], settle: 4)
        app.swipeUp()
        shot("22-story-02-options")
        let summary = launch(["-SaryScreen", "summary"])
        if tapID(summary, "summary.story", "22-story-03-from-summary", timeout: 15) { expect(summary, ["story.preview"], "22-story-03-from-summary", timeout: 8) }
        shot("22-story-03-from-summary", settle: 3)
    }

    // MARK: - 23 Profile, settings and their sub-pages

    func test23ProfileAndSettings() {
        let sheet = launch(["-SaryScreen", "home"])
        if tapID(sheet, "home.profile", "23-profile-01-sheet", timeout: 30) { expect(sheet, ["profile.sheet.settings"], "23-profile-01-sheet", timeout: 5) }
        shot("23-profile-01-sheet")
        let fromSheet: [(String, String)] = [("23-profile-02-favorites", "profile.sheet.favorites"), ("23-profile-03-activity", "profile.sheet.activity"),
                                             ("23-profile-04-help", "profile.sheet.help"), ("23-profile-05-terms", "profile.sheet.terms")]
        for (name, id) in fromSheet {
            let app = launch(["-SaryScreen", "home"])
            if tapID(app, "home.profile", name, timeout: 30), tapID(app, id, name, timeout: 5) { sleep(2) }
            shot(name, settle: 2)
        }
        note("23-profile-05-terms", "«الشروط والخصوصية» may open a web page; the shot shows what the app presents.")

        let direct: [(String, String, [String])] = [
            ("23-profile-06-my-profile", "profile", ["profile.name", "profile.save"]),
            ("23-profile-07-settings", "settings", ["settings.appearance"]),
            ("23-profile-09-appearance", "appearance", []),
            ("23-profile-10-privacy", "privacy", ["privacy.deleteAccount"]),
            ("23-profile-11-privacy-bottom", "privacy-account", ["privacy.deleteAccount"]),
            ("23-profile-12-delete-account", "delete-account", ["deleteAccount.submit"]),
            ("23-profile-13-delete-account-typed", "delete-account-typed", ["deleteAccount.submit"]),
            ("23-profile-14-notifications", "notifications", []),
            ("23-profile-15-about", "about", []),
            ("23-profile-16-advanced", "advanced", []),
        ]
        for (name, debug, ready) in direct {
            let app = screen(name, ["-SaryScreen", debug], ready: ready)
            if debug == "settings" {
                app.swipeUp()
                shot("23-profile-08-settings-scrolled")
            }
        }

        /* Rows without their own debug screen: opened from «الإعدادات». */
        let rows: [(String, String)] = [("23-profile-17-recovery", "settings.recovery"), ("23-profile-18-convoy-alerts", "settings.convoyAlerts"),
                                        ("23-profile-19-blocked", "settings.blocked"), ("23-profile-20-intro", "settings.intro"),
                                        ("23-profile-21-visuals", "settings.visuals"), ("23-profile-22-talk-mode", "settings.talkMode"),
                                        ("23-profile-23-radio-sounds", "settings.radioSounds"), ("23-profile-24-voice-level", "settings.voiceLevel")]
        for (name, id) in rows {
            let app = launch(["-SaryScreen", "settings"])
            if el(app, "settings.appearance").waitForExistence(timeout: 15), tapID(app, id, name) { sleep(2) }
            shot(name, settle: 1)
        }
    }

    // MARK: - 24 Outing settings and their sub-pages

    func test24OutingSettings() {
        let app = live(["-SaryLiveTab", "more"], ready: ["settings.page"], name: "24-outsettings-01-top")
        shot("24-outsettings-01-top", settle: 3)
        app.swipeUp()
        shot("24-outsettings-02-middle")
        app.swipeUp()
        shot("24-outsettings-03-bottom")

        let pages: [(String, String)] = [
            ("24-outsettings-04-sharing", "settings.sharing"), ("24-outsettings-05-default-layer", "settings.defaultLayer"),
            ("24-outsettings-06-map-direction", "settings.mapDirection"), ("24-outsettings-07-units", "settings.units"),
            ("24-outsettings-08-driving", "settings.driving"), ("24-outsettings-09-trail", "settings.trail"),
            ("24-outsettings-10-default-channel", "settings.defaultChannel"), ("24-outsettings-11-talk-mode", "settings.talkMode"),
            ("24-outsettings-12-nav-voice", "settings.navVoice"), ("24-outsettings-13-volume", "settings.volume"),
            ("24-outsettings-14-media", "settings.media"), ("24-outsettings-15-phone-panel", "settings.phone"),
        ]
        for (name, id) in pages {
            let p = live(["-SaryLiveTab", "more"], ready: ["settings.page"], name: name)
            if tapID(p, id, name) { sleep(2) }
            shot(name, settle: 1)
        }
        let clear = live(["-SaryLiveTab", "more"], ready: ["settings.page"], name: "24-outsettings-16-clear-history-confirm")
        if tapID(clear, "settings.clearHistory", "24-outsettings-16-clear-history-confirm") { sleep(1) }
        shot("24-outsettings-16-clear-history-confirm")
        let old = live([], name: "24-outsettings-17-from-more")
        if old.buttons["outing-actions"].waitForExistence(timeout: 10) { old.openLiveSettings() }
        expect(old, ["settings.page"], "24-outsettings-17-from-more", timeout: 8)
        shot("24-outsettings-17-from-more")
    }

    // MARK: - 25 Offline maps

    func test25OfflineMaps() {
        screen("25-offline-01-list", ["-SaryScreen", "offline-maps"], ready: [])
        let flow = screen("25-offline-02-flow", ["-SaryScreen", "offline-flow", "-SaryMapboxOffline", "-SaryClearAmbient"], ready: ["offline.add", "offline.usage"])
        if tapID(flow, "offline.add", "25-offline-03-add-area") { expect(flow, ["offline.download", "offline.pickerMap"], "25-offline-03-add-area", timeout: 8) }
        shot("25-offline-03-add-area", settle: 4)
        screen("25-offline-04-area-picker", ["-SaryScreen", "offline-picker"], ready: ["offline.pickerMap", "offline.download"], settle: 4)
        let fromOuting = live(["-SaryLiveTab", "more"], ready: ["settings.page"], name: "25-offline-05-from-outing")
        if tapID(fromOuting, "settings-offline", "25-offline-05-from-outing") { sleep(3) }
        shot("25-offline-05-from-outing")
    }

    // MARK: - 26 Performance and diagnostics

    func test26Performance() {
        let app = live(["-SaryLiveTab", "more"], ready: ["settings.page"], name: "26-perf-01-diagnostics")
        if tapID(app, "settings.diagnostics", "26-perf-01-diagnostics") { sleep(2) }
        shot("26-perf-01-diagnostics")
        if tapLabel(app, "أداء التطبيق", "26-perf-02-app-performance") { sleep(2) }
        note("26-perf-02-app-performance", "MetricKit delivers no payloads on a simulator: the page shows its empty state.")
        shot("26-perf-02-app-performance")
        let gps = live(["-SaryLiveTab", "more"], ready: ["settings.page"], name: "26-perf-03-gps-quality")
        if tapID(gps, "settings.diagnostics", "26-perf-03-gps-quality"), tapID(gps, "settings.gpsQuality", "26-perf-03-gps-quality") { sleep(2) }
        shot("26-perf-03-gps-quality")
    }

    // MARK: - 27 Solo outing

    func test27Solo() {
        let app = live(["-SarySolo", "24.7590,46.7491,روضة الثمامة", "-SaryNavDemo"], ready: ["nav.banner", "outing.map", "nav.offroad"],
                       name: "27-solo-01-guiding")
        shot("27-solo-01-guiding", settle: 6)
        let summary = el(app, "outing-sheet-summary")
        if !tapIfThere(summary) { tapIfThere(el(app, "nav.bottomBar")) }
        shot("27-solo-02-sheet")
        let home = launch(["-SaryScreen", "home", "-SaryNavDemo", "-SaryContext", "stopped"])
        if el(home, "home.search").waitForExistence(timeout: 30) {
            sleep(2)
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.3)
        }
        expect(home, ["home.place.go"], "27-solo-03-place-card-go", timeout: 10)
        shot("27-solo-03-place-card-go")
        if tapID(home, "home.place.go", "27-solo-04-from-home") {
            expect(home, ["nav.banner", "outing.map", "nav.offroad"], "27-solo-04-from-home", timeout: 25)
        }
        shot("27-solo-04-from-home", settle: 4)
    }

    // MARK: - 28 Dark and night variants

    func test28DarkAndNight() {
        screen("28-dark-01-home", ["-SaryScreen", "home"], ready: ["home.search"], scheme: "dark", settle: 5)
        let liveDark = live([], scheme: "dark", name: "28-dark-02-live-stopped")
        shot("28-dark-02-live-stopped", settle: 5)
        tapIfThere(el(liveDark, "outing-sheet-summary"))
        shot("28-dark-03-live-sheet-half")
        live(["-SaryLiveModal", "actions"], scheme: "dark", ready: ["outing-actions-sheet"], name: "28-dark-04-more")
        shot("28-dark-04-more", settle: 3)
        live(["-SaryContext", "driving", "-SaryNavDemo", "-SaryNavDelay", "3", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavState", "guiding",
              "-SaryVisualsClock", "2026-11-05T19:30:00Z"], scheme: "dark", night: true, ready: ["nav.banner"], name: "28-dark-05-night-guiding")
        shot("28-dark-05-night-guiding", settle: 6)
        screen("28-dark-06-summary", ["-SaryScreen", "summary"], ready: ["summary.stats"], scheme: "dark")
        screen("28-dark-07-settings", ["-SaryScreen", "settings"], ready: ["settings.appearance"], scheme: "dark")
        screen("28-dark-08-create", ["-SaryScreen", "create-coordinate"], ready: ["create.dest.field"], scheme: "dark")
    }

    // MARK: - 29 The largest Dynamic Type size

    func test29LargestText() {
        screen("29-bigtext-01-home", ["-SaryScreen", "home"], ready: ["home.search"], textSize: largestText, settle: 5)
        live(["-SaryLiveSheet", "half"], textSize: largestText, name: "29-bigtext-02-live-sheet")
        shot("29-bigtext-02-live-sheet", settle: 4)
        screen("29-bigtext-03-settings", ["-SaryScreen", "settings"], ready: ["settings.appearance"], textSize: largestText)
        screen("29-bigtext-04-invite", ["-SaryScreen", "invite-valid"], ready: ["invite.join"], textSize: largestText, welcomeIsOK: true)
    }
}
