import XCTest
@testable import SaryAlbarq

/// The owner's rule, locked: no position leaves the phone before location
/// consent AND «شارك موقعي» AND sharing on for that member in an active outing.
/// Off screen (owner decision 2026-11) only with «دائمًا»; never with «أثناء الاستخدام».
final class SendGateTests: XCTestCase {
    private let open = SendGate(consent: true, osAuthorized: true, userWantsShare: true, serverSharing: true, outingActive: true, foreground: true, closed: false)

    func testOpenOnlyWhenEverythingHolds() {
        XCTAssertTrue(open.allowsPosition)
        XCTAssertFalse(open.allowsBackgroundPosition, "on screen: the socket path, not the background sender")
        let flips: [(String, (inout SendGate) -> Void)] = [
            ("no consent", { $0.consent = false }),
            ("no iOS permission", { $0.osAuthorized = false }),
            ("did not press share", { $0.userWantsShare = false }),
            ("server says sharing off", { $0.serverSharing = false }),
            ("outing not active", { $0.outingActive = false }),
            ("app in background with «أثناء الاستخدام» only", { $0.foreground = false; $0.alwaysAuthorized = false }),
            ("session closed", { $0.closed = true }),
        ]
        for (why, f) in flips {
            var g = open
            f(&g)
            XCTAssertFalse(g.allowsPosition, why)
            XCTAssertFalse(g.allowsBackgroundPosition, why)
            XCTAssertFalse(g.allowsSosFix, "SOS carries no position either: \(why)")
        }
    }

    func testBackgroundAllowedOnlyWithAlwaysConsentSharingAndActiveOuting() {
        var bg = open
        bg.foreground = false
        bg.alwaysAuthorized = true
        XCTAssertTrue(bg.allowsPosition)
        XCTAssertTrue(bg.allowsBackgroundPosition)
        let flips: [(String, (inout SendGate) -> Void)] = [
            ("no «دائمًا»", { $0.alwaysAuthorized = false }),
            ("no consent", { $0.consent = false }),
            ("no iOS permission", { $0.osAuthorized = false }),
            ("stopped sharing", { $0.userWantsShare = false }),
            ("server sharing off", { $0.serverSharing = false }),
            ("outing paused / ended", { $0.outingActive = false }),
            ("left / removed / signed out", { $0.closed = true }),
        ]
        for (why, f) in flips {
            var g = bg
            f(&g)
            XCTAssertFalse(g.allowsBackgroundPosition, why)
            XCTAssertFalse(g.allowsPosition, why)
        }
    }

    func testServerDefaultSharingIsNotConsent() {
        /* The server turns `sharing` on at join; that alone must send nothing, on screen or off. */
        XCTAssertFalse(SendGate(serverSharing: true, outingActive: true, foreground: true).allowsPosition)
        XCTAssertFalse(SendGate(serverSharing: true, outingActive: true, foreground: false, alwaysAuthorized: true).allowsPosition)
    }
}

final class ShareMemoryTests: XCTestCase {
    private var d: UserDefaults!
    override func setUp() {
        d = UserDefaults(suiteName: "share-memory-\(UUID().uuidString)")
    }

    func testConsentIsPerIdentity() {
        ShareMemory.recordConsent(user: "A", outing: "o1", defaults: d)
        XCTAssertTrue(ShareMemory.hasConsent(user: "A", outing: "o1", defaults: d))
        XCTAssertFalse(ShareMemory.hasConsent(user: "B", outing: "o1", defaults: d), "a new identity on the same phone starts with no consent")
        XCTAssertFalse(ShareMemory.hasConsent(user: "A", outing: "o2", defaults: d))
    }

    func testActiveShareIsPerIdentity() {
        ShareMemory.setActiveShare(user: "A", outing: "o1", defaults: d)
        XCTAssertEqual(ShareMemory.activeShare(user: "A", defaults: d), "o1")
        XCTAssertNil(ShareMemory.activeShare(user: "B", defaults: d))
        ShareMemory.setActiveShare(user: "B", outing: nil, defaults: d)
        XCTAssertEqual(ShareMemory.activeShare(user: "A", defaults: d), "o1", "B cannot clear A's record either")
    }

    func testLegacyUnscopedKeysAreNeverHonoured() {
        d.set(["o1"], forKey: "sary.outings.consent.v1")
        d.set("o1", forKey: "sary.outings.activeShare.v1")
        XCTAssertFalse(ShareMemory.hasConsent(user: "A", outing: "o1", defaults: d))
        XCTAssertNil(ShareMemory.activeShare(user: "A", defaults: d))
        ShareMemory.dropLegacy(defaults: d)
        XCTAssertNil(d.object(forKey: "sary.outings.consent.v1"))
    }
}

/// The whole session with a fake socket: the server says `sharing: true`
/// (its default after join) and fixes arrive — nothing may be sent.
@MainActor
final class SessionPrivacyTests: XCTestCase {
    private var sockets: [FakeSocket] = []
    private var defaults: UserDefaults!
    private var foreground = true
    private var location: LocationSharer!

    override func setUp() async throws {
        sockets = []
        foreground = true
        defaults = UserDefaults(suiteName: "session-privacy-\(UUID().uuidString)")
        location = LocationSharer()
    }

    private func session(user: String = "u1", authorized: Bool = true) -> OutingSession {
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = FakeScheduler()
        env.isForeground = { [unowned self] in self.foreground }
        env.defaults = defaults
        env.timers = false
        env.authorizationOverride = authorized
        /* «أثناء الاستخدام» here, whatever the simulator granted the test host; «دائمًا» is in BackgroundShareTests. */
        env.alwaysOverride = false
        location.testAuthorization = authorized ? .authorizedWhenInUse : .denied
        let s = OutingSession(id: "o1", myUserId: user, api: OutingsAPI(tokenProvider: { "t" }), token: String(repeating: "t", count: 43), location: location, env: env)
        s.open()
        return s
    }

    private func serverReady(_ s: FakeSocket, me: String = "u1") {
        s.serverSays(["type": "ready", "snapshot": [
            "outing": ["id": "o1", "name": "x", "status": "active", "owner_id": "u0"],
            "me": ["user_id": me, "role": "member", "sharing": true],
            "members": [
                ["user_id": me, "display_name": "أنا", "role": "member", "sharing": true, "joined_at": "2026-11-03T10:00:00.000Z"],
            ],
            "positions": [], "server_now": ISODate.string(Date()),
        ]])
    }

    private func freshFix() -> DeviceFix {
        DeviceFix(lat: 24.71, lng: 46.67, accuracy: 6, heading: 10, speed: 8, atMs: Date().timeIntervalSince1970 * 1000 - 200)
    }

    private var positionsSent: Int {
        sockets.flatMap(\.sent).filter { $0["type"] as? String == "position" }.count
    }

    /// Before this phone joined (no «انضم» tapped here): the server's default `sharing=true` sends nothing.
    func testNotJoinedHereSendsNothing() {
        let s = session()
        serverReady(sockets[0])
        XCTAssertEqual(s.view?.snapshot.me.sharing, true, "server default after join")
        s.resumeIfPreviouslySharing()
        for _ in 0..<5 { s.handleFix(freshFix()) }
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
    }

    /// Owner decision (build 6): tapping «انضم» is the consent; sharing starts without «شارك موقعي».
    func testJoiningIsConsentAndSharesByDefault() {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        XCTAssertTrue(s.wantsToShare)
        XCTAssertTrue(s.gate.allowsPosition, "joined + permission + active outing + server sharing: visible at once")
        s.handleFix(freshFix())
        XCTAssertEqual(positionsSent, 1)
    }

    func testJoinedThenStoppedSendsNothing() {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        s.stopSharingLocally()
        s.handleFix(freshFix())
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults), "a relaunch does not resume a stopped share")
    }

    func testJoinedThenOutingEndedSendsNothing() {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        sockets[0].serverSays(["type": "outing_status", "status": "ended"])
        s.handleFix(freshFix())
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
    }

    func testJoinedThenLeftOrRemovedSendsNothing() {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        sockets[0].serverSays(["type": "member_left", "user_id": "u1"])
        s.handleFix(freshFix())
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
    }

    func testDeletingTheAccountForgetsJoinConsent() {
        ShareMemory.consentByJoining(user: "u1", outing: "o1", defaults: defaults)
        LocalAccountData.wipe(defaults: defaults)
        XCTAssertFalse(ShareMemory.hasConsent(user: "u1", outing: "o1", defaults: defaults))
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults))
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        s.handleFix(freshFix())
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
    }

    func testAnotherIdentitysConsentAndShareAreNotInherited() {
        ShareMemory.recordConsent(user: "someoneElse", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "someoneElse", outing: "o1", defaults: defaults)
        let s = session(user: "u1")
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        XCTAssertFalse(s.wantsToShare)
        s.handleFix(freshFix())
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
    }

    func testWithWhenInUseOnlyAnEarlierShareResumesOnlyInForeground() {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        foreground = false
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        XCTAssertTrue(s.wantsToShare, "the intent survives a relaunch")
        XCTAssertFalse(s.gate.allowsPosition, "«أثناء الاستخدام»: nothing goes out while the app is in the background")
        s.handleFix(freshFix())
        XCTAssertEqual(positionsSent, 0)
        foreground = true
        s.foreground(true)
        XCTAssertTrue(s.gate.allowsPosition, "back on screen with consent + share + server sharing: the gate opens")
        s.foreground(false)
        XCTAssertFalse(s.gate.allowsPosition)
    }

    func testNoLocationPermissionNoSend() {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        let s = session(authorized: false)
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        s.handleFix(freshFix())
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertEqual(positionsSent, 0)
    }

    func testServerSaysSharingOffClosesTheGate() {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        XCTAssertTrue(s.gate.allowsPosition)
        sockets[0].serverSays(["type": "member_sharing", "user_id": "u1", "sharing": false])
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertFalse(s.wantsToShare, "switched off elsewhere: the intent ends too")
    }
}

/// «ملخص رحلتي»: totals only, built on the device from my own fixes.
final class TripLogTests: XCTestCase {
    func testAccumulatesDistanceAndMovingTimeIgnoringJitterAndJumps() {
        var log = TripLog()
        let t0 = 1_000_000.0
        log.add(lat: 24.7, lng: 46.6, accuracy: 5, speed: 0, atMs: t0)
        XCTAssertNil(log.totals, "one fix is not a trip")
        /* ~111 m north in 10 s, driving. */
        log.add(lat: 24.701, lng: 46.6, accuracy: 5, speed: 11, atMs: t0 + 10_000)
        /* parked jitter: 3 m, not distance, not moving. */
        log.add(lat: 24.70103, lng: 46.6, accuracy: 5, speed: 0, atMs: t0 + 20_000)
        /* a 5 km jump in 2 s: a GPS glitch. */
        log.add(lat: 24.75, lng: 46.6, accuracy: 5, speed: nil, atMs: t0 + 22_000)
        /* a bad fix is ignored. */
        log.add(lat: 24.9, lng: 46.6, accuracy: 300, speed: nil, atMs: t0 + 23_000)
        let t = log.totals!
        XCTAssertEqual(Double(t.distanceM), 111, accuracy: 3)
        XCTAssertEqual(t.durationS, 22)
        XCTAssertEqual(t.movingS, 10)
    }

    func testStoreIsPerOutingAndForgettable() {
        let d = UserDefaults(suiteName: "trip-test-\(UUID().uuidString)")!
        TripLogStore.update("a", defaults: d) { $0.add(lat: 1, lng: 1, accuracy: 5, speed: 0, atMs: 1) }
        XCTAssertNotNil(TripLogStore.load("a", defaults: d))
        XCTAssertNil(TripLogStore.load("b", defaults: d))
        TripLogStore.forgetAll(defaults: d)
        XCTAssertNil(TripLogStore.load("a", defaults: d))
    }
}
