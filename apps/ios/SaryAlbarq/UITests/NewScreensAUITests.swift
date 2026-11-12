import XCTest

/// Build 47 «شاشات الطلعة» group A behind `-SaryNewUI`: first-run onboarding, join by link, the invite preview and its
/// location recovery. Rules checked on every screen (designer prompt §٣): the ✕/back control sits on the left and the
/// title on the right, the ONE primary is ≥ 58 pt, secondaries ≥ 52 pt, and the actions never sit under the keyboard
/// or off screen. With the flag off the legacy screens are untouched (`testLegacyOnboardingIsUnchangedWithTheFlagOff`).
/// Shots: `SARY_SHOTS` dir, prefix `SARY_SHOT_PREFIX` (default `a`).
final class NewScreensAUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ screen: String, newUI: Bool = true, text: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-SaryScreen", screen, "-SaryScheme", "dark"]
            + (newUI ? ["-SaryNewUI"] : ["-SaryLegacyUI"])
            + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "a"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    private func assertPrimary(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = el(app, id)
        XCTAssertTrue(b.waitForExistence(timeout: 15), id, file: file, line: line)
        XCTAssertGreaterThanOrEqual(b.frame.height, 57.5, "\(id) is the 58 pt primary", file: file, line: line)
        XCTAssertTrue(b.isHittable, "\(id) is reachable", file: file, line: line)
    }

    private func assertSecondary(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = el(app, id)
        XCTAssertTrue(b.waitForExistence(timeout: 10), id, file: file, line: line)
        XCTAssertGreaterThanOrEqual(b.frame.height, 51.5, "\(id) is a 52 pt secondary", file: file, line: line)
        XCTAssertTrue(b.isHittable, id, file: file, line: line)
    }

    // MARK: - Onboarding

    func testIntroHasOnePrimaryAndASecondary() {
        let app = launch("onboarding")
        assertPrimary(app, "onboarding.begin")
        assertSecondary(app, "onboarding.restore")
        XCTAssertLessThan(el(app, "onboarding.begin").frame.minY, el(app, "onboarding.restore").frame.minY, "the primary is above the secondary")
        XCTAssertTrue(el(app, "onboarding.idea").exists)
        XCTAssertTrue(el(app, "onboarding.points").exists, "the new glass card of the three promises")
        shot("onboarding-intro")
    }

    func testProfileStepHeaderAndPinnedPrimary() {
        let app = launch("onboarding-profile")
        assertPrimary(app, "onboarding.start")
        let back = el(app, "page-back"), title = app.staticTexts["عرّفنا عليك"]
        XCTAssertTrue(back.waitForExistence(timeout: 5) && title.exists)
        XCTAssertGreaterThanOrEqual(back.frame.width, 43.5); XCTAssertGreaterThanOrEqual(back.frame.height, 43.5)
        XCTAssertFalse(el(app, "onboarding.start").isEnabled, "no name yet: the primary waits")
        let name = el(app, "onboarding.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        shot("onboarding-profile")
        app.textFields["onboarding.name"].tap()
        app.textFields["onboarding.name"].typeText("أبو فهد")
        XCTAssertTrue(el(app, "onboarding.start").isEnabled, "a name enables the primary")
        XCTAssertTrue(el(app, "onboarding.start").isHittable, "the primary stays above the keyboard")
        shot("onboarding-profile-typing")
    }

    func testLocationExplainerActions() {
        let app = launch("onboarding-location")
        assertPrimary(app, "onboarding.allowLocation")
        assertSecondary(app, "onboarding.skipLocation")
        XCTAssertTrue(el(app, "onboarding.location.title").exists)
        shot("onboarding-location")
    }

    func testLegacyOnboardingIsUnchangedWithTheFlagOff() {
        let app = launch("onboarding", newUI: false)
        XCTAssertTrue(el(app, "onboarding.begin").waitForExistence(timeout: 15))
        XCTAssertFalse(el(app, "onboarding.points").exists, "the new card is not there with the flag off")
        XCTAssertTrue(el(app, "onboarding.restore").exists)
    }

    func testOnboardingActionsSurviveAccessibilityTextSize() {
        let app = launch("onboarding-location", text: "UICTContentSizeCategoryAccessibilityXL")
        XCTAssertTrue(el(app, "onboarding.allowLocation").waitForExistence(timeout: 15))
        XCTAssertTrue(el(app, "onboarding.allowLocation").isHittable, "the pinned primary stays reachable at large text")
        XCTAssertTrue(el(app, "onboarding.skipLocation").isHittable)
        shot("onboarding-location-axl")
    }

    // MARK: - Join by link / invite

    func testJoinByLinkHeaderAndPrimary() {
        let app = launch("join")
        assertPrimary(app, "paste.continue")
        assertSecondary(app, "paste.scan")
        XCTAssertTrue(el(app, "paste.paste").exists)
        XCTAssertFalse(el(app, "paste.continue").isEnabled, "no link yet")
        let close = el(app, "page-close"), title = app.staticTexts["انضم برابط"]
        XCTAssertTrue(close.exists && title.exists)
        XCTAssertLessThan(close.frame.midX, title.frame.midX, "✕ on the left, the title on the right (RTL)")
        XCTAssertGreaterThanOrEqual(close.frame.width, 43.5)
        shot("join")
        app.textFields["paste.field"].tap()
        app.textFields["paste.field"].typeText("https://example.com/x")
        XCTAssertTrue(el(app, "paste.continue").isEnabled)
        XCTAssertTrue(el(app, "paste.continue").isHittable, "above the keyboard")
    }

    func testInviteValidShowsTheOneJoinPrimary() {
        let app = launch("invite-valid")
        assertPrimary(app, "invite.join")
        for id in ["invite.inviter", "invite.name", "join.shareStatement"] {
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), id)
        }
        let close = el(app, "page-close"), title = app.staticTexts["دعوة طلعة"]
        XCTAssertTrue(close.exists && title.exists)
        XCTAssertLessThan(close.frame.midX, title.frame.midX)
        shot("invite-valid")
    }

    func testInvitePersonalAndStates() {
        let personal = launch("invite-personal")
        XCTAssertTrue(el(personal, "invite.personal").waitForExistence(timeout: 15))
        assertPrimary(personal, "invite.join")
        shot("invite-personal")
        personal.terminate()
        for (screen, id) in [("invite-expired", "invite.expired"), ("invite-taken", "invite.taken"), ("invite-invalid", "invite.invalid")] {
            let app = launch(screen)
            XCTAssertTrue(el(app, id).waitForExistence(timeout: 15), id)
            XCTAssertTrue(el(app, "invite.close").exists, "one button to leave")
            XCTAssertFalse(el(app, "invite.join").exists, "no join on a dead invite")
            shot(screen)
            app.terminate()
        }
    }

    func testInviteNeedsLocationRecoveryActions() {
        let app = launch("invite-needs-location")
        XCTAssertTrue(el(app, "join.needsLocation").waitForExistence(timeout: 15))
        assertPrimary(app, "join.openSettings")
        assertSecondary(app, "join.cancel")
        shot("invite-needs-location")
    }

    func testInviteStaysUsableOnASmallScreenTextSize() {
        let app = launch("invite-valid", text: "UICTContentSizeCategoryAccessibilityL")
        XCTAssertTrue(el(app, "invite.join").waitForExistence(timeout: 15))
        XCTAssertTrue(el(app, "invite.join").isHittable, "the primary is pinned: it never scrolls away")
        shot("invite-valid-axl")
    }

    // MARK: - Create wizard, my outings, details, summary

    func testCreateWizardUsesTheUnifiedHeader() {
        let app = launch("create")
        XCTAssertTrue(app.textFields["create.dest.field"].waitForExistence(timeout: 15), "step ١ is «وين رايحين؟»")
        XCTAssertTrue(el(app, "create.progress").exists)
        let close = el(app, "page-close"), title = app.staticTexts["وين رايحين؟"]
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThanOrEqual(close.frame.width, 43.5); XCTAssertGreaterThanOrEqual(close.frame.height, 43.5)
        if title.exists { XCTAssertLessThan(close.frame.midX, title.frame.midX, "✕ left, title right") }
        shot("create-destination")
    }

    func testQuickCreateKeepsItsControls() {
        let app = launch("create-quick")
        XCTAssertTrue(el(app, "start.withFriends").waitForExistence(timeout: 20) || el(app, "create.approve").waitForExistence(timeout: 5))
        for id in ["start.destination", "start.solo", "start.changePlace", "start.statement"] {
            XCTAssertTrue(el(app, id).exists, id)
        }
        XCTAssertTrue(el(app, "page-close").exists)
        shot("create-quick")
    }

    func testHistoryListRowsAreUniformAndEmptyStateExists() {
        let app = launch("history")
        let back = el(app, "page-back")
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["الطلعات السابقة"].exists)
        let rows = app.descendants(matching: .any).matching(identifier: "outing-row")
        if rows.count > 0 {
            XCTAssertGreaterThanOrEqual(rows.firstMatch.frame.height, 55, "rows have one fixed minimum height")
        } else {
            XCTAssertTrue(app.staticTexts["ما فيه طلعات منتهية"].exists)
        }
        shot("history")
    }

    func testDetailsHasOnePinnedPrimary() {
        let app = launch("details")
        assertPrimary(app, "details.open")
        XCTAssertTrue(el(app, "page-back").exists)
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(el(app, "details.leave").waitForExistence(timeout: 5), "«غادر الطلعة» is still reachable at the end of the page")
        shot("details")
    }

    func testSummaryHasOnePinnedPrimary() {
        let app = launch("summary")
        assertPrimary(app, "summary.story")
        XCTAssertTrue(el(app, "summary.stats").waitForExistence(timeout: 10))
        for _ in 0..<6 where !el(app, "summary.shareText").isHittable { app.swipeUp() }
        XCTAssertTrue(el(app, "summary.shareText").exists, "the text share is kept")
        if el(app, "summary.shareMine").exists {
            XCTAssertLessThan(el(app, "summary.shareMine").frame.height, 57.5, "«شارك ملخصي» is a secondary now")
        }
        shot("summary")
    }

    func testDetailsAndSummaryAreUnchangedWithTheFlagOff() {
        let app = launch("summary", newUI: false)
        XCTAssertTrue(el(app, "summary.story").waitForExistence(timeout: 15), "legacy: the story button sits in the page")
        XCTAssertTrue(el(app, "page-back").exists)
    }
}
