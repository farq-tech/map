import CoreLocation
import XCTest
@testable import SaryAlbarq

/// The one-step invitee join (owner decision, build 14): the state machine, its words, and the
/// forced share once joined (no toggle; paused keeps the intent; leaving is the way out).
final class JoinMachineTests: XCTestCase {
    private func run(_ events: [JoinEvent], from s: JoinStep = .ready) -> JoinStep {
        events.reduce(s) { JoinMachine.next($0, $1) }
    }

    func testPermissionFromIOS() {
        XCTAssertEqual(JoinPermission.from(.notDetermined, .fullAccuracy), .notAsked)
        XCTAssertEqual(JoinPermission.from(.authorizedWhenInUse, .fullAccuracy), .granted)
        XCTAssertEqual(JoinPermission.from(.authorizedAlways, .fullAccuracy), .granted)
        XCTAssertEqual(JoinPermission.from(.authorizedWhenInUse, .reducedAccuracy), .reduced, "precise off is not enough")
        XCTAssertEqual(JoinPermission.from(.denied, .fullAccuracy), .denied)
        XCTAssertEqual(JoinPermission.from(.restricted, .fullAccuracy), .denied)
    }

    func testNewInviteeOneTapToTheTrip() {
        /* No identity: made silently, then the location prompt, then the join. */
        var s = JoinMachine.next(.ready, .tapJoin(hasIdentity: false))
        XCTAssertEqual(s, .preparing)
        XCTAssertTrue(s.busy)
        s = JoinMachine.next(s, .identityReady)
        XCTAssertEqual(s, .askingLocation, "the location prompt comes right after, no other screen")
        s = JoinMachine.next(s, .permission(.granted))
        XCTAssertEqual(s, .joining(viewOnly: false))
        XCTAssertEqual(JoinMachine.next(s, .joined), .entered)
    }

    func testExistingIdentitySkipsStraightToTheLocationPrompt() {
        XCTAssertEqual(run([.tapJoin(hasIdentity: true)]), .askingLocation)
        XCTAssertEqual(run([.tapJoin(hasIdentity: true), .permission(.granted), .joined]), .entered)
    }

    func testRefusedDoesNotJoinAndWaitsCalmly() {
        let s = run([.tapJoin(hasIdentity: true), .permission(.denied)])
        XCTAssertEqual(s, .needsLocation(.denied), "never POST /invites/join without the location")
        XCTAssertFalse(s.busy)
        XCTAssertEqual(JoinMachine.next(s, .sceneActive(.denied)), .needsLocation(.denied), "still refused: same screen")
        XCTAssertEqual(JoinMachine.next(s, .joined), s, "a stray join result is ignored")
    }

    func testPreciseOffAsksForPreciseThenJoins() {
        let asking = run([.tapJoin(hasIdentity: true), .permission(.reduced)])
        XCTAssertEqual(asking, .askingPrecise, "approximate: iOS's temporary «الموقع الدقيق» prompt next, not a dead end")
        XCTAssertTrue(asking.busy)
        XCTAssertEqual(JoinMachine.next(asking, .precise(.granted)), .joining(viewOnly: false))
        XCTAssertEqual(JoinMachine.next(asking, .sceneActive(.reduced)), .askingPrecise, "the prompt's own inactive → active is not an answer")
        XCTAssertEqual(JoinMachine.next(asking, .sceneActive(.granted)), .joining(viewOnly: false))
        XCTAssertEqual(JoinMachine.next(asking, .precise(.notAsked)), .askingPrecise)
    }

    func testStillApproximateGoesToRecoveryWithAWayIn() {
        let s = run([.tapJoin(hasIdentity: true), .permission(.reduced), .precise(.reduced)])
        XCTAssertEqual(s, .needsLocation(.reduced))
        XCTAssertEqual(JoinMachine.next(s, .enterWithoutLocation), .joining(viewOnly: true))
        XCTAssertEqual(JoinMachine.next(s, .sceneActive(.granted)), .joining(viewOnly: false), "precise turned on in Settings: in, sharing")
    }

    func testDeniedRecoveryOpensTheTripInViewMode() {
        let s = run([.tapJoin(hasIdentity: false), .identityReady, .permission(.denied)])
        XCTAssertEqual(s, .needsLocation(.denied))
        let v = JoinMachine.next(s, .enterWithoutLocation)
        XCTAssertEqual(v, .joining(viewOnly: true), "no dead end: the trip opens without my location")
        XCTAssertEqual(JoinMachine.next(v, .joined), .entered)
        XCTAssertEqual(run([.enterWithoutLocation]), .ready, "only from the recovery screen")
    }

    func testGrantedInSettingsJoinsByItself() {
        let waiting = run([.tapJoin(hasIdentity: true), .permission(.denied)])
        XCTAssertEqual(JoinMachine.next(waiting, .sceneActive(.granted)), .joining(viewOnly: false), "back from Settings with permission: join at once")
        XCTAssertEqual(JoinMachine.next(waiting, .permission(.granted)), .joining(viewOnly: false), "the delegate's answer works too")
        XCTAssertEqual(run([.sceneActive(.reduced)], from: waiting), .needsLocation(.reduced), "allowed but imprecise: still waiting")
        XCTAssertEqual(run([.sceneActive(.reduced), .sceneActive(.granted), .joined], from: waiting), .entered)
    }

    func testCancelKeepsNothing() {
        XCTAssertEqual(run([.cancel]), .cancelled)
        XCTAssertEqual(run([.tapJoin(hasIdentity: true), .permission(.denied), .cancel]), .cancelled)
        XCTAssertEqual(run([.tapJoin(hasIdentity: true), .permission(.reduced), .cancel]), .cancelled)
        XCTAssertEqual(run([.tapJoin(hasIdentity: true), .permission(.granted), .cancel]), .joining(viewOnly: false), "the join in flight is not cancelled half-way")
    }

    func testUnansweredPromptKeepsWaiting() {
        /* The prompt makes the app inactive → active before iOS's answer lands. */
        XCTAssertEqual(run([.tapJoin(hasIdentity: true), .sceneActive(.notAsked)]), .askingLocation)
        XCTAssertEqual(run([.tapJoin(hasIdentity: true), .permission(.notAsked)]), .askingLocation)
    }

    func testFailuresComeBackToTheOneScreenAndRetry() {
        let f = run([.tapJoin(hasIdentity: false), .identityFailed("الشبكة")])
        XCTAssertEqual(f, .failed("الشبكة"))
        XCTAssertEqual(JoinMachine.next(f, .tapJoin(hasIdentity: false)), .preparing)
        let j = run([.tapJoin(hasIdentity: true), .permission(.granted), .joinFailed("انتهت")])
        XCTAssertEqual(j, .failed("انتهت"))
        XCTAssertEqual(JoinMachine.next(j, .tapJoin(hasIdentity: true)), .askingLocation)
    }

    func testDuplicateTapsDoNothingWhileBusy() {
        for s in [JoinStep.preparing, .askingLocation, .askingPrecise, .joining(viewOnly: false), .joining(viewOnly: true)] {
            XCTAssertEqual(JoinMachine.next(s, .tapJoin(hasIdentity: true)), s)
        }
    }

    func testTheHonestWords() {
        XCTAssertEqual(JoinCopy.statement, "بانضمامك يشوف أعضاء الطلعة موقعك المباشر لين تنتهي الطلعة أو تغادرها")
        XCTAssertEqual(ShareMemory.joinStatement, JoinCopy.statement, "same line on the creator's last step and «انضم برابط»")
        XCTAssertEqual(JoinCopy.button, "انضم للطلعة")
        XCTAssertEqual(JoinCopy.prePromptTitle, "عشان العيال يشوفونك وتوصلك الفزعة", "the Najdi pre-prompt, before the system alert")
        XCTAssertTrue(JoinCopy.prePromptDetail.contains("السماح أثناء استخدام التطبيق"))
        XCTAssertNotEqual(JoinCopy.needsTitle(.denied), JoinCopy.needsTitle(.reduced))
        XCTAssertTrue(JoinCopy.needsMessage(.reduced).contains("الموقع الدقيق"))
        XCTAssertEqual(JoinCopy.hiddenTitle, "موقعك مو ظاهر للعيال")
        XCTAssertEqual(JoinCopy.enterWithout, "ادخل الطلعة بدون موقعي")
        for t in [JoinCopy.statement, JoinCopy.prePromptDetail, JoinCopy.needsMessage(.denied), JoinCopy.needsMessage(.reduced), JoinCopy.enterWithoutNote] {
            XCTAssertFalse(t.contains("أوقف"), "no stop switch is promised: \(t)")
            XCTAssertFalse(t.contains("شارك موقعي"), t)
        }
    }
}

/// Once joined: sharing is on by itself and stays on while a member — paused keeps the intent,
/// a member whose server flag an older build switched off is switched back on, and «دائمًا»
/// is offered only after the app was off screen while sharing with «أثناء الاستخدام».
@MainActor
final class ForcedShareSessionTests: XCTestCase {
    private var sockets: [FakeSocket] = []
    private var defaults: UserDefaults!
    private var foreground = true
    private var location: LocationSharer!

    override func setUp() async throws {
        sockets = []
        foreground = true
        defaults = UserDefaults(suiteName: "forced-share-\(UUID().uuidString)")
        location = LocationSharer()
        location.ignoresSystemFixes = true
        StubAPIProtocol.requests = []
        StubAPIProtocol.snapshot = BackgroundSessionTests.snapshotJSON()
    }

    private func session(always: Bool = false) -> OutingSession {
        location.testAuthorization = always ? .authorizedAlways : .authorizedWhenInUse
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = FakeScheduler()
        env.isForeground = { [unowned self] in self.foreground }
        env.defaults = defaults
        env.timers = false
        env.authorizationOverride = true
        env.alwaysOverride = always
        env.trailDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("forced-\(UUID().uuidString)")
        env.keepAlive = { {} }
        env.postPosition = { _, _ in }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubAPIProtocol.self]
        let api = OutingsAPI(base: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg), tokenProvider: { "t" })
        let s = OutingSession(id: "o1", myUserId: "u1", api: api, token: String(repeating: "t", count: 43), location: location, env: env)
        s.open()
        return s
    }

    private func ready(_ sharing: Bool = true, status: String = "active") {
        sockets.last!.serverSays(["type": "ready", "snapshot": BackgroundSessionTests.snapshotJSON(status: status, sharing: sharing)])
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    private func joined() -> OutingSession {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        s.resumeIfPreviouslySharing()
        return s
    }

    func testJoiningSharesWithoutAnyPress() {
        let s = joined()
        ready()
        XCTAssertTrue(s.wantsToShare)
        XCTAssertTrue(s.isSharingNow, "in the live trip, sharing on — no «شارك موقعي»")
    }

    func testPauseKeepsTheIntentAndResumeSharesAgainByItself() {
        let s = joined()
        ready()
        sockets.last!.serverSays(["type": "outing_status", "status": "paused"])
        XCTAssertFalse(s.gate.allowsPosition, "nothing is sent while the trip is paused")
        XCTAssertTrue(s.wantsToShare, "the intent stays: there is no switch to press again")
        XCTAssertEqual(ShareMemory.activeShare(user: "u1", defaults: defaults), "o1")
        sockets.last!.serverSays(["type": "outing_status", "status": "active"])
        XCTAssertTrue(s.isSharingNow, "resumed: sharing again at once")
    }

    func testEndedOrLeftStopsForGood() async {
        let s = joined()
        ready()
        sockets.last!.serverSays(["type": "outing_status", "status": "ended"])
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertFalse(s.wantsToShare)
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults), "an ended trip never resumes")

        StubAPIProtocol.snapshot = BackgroundSessionTests.snapshotJSON()
        let t = joined()
        ready()
        _ = await t.leave()
        XCTAssertFalse(t.gate.allowsPosition, "«غادر الطلعة» is the way to stop")
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults))
    }

    func testAnOlderBuildsStopIsSwitchedBackOnWhenTheTripOpens() async {
        let s = joined()
        ready(false)
        await settle()
        XCTAssertTrue(StubAPIProtocol.requests.contains { $0.method == "PATCH" && $0.path == "/api/outings/o1/me" && $0.body["sharing"] as? Bool == true },
                      "sharing is forced on: the server flag is set again")
        XCTAssertEqual(s.view?.snapshot.me.sharing, true)
        XCTAssertTrue(s.isSharingNow)
    }

    func testALaterOffFromTheServerIsStillRespected() {
        let s = joined()
        ready()
        XCTAssertTrue(s.isSharingNow)
        sockets.last!.serverSays(["type": "member_sharing", "user_id": "u1", "sharing": false])
        XCTAssertFalse(s.gate.allowsPosition, "the server's word closes the gate (never-show-stale rules unchanged)")
    }

    func testBackToTheListKeepsTheShareArmed() {
        let s = joined()
        ready()
        s.keepShareOnClose = true
        s.close()
        XCTAssertFalse(s.gate.allowsPosition, "nothing is sent from the list")
        XCTAssertEqual(ShareMemory.activeShare(user: "u1", defaults: defaults), "o1", "opening the trip again picks it up")
        XCTAssertTrue(ShareMemory.hasConsent(user: "u1", outing: "o1", defaults: defaults))
    }

    func testAlwaysIsOfferedOnlyAfterTheScreenWasLeftWhileSharing() {
        let s = joined()
        ready()
        XCTAssertFalse(s.askAlwaysOnReturn, "never at join")
        foreground = false
        s.foreground(false)
        XCTAssertTrue(s.askAlwaysOnReturn, "«أثناء الاستخدام» only: sending paused off screen — offer «دائمًا» on return")
        foreground = true
        s.foreground(true)
        XCTAssertTrue(s.isSharingNow, "back on screen: sharing again without a press")
    }

    func testWithAlwaysNothingIsOffered() {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        let s = session(always: true)
        s.resumeIfPreviouslySharing()
        ready()
        foreground = false
        s.foreground(false)
        XCTAssertFalse(s.askAlwaysOnReturn)
    }
}
