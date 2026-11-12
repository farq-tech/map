import XCTest

/// The trip's guidance until «وصلتوا»: the leader's «للكل» / «لي فقط», members only for
/// themselves (a non-leader's command ignored), over the `-demo` outing (no server,
/// no production outing) with the offline demo router (`-SaryNavDemo`). `-SaryAutoNav` opts the
/// demo into the trip's automatic guidance (real outings always have it).
///
/// The simulator's location is set from outside (`xcrun simctl location <udid> set 24.7113,46.6744`,
/// Olaya, where the demo group is). SARY_SHOTS=<dir> (TEST_RUNNER_SARY_SHOTS) also writes PNGs.
final class TripAutoNavUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let member = ["-SaryDemoMe", "00000000-0000-4000-8000-000000000002"]
    /// Guidance already on for this phone (as after the leader's «للكل», or a relaunch).
    private static let on = ["-SaryAutoNavActive"]

    private func launch(_ extra: [String], sheet: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-demoSharing", "-SaryAutoNav", "-SaryNavDemo",
                               "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0", "-SaryWeatherDemo", "calm"]
            + (sheet.map { ["-SaryLiveSheet", $0] } ?? []) + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        /* The reinstall resets the location permission: answer iOS's prompt directly, whenever it shows. */
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(45)
        while !el(app, "outing-sheet-summary").exists && !el(app, "nav.bottomBar").exists && Date() < deadline {
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
            }
            usleep(250_000)
        }
        for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] where springboard.buttons[label].waitForExistence(timeout: 1.5) {
            springboard.buttons[label].tap()
        }
        if !(el(app, "outing-sheet-summary").exists || el(app, "nav.bottomBar").exists) { shot(app, "debug-launch") }
        XCTAssertTrue(el(app, "outing-sheet-summary").exists || el(app, "nav.bottomBar").exists, "the live screen")
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The leader presses «ابدأ الطلعة»: his choice, «للكل» highlighted; «للكل» starts guidance.
    func testLeaderStartTripForAll() {
        let app = launch(["-demoNotStarted"], sheet: "half")
        XCTAssertFalse(el(app, "nav.banner").exists, "nothing before the start")
        /* UI-AUDIT م3: one «ابدأ الطلعة» — the CTA (the sheet's second button is gone). */
        XCTAssertFalse(el(app, "live.start").exists, "no second «ابدأ الطلعة» in the sheet")
        let start = el(app, "flow.cta.startOuting")
        XCTAssertTrue(start.waitForExistence(timeout: 10), "«ابدأ الطلعة»")
        shot(app, "autonav-0-before-start")
        start.tap()
        XCTAssertTrue(el(app, "nav.choice").waitForExistence(timeout: 10), "the leader's choice")
        XCTAssertTrue(el(app, "nav.choice.all").exists, "«ابدأ التوجيه للكل»")
        XCTAssertTrue(el(app, "nav.choice.me").exists, "«لي فقط»")
        XCTAssertFalse(el(app, "nav.banner").exists, "not silently started for everyone")
        sleep(1)
        shot(app, "autonav-0b-leader-choice")
        el(app, "nav.choice.all").tap()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15), "turn-by-turn starts")
        XCTAssertTrue(el(app, "nav.distance").exists, "the next manoeuvre's distance")
        XCTAssertTrue(el(app, "nav.instruction").exists, "the next manoeuvre")
        XCTAssertTrue(el(app, "nav.banner.eta").exists, "where to and the ETA, in the header")
        XCTAssertTrue(el(app, "nav.banner.eta").label.contains("روضة الثمامة"))
        XCTAssertFalse(el(app, "nav.options").exists, "no options sheet to tap through")
        XCTAssertTrue(el(app, "nav.auto.pause").waitForExistence(timeout: 5), "«أوقف التوجيه»")
        sleep(2)
        shot(app, "autonav-1-started")
    }

    func testLeaderStartTripOnlyMe() {
        let app = launch(["-demoNotStarted"], sheet: "half")
        let start = el(app, "flow.cta.startOuting")
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(el(app, "nav.choice.me").waitForExistence(timeout: 10))
        el(app, "nav.choice.me").tap()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15), "guidance for the leader himself")
    }

    /// A member: the leader's «للكل» arrives over his note ⇒ guidance starts; a local stop stays local.
    func testMemberFollowsTheLeadersCommandAndStopsLocally() {
        /* The broadcast timer runs from app launch: leave room for a slow simulator's launch. */
        let app = launch(Self.member + ["-SaryDemoLeaderBroadcast", "25"])
        XCTAssertFalse(el(app, "nav.banner").exists, "nothing before the leader's command")
        XCTAssertTrue(el(app, "nav.auto.start").waitForExistence(timeout: 8), "a member can start it for himself")
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 45), "the leader's «للكل» starts it here")
        sleep(1)
        shot(app, "autonav-1b-member-following-leader")
        el(app, "nav.auto.pause").tap()
        el(app, "end.action.endTrip").tap() // «إنهاء الرحلة» → the end sheet's first row
        XCTAssertTrue(el(app, "nav.auto.resume").waitForExistence(timeout: 5), "stopped on this phone only")
        sleep(6)
        XCTAssertFalse(el(app, "nav.banner").exists, "the leader's old command does not restart it")
    }

    /// The setting off: «أمير الرحلة بدأ التوجيه · ابدأ», one tap.
    func testMemberBannerWhenTheSettingIsOff() {
        let app = launch(Self.member + ["-SaryAutoNavAsk", "-SaryDemoLeaderBroadcast", "5"])
        let banner = el(app, "nav.auto.leaderBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the leader's offer")
        XCTAssertFalse(el(app, "nav.banner").exists, "not started without asking")
        sleep(1)
        shot(app, "autonav-1c-member-banner")
        banner.tap()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15))
    }

    /// The same command from a member who is not the leader: ignored.
    func testNonLeaderCommandIsIgnored() {
        let app = launch(Self.member + ["-SaryDemoFakeBroadcast", "4"])
        XCTAssertTrue(el(app, "nav.auto.start").waitForExistence(timeout: 10))
        sleep(10)
        XCTAssertFalse(el(app, "nav.banner").exists, "a non-leader cannot start guidance for others")
        XCTAssertTrue(el(app, "nav.auto.start").exists, "still only «ابدأ التوجيه» for myself")
        shot(app, "autonav-1d-non-leader-ignored")
    }

    /// An active trip opened (a member joining, or the app relaunched): guidance resumes by itself.
    func testOpeningAnActiveTripResumesNavigation() {
        let app = launch(Self.on + ["-SaryDrive", "1"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15))
        sleep(2)
        shot(app, "autonav-2-resumed-drive")
    }

    /// Build 21 regression: guidance on, my only fix 5 minutes old. Never silent: «ننتظر موقعك…»,
    /// then the guidance starts by itself with the first fresh fix.
    func testOldFixWaitsVisiblyThenGuidanceStartsByItself() {
        let app = launch(Self.on + ["-SaryStaleFixThenFresh", "25"])
        XCTAssertTrue(el(app, "nav.waitFix.text").waitForExistence(timeout: 15), "«ننتظر موقعك…» is shown")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'ننتظر موقعك'")).firstMatch.exists)
        XCTAssertFalse(el(app, "nav.banner").exists, "no guidance from a 5-minute-old fix")
        shot(app, "autonav-wait-fix")
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 40), "starts by itself with the fresh fix")
        XCTAssertTrue(el(app, "nav.waitFix.text").waitForNonExistence(timeout: 5))
    }

    func testArrivalSaysWasaltuAndStops() {
        let app = launch(Self.on + ["-SaryAutoNavArrive", "6"])
        let title = el(app, "nav.arrived.title")
        /* Arrival fires 6 s into guidance: on a slow simulator the banner can already be gone when
         * we first look, so either the banner or the arrival card proves guidance started. */
        let started = NSPredicate { _, _ in self.el(app, "nav.banner").exists || title.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: started, object: nil)], timeout: 20), .completed, "guidance started")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the arrival card")
        XCTAssertEqual(title.label, "وصلتوا")
        XCTAssertFalse(el(app, "nav.banner").exists, "guidance stopped")
        sleep(1)
        shot(app, "autonav-5-arrived")
        el(app, "nav.arrived.end").tap()
        sleep(6)
        XCTAssertFalse(el(app, "nav.banner").exists, "never restarts after arrival")
    }

    func testStopAdvancesToTheDestination() {
        let app = launch(Self.on + ["-demoPlanStops", "-SaryAutoNavArrive", "14"])
        let eta = el(app, "nav.banner.eta")
        XCTAssertTrue(eta.waitForExistence(timeout: 15))
        XCTAssertTrue(eta.label.contains("محطة البنزين"), "the next planned stop first: \(eta.label)")
        shot(app, "autonav-3-to-stop")
        XCTAssertTrue(el(app, "nav.arrived.title").waitForExistence(timeout: 20), "«وصلتوا» at the stop")
        shot(app, "autonav-4-at-stop")
        let next = NSPredicate(format: "label CONTAINS %@", "روضة الثمامة")
        expectation(for: next, evaluatedWith: eta)
        waitForExpectations(timeout: 25)
        XCTAssertTrue(el(app, "nav.banner").exists, "on to the destination by itself")
        XCTAssertTrue(el(app, "nav.arrived.title").waitForExistence(timeout: 25))
    }

    func testPauseAndResumeOnThisPhone() {
        let app = launch(Self.on)
        XCTAssertTrue(el(app, "nav.auto.pause").waitForExistence(timeout: 15))
        el(app, "nav.auto.pause").tap()
        el(app, "end.action.endTrip").tap() // «إنهاء الرحلة» → the end sheet's first row
        let resume = el(app, "nav.auto.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "«استأنف التوجيه»")
        XCTAssertFalse(el(app, "nav.banner").exists)
        sleep(6)
        XCTAssertFalse(el(app, "nav.banner").exists, "paused stays paused")
        shot(app, "autonav-6-paused")
        resume.tap()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 15), "back on")
    }

    func testOfflineFallsBackToTheArrowThenTheRoad() {
        let app = launch(Self.on + ["-SaryNavOfflineFor", "12", "-SaryNavRetry", "4"])
        let panel = el(app, "nav.offroad")
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "bearing guidance at once")
        /* Lovable (#95): the panel is a container now (distance, title and note read one by one),
         * so the offline title is checked on its own element — the same words, the same moment. */
        let title = el(app, "nav.offroad.title")
        XCTAssertTrue(title.exists, "the panel's title")
        XCTAssertTrue(title.label.contains("بلا إنترنت · اتجاه مباشر"), title.label)
        XCTAssertTrue(el(app, "nav.offroad.distance").exists, "how far, with the arrow")
        XCTAssertFalse(el(app, "nav.banner").exists, "no made-up route")
        sleep(1)
        shot(app, "autonav-7-offline-arrow")
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 30), "the road route once routing works again")
        shot(app, "autonav-8-online-again")
    }

    func testOffRoadLegAfterTheRoad() {
        /* The road part ends 30 s after launch: room for a slow simulator to show it first. */
        let app = launch(Self.on + ["-SaryNavOffRoad", "-SaryAutoNavRouteEnd", "30", "-SaryDrive", "1"])
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 25), "the road part first")
        /* The plan's drawn route reaches the camp: the leg follows it («اسلك هذا المسار»). */
        let follow = el(app, "follow.title")
        let arrow = el(app, "nav.offroad")
        let deadline = Date().addingTimeInterval(45)
        while !follow.exists && !arrow.exists && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(follow.exists || arrow.exists, "switches to off-road guidance by itself")
        sleep(2)
        shot(app, "autonav-9-offroad")
    }
}

/// «اتجه» on my own (docs/SOLO-OUTING.md, step 4): `-SarySolo` opens a solo outing (one member, on
/// this phone only) to a test destination, over `-demo`'s local identity with the offline demo router
/// (`-SaryNavDemo`). The group's UI is gone, the header says «على جوالك فقط», SOS is a 911 call, and
/// guidance starts by itself. `-SaryContext stopped` keeps the header (guiding would make it «driving»).
///
/// The simulator's location is set from outside, as for `TripAutoNavUITests`
/// (`xcrun simctl location <udid> set 24.7113,46.6744`).
final class SoloOutingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SarySolo", "24.7590,46.7491,روضة الثمامة", "-SaryNavDemo",
                               "-SaryScheme", "light", "-SaryDrive", "0", "-SaryNight", "0", "-SaryWeatherDemo", "calm",
                               "-SaryContext", "stopped"] + extra
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow", "السماح"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.allowLocationIfAsked()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(45)
        while !el(app, "outing-sheet-summary").exists && !el(app, "nav.bottomBar").exists && Date() < deadline {
            for label in ["Allow While Using App", "السماح أثناء استخدام التطبيق"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
            }
            usleep(250_000)
        }
        XCTAssertTrue(el(app, "outing-sheet-summary").exists || el(app, "nav.bottomBar").exists, "the live screen, on a solo outing")
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openMore(_ app: XCUIApplication) {
        let more = el(app, "nav.more").exists ? el(app, "nav.more") : el(app, "outing-actions")
        if !more.waitForExistence(timeout: 4) { el(app, "outing-sheet-summary").tap() }
        XCTAssertTrue(more.waitForExistence(timeout: 6), "«المزيد»")
        more.tap()
        XCTAssertTrue(el(app, "outing-actions-sheet").waitForExistence(timeout: 6))
    }

    func testGuidanceStartsByItself() {
        let app = launch()
        XCTAssertTrue(el(app, "nav.banner").waitForExistence(timeout: 25), "turn-by-turn to the destination, without a tap")
        shot(app, "solo-1-guiding")
    }

    func testNoWalkieTalkieNoVoiceNotes() {
        let app = launch()
        sleep(2)
        XCTAssertFalse(el(app, "outing-ptt").exists, "no «اضغط وتكلم» in a solo outing")
        XCTAssertFalse(el(app, "ptt-channel-chip").exists)
        XCTAssertFalse(el(app, "outing-ptt-caption").exists)
        XCTAssertFalse(el(app, "voice-note-timer").exists, "no recording")
    }

    func testNoChatNoFriends() {
        let app = launch()
        sleep(2)
        XCTAssertFalse(el(app, "sheet.chat").exists, "no chat in the quick row")
        XCTAssertFalse(el(app, "sheet.rally").exists, "no rally point")
        openMore(app)
        for id in ["outing-chat", "outing-invite", "outing-convoy", "outing-note-open", "outing-fit", "outing-ptt-channels", "live.hideLocation"] {
            XCTAssertFalse(el(app, id).exists, "\(id) is not offered in a solo outing")
        }
        XCTAssertFalse(app.staticTexts["الأصدقاء"].exists, "no «الأصدقاء» group")
        XCTAssertTrue(el(app, "outing-stuck").exists, "the safety pack stays")
        let end = el(app, "settings-end")
        for _ in 0..<8 where !(end.exists && end.isHittable) { app.swipeUp(); usleep(500_000) }
        XCTAssertTrue(end.waitForExistence(timeout: 6))
        XCTAssertTrue(end.label.contains("أنهِ المشوار"), end.label)
        XCTAssertFalse(el(app, "settings-leave").exists, "nothing to leave")
        shot(app, "solo-2-more")
    }

    func testHeaderSaysOnThisPhoneOnly() {
        let app = launch()
        let header = el(app, "trip.header")
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the trip header")
        XCTAssertTrue(header.label.contains("على جوالك فقط"), header.label)
        shot(app, "solo-3-header")
    }

    func testSOSIsA911Call() {
        let app = launch()
        let sos = el(app, "outing-sos")
        XCTAssertTrue(sos.waitForExistence(timeout: 20))
        sos.press(forDuration: 1.6)
        XCTAssertTrue(el(app, "solo.sos.call911").waitForExistence(timeout: 6), "«اتصل ٩١١» first")
        XCTAssertFalse(el(app, "sos-countdown").exists, "no «نرسل طوارئ…»: nothing is sent")
        XCTAssertTrue(el(app, "enjad.call").exists, "Enjad as the second option")
        shot(app, "solo-4-sos")
    }
}
