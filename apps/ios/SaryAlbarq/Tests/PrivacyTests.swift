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
        /* Without the iOS 17 background activity session (with it, sharing keeps going off screen:
         * BackgroundShareTests.testWhenInUseWithActivitySessionKeepsSendingOffScreen). */
        env.backgroundSessionOverride = false
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

    /// The per-fix fast path writes the same `[String: TripLog]` JSON the old full encode did.
    func testStoreFastPathMatchesAFullDecode() throws {
        let d = UserDefaults(suiteName: "trip-test-\(UUID().uuidString)")!
        var expected: [String: TripLog] = [:]
        for i in 0..<40 {
            let id = ["a", "b", "c\"q"][i % 3]
            let fix = { (l: inout TripLog) in l.add(lat: 24.7 + Double(i) * 0.0005, lng: 46.6, accuracy: 5, speed: 10, atMs: Double(i) * 1000) }
            TripLogStore.update(id, defaults: d, fix)
            var e = expected[id] ?? TripLog()
            fix(&e)
            expected[id] = e
        }
        let raw = try XCTUnwrap(d.data(forKey: TripLogStore.key))
        XCTAssertEqual(try JSONDecoder().decode([String: TripLog].self, from: raw), expected)
        for (id, log) in expected { XCTAssertEqual(TripLogStore.load(id, defaults: d), log) }
    }

    /// Another writer of the key (the settings clean-up, a wipe) is seen at once: nothing stale comes back.
    func testStoreSeesOtherWritersOfTheKey() throws {
        let d = UserDefaults(suiteName: "trip-test-\(UUID().uuidString)")!
        TripLogStore.update("old", defaults: d) { _ in }
        TripLogStore.update("now", defaults: d) { _ in }
        var all = try JSONDecoder().decode([String: TripLog].self, from: XCTUnwrap(d.data(forKey: TripLogStore.key)))
        all["old"] = nil
        d.set(try JSONEncoder().encode(all), forKey: TripLogStore.key)
        XCTAssertNil(TripLogStore.load("old", defaults: d))
        TripLogStore.update("now", defaults: d) { $0.add(lat: 24.7, lng: 46.6, accuracy: 5, speed: 0, atMs: 5) }
        XCTAssertNil(TripLogStore.load("old", defaults: d), "a write never brings back what another writer removed")
        d.removeObject(forKey: TripLogStore.key)
        XCTAssertNil(TripLogStore.load("now", defaults: d))
        d.set(Data("not json".utf8), forKey: TripLogStore.key)
        TripLogStore.update("x", defaults: d) { _ in }
        XCTAssertNotNil(TripLogStore.load("x", defaults: d), "a broken value is replaced, as before")
    }
}

/// `OutingSession.Kind` (docs/SOLO-OUTING.md (ب)): "no server" (`isLocal`) and "demo data"
/// (`isDemo`) are separate questions. A solo session is local without being the demo.
@MainActor
final class OutingSessionKindTests: XCTestCase {
    func testKindMapping() {
        XCTAssertFalse(OutingSession.Kind.server.isLocal, "a real outing talks to the server")
        XCTAssertFalse(OutingSession.Kind.server.isDemo)
        XCTAssertTrue(OutingSession.Kind.demo.isLocal, "the demo never talks to the server")
        XCTAssertTrue(OutingSession.Kind.demo.isDemo)
        XCTAssertTrue(OutingSession.Kind.solo.isLocal, "solo never talks to the server")
        XCTAssertFalse(OutingSession.Kind.solo.isDemo, "solo has no demo data or demo behaviour")
    }

    private func env() -> SessionEnv {
        var e = SessionEnv()
        e.defaults = UserDefaults(suiteName: "session-kind-\(UUID().uuidString)")!
        e.timers = false
        e.nearbyMesh = false
        e.trailMatching = nil
        e.trailDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("kind-\(UUID().uuidString)")
        return e
    }

    func testSessionWithoutDemoViewIsServer() {
        let s = OutingSession(id: "o1", myUserId: "u1", api: OutingsAPI(tokenProvider: { "t" }), token: String(repeating: "t", count: 43),
                              location: LocationSharer(), env: env())
        XCTAssertEqual(s.kind, .server)
        XCTAssertFalse(s.isLocal)
        XCTAssertFalse(s.isDemo)
        XCTAssertNotNil(s.safetyBackend, "a real outing keeps the server's safety pack")
    }

    func testSessionWithDemoViewIsDemoAndLocal() {
        let s = OutingSession(id: DemoData.outingId, myUserId: DemoData.meId, api: OutingsAPI(tokenProvider: { nil }), token: "",
                              location: LocationSharer(), demo: DemoData.view(), env: env())
        XCTAssertEqual(s.kind, .demo)
        XCTAssertTrue(s.isLocal)
        XCTAssertTrue(s.isDemo)
        XCTAssertNil(s.safetyBackend, "the demo's safety pack is all local")
    }
}

/// «اتجه» on my own (docs/SOLO-OUTING.md, step 2): a one-member local session that never
/// reaches the server, and an `OutingsAPI` that refuses `solo-` ids before the network.
@MainActor
final class SoloOutingTests: XCTestCase {
    private var sockets: [FakeSocket] = []
    private let me = PublicUser(id: "u1", display_name: "أنا")

    override func setUp() async throws {
        sockets = []
        StubAPIProtocol.requests = []
        StubAPIProtocol.failing = []
    }

    private func env() -> SessionEnv {
        var e = SessionEnv()
        e.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        e.scheduler = FakeScheduler()
        e.isForeground = { true }
        e.defaults = UserDefaults(suiteName: "solo-\(UUID().uuidString)")!
        e.timers = false
        e.authorizationOverride = true
        e.alwaysOverride = false
        e.backgroundSessionOverride = false
        e.trailMatching = nil
        e.keepAlive = { {} }
        e.trailDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("solo-\(UUID().uuidString)")
        return e
    }

    private func solo() -> OutingSession {
        let location = LocationSharer()
        location.testAuthorization = .authorizedWhenInUse
        return OutingSession.solo(me: me, name: "مشوار إلى النفود", location: location, env: env())
    }

    func testSoloIsLocalAndNotTheDemo() {
        let s = solo()
        XCTAssertEqual(s.kind, .solo)
        XCTAssertTrue(s.isLocal, "no server behind a solo outing")
        XCTAssertFalse(s.isDemo, "no demo data or demo behaviour in a solo outing")
        XCTAssertTrue(s.id.hasPrefix("solo-"))
        XCTAssertNotNil(UUID(uuidString: String(s.id.dropFirst("solo-".count))), "solo- then a UUID")
        XCTAssertNotEqual(SoloOuting.newId(), SoloOuting.newId())
        XCTAssertNil(s.safetyBackend, "the safety pack has no server either")
        XCTAssertEqual(s.link, .live, "no false «ما فيه نت» from a link that does not exist")
    }

    func testSoloHasOneMemberAndItIsMe() throws {
        let s = solo()
        let v = try XCTUnwrap(s.view, "a local session starts with its own picture")
        XCTAssertEqual(v.members.count, 1)
        XCTAssertEqual(v.myId, "u1")
        XCTAssertEqual(v.me?.user_id, "u1")
        XCTAssertEqual(v.me?.display_name, "أنا")
        XCTAssertNil(v.me?.phone, "never a phone number in the outing picture")
        XCTAssertTrue(v.iLead)
        XCTAssertEqual(v.status, .active)
        XCTAssertTrue(v.positions.isEmpty)
        XCTAssertEqual(v.snapshot.outing.id, s.id)
        XCTAssertEqual(v.snapshot.outing.name, "مشوار إلى النفود")
        XCTAssertFalse(v.snapshot.me.sharing)
        XCTAssertEqual(v.snapshot.invite?.active, false)
    }

    func testSoloOpensNoLiveChannelAndSendsNothing() async {
        let s = solo()
        s.open()
        XCTAssertTrue(sockets.isEmpty, "no LiveChannel: no socket was ever made")
        XCTAssertFalse(s.gate.allowsPosition, "SendGate stays closed: no consent, no share press, server flag off")
        XCTAssertFalse(s.isSharingNow)
        /* Group actions apply on this phone only; the outing ends locally. */
        let rallied = await s.setRally(lat: 24.7, lng: 46.6, label: nil)
        XCTAssertTrue(rallied)
        XCTAssertEqual(s.view?.snapshot.outing.rally?.lat, 24.7)
        await s.setStatus("end")
        XCTAssertEqual(s.view?.status, .ended)
        XCTAssertEqual(s.closedReason, .outingEnded)
        XCTAssertTrue(sockets.isEmpty, "still no socket after acting in the outing")
        s.close()
    }

    /// Step 3: «مساري» records in a solo outing, to trails-v1/solo-<UUID>.json, with my totals —
    /// all on this device, through no socket and no request.
    func testSoloRecordsItsTrailOnThePhoneOnly() throws {
        let e = env()
        let location = LocationSharer()
        location.testAuthorization = .authorizedWhenInUse
        let s = OutingSession.solo(me: me, name: "مشوار إلى النفود", location: location, env: e)
        s.open()
        XCTAssertTrue(s.trailRecordingAllowed, "the solo outing is active and I am in it")
        let now = Date().timeIntervalSince1970 * 1000
        for i in 0..<6 {
            s.trailFix(DeviceFix(lat: 25.123456 + Double(i) * 0.0003, lng: 47.654321, accuracy: 5, heading: nil, speed: 10, atMs: now - 60_000 + Double(i) * 1000))
        }
        XCTAssertEqual(s.trail.points.count, 6)
        s.saveTrail()
        XCTAssertTrue(TrailStore.fileName(s.id).hasPrefix("solo-"))
        XCTAssertEqual(TrailStore.load(s.id, in: e.trailDirectory)?.points.count, 6, "kept in trails-v1/solo-<UUID>.json")
        XCTAssertNotNil(TripLogStore.load(s.id, defaults: e.defaults), "my totals for the summary, from the trail's fixes")
        XCTAssertFalse(s.gate.allowsPosition, "recording never opens the sharing gate")
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertTrue(StubAPIProtocol.requests.isEmpty)
        s.close()
    }

    /// Step 3: the plan of a solo outing lives on this phone (`LocalPlanBackend`); a server
    /// outing keeps its own backend.
    @MainActor
    func testSoloPlanIsLocal() async throws {
        let defaults = UserDefaults(suiteName: "solo-plan-\(UUID().uuidString)")!
        let demo = DemoPlanBackend(arguments: [])
        let center = PlanCenter(backend: demo, local: LocalPlanBackend(defaults: defaults))
        let id = SoloOuting.newId()
        XCTAssertTrue(center.backend(for: id) is LocalPlanBackend)
        XCTAssertTrue(center.backend(for: "o1") === demo)
        let d = OutingDestination(name: "روضة الثمامة", lat: 24.7590, lng: 46.7491)
        let ok = await center.model(id).setDestination(d)
        XCTAssertTrue(ok)
        XCTAssertEqual(center.model(id).plan.destination, d)
        /* Kept on the phone: a new store (a relaunch) still has it. */
        let again = try await LocalPlanBackend(defaults: defaults).plan(id)
        XCTAssertEqual(again.destination, d)
        XCTAssertTrue(StubAPIProtocol.requests.isEmpty)
    }

    func testAPIRefusesSoloIdsWithoutTheNetwork() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubAPIProtocol.self]
        let api = OutingsAPI(base: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg), tokenProvider: { "t" })
        let id = SoloOuting.newId()
        let calls: [(String, () async throws -> Void)] = [
            ("get", { _ = try await api.get(id) }),
            ("poll", { _ = try await api.poll(id) }),
            ("heartbeat", { try await api.heartbeat(id, gps: .ok) }),
            ("status", { _ = try await api.setStatus(id, action: "end") }),
            ("sharing", { _ = try await api.setSharing(id, sharing: true) }),
            ("note", { _ = try await api.note(id, text: "هلا") }),
            ("sos", { _ = try await api.raiseSos(id, fix: nil) }),
            ("rally", { _ = try await api.setRally(id, lat: 24.7, lng: 46.6, label: nil) }),
            ("leave", { try await api.leave(id) }),
            ("summary", { _ = try await api.shareSummary(id, TripTotals(distanceM: 1000, durationS: 600, movingS: 500)) }),
            ("personal invites", { _ = try await api.personalInvites(id) }),
            ("chat", { _ = try await api.chatOverview(id) }),
            ("clip upload (raw)", { _ = try await api.uploadClip(id, audio: Data([1, 2, 3]), durationMs: 900) }),
            ("voice note upload (raw)", { _ = try await api.uploadVoiceNote(id, audio: Data([1, 2, 3]), durationMs: 900, channel: "1", clientId: "c1", ageMs: 0) }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name): a solo id went through")
            } catch let e as OutingAPIError {
                XCTAssertEqual(e, .localOuting, name)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        api.heartbeatTerminatingNow(id, gps: .ok, wait: 0.5)
        XCTAssertTrue(StubAPIProtocol.requests.isEmpty, "nothing for a solo outing reached the network: \(StubAPIProtocol.requests.map(\.path))")
        XCTAssertEqual(OutingsAPI.localOutingId(inPath: "/\(id)/plan"), id)
        XCTAssertNil(OutingsAPI.localOutingId(inPath: "/o1/plan"))
        XCTAssertNil(OutingsAPI.localOutingId(inPath: "/me"))
        /* Control: a server outing still goes out (the stub is wired). */
        _ = try? await api.heartbeat("o1", gps: .ok)
        XCTAssertEqual(StubAPIProtocol.requests.map(\.path), ["/api/outings/o1/heartbeat"])
    }
}
