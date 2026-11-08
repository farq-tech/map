import XCTest
@testable import SaryAlbarq

/// «احذف حسابي» against a fake API: the order of steps, the 404/405 fallback, and
/// that a failure deletes nothing.
@MainActor
final class AccountDeletionTests: XCTestCase {
    final class FakeAPI: AccountBackend {
        var deleteError: OutingAPIError?
        var calls: [String] = []
        var current: [OutingSummary] = []
        var history: [OutingSummary] = []
        var leaveFails: Set<String> = []

        func deleteAccount() async throws {
            calls.append("DELETE /me")
            if let deleteError { throw deleteError }
        }
        func updateProfile(name: String?, phone: String?, avatar: String?) async throws -> PublicUser {
            calls.append("PATCH /me phone=\(phone ?? "nil") avatar=\(avatar ?? "nil")")
            return PublicUser(id: "me", display_name: "أنا", avatar: nil, phone: nil)
        }
        func list() async throws -> OutingsAPI.ListBox {
            calls.append("GET /")
            return .init(current: current, history: history)
        }
        func withdrawSummary(_ id: String) async throws { calls.append("DELETE /\(id)/summary") }
        func leave(_ id: String) async throws {
            calls.append("POST /\(id)/leave")
            if leaveFails.contains(id) { throw OutingAPIError(code: "not_a_member", status: 404) }
        }
    }

    var api: FakeAPI!
    var steps: [String] = []

    override func setUp() { reset() }

    private func reset() {
        api = FakeAPI()
        steps = []
    }

    private func deleter() -> AccountDeleter {
        AccountDeleter(
            backend: api,
            myUserId: "me",
            forgetPush: { [unowned self] in steps.append("forgetPush") },
            unregisterPushOnServer: { [unowned self] in steps.append("unregisterPushOnServer") },
            wipeLocal: { [unowned self] in steps.append("wipeLocal") }
        )
    }

    private func outing(_ id: String, status: OutingStatus = .active, summaries: [TripShare]? = nil) -> OutingSummary {
        OutingSummary(id: id, name: id, status: status, role: "member", my_status: "active", member_count: 2,
                      created_at: nil, started_at: nil, ended_at: nil, summaries: summaries)
    }

    func testServerDeleteThenPushAndLocalWipe() async {
        let r = await deleter().run()
        XCTAssertEqual(r, .deleted)
        XCTAssertEqual(api.calls, ["DELETE /me"], "one call: the server does the leaving and deleting")
        XCTAssertEqual(steps, ["forgetPush", "wipeLocal"], "no server push call afterwards: the token is dead and the server dropped it")
        XCTAssertNotNil(r.notice)
        XCTAssertTrue(r.notice!.message.contains("الخرائط التي نزّلتها بلا إنترنت باقية"), "says the offline areas stay")
    }

    func testNotDeployedFallsBackToTheOldWipeAndSaysSo() async {
        for status in [404, 405] {
            reset()
            api.deleteError = OutingAPIError(code: "http_\(status)", status: status)
            api.current = [outing("o1"), outing("o2"), outing("gone")]
            api.leaveFails = ["gone"]
            let mine = TripShare(user_id: "me", display_name: "أنا", distance_m: 1, duration_s: 1, moving_s: 1)
            let theirs = TripShare(user_id: "x", display_name: "س", distance_m: 1, duration_s: 1, moving_s: 1)
            api.history = [outing("h1", status: .ended, summaries: [mine]), outing("h2", status: .ended, summaries: [theirs])]
            let r = await deleter().run()
            XCTAssertEqual(r, .wipedLocally(leftOutings: 2), "status \(status)")
            XCTAssertEqual(api.calls, ["DELETE /me", "PATCH /me phone= avatar=", "GET /", "DELETE /h1/summary",
                                       "POST /o1/leave", "POST /o2/leave", "POST /gone/leave"])
            XCTAssertEqual(steps, ["unregisterPushOnServer", "forgetPush", "wipeLocal"], "token still valid: tell the server first")
            let n = r.notice!
            XCTAssertTrue(n.title.contains("لم يُحذف"), "honest: the account itself is not deleted")
            XCTAssertTrue(n.message.contains("الخادم لا يدعم حذف الحساب بعد"))
        }
    }

    func testOtherErrorsDeleteNothing() async {
        for e in [OutingAPIError(code: "network", status: 0), OutingAPIError(code: "rate_limited", status: 429),
                  OutingAPIError(code: "http_500", status: 500), OutingAPIError(code: "unauthorized", status: 401)] {
            reset()
            api.deleteError = e
            let r = await deleter().run()
            XCTAssertEqual(r, .failed(e.arabic), e.code)
            XCTAssertEqual(api.calls, ["DELETE /me"])
            XCTAssertEqual(steps, [], "nothing wiped on \(e.code): the person can try again")
            XCTAssertNil(r.notice)
        }
    }

    func testLocalWipeKeepsAppearanceAndOfflineAreas() {
        let d = UserDefaults(suiteName: "acct-\(UUID().uuidString)")!
        for k in LocalAccountData.keys { d.set("x", forKey: k) }
        d.set("dark", forKey: "sary.appearance.scheme")
        d.set(true, forKey: MapboxTelemetry.key)
        IdentityStore.save(Identity(token: "t".padding(toLength: 43, withPad: "t", startingAt: 0),
                                    user: PublicUser(id: "me", display_name: "أنا", avatar: nil, phone: nil)))
        XCTAssertNotNil(IdentityStore.load())
        LocalAccountData.wipe(defaults: d)
        XCTAssertNil(IdentityStore.load(), "Keychain identity gone")
        for k in LocalAccountData.keys { XCTAssertNil(d.object(forKey: k), k) }
        XCTAssertEqual(d.string(forKey: "sary.appearance.scheme"), "dark", "appearance stays")
        XCTAssertEqual(d.object(forKey: MapboxTelemetry.key) as? Bool, true)
        for k in [ShareMemory.consentKey, TripLogStore.key, InviteTokenStore.key, OnboardingProgress.key, PushRegistrar.tokenKey] {
            XCTAssertTrue(LocalAccountData.keys.contains(k), k)
        }
    }

    func testLocalWipeRemovesEverySaryKeyButDeviceSettings() {
        let d = UserDefaults(suiteName: "acct-all-\(UUID().uuidString)")!
        let personal = ["sary.ptt.channel.o1", "sary.ptt.muted.o1", "sary.live.context.v1", "sary.position",
                        "sary.groupAudio.state", "sary.media.state", "sary.outings.notify.v1", "sary.plan.localDestination.v1.o1",
                        "sary.someFutureKey.v9"]
        let kept = ["sary.appearance.v1", "sary.intro.lastShown", "sary.debug.apiBase", "sary.dev.unlocked"]
        for k in personal + kept { d.set("x", forKey: k) }
        d.set("other", forKey: "notSary.key")
        LocalAccountData.wipe(defaults: d)
        for k in personal { XCTAssertNil(d.object(forKey: k), k) }
        for k in kept { XCTAssertEqual(d.string(forKey: k), "x", k) }
        XCTAssertEqual(d.string(forKey: "notSary.key"), "other")
        XCTAssertTrue(LocalAccountData.allAccountKeys(in: d).isEmpty)
    }

    func testForgetDeviceStopsApnsWithoutCallingTheServer() async {
        final class Backend: PushBackend {
            var unregistered: [String] = []
            func apnsConfig() async throws -> OutingsAPI.ApnsConfig { .init(enabled: true, bundle_id: "sa.sary.albarq") }
            func registerApns(token: String, environment: String, bundleId: String) async throws {}
            func unregisterApns(token: String) async throws { unregistered.append(token) }
        }
        let backend = Backend()
        let system = PushRegistrarTests.FakeSystem()
        system.status = .authorized
        let d = UserDefaults(suiteName: "acct-push-\(UUID().uuidString)")!
        let r = PushRegistrar(backend: backend, system: system, defaults: d, bundleId: "sa.sary.albarq", environment: "sandbox")
        await r.register("ab".padding(toLength: 64, withPad: "ab", startingAt: 0), signedIn: true)
        XCTAssertEqual(r.state, .registered)
        r.forgetDevice()
        XCTAssertNil(r.registeredToken)
        XCTAssertEqual(system.unregisterCalls, 1)
        XCTAssertEqual(backend.unregistered, [], "the server already dropped it with the account")
        XCTAssertEqual(r.state, .notAsked)
        XCTAssertFalse(r.explained)
    }

    func testDemoModelDeletesAndReturnsToOnboarding() async {
        let m = AppModel(arguments: ["-demo", "-SaryScreen", "privacy"])
        XCTAssertNotNil(m.identity)
        let r = await m.deleteAccount()
        XCTAssertEqual(r, .deleted)
        XCTAssertNil(m.identity, "back to onboarding")
        XCTAssertNil(m.debugScreen)
        XCTAssertEqual(m.accountNotice, .deleted)
        XCTAssertFalse(OnboardingProgress.done)
    }
}

/// Build 20: signed in, closed the app, opened it → not signed in. The session lives in the
/// Keychain and must survive a relaunch, an offline start and a Keychain that cannot answer yet;
/// only an explicit sign-out deletes it.
@MainActor
final class SessionPersistenceTests: XCTestCase {
    final class FakeKeychain: IdentityKeychain {
        var data: Data?
        var status: OSStatus = errSecSuccess
        var deletes = 0
        func read() -> (status: OSStatus, data: Data?) {
            if status != errSecSuccess { return (status, nil) }
            return data == nil ? (errSecItemNotFound, nil) : (errSecSuccess, data)
        }
        func write(_ d: Data) -> OSStatus {
            if status != errSecSuccess { return status }
            data = d
            return errSecSuccess
        }
        func delete() -> OSStatus { deletes += 1; data = nil; return errSecSuccess }
    }

    private var saved: IdentityKeychain!
    private let me = Identity(token: String(repeating: "A", count: 43), user: PublicUser(id: "u-1", display_name: "أبو فهد", avatar: nil, phone: "+966501234567"))

    private var savedProtected: (() -> Bool)!

    override func setUp() {
        saved = IdentityStore.keychain
        savedProtected = IdentityStore.protectedDataAvailable
        IdentityStore.protectedDataAvailable = { true }
        IdentityStore.forgetCache()
    }

    override func tearDown() {
        IdentityStore.keychain = saved
        IdentityStore.protectedDataAvailable = savedProtected
        IdentityStore.forgetCache()
    }

    /// A «when unlocked» item (saved by an older build) is invisible while the phone is locked:
    /// the Keychain answers "not found". A quick relaunch then showed the welcome screen to a
    /// signed-in person. Now: not found + no protected data = wait (splash), never onboarding.
    final class HidingKeychain: IdentityKeychain {
        var data: Data?
        var hidden = false
        var writes = 0
        func read() -> (status: OSStatus, data: Data?) {
            if hidden || data == nil { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
        func write(_ d: Data) -> OSStatus { writes += 1; data = d; return errSecSuccess }
        func delete() -> OSStatus { data = nil; return errSecSuccess }
    }

    func testQuickRelaunchWithAHiddenItemWaitsThenSignsInNeverWelcome() {
        let k = HidingKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        k.hidden = true
        IdentityStore.protectedDataAvailable = { false }
        XCTAssertEqual(IdentityStore.read(), .unavailable(errSecItemNotFound), "not found while locked is not an answer")
        let m = AppModel(arguments: ["-SaryOffline"])
        XCTAssertNil(m.identity)
        XCTAssertTrue(m.identityPending, "splash, not the welcome screen")
        /* Unlocked / foreground: the same account comes back. */
        k.hidden = false
        IdentityStore.protectedDataAvailable = { true }
        m.retryIdentityRead()
        XCTAssertFalse(m.identityPending)
        XCTAssertEqual(m.identity, me)
    }

    func testAnEarlyNotFoundIsCorrectedWhenTheAppComesForward() {
        /* The race the protected-data check cannot see: "not found" with data reported available. */
        let k = HidingKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        k.hidden = true
        let m = AppModel(arguments: ["-SaryOffline"])
        XCTAssertNil(m.identity)
        k.hidden = false
        m.retryIdentityRead()
        XCTAssertEqual(m.identity, me, "the welcome screen does not stay over a real account")
    }

    func testAFoundItemIsRewrittenOnceToMoveItToAfterFirstUnlock() {
        let k = HidingKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        let before = k.writes
        _ = IdentityStore.read()
        _ = IdentityStore.read()
        XCTAssertEqual(k.writes, before + 1, "updated in place once per launch")
    }

    func testSignedOutStaysSignedOutOnForeground() {
        let k = HidingKeychain()
        IdentityStore.keychain = k
        let m = AppModel(arguments: ["-SaryOffline"])
        m.retryIdentityRead()
        XCTAssertNil(m.identity)
        XCTAssertFalse(m.identityPending, "nothing saved: onboarding, as before")
    }

    func testIdentitySurvivesARelaunch() {
        let k = FakeKeychain()
        IdentityStore.keychain = k
        XCTAssertEqual(IdentityStore.read(), .none)
        IdentityStore.save(me)
        IdentityStore.forgetCache() // the process is gone
        XCTAssertEqual(IdentityStore.read(), .found(me))
        var renamed = me
        renamed.user.display_name = "فهد"
        IdentityStore.save(renamed)
        XCTAssertEqual(k.deletes, 0, "a save updates in place: never delete-then-add")
        IdentityStore.forgetCache()
        XCTAssertEqual(IdentityStore.load(), renamed)
    }

    func testAKeychainThatCannotAnswerIsNotSignedOut() {
        let k = FakeKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        k.status = errSecInteractionNotAllowed // started by iOS before protected data is available
        XCTAssertEqual(IdentityStore.read(), .unavailable(errSecInteractionNotAllowed))
        XCTAssertNil(IdentityStore.load())
        XCTAssertNotNil(k.data, "nothing was deleted")
        k.status = errSecSuccess
        XCTAssertEqual(IdentityStore.read(), .found(me))
        XCTAssertEqual(IdentityStore.currentToken(), me.token)
        k.status = errSecInteractionNotAllowed
        XCTAssertEqual(IdentityStore.currentToken(), me.token, "requests keep the token this process already read")
    }

    func testRelaunchWithTheKeychainLockedWaitsInsteadOfOnboarding() async {
        let k = FakeKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        k.status = errSecInteractionNotAllowed
        let m = AppModel(arguments: ["-SaryOffline"])
        XCTAssertNil(m.identity)
        XCTAssertTrue(m.identityPending, "the splash stays; onboarding (a second account) never shows")
        /* Onboarding cannot make a new identity over the unreadable one. */
        let made = await m.createIdentity(name: "حساب جديد", phone: "")
        XCTAssertFalse(made)
        XCTAssertEqual(k.data.flatMap { try? JSONDecoder().decode(Identity.self, from: $0) }, me, "the real account is untouched")
        m.errorText = nil
        /* Protected data comes back: the same account, signed in. */
        k.status = errSecSuccess
        m.applyIdentityRead(IdentityStore.read())
        XCTAssertFalse(m.identityPending)
        XCTAssertEqual(m.identity, me)
    }

    func testOfflineRelaunchKeepsTheSession() {
        let k = FakeKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        let m = AppModel(arguments: ["-SaryOffline"])
        XCTAssertEqual(m.identity, me)
        XCTAssertTrue(m.signedIn)
        XCTAssertFalse(m.identityPending)
    }

    func testOnboardingAdoptsTheAccountAlreadyOnThisPhone() async {
        let k = FakeKeychain()
        IdentityStore.keychain = k
        let m = AppModel(arguments: ["-SaryOffline"])
        XCTAssertNil(m.identity)
        /* The account appears (e.g. it was unreadable when the app started). */
        IdentityStore.save(me)
        let ok = await m.createIdentity(name: "اسم ثاني", phone: "")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.identity, me, "no second identity over the real one")
    }

    func testOnlyAnExplicitSignOutDeletes() async {
        let k = FakeKeychain()
        IdentityStore.keychain = k
        IdentityStore.save(me)
        IdentityStore.forgetCache()
        let m = AppModel(arguments: ["-SaryOffline"])
        XCTAssertEqual(m.identity, me)
        await m.signOut()
        XCTAssertNil(m.identity)
        XCTAssertNil(k.data)
        IdentityStore.forgetCache()
        XCTAssertEqual(IdentityStore.read(), .none)
    }
}
