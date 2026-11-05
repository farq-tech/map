import XCTest
@testable import SaryAlbarq

/// «مقدمة سينمائية»: when the launch plays the intro (IntroPolicy).
final class IntroPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func facts(_ edit: (inout IntroFacts) -> Void = { _ in }) -> IntroFacts {
        var f = IntroFacts(now: now)
        edit(&f)
        return f
    }

    func testFirstColdLaunchPlaysTheIntro() {
        XCTAssertNil(IntroPolicy.skipReason(facts()))
        XCTAssertEqual(IntroPolicy.mode(facts()), .full)
    }

    func testAtMostOnceEverySixHours() {
        XCTAssertEqual(IntroPolicy.skipReason(facts { $0.lastShown = now.addingTimeInterval(-60) }), .recentlyShown)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.lastShown = now.addingTimeInterval(-5.9 * 3600) }), .still)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.lastShown = now.addingTimeInterval(-6 * 3600) }), .full)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.lastShown = now.addingTimeInterval(-3 * 86400) }), .full)
    }

    func testClockSetBackwardsDoesNotBlockForever() {
        XCTAssertEqual(IntroPolicy.mode(facts { $0.lastShown = now.addingTimeInterval(86400) }), .full)
    }

    func testSettingOffShowsOnlyTheStillFrame() {
        XCTAssertEqual(IntroPolicy.skipReason(facts { $0.enabled = false }), .turnedOff)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.enabled = false }), .still)
    }

    func testBackgroundLaunchesNeverShowAnything() {
        // PushToTalk wake-up, location relaunch, background push: no UI at all.
        XCTAssertEqual(IntroPolicy.skipReason(facts { $0.foregroundLaunch = false }), .notForeground)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.foregroundLaunch = false }), .none)
    }

    func testLaunchesForSomethingGoStraightToTheApp() {
        // Deep / invite link, tapped notification, Live Activity, PushToTalk.
        XCTAssertEqual(IntroPolicy.skipReason(facts { $0.openedForSomething = true }), .openedForSomething)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.openedForSomething = true }), .none)
    }

    func testActiveTripAndCarPlayGoStraightToTheLiveScreen() {
        XCTAssertEqual(IntroPolicy.mode(facts { $0.activeTrip = true }), .none)
        XCTAssertEqual(IntroPolicy.skipReason(facts { $0.activeTrip = true }), .activeTrip)
        XCTAssertEqual(IntroPolicy.mode(facts { $0.carPlay = true }), .none)
        XCTAssertEqual(IntroPolicy.skipReason(facts { $0.carPlay = true }), .carPlay)
    }

    func testTripWinsOverEverythingElse() {
        // Even a first launch with the intro on: a trip in progress means no show.
        let f = facts { $0.activeTrip = true; $0.lastShown = nil; $0.enabled = true }
        XCTAssertEqual(IntroPolicy.mode(f), .none)
    }

    func testSoundFollowsItsSettingAndOnlyWithTheFullIntro() {
        XCTAssertTrue(IntroPolicy.playsSound(mode: .full, soundOn: true))
        XCTAssertFalse(IntroPolicy.playsSound(mode: .full, soundOn: false))
        XCTAssertFalse(IntroPolicy.playsSound(mode: .still, soundOn: true))
        XCTAssertFalse(IntroPolicy.playsSound(mode: .none, soundOn: true))
    }

    func testSettingsDefaultOnAndRemembered() {
        let d = UserDefaults(suiteName: "intro-tests")!
        d.removePersistentDomain(forName: "intro-tests")
        XCTAssertTrue(IntroPolicy.enabled(d))
        XCTAssertTrue(IntroPolicy.soundOn(d))
        XCTAssertNil(IntroPolicy.lastShown(d))
        d.set(false, forKey: IntroPolicy.enabledKey)
        d.set(false, forKey: IntroPolicy.soundKey)
        IntroPolicy.markShown(now, d)
        XCTAssertFalse(IntroPolicy.enabled(d))
        XCTAssertFalse(IntroPolicy.soundOn(d))
        XCTAssertEqual(IntroPolicy.lastShown(d), now)
        d.removePersistentDomain(forName: "intro-tests")
    }

    func testAutomationRunsDoNotSeeTheIntroUnlessAsked() {
        XCTAssertFalse(IntroPolicy.isAutomation([]))
        XCTAssertTrue(IntroPolicy.isAutomation(["-resetState", "-demo"]))
        XCTAssertTrue(IntroPolicy.isAutomation(["-SaryScreen", "summary"]))
        XCTAssertFalse(IntroPolicy.isAutomation(["-resetState", "-SaryIntro", "1"]))
        XCTAssertTrue(IntroPolicy.isAutomation(["-SaryIntro", "0"]))
        XCTAssertTrue(IntroPolicy.isAutomation([], environment: ["XCTestConfigurationFilePath": "/x"]))
    }

    func testFirstFrameIsTheLaunchFrame() {
        // The launch image is IntroScene at t = 0: nothing animated is visible yet.
        let logo = IntroScene.logoState(0, reduceMotion: false)
        XCTAssertEqual(logo.opacity, 0)
        XCTAssertEqual(IntroScene.drift(0), 0)
        XCTAssertTrue(IntroScene.stars.allSatisfy { IntroScene.T.starsIn + $0.delay > 0 })
        // …and the logo comes to rest and lights by the reveal, then the intro ends in ≈4 s.
        let rest = IntroScene.logoState(IntroScene.T.reveal + 0.1, reduceMotion: false)
        XCTAssertEqual(rest.center.y, IntroScene.logoRest.y, accuracy: 0.5)
        XCTAssertGreaterThan(rest.light, 0.99)
        XCTAssertLessThanOrEqual(IntroScene.T.total, 4.5)
    }

    func testScoreIsBundledAndSmall() throws {
        let url = try XCTUnwrap(IntroAudio.url)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(size, 300_000)
    }
}
